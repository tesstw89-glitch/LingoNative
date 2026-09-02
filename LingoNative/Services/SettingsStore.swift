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
    @Published var dragTokenAudioEnabled: Bool { didSet { save() } }
    @Published var hapticsEnabled: Bool { didSet { save() } }
    @Published var soundEffectsEnabled: Bool { didSet { save() } }
    @Published var showLemmaHints: Bool { didSet { save() } }
    @Published var dailyGoalXP: Int { didSet { save() } }
    @Published var speechRate: Double { didSet { save() } }
    @Published var darkModeEnabled: Bool { didSet { save() } }
    @Published var enhancedAnswerCheckingEnabled: Bool { didSet { save() } }
    @Published var nonHeadphoneModeEnabled: Bool { didSet { save() } }
    @Published var enabledExerciseTypes: Set<ExerciseType> { didSet { save() } }
    @Published private(set) var editorNotes: [String: String] = [:]

    static let runtimeSoundDefaultsKey = "lingoNative.runtime.soundEnabled.v1"
    static let runtimeElevenLabsDefaultsKey = "lingoNative.runtime.elevenLabsEnabled.v1"


    static let audioRequiredExerciseTypes: Set<ExerciseType> = [
        .listening,
        .listenWrite,
        .speaking
    ]

    var effectiveExerciseTypes: Set<ExerciseType> {
        guard nonHeadphoneModeEnabled else { return enabledExerciseTypes }

        let filtered = enabledExerciseTypes.subtracting(Self.audioRequiredExerciseTypes)
        if !filtered.isEmpty {
            return filtered
        }

        // Elsewhere an empty set means "all exercise types", so never return
        // empty while Non-headphone mode is active.
        return Set(ExerciseType.userSelectableCases)
            .subtracting(Self.audioRequiredExerciseTypes)
    }

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
        var dragTokenAudioEnabled: Bool?
        var hapticsEnabled: Bool
        var soundEffectsEnabled: Bool?
        var showLemmaHints: Bool
        var dailyGoalXP: Int
        var speechRate: Double
        var darkModeEnabled: Bool?
        var enhancedAnswerCheckingEnabled: Bool?
        var nonHeadphoneModeEnabled: Bool?
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
            dragTokenAudioEnabled = payload.dragTokenAudioEnabled ?? true
            hapticsEnabled = payload.hapticsEnabled
            soundEffectsEnabled = payload.soundEffectsEnabled ?? true
            showLemmaHints = payload.showLemmaHints
            dailyGoalXP = payload.dailyGoalXP
            speechRate = payload.speechRate
            darkModeEnabled = payload.darkModeEnabled ?? false
            enhancedAnswerCheckingEnabled = payload.enhancedAnswerCheckingEnabled ?? true
            nonHeadphoneModeEnabled = payload.nonHeadphoneModeEnabled ?? false
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
            dragTokenAudioEnabled = true
            hapticsEnabled = true
            soundEffectsEnabled = true
            showLemmaHints = true
            dailyGoalXP = 50
            speechRate = 0.46
            darkModeEnabled = false
            enhancedAnswerCheckingEnabled = true
            nonHeadphoneModeEnabled = false
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
        dragTokenAudioEnabled = true
        hapticsEnabled = true
        soundEffectsEnabled = true
        showLemmaHints = true
        dailyGoalXP = 50
        speechRate = 0.46
        darkModeEnabled = false
        enhancedAnswerCheckingEnabled = true
        nonHeadphoneModeEnabled = false
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
            dragTokenAudioEnabled: dragTokenAudioEnabled,
            hapticsEnabled: hapticsEnabled,
            soundEffectsEnabled: soundEffectsEnabled,
            showLemmaHints: showLemmaHints,
            dailyGoalXP: dailyGoalXP,
            speechRate: speechRate,
            darkModeEnabled: darkModeEnabled,
            enhancedAnswerCheckingEnabled: enhancedAnswerCheckingEnabled,
            nonHeadphoneModeEnabled: nonHeadphoneModeEnabled,
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


// MARK: - Local corpus text edits

struct TermTextEdit: Codable, Hashable {
    enum Kind: String, Codable {
        case phrase
        case lemma
    }

    let kind: Kind
    let originalForeign: String
    let originalEnglish: String
    var foreign: String
    var english: String
}

final class TermEditStore: ObservableObject {
    static let shared = TermEditStore()

    @Published private(set) var revision: Int = 0

