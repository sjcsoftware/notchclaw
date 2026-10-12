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

    internal(set) var phase: Phase = .idle
    internal(set) var transcript = ""
    internal(set) var level: Float = 0

    /// Delivers the final transcript after release (empty if nothing was heard).
    @ObservationIgnored var onFinished: ((String) -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var releasedEarly = false
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?
    @ObservationIgnored private var failureReset: Task<Void, Never>?

    var isActive: Bool { phase == .listening || phase == .finishing }

    func begin(localeIdentifier: String) {
        guard !isActive else { return }
        releasedEarly = false
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
                // Released before permissions resolved; nothing was recorded.
                phase = .idle
                return
            }
            startRecognition(localeIdentifier: localeIdentifier)
        }
    }

    func end() {
        switch phase {
        case .listening:
            guard request != nil else {
                releasedEarly = true
                return
            }
            phase = .finishing
            stopAudio()
            request?.endAudio()
            finishTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                self?.deliver()
            }
        default:
            break
        }
    }

    func cancel() {
        task?.cancel()
        stopAudio()
        cleanup()
        phase = .idle
    }

    private func startRecognition(localeIdentifier: String) {
        let locale = localeIdentifier.isEmpty ? Locale.current : Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            fail("Speech recognition isn't available for this language.")
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No microphone input available.")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor in self?.level = level }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            fail("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if isFinal || (failed && self.phase == .finishing) {
                    self.deliver()
                } else if failed, self.phase == .listening, self.transcript.isEmpty {
                    // Recognition can error transiently while still listening; keep going.
                }
            }
        }
    }

    private func deliver() {
        guard phase == .finishing else { return }
        finishTimeout?.cancel()
        let text = transcript.trimmed
        cleanup()
        phase = .idle
        onFinished?(text)
    }

    private func fail(_ message: String) {
        stopAudio()
        cleanup()
        phase = .failed(message)
        failureReset?.cancel()
        failureReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
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
        request = nil
        recognizer = nil
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

    static func ensurePermissions() async -> Bool {
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
