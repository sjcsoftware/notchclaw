import AppKit
import Foundation
import Network
import Observation

struct GatewayError: Error, LocalizedError, Equatable {
    var code: String
    var message: String
    var details: JSON?
    var retryAfterMs: Double?

    var errorDescription: String? { message }
    var detailCode: String? { details?["code"]?.string }

    static let notConnected = GatewayError(code: "NOT_CONNECTED", message: "Not connected to the gateway")
    static func timeout(_ what: String) -> GatewayError {
        GatewayError(code: "TIMEOUT", message: "\(what) timed out")
    }

    init(code: String, message: String, details: JSON? = nil, retryAfterMs: Double? = nil) {
        self.code = code
        self.message = message
        self.details = details
        self.retryAfterMs = retryAfterMs
    }

    init(frame: JSON?) {
        code = frame?["code"]?.string ?? "UNKNOWN"
        message = frame?["message"]?.text ?? "Gateway request failed"
        details = frame?["details"]
        retryAfterMs = frame?["retryAfterMs"]?.double
    }
}

enum ConnectionState: Equatable {
    /// Not configured, or deliberately stopped.
    case idle
    case connecting(attempt: Int)
    case connected
    /// Network or gateway unreachable. Retrying automatically.
    case offline(String)
    /// Gateway knows the device but an operator must approve it.
    case pairingRequired(requestId: String?)
    /// Credentials rejected. Waits for the user to fix settings.
    case authFailed(String)

    var isConnected: Bool { self == .connected }
}

/// WebSocket operator client for an OpenClaw gateway (protocol v4).
///
/// Handles the challenge/connect handshake with a signed device identity,
/// request/response correlation, event fan-out, tick watchdog, and fast
/// reconnects driven by network-path and wake notifications.
@MainActor
@Observable
final class GatewayClient {
    static let protocolVersion: Int64 = 4
    static let clientId = "openclaw-macos"
    static let clientMode = "ui"
    static let role = "operator"
    static let scopes = ["operator.read", "operator.write", "operator.approvals"]
    static let caps = ["usage-refreshing", "exec-approvals"]

    private(set) var state: ConnectionState = .idle
    private(set) var serverVersion: String?
    private(set) var grantedScopes: [String] = []
    private(set) var networkAvailable = true
    private(set) var lastError: String?

    @ObservationIgnored var onEvent: ((String, JSON) -> Void)?
    @ObservationIgnored var onConnected: (() -> Void)?

