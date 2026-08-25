import Foundation
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    @Published var sessionLength: Int { didSet { save() } }
    @Published var heartsEnabled: Bool { didSet { save() } }
    @Published var soundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEnabled, forKey: Self.runtimeSoundDefaultsKey)
            save()
        }
    }
    @Published var elevenLabsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(elevenLabsEnabled, forKey: Self.runtimeElevenLabsDefaultsKey)
            save()
        }
    }
    @Published var autoplayAudio: Bool { didSet { save() } }
    @Published var hapticsEnabled: Bool { didSet { save() } }
    @Published var soundEffectsEnabled: Bool { didSet { save() } }
    @Published var showLemmaHints: Bool { didSet { save() } }
    @Published var dailyGoalXP: Int { didSet { save() } }
    @Published var speechRate: Double { didSet { save() } }
    @Published var darkModeEnabled: Bool { didSet { save() } }
    @Published var enhancedAnswerCheckingEnabled: Bool { didSet { save() } }
    @Published var enabledExerciseTypes: Set<ExerciseType> { didSet { save() } }
    @Published private(set) var editorNotes: [String: String] = [:]

    static let runtimeSoundDefaultsKey = "lingoNative.runtime.soundEnabled.v1"
    static let runtimeElevenLabsDefaultsKey = "lingoNative.runtime.elevenLabsEnabled.v1"

    static var runtimeSoundEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: runtimeSoundDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: runtimeSoundDefaultsKey)
    }

    static var runtimeElevenLabsEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: runtimeElevenLabsDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: runtimeElevenLabsDefaultsKey)
    }

    private let defaults: UserDefaults
    private let key = "lingoNative.settings.v2"
    private let editorNotesKey = "lingoNative.editorNotes.v1"

    private struct Payload: Codable {
        var sessionLength: Int
        var heartsEnabled: Bool
        var soundEnabled: Bool?
        var elevenLabsEnabled: Bool?
        var autoplayAudio: Bool
        var hapticsEnabled: Bool
        var soundEffectsEnabled: Bool?
        var showLemmaHints: Bool
        var dailyGoalXP: Int
        var speechRate: Double
        var darkModeEnabled: Bool?
        var enhancedAnswerCheckingEnabled: Bool?
        var enabledExerciseTypes: Set<ExerciseType>
        var listenWriteIntroduced: Bool?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let noteData = defaults.data(forKey: editorNotesKey),
           let savedNotes = try? JSONDecoder().decode([String: String].self, from: noteData) {
            editorNotes = savedNotes
        }

        if let data = defaults.data(forKey: key),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            sessionLength = payload.sessionLength
            heartsEnabled = payload.heartsEnabled
            soundEnabled = payload.soundEnabled ?? true
            elevenLabsEnabled = payload.elevenLabsEnabled ?? true
            autoplayAudio = payload.autoplayAudio
            hapticsEnabled = payload.hapticsEnabled
            soundEffectsEnabled = payload.soundEffectsEnabled ?? true
            showLemmaHints = payload.showLemmaHints
            dailyGoalXP = payload.dailyGoalXP
            speechRate = payload.speechRate
            darkModeEnabled = payload.darkModeEnabled ?? false
            enhancedAnswerCheckingEnabled = payload.enhancedAnswerCheckingEnabled ?? true
            var selectable = payload.enabledExerciseTypes.intersection(Set(ExerciseType.userSelectableCases))
            if payload.listenWriteIntroduced != true {
                selectable.insert(.listenWrite)
            }
            enabledExerciseTypes = selectable.isEmpty ? Set(ExerciseType.userSelectableCases) : selectable
        } else {
            sessionLength = 10
            heartsEnabled = true
            soundEnabled = true
            elevenLabsEnabled = true
            autoplayAudio = true
            hapticsEnabled = true
            soundEffectsEnabled = true
            showLemmaHints = true
            dailyGoalXP = 50
            speechRate = 0.46
            darkModeEnabled = false
            enhancedAnswerCheckingEnabled = true
            enabledExerciseTypes = Set(ExerciseType.userSelectableCases)
        }

        UserDefaults.standard.set(soundEnabled, forKey: Self.runtimeSoundDefaultsKey)
        UserDefaults.standard.set(elevenLabsEnabled, forKey: Self.runtimeElevenLabsDefaultsKey)
    }

    func reset() {
        sessionLength = 10
        heartsEnabled = true
        soundEnabled = true
        elevenLabsEnabled = true
        autoplayAudio = true
        hapticsEnabled = true
        soundEffectsEnabled = true
        showLemmaHints = true
        dailyGoalXP = 50
        speechRate = 0.46
        darkModeEnabled = false
        enhancedAnswerCheckingEnabled = true
        enabledExerciseTypes = Set(ExerciseType.userSelectableCases)
        save()
    }

    func toggleExercise(_ type: ExerciseType) {
        guard type != .introduction else { return }
        if enabledExerciseTypes.contains(type) {
            guard enabledExerciseTypes.count > 1 else { return }
            enabledExerciseTypes.remove(type)
        } else {
            enabledExerciseTypes.insert(type)
        }
    }

    func editorNote(for phrase: PhraseEntry, course: LanguageCourse) -> String? {
        let key = phrase.progressKey(course: course)
        guard let note = editorNotes[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty else {
            return nil
        }
        return note
    }

    func setEditorNote(_ note: String, for phrase: PhraseEntry, course: LanguageCourse) {
        let key = phrase.progressKey(course: course)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            editorNotes.removeValue(forKey: key)
        } else {
            editorNotes[key] = trimmed
        }

        if let data = try? JSONEncoder().encode(editorNotes) {
            defaults.set(data, forKey: editorNotesKey)
        }
    }

    private func save() {
        UserDefaults.standard.set(soundEnabled, forKey: Self.runtimeSoundDefaultsKey)
        UserDefaults.standard.set(elevenLabsEnabled, forKey: Self.runtimeElevenLabsDefaultsKey)

        let payload = Payload(
            sessionLength: sessionLength,
            heartsEnabled: heartsEnabled,
            soundEnabled: soundEnabled,
            elevenLabsEnabled: elevenLabsEnabled,
            autoplayAudio: autoplayAudio,
            hapticsEnabled: hapticsEnabled,
            soundEffectsEnabled: soundEffectsEnabled,
            showLemmaHints: showLemmaHints,
            dailyGoalXP: dailyGoalXP,
            speechRate: speechRate,
            darkModeEnabled: darkModeEnabled,
            enhancedAnswerCheckingEnabled: enhancedAnswerCheckingEnabled,
            enabledExerciseTypes: enabledExerciseTypes,
            listenWriteIntroduced: true
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Optional local AI model

enum LocalAIModelFiles {
    static let fileName = "Qwen3-4B-Q4_K_M.gguf"

    static var directoryURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("LingoNativeAI", isDirectory: true)
    }

    static var modelURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }
}