    private let defaults: UserDefaults
    private let storageKey = "lingoNative.termTextEdits.v1"
    private let lock = NSLock()
    private var edits: [String: TermTextEdit]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
                [String: TermTextEdit].self,
                from: data
           ) {
            edits = decoded
        } else {
            edits = [:]
        }
    }

    static func phraseKey(
        course: LanguageCourse,
        phraseID: String
    ) -> String {
        "phrase:\(course.rawValue):\(phraseID)"
    }

    static func lemmaKey(
        course: LanguageCourse,
        foreign: String,
        english: String
    ) -> String {
        "lemma:\(course.rawValue):\(component(foreign))||\(component(english))"
    }

    func effectiveText(
        key: String,
        foreign: String,
        english: String
    ) -> (foreign: String, english: String) {
        lock.lock()
        let edit = edits[key]
        lock.unlock()

        guard let edit else {
            return (foreign, english)
        }

        return (edit.foreign, edit.english)
    }

    func hasEdit(forKey key: String) -> Bool {
        lock.lock()
        let exists = edits[key] != nil
        lock.unlock()
        return exists
    }

    func setPhrase(
        course: LanguageCourse,
        phraseID: String,
        originalForeign: String,
        originalEnglish: String,
        foreign: String,
        english: String
    ) {
        set(
            key: Self.phraseKey(
                course: course,
                phraseID: phraseID
            ),
            edit: TermTextEdit(
                kind: .phrase,
                originalForeign: originalForeign,
                originalEnglish: originalEnglish,
                foreign: foreign,
                english: english
            )
        )
    }

    func setLemma(
        course: LanguageCourse,
        originalForeign: String,
        originalEnglish: String,
        foreign: String,
        english: String
    ) {
        set(
            key: Self.lemmaKey(
                course: course,
                foreign: originalForeign,
                english: originalEnglish
            ),
            edit: TermTextEdit(
                kind: .lemma,
                originalForeign: originalForeign,
                originalEnglish: originalEnglish,
                foreign: foreign,
                english: english
            )
        )
    }

    func removeEdit(forKey key: String) {
        lock.lock()
        edits.removeValue(forKey: key)
        let snapshot = edits
        lock.unlock()

        persist(snapshot)
        revision &+= 1
    }

    func applying(
        course: LanguageCourse,
        to phrase: PhraseEntry
    ) -> PhraseEntry {
        let snapshot = snapshotForCourse(course)
        guard !snapshot.isEmpty else { return phrase }

        return Self.apply(
            course: course,
            phrase: phrase,
            edits: snapshot
        )
    }

    func applying(
        course: LanguageCourse,
        to entries: [PhraseEntry]
    ) -> [PhraseEntry] {
        let snapshot = snapshotForCourse(course)
        guard !snapshot.isEmpty else { return entries }

        return entries.map {
            Self.apply(
                course: course,
                phrase: $0,
                edits: snapshot
            )
        }
    }

    func applying(to corpus: Corpus) -> Corpus {
        let snapshot = snapshotForCourse(corpus.course)
        guard !snapshot.isEmpty else { return corpus }

        let editedEntries = corpus.entries.map {
            Self.apply(
                course: corpus.course,
                phrase: $0,
                edits: snapshot
            )
        }

        let entriesByID = Dictionary(
            uniqueKeysWithValues: editedEntries.map { ($0.id, $0) }
        )

        let editedUnits = corpus.units.map { unit in
            LearningUnit(
                id: unit.id,
                title: unit.title,
                topicID: unit.topicID,
                topicTitle: unit.topicTitle,
                topicIcon: unit.topicIcon,
                phrases: unit.phrases.map {
                    entriesByID[$0.id]
                        ?? Self.apply(
                            course: corpus.course,
                            phrase: $0,
                            edits: snapshot
                        )
                },
                phraseCount: unit.phraseCount
            )
        }

        return Corpus(
            course: corpus.course,
            entries: editedEntries,
            units: editedUnits,
            topics: corpus.topics,
            blockSize: corpus.blockSize
        )
    }

    // StarStore keys lemmas by their original text. If the learner edits
    // a lemma/chunk, resolve the edited form back to that original key.
    func canonicalLemmaStarKey(
        course: LanguageCourse,
        foreign: String,
        english: String
    ) -> String {
        let direct = Self.lemmaKey(
            course: course,
            foreign: foreign,
            english: english
        )

        lock.lock()
        defer { lock.unlock() }

        if edits[direct] != nil {
            return direct
        }

        let wantedForeign = Self.component(foreign)
        let wantedEnglish = Self.component(english)
        let prefix = "lemma:\(course.rawValue):"

        for (key, edit) in edits
        where key.hasPrefix(prefix) && edit.kind == .lemma {
            if Self.component(edit.foreign) == wantedForeign,
               Self.component(edit.english) == wantedEnglish {
                return key
            }
        }

        return direct
    }

    private func snapshotForCourse(
        _ course: LanguageCourse
    ) -> [String: TermTextEdit] {
        let phrasePrefix = "phrase:\(course.rawValue):"
        let lemmaPrefix = "lemma:\(course.rawValue):"

        lock.lock()
        let snapshot = edits.filter {
            $0.key.hasPrefix(phrasePrefix)
                || $0.key.hasPrefix(lemmaPrefix)
        }
        lock.unlock()

        return snapshot
    }

    private static func apply(
        course: LanguageCourse,
        phrase: PhraseEntry,
        edits: [String: TermTextEdit]
    ) -> PhraseEntry {
        let phraseKey = Self.phraseKey(
            course: course,
            phraseID: phrase.id
        )

        let phraseEdit = edits[phraseKey]

        let editedLemmas = phrase.lemmas.map { lemma -> Lemma in
            let lemmaKey = Self.lemmaKey(
                course: course,
                foreign: lemma.foreign,
                english: lemma.english
            )

            guard let edit = edits[lemmaKey] else {
                return lemma
            }

            return Lemma(
                foreign: edit.foreign,
                transliteration: lemma.transliteration,
                english: edit.english
            )
        }

        return PhraseEntry(
            id: phrase.id,
            topicID: phrase.topicID,
            topicTitle: phrase.topicTitle,
            foreign: phraseEdit?.foreign ?? phrase.foreign,
            transliteration: phrase.transliteration,
            tokens: phrase.tokens,
            english: phraseEdit?.english ?? phrase.english,
            lemmas: editedLemmas,
            context: phrase.context
        )
    }

    private func set(
        key: String,
        edit: TermTextEdit
    ) {
        lock.lock()
        edits[key] = edit
        let snapshot = edits
        lock.unlock()

        persist(snapshot)
        revision &+= 1
    }

    private func persist(
        _ snapshot: [String: TermTextEdit]
    ) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        defaults.set(data, forKey: storageKey)
    }

    private static func component(
        _ text: String
    ) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

