import AVFoundation
import Speech
import SwiftUI

@MainActor
final class SpeechSynthesizer: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, course: LanguageCourse, rate: Double = 0.48, volume: Float = 1.0) {
        let cleaned = Self.stripParentheses(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return }

        configureAudioSessionForTTS()

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = bestVoice(for: course.speechLocaleIdentifier)
        utterance.rate = Float(min(max(rate, 0.30), 0.60))
        utterance.volume = max(0, min(volume, 1))
        utterance.pitchMultiplier = 1.0

        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func bestVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let prefix = languageCodePrefix(for: languageCode)
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }

        // Prefer the requested regional locale when an upgraded voice exists.
        if let exactPremium = voices.first(where: {
            $0.language == languageCode && $0.quality == .premium
        }) {
            return exactPremium
        }

        if let exactEnhanced = voices.first(where: {
            $0.language == languageCode && $0.quality == .enhanced
        }) {
            return exactEnhanced
        }

        // This mirrors LanguageTrainer's behaviour: use the best installed
        // voice for the language before falling back to the system default.
        if let premium = voices.first(where: { $0.quality == .premium }) {
            return premium
        }

        if let enhanced = voices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }

        return AVSpeechSynthesisVoice(language: languageCode) ?? voices.first
    }

    private func languageCodePrefix(for languageCode: String) -> String {
        if languageCode.hasPrefix("fr") { return "fr" }
        if languageCode.hasPrefix("es") { return "es" }
        return languageCode
    }

    private func configureAudioSessionForTTS() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetooth, .mixWithOthers]
            )
            try session.setActive(true)
        } catch {
            print("⚠️ Audio session (TTS) error:", error.localizedDescription)
        }
    }

    static func stripParentheses(_ text: String) -> String {
        var output = text

        while let start = output.firstIndex(of: "("),
              let end = output[start...].firstIndex(of: ")") {
            output.removeSubrange(start...end)
        }

        while output.contains("  ") {
            output = output.replacingOccurrences(of: "  ", with: " ")
        }

        return output
    }
}

@MainActor
final class SpeechRecognizerService: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInputTap = false

    func start(localeIdentifier: String) async {
        stop()
        transcript = ""
        errorMessage = nil

        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            errorMessage = "Speech recognition permission is needed for speaking practice."
            return
        }

        let microphoneAllowed = await requestMicrophonePermission()
        guard microphoneAllowed else {
            errorMessage = "Microphone permission is needed for speaking practice."
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            errorMessage = "Speech recognition is not available for this language."
            return
        }
        guard recognizer.isAvailable else {
            errorMessage = "Speech recognition is temporarily unavailable."
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            hasInputTap = true

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal {
                            self.stop()
                        }
                    }
                    if let error {
                        if self.transcript.isEmpty {
                            self.errorMessage = error.localizedDescription
                        }
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