    @ObservationIgnored private let store: SecureStore
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    @ObservationIgnored private var challengeWaiter: CheckedContinuation<(String, Int64), Error>?
    @ObservationIgnored private var bufferedChallenge: (String, Int64)?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var lastFrameAt = Date()
    @ObservationIgnored private var lastPingAt = Date()
    @ObservationIgnored private var tickInterval: TimeInterval = 30
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var usedStoredDeviceToken = false
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(store: SecureStore = .shared) {
        self.store = store
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        startPathMonitor()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectNow(reason: "wake") }
        }
    }

    // MARK: Public API

    /// Applies new connection settings and (re)connects when they are usable.
    func configure(urlString: String, token: String) {
        let newURL = Self.normalizedURL(urlString)
        let changed = newURL != url || token != self.token
        url = newURL
        self.token = token
        guard newURL != nil else {
            stop()
            return
        }
        if changed || !state.isConnected {
            wantsConnection = true
            attempt = 0
            connectNow()
        }
    }

    func stop() {
        wantsConnection = false
        reconnectTask?.cancel()
        teardown(error: GatewayError.notConnected)
        state = .idle
    }

    /// Drops the current socket (if any) and connects immediately.
    func reconnectNow(reason: String) {
        guard wantsConnection, url != nil else { return }
        Log.info("Reconnecting now (\(reason))")
        attempt = 0
        connectNow()
    }

    func request(_ method: String, _ params: JSON = .object([:]), timeout: TimeInterval = 30) async throws -> JSON {
        guard state.isConnected, let ws = socket else { throw GatewayError.notConnected }
        return try await send(method, params, on: ws, timeout: timeout)
    }

    /// Normalizes user input like `host:18789`, `http://…`, or `wss://…` to a WebSocket URL.
    nonisolated static func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmed
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http://") { s = "ws://" + s.dropFirst("http://".count) }
        else if s.hasPrefix("https://") { s = "wss://" + s.dropFirst("https://".count) }
        else if !s.hasPrefix("ws://") && !s.hasPrefix("wss://") { s = "ws://" + s }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    var gatewayKey: String { url?.absoluteString ?? "" }

    /// Resolves a gateway-relative path (e.g. a media ticket URL) against the gateway's HTTP(S) origin.
    func httpURL(forPath path: String) -> URL? {
        url.flatMap { Self.httpURL(gateway: $0, path: path) }
    }

    nonisolated static func httpURL(gateway: URL, path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme == "https" || absolute.scheme == "http" { return absolute }
        guard var components = URLComponents(url: gateway, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else { return nil }
        return URL(string: path, relativeTo: origin)?.absoluteURL
    }

    // MARK: Connection lifecycle

    private func connectNow() {
        reconnectTask?.cancel()
        teardown(error: GatewayError(code: "RECONNECTING", message: "Reconnecting"))
        generation += 1
        let gen = generation
        Task { await self.performConnect(gen: gen) }
    }

    private func performConnect(gen: Int) async {
        guard let url, gen == generation else { return }
        state = .connecting(attempt: attempt)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 64 * 1024 * 1024
        socket = ws
        bufferedChallenge = nil
        lastFrameAt = Date()
        ws.resume()
        Task { await self.receiveLoop(ws, gen: gen) }

        do {
            let (nonce, ts) = try await waitForChallenge(timeout: 12)
            guard gen == generation else { return }
            let hello = try await send("connect", connectParams(nonce: nonce, signedAt: ts), on: ws, timeout: 20)
            guard gen == generation else { return }
            applyHello(hello)
            attempt = 0
            lastError = nil
            state = .connected
            startWatchdog()
            Log.info("Connected to gateway \(serverVersion ?? "?")")
            onConnected?()
        } catch {
            guard gen == generation else { return }
            handleConnectFailure(error)
        }
    }

    private func connectParams(nonce: String, signedAt: Int64) -> JSON {
        let identity = store.identity
        let stored = store.deviceToken(for: gatewayKey)
        let authToken = token.nonEmpty ?? stored?.token
        usedStoredDeviceToken = token.nonEmpty == nil && stored != nil

        var params: [String: JSON] = [
            "minProtocol": .int(Self.protocolVersion),
            "maxProtocol": .int(Self.protocolVersion),
            "client": [
                "id": .string(Self.clientId),
                "displayName": "NotchClaw",
                "version": .string(AppInfo.version),
                "platform": "macos",
                "deviceFamily": "Mac",
                "mode": .string(Self.clientMode),
                "instanceId": .string(InstanceID.value),
            ],
            "role": .string(Self.role),
            "scopes": JSON(Self.scopes),
            "caps": JSON(Self.caps),
            "locale": .string(Locale.preferredLanguages.first ?? "en-US"),
            "userAgent": .string("NotchClaw/\(AppInfo.version)"),
        ]
        if let authToken {
            params["auth"] = ["token": .string(authToken)]
        }
        let payload = DeviceAuthPayload.v2(
            deviceId: identity.deviceId, clientId: Self.clientId, clientMode: Self.clientMode,
            role: Self.role, scopes: Self.scopes, signedAtMs: signedAt, token: authToken, nonce: nonce)
        if let signature = identity.sign(payload), let publicKey = identity.publicKeyBase64Url {
            params["device"] = [
                "id": .string(identity.deviceId),
                "publicKey": .string(publicKey),
                "signature": .string(signature),
                "signedAt": .int(signedAt),
                "nonce": .string(nonce),
            ]
        }
        return .object(params)
    }

    private func applyHello(_ hello: JSON) {
        serverVersion = hello["server"]?["version"]?.string
        grantedScopes = hello["auth"]?["scopes"]?.array?.compactMap(\.string) ?? []
        if let ms = hello["policy"]?["tickIntervalMs"]?.double, ms > 0 {
            tickInterval = ms / 1000
        }
        if let deviceToken = hello["auth"]?["deviceToken"]?.text {
            store.setDeviceToken(
                StoredDeviceToken(
                    token: deviceToken, scopes: grantedScopes, deviceId: store.identity.deviceId,
                    updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)),
                for: gatewayKey)
        }
    }

    private func handleConnectFailure(_ error: Error) {
        let gwError = error as? GatewayError
        let detail = gwError?.detailCode ?? ""
        let message = gwError?.message ?? error.localizedDescription
        lastError = message
        teardown(error: error)
        Log.error("Connect failed: \(gwError?.code ?? "") \(detail) \(message)")

        if detail == "PAIRING_REQUIRED" || gwError?.code == "NOT_PAIRED" {
            state = .pairingRequired(requestId: gwError?.details?["requestId"]?.string)
            scheduleReconnect(after: 3)
            return
        }
        if detail.hasPrefix("AUTH_") || gwError?.code == "UNAUTHORIZED" || detail.hasPrefix("DEVICE_AUTH") {
            if usedStoredDeviceToken {
                // Stale device token: forget it and retry once with whatever is configured.
                store.setDeviceToken(nil, for: gatewayKey)
                usedStoredDeviceToken = false
                scheduleReconnect(after: 0.25)
                return
            }
            state = .authFailed(Self.describeAuthFailure(detail: detail, message: message))
            return
        }
        if detail == "OPERATOR_ACCESS_DENIED" {
            state = .authFailed("Gateway denied operator access. Ask the gateway admin to grant access.")
            scheduleReconnect(after: 30)
            return
        }
        state = .offline(networkAvailable ? Self.friendly(message) : "No network")
        if let retry = gwError?.retryAfterMs {
            scheduleReconnect(after: min(retry / 1000, 30))
        } else {
            scheduleReconnect()
        }
    }

    nonisolated static func describeAuthFailure(detail: String, message: String) -> String {
        switch detail {
        case "AUTH_TOKEN_MISMATCH": return "Gateway token doesn't match."
        case "AUTH_TOKEN_MISSING", "AUTH_REQUIRED": return "Gateway requires a token."
        case "AUTH_SCOPE_MISMATCH": return "Device not approved for these permissions. Re-pair on the gateway."
        default: return message
        }
    }

    nonisolated static func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("could not connect") || lower.contains("connection refused") { return "Gateway unreachable" }
        if lower.contains("timed out") { return "Gateway timed out" }
        if lower.contains("offline") || lower.contains("network connection was lost") { return "Connection lost" }
        if lower.contains("hostname") { return "Gateway host not found" }
        return message
    }

    private func handleDisconnect(reason: String) {
        guard wantsConnection else { return }
        Log.info("Disconnected: \(reason)")
        teardown(error: GatewayError(code: "DISCONNECTED", message: reason))
        if case .authFailed = state { return }
        if case .pairingRequired = state {} else {
            state = .offline(networkAvailable ? Self.friendly(reason) : "No network")
        }
        scheduleReconnect()
    }

    private func scheduleReconnect(after explicitDelay: TimeInterval? = nil) {
        guard wantsConnection else { return }
        reconnectTask?.cancel()
        // When the network is down the path monitor triggers the reconnect.
        guard networkAvailable else { return }
        let delay = explicitDelay ?? min(10, 0.25 * pow(2, Double(attempt))) + Double.random(in: 0...0.2)
        attempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connectNow()
        }
    }

    private func teardown(error: Error) {
        generation += 1
        watchdog?.invalidate()
        watchdog = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        challengeWaiter?.resume(throwing: error)
        challengeWaiter = nil
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting { cont.resume(throwing: error) }
    }

    // MARK: Frames

    private func receiveLoop(_ ws: URLSessionWebSocketTask, gen: Int) async {
        while gen == generation {
            do {
                let message = try await ws.receive()
                guard gen == generation else { return }
                lastFrameAt = Date()
                let data: Data
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                guard let frame = try? JSON.decode(data) else { continue }
                handleFrame(frame)
            } catch {
                guard gen == generation else { return }
                if case .connected = state {
                    handleDisconnect(reason: error.localizedDescription)
                } else {
                    handleConnectFailure(error)
                }
                return
            }
        }
    }

    private func handleFrame(_ frame: JSON) {
        switch frame["type"]?.string {
        case "res":
            guard let id = frame["id"]?.string, let cont = pending.removeValue(forKey: id) else { return }
            if frame["ok"]?.bool == true {
                cont.resume(returning: frame["payload"] ?? .null)
            } else {
                cont.resume(throwing: GatewayError(frame: frame["error"]))
            }
        case "event":
            guard let name = frame["event"]?.string else { return }
            let payload = frame["payload"] ?? .null
            if name == "connect.challenge" {
                guard let nonce = payload["nonce"]?.text, let ts = payload["ts"]?.int, ts >= 0 else { return }
                if let waiter = challengeWaiter {
                    challengeWaiter = nil
                    waiter.resume(returning: (nonce, ts))
                } else {
                    bufferedChallenge = (nonce, ts)
                }
                return
            }
            if name == "tick" { return }
            onEvent?(name, payload)
        default:
            break
        }
    }

    private func waitForChallenge(timeout: TimeInterval) async throws -> (String, Int64) {
        if let buffered = bufferedChallenge {
            bufferedChallenge = nil
            return buffered
        }
        let gen = generation
        return try await withCheckedThrowingContinuation { cont in
            challengeWaiter = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, gen == self.generation, let waiter = self.challengeWaiter else { return }
                self.challengeWaiter = nil
                waiter.resume(throwing: GatewayError.timeout("Gateway handshake"))
            }
        }
    }

    private func send(_ method: String, _ params: JSON, on ws: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> JSON {
        let id = UUID().uuidString
        let frame: JSON = ["type": "req", "id": .string(id), "method": .string(method), "params": params]
        let text = String(decoding: try frame.encoded(), as: UTF8.self)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            ws.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.failPending(id, error) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.failPending(id, GatewayError.timeout(method))
            }
        }
    }

    private func failPending(_ id: String, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: Liveness

    private func startWatchdog() {
        watchdog?.invalidate()
        lastPingAt = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLiveness() }
        }
    }

    private func checkLiveness() {
        guard state.isConnected, let ws = socket else { return }
        let silence = Date().timeIntervalSince(lastFrameAt)
        if silence > max(tickInterval * 2, 20) {
            handleDisconnect(reason: "Gateway went silent")
            return
        }
        if Date().timeIntervalSince(lastPingAt) >= 10 {
            lastPingAt = Date()
            probe(ws, timeout: 8)
        }
    }

    /// Pings the socket; a missing pong means the connection is dead.
    private func probe(_ ws: URLSessionWebSocketTask, timeout: TimeInterval) {
        let gen = generation
        let answered = PingFlag()
        ws.sendPing { [weak self] error in
            Task { @MainActor in
                answered.value = true
                guard let self, gen == self.generation else { return }
                if error != nil { self.handleDisconnect(reason: "Connection lost") }
                else { self.lastFrameAt = Date() }
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, gen == self.generation, !answered.value else { return }
            self.handleDisconnect(reason: "Connection lost")
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(available: available) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.notchclaw.path"))
    }

    private func networkChanged(available: Bool) {
        let was = networkAvailable
        networkAvailable = available
        guard wantsConnection else { return }
        if !available {
            if state != .idle {
                teardown(error: GatewayError(code: "OFFLINE", message: "No network"))
                if case .authFailed = state {} else { state = .offline("No network") }
            }
            reconnectTask?.cancel()
        } else if !was {
            // Network is back: reconnect immediately instead of waiting out backoff.
            if case .authFailed = state { return }
            reconnectNow(reason: "network restored")
        } else if state.isConnected, let ws = socket {
            // Interface changed (e.g. Wi-Fi switch): verify the socket quickly.
            probe(ws, timeout: 3)
        }
    }
}

/// Stable per-install identifier reported to the gateway for presence display.
enum InstanceID {
    static var value: String {
        let key = "instanceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}

@MainActor
private final class PingFlag {
    var value = false
}

#if DEBUG
extension GatewayClient {
    /// Debug-only: pretend to be connected for screenshot rendering.
    func simulateConnected(version: String) {
        state = .connected
        serverVersion = version
    }
}
#endif
