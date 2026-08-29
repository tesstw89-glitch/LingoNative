import AVFoundation
import CryptoKit
import Foundation
import Speech
import SwiftUI

@MainActor
final class SpeechSynthesizer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var elevenLabsPlayer: AVAudioPlayer?
    private var elevenLabsTask: Task<Void, Never>?

    @Published private(set) var isSpeaking = false

    /// Headphone Mode owns one playAndRecord session for the whole run.
    /// When true, TTS must not replace that session with playback-only audio.
    var preservesActiveAudioSession = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, course: LanguageCourse, rate: Double = 0.48, volume: Float = 1.0) {
        let cleaned = Self.stripParentheses(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return }

        guard SettingsStore.runtimeSoundEnabled else {
            stop()
            return
        }

        if course == .arabic {
            if SettingsStore.runtimeElevenLabsEnabled {
                speakArabicWithElevenLabs(cleaned, rate: rate, volume: volume)
            } else {
                speakWithSystemVoice(cleaned, course: .arabic, rate: rate, volume: volume)
            }
            return
        }

        speakWithSystemVoice(cleaned, course: course, rate: rate, volume: volume)
    }

    func speakEnglish(_ text: String, rate: Double = 0.48, volume: Float = 1.0) {
        let cleaned = Self.stripParentheses(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return }

        guard SettingsStore.runtimeSoundEnabled else {
            stop()
            return
        }

        if let cueName = Self.bundledEnglishCueName(for: cleaned),
           playBundledCue(named: cueName, volume: volume) {
            return
        }

        speakWithSystemVoice(
            cleaned,
            localeIdentifier: "en-GB",
            rate: rate,
            volume: volume
        )
    }

    func stop() {
        elevenLabsTask?.cancel()
        elevenLabsTask = nil

        if elevenLabsPlayer?.isPlaying == true {
            elevenLabsPlayer?.stop()
        }
        elevenLabsPlayer = nil

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        isSpeaking = false
        releaseAudioSessionAfterTTS()
    }

    private static func bundledEnglishCueName(for text: String) -> String? {
        switch text {
        case "Correct!":
            return "Correct"
        case "Exercise done!":
            return "Exercise_Finished"
        default:
            return nil
        }
    }

    @discardableResult
    private func playBundledCue(named resourceName: String, volume: Float) -> Bool {
        let possibleURLs = [
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "mp3",
                subdirectory: "TopicData/HeadphoneCues"
            ),
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "mp3",
                subdirectory: "HeadphoneCues"
            ),
            Bundle.main.url(forResource: resourceName, withExtension: "mp3")
        ]

        guard let url = possibleURLs.compactMap({ $0 }).first else {
            print("⚠️ Bundled headphone cue not found: \(resourceName).mp3")
            return false
        }

        do {
            configureAudioSessionForTTS()

            elevenLabsTask?.cancel()
            elevenLabsTask = nil
            elevenLabsPlayer?.stop()
            elevenLabsPlayer = nil

            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = max(0, min(volume, 1))
            player.prepareToPlay()
            elevenLabsPlayer = player
            isSpeaking = true

            guard player.play() else {
                elevenLabsPlayer = nil
                isSpeaking = false
                return false
            }

            return true
        } catch {
            elevenLabsPlayer = nil
            isSpeaking = false
            print("⚠️ Bundled headphone cue playback error:", error.localizedDescription)
            return false
        }
    }

    private func speakArabicWithElevenLabs(_ text: String, rate: Double, volume: Float) {
        guard SettingsStore.runtimeSoundEnabled else { return }
        guard SettingsStore.runtimeElevenLabsEnabled else {
            speakWithSystemVoice(text, course: .arabic, rate: rate, volume: volume)
            return
        }

        guard let configuration = ElevenLabsConfiguration.current else {
            print("⚠️ ElevenLabs Arabic TTS is not configured. Add ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID to the Xcode Run scheme environment.")
            speakWithSystemVoice(text, course: .arabic, rate: rate, volume: volume)
            return
        }

        configureAudioSessionForTTS()

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        elevenLabsTask?.cancel()
        elevenLabsPlayer?.stop()
        elevenLabsPlayer = nil
        isSpeaking = true

        let cacheURL = elevenLabsCacheURL(
            text: text,
            voiceID: configuration.voiceID,
            modelID: configuration.modelID
        )

        if FileManager.default.fileExists(atPath: cacheURL.path) {
            playElevenLabsAudio(at: cacheURL, rate: rate, volume: volume)
            return
        }

        elevenLabsTask = Task { [weak self] in
            guard let self else { return }

            do {
                let audioData = try await self.generateElevenLabsSpeech(
                    text: text,
                    configuration: configuration
                )

                guard !Task.isCancelled else { return }

                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try audioData.write(to: cacheURL, options: .atomic)

                guard !Task.isCancelled else { return }
                self.playElevenLabsAudio(at: cacheURL, rate: rate, volume: volume)
            } catch is CancellationError {
                return
            } catch {
                self.isSpeaking = false
                print("⚠️ ElevenLabs TTS error:", error.localizedDescription)
            }
        }
    }

    private func generateElevenLabsSpeech(
        text: String,
        configuration: ElevenLabsConfiguration
    ) async throws -> Data {
        guard let url = URL(
            string: "https://api.elevenlabs.io/v1/text-to-speech/\(configuration.voiceID)?output_format=mp3_44100_128"
        ) else {
            throw ElevenLabsError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let payload = ElevenLabsRequest(
            text: text,
            modelID: configuration.modelID
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown ElevenLabs response"
            throw ElevenLabsError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        guard !data.isEmpty else {
            throw ElevenLabsError.emptyAudio
        }

        return data
    }

    private func playElevenLabsAudio(at url: URL, rate: Double, volume: Float) {
        do {
            configureAudioSessionForTTS()

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = Self.elevenLabsPlaybackRate(from: rate)
            player.volume = max(0, min(volume, 1))
            player.prepareToPlay()
            isSpeaking = true
            player.play()
            elevenLabsPlayer = player
        } catch {
            isSpeaking = false
            print("⚠️ ElevenLabs playback error:", error.localizedDescription)
        }
    }

    private func elevenLabsCacheURL(text: String, voiceID: String, modelID: String) -> URL {
        let cacheKey = "\(voiceID)|\(modelID)|\(text)"
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined() + ".mp3"

        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ElevenLabsTTS", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private static func elevenLabsPlaybackRate(from appRate: Double) -> Float {
        // The app's existing speech-rate control is centred around 0.48.
        // Adjust cached audio locally so changing playback speed does not spend
        // more ElevenLabs credits or create duplicate generations.
        Float(min(max(appRate / 0.48, 0.75), 1.25))
    }

    private func speakWithSystemVoice(_ text: String, course: LanguageCourse, rate: Double, volume: Float) {
        speakWithSystemVoice(
            text,
            localeIdentifier: course.speechLocaleIdentifier,
            rate: rate,
            volume: volume
        )
    }

    private func speakWithSystemVoice(
        _ text: String,
        localeIdentifier: String,
        rate: Double,
        volume: Float
    ) {
        configureAudioSessionForTTS()

        elevenLabsTask?.cancel()
        elevenLabsPlayer?.stop()
        elevenLabsPlayer = nil

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice(for: localeIdentifier)
        utterance.rate = Float(min(max(rate, 0.30), 0.60))
        utterance.volume = max(0, min(volume, 1))
        utterance.pitchMultiplier = 1.0

        isSpeaking = true
        synthesizer.speak(utterance)
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

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.synthesizer.isSpeaking {
                self.isSpeaking = false
                self.releaseAudioSessionAfterTTS()
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.synthesizer.isSpeaking {
                self.isSpeaking = false
                self.releaseAudioSessionAfterTTS()
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.elevenLabsPlayer === player {
                self.isSpeaking = false
                self.releaseAudioSessionAfterTTS()
            }
        }
    }

    private func configureAudioSessionForTTS() {
        if preservesActiveAudioSession { return }

        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )

            try session.setActive(true)
        } catch {
            print("⚠️ Audio session (TTS) error:", error.localizedDescription)
        }
    }

    private func releaseAudioSessionAfterTTS() {
        guard !preservesActiveAudioSession else { return }

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            print("⚠️ Audio session release error:", error.localizedDescription)
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

private struct ElevenLabsConfiguration {
    let apiKey: String
    let voiceID: String
    let modelID: String

    static var current: ElevenLabsConfiguration? {
        let environment = ProcessInfo.processInfo.environment

        guard let apiKey = environment["ELEVENLABS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty,
              let voiceID = environment["ELEVENLABS_VOICE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !voiceID.isEmpty else {
            return nil
        }

        let modelID = environment["ELEVENLABS_MODEL_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ElevenLabsConfiguration(
            apiKey: apiKey,
            voiceID: voiceID,
            modelID: (modelID?.isEmpty == false ? modelID! : "eleven_multilingual_v2")
        )
    }
}

private struct ElevenLabsRequest: Encodable {
    let text: String
    let modelID: String

    enum CodingKeys: String, CodingKey {
        case text
        case modelID = "model_id"
    }
}

private enum ElevenLabsError: LocalizedError {
    case invalidURL
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not create the ElevenLabs URL."
        case .invalidResponse:
            return "ElevenLabs returned an invalid response."
        case let .requestFailed(statusCode, message):
            return "ElevenLabs returned HTTP \(statusCode): \(message)"
        case .emptyAudio:
            return "ElevenLabs returned an empty audio file."
        }
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
            try audioSession.setCategory(
                .record,
                mode: .measurement,
                options: [.duckOthers, .allowBluetooth]
            )
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

private final class ContinuousSpeechBufferRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var enabled = false

    func route(
        to request: SFSpeechAudioBufferRecognitionRequest?,
        enabled: Bool
    ) {
        lock.lock()
        self.request = request
        self.enabled = enabled
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = enabled ? request : nil
        lock.unlock()
        request?.append(buffer)
    }
}

@MainActor
final class ContinuousSpeechRecognizerService: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?
    @Published private(set) var isSessionActive = false

    private let audioEngine = AVAudioEngine()
    private let router = ContinuousSpeechBufferRouter()

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInputTap = false

    func startSession(localeIdentifier: String) async -> Bool {
        if isSessionActive { return true }

        transcript = ""
        errorMessage = nil

        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            errorMessage = "Speech recognition permission is needed for headphone mode."
            return false
        }

        let microphoneAllowed = await requestMicrophonePermission()
        guard microphoneAllowed else {
            errorMessage = "Microphone permission is needed for headphone mode."
            return false
        }

        guard let recognizer = SFSpeechRecognizer(
            locale: Locale(identifier: localeIdentifier)
        ) else {
            errorMessage = "Speech recognition is not available for this language."
            return false
        }

        guard recognizer.isAvailable else {
            errorMessage = "Speech recognition is temporarily unavailable."
            return false
        }

        self.recognizer = recognizer

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.duckOthers, .allowBluetooth, .defaultToSpeaker]
            )
            try audioSession.setActive(true)

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: format
            ) { [router] buffer, _ in
                router.append(buffer)
            }
            hasInputTap = true

            audioEngine.prepare()
            try audioEngine.start()

            isSessionActive = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            endSession()
            return false
        }
    }

    func beginRecognition() {
        guard isSessionActive,
              let recognizer,
              recognizer.isAvailable else {
            errorMessage = "Speech recognition is temporarily unavailable."
            return
        }

        stopRecognitionTask()
        transcript = ""
        errorMessage = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        recognitionRequest = request
        router.route(to: request, enabled: true)

        recognitionTask = recognizer.recognitionTask(with: request) {
            [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }

                if let error {
                    if self.transcript.isEmpty {
                        self.errorMessage = error.localizedDescription
                    }
                    self.router.route(to: nil, enabled: false)
                    self.isRecording = false
                }
            }
        }

        isRecording = true
    }

    /// Recognition pauses between prompts, but the microphone engine and
    /// playAndRecord session stay active so lock-screen execution continues.
    func pauseRecognition() {
        stopRecognitionTask()
        transcript = ""
        errorMessage = nil
    }

    func endSession() {
        stopRecognitionTask()

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }

        isSessionActive = false
        recognizer = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func stopRecognitionTask() {
        router.route(to: nil, enabled: false)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    private func requestSpeechAuthorization() async
        -> SFSpeechRecognizerAuthorizationStatus {
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
