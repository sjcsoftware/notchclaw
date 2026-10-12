import CryptoKit
import Foundation

/// Ed25519 device identity the gateway pairs with. The device id is the
/// SHA-256 hex fingerprint of the raw public key, matching OpenClaw's clients.
struct DeviceIdentity: Codable, Equatable {
    var deviceId: String
    var publicKey: String  // base64 raw 32 bytes
    var privateKey: String  // base64 raw 32 bytes
    var createdAtMs: Int64

    static func generate() -> DeviceIdentity {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation
        return DeviceIdentity(
            deviceId: fingerprint(pub),
            publicKey: pub.base64EncodedString(),
            privateKey: key.rawRepresentation.base64EncodedString(),
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    static func fingerprint(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    var publicKeyBase64Url: String? {
        Data(base64Encoded: publicKey).map(Base64URL.encode)
    }

    func sign(_ payload: String) -> String? {
        guard let raw = Data(base64Encoded: privateKey),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
              let sig = try? key.signature(for: Data(payload.utf8))
        else { return nil }
        return Base64URL.encode(sig)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Builds the challenge-bound string the device signs during `connect`.
/// Format: `v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce`.
enum DeviceAuthPayload {
    static func v2(
        deviceId: String, clientId: String, clientMode: String, role: String,
        scopes: [String], signedAtMs: Int64, token: String?, nonce: String
    ) -> String {
        [
            "v2", deviceId, clientId, clientMode, role,
            scopes.joined(separator: ","), String(signedAtMs), token ?? "", nonce,
        ].joined(separator: "|")
    }
}

/// A device token the gateway issued after pairing, keyed per gateway URL.
struct StoredDeviceToken: Codable, Equatable {
    var token: String
    var scopes: [String]
    var deviceId: String
    var updatedAtMs: Int64
}

/// File-backed secrets under Application Support (mode 0600), mirroring how
/// OpenClaw itself stores device identity on disk.
final class SecureStore {
    static let shared = SecureStore()

    private struct Contents: Codable {
        var identity: DeviceIdentity?
        var gatewayToken: String?
        var deviceTokens: [String: StoredDeviceToken] = [:]
    }

    private let url: URL
    private var contents: Contents

    init(directory: URL = AppPaths.supportDirectory) {
        url = directory.appendingPathComponent("credentials.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Contents.self, from: data) {
            contents = decoded
        } else {
            contents = Contents()
        }
    }

    var identity: DeviceIdentity {
        if let existing = contents.identity { return existing }
        let fresh = DeviceIdentity.generate()
        contents.identity = fresh
        save()
        return fresh
    }

    var gatewayToken: String {
        get { contents.gatewayToken ?? "" }
        set {
            contents.gatewayToken = newValue.isEmpty ? nil : newValue
            save()
        }
    }

    func deviceToken(for gatewayKey: String) -> StoredDeviceToken? {
        guard let entry = contents.deviceTokens[gatewayKey], entry.deviceId == identity.deviceId else { return nil }
        return entry
    }

    func setDeviceToken(_ entry: StoredDeviceToken?, for gatewayKey: String) {
        contents.deviceTokens[gatewayKey] = entry
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(contents)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.error("Failed to save credentials: \(error.localizedDescription)")
        }
    }
}