@MainActor
final class LocalAIModelStore: NSObject, ObservableObject {
    static let shared = LocalAIModelStore()

    enum DownloadState: Equatable {
        case notInstalled
        case downloading
        case installed
        case failed(String)
    }

    static let approximateDownloadSize = "2.5 GB"

    /// Public GGUF used by the local semantic answer checker.
    private static let remoteModelURL = URL(
        string: "https://huggingface.co/lmstudio-community/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf?download=true"
    )!

    @Published private(set) var state: DownloadState = .notInstalled
    @Published private(set) var downloadProgress: Double = 0

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession!

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: LocalAIModelFiles.modelURL.path)
    }

    var modelPath: String? {
        isInstalled ? LocalAIModelFiles.modelURL.path : nil
    }

    override private init() {
        super.init()

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = false
        configuration.timeoutIntervalForResource = 60 * 60 * 6

        session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )

        refresh()
    }

    func refresh() {
        state = isInstalled ? .installed : .notInstalled
        if isInstalled {
            downloadProgress = 1
        }
    }

    func downloadModel() {
        guard !isInstalled, downloadTask == nil else { return }

        downloadProgress = 0
        state = .downloading

        let task = session.downloadTask(with: Self.remoteModelURL)
        task.taskDescription = LocalAIModelFiles.fileName
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = 0
        state = isInstalled ? .installed : .notInstalled
    }

    func removeModel() {
        cancelDownload()
        try? FileManager.default.removeItem(at: LocalAIModelFiles.modelURL)
        downloadProgress = 0
        state = .notInstalled
    }
}

extension LocalAIModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))

        Task { @MainActor [weak self] in
            self?.downloadProgress = progress
            self?.state = .downloading
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try LocalAIModelFiles.prepareDirectory()

            let destination = LocalAIModelFiles.modelURL
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            Task { @MainActor [weak self] in
                self?.downloadTask = nil
                self?.downloadProgress = 1
                self?.state = .installed
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.downloadTask = nil
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }

        Task { @MainActor [weak self] in
            self?.downloadTask = nil
            self?.state = .failed(error.localizedDescription)
        }
    }
}
