import AVFoundation
import Foundation
import Observation
import Speech

/// Push-to-talk speech capture: hold to listen, release to transcribe.
@MainActor
@Observable
final class VoiceController {
    enum Phase: Equatable {
        case idle
        case listening
        case finishing
        case failed(String)
    }

    var phase: Phase = .idle
    var transcript = ""
    var level: Float = 0

    /// Delivers the final transcript after release.
    @ObservationIgnored var onFinished: ((String) -> Void)?
    /// Called when a listening attempt ends in an error shown to the user.
    @ObservationIgnored var onFailed: (() -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let requestBox = RequestBox()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var taskGeneration = 0
    @ObservationIgnored private var usingOnDevice = false
    @ObservationIgnored private var retriedOnServer = false
    @ObservationIgnored private var lastError: Error?
    @ObservationIgnored private var releasedEarly = false
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?
    @ObservationIgnored private var failureReset: Task<Void, Never>?

    var isActive: Bool { phase == .listening || phase == .finishing }

    func begin(localeIdentifier: String) {
        guard !isActive else { return }
        failureReset?.cancel()
        releasedEarly = false
        retriedOnServer = false
        lastError = nil
        transcript = ""
        level = 0
        phase = .listening
        Task {
            guard await Self.ensurePermissions() else {
                fail("Allow Microphone and Speech Recognition for NotchClaw in System Settings › Privacy & Security.")
                return
            }
            guard phase == .listening else { return }
            if releasedEarly {
                // Released before the permission prompt resolved; nothing was recorded.
                phase = .idle
                return
            }
            startRecognition(localeIdentifier: localeIdentifier)
        }
    }

    func end() {
        guard phase == .listening else { return }
        guard requestBox.request != nil else {
            releasedEarly = true
            return
        }
        phase = .finishing
        stopAudio()
        requestBox.request?.endAudio()
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.deliver()
        }
    }

    func cancel() {
        taskGeneration += 1
        task?.cancel()
        stopAudio()
        cleanup()
        phase = .idle
    }

    private func startRecognition(localeIdentifier: String) {
        let locale = localeIdentifier.isEmpty ? Locale.current : Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            fail("Speech recognition isn't available for this language right now.")
            return
        }
        self.recognizer = recognizer

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No microphone input available.")
            return
        }
        startTask(onDevice: recognizer.supportsOnDeviceRecognition)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.makeTap(box: requestBox) { [weak self] level in self?.level = level })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            fail("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    private func startTask(onDevice: Bool) {
        guard let recognizer else { return }
        task?.cancel()
        taskGeneration += 1
        let generation = taskGeneration
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = onDevice
        usingOnDevice = onDevice
        requestBox.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler { [weak self] text, isFinal, error in
            self?.handleResult(text: text, isFinal: isFinal, error: error, generation: generation)
        })
    }

    private func handleResult(text: String?, isFinal: Bool, error: Error?, generation: Int) {
        guard generation == taskGeneration else { return }
        if let text, !text.isEmpty { transcript = text }
        if isFinal {
            if phase == .finishing { deliver() }
            return
        }
        guard let error else { return }
        lastError = error
        Log.error("Speech recognition error: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
        switch phase {
        case .listening:
            if usingOnDevice, !retriedOnServer, transcript.isEmpty {
                // On-device models can be missing; fall back to Apple's server recognizer.
                retriedOnServer = true
                startTask(onDevice: false)
            } else if transcript.isEmpty {
                fail(Self.friendly(error))
            }
        case .finishing:
            deliver()
        default:
            break
        }
    }

    private func deliver() {
        guard phase == .finishing else { return }
        finishTimeout?.cancel()
        let text = transcript.trimmed
        let error = lastError
        taskGeneration += 1
        cleanup()
        if text.isEmpty {
            fail(error.map(Self.friendly) ?? "Didn't catch that — hold the shortcut and try again.", resetAfter: 2.5)
            return
        }
        phase = .idle
        onFinished?(text)
    }

    private func fail(_ message: String, resetAfter: TimeInterval = 4) {
        taskGeneration += 1
        task?.cancel()
        stopAudio()
        cleanup()
        phase = .failed(message)
        onFailed?()
        failureReset?.cancel()
        failureReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(resetAfter))
            guard !Task.isCancelled, let self, case .failed = self.phase else { return }
            self.phase = .idle
        }
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        level = 0
    }

    private func cleanup() {
        task = nil
        requestBox.request = nil
        recognizer = nil
    }

    nonisolated static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        let text = ns.localizedDescription
        if text.localizedCaseInsensitiveContains("dictation") || text.localizedCaseInsensitiveContains("siri") {
            return "Turn on Dictation in System Settings › Keyboard to use voice."
        }
        if ns.code == 1110 { return "Didn't catch that — try again." }
        if ns.code == 1101 || ns.code == 1107 { return "Speech service is busy — try again." }
        return "Voice failed: \(text)"
    }

    /// Built outside the main actor: the audio engine calls this on its own thread.
    nonisolated private static func makeTap(
        box: RequestBox, onLevel: @escaping @MainActor (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            box.request?.append(buffer)
            let level = rms(buffer)
            Task { @MainActor in onLevel(level) }
        }
    }

    nonisolated private static func makeHandler(
        _ handler: @escaping @MainActor (String?, Bool, Error?) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in handler(text, isFinal, error) }
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        // Map roughly -50dB…0dB to 0…1.
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 50))
    }

    nonisolated static func ensurePermissions() async -> Bool {
        let mic: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = true
        case .notDetermined: mic = await AVCaptureDevice.requestAccess(for: .audio)
        default: mic = false
        }
        guard mic else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}

/// Thread-safe holder so the audio thread always appends to the current request.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }
}
