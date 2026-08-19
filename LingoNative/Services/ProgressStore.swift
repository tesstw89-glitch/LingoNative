import Foundation
import Combine

@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var completedNodeIDs: Set<String>
    @Published private(set) var hearts: Int
    @Published private(set) var xp: Int
    @Published private(set) var phraseProgress: [String: PhraseProgress]
    @Published private(set) var bookmarkedPhraseKeys: Set<String>
    @Published private(set) var dailyActivity: [String: DailyActivity]
    @Published private(set) var savedLessonSessions: [String: SavedLessonSession]

    private let defaults: UserDefaults
    private let completedKey = "completedNodeIDs"
    private let heartsKey = "hearts"
    private let xpKey = "xp"
    private let phraseProgressKey = "phraseProgress.v2"
    private let bookmarksKey = "bookmarkedPhraseKeys"
    private let dailyActivityKey = "dailyActivity.v2"
    private let savedLessonsKey = "savedLessonSessions.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        completedNodeIDs = Set(defaults.stringArray(forKey: completedKey) ?? [])
        hearts = defaults.object(forKey: heartsKey) == nil ? 5 : defaults.integer(forKey: heartsKey)
        xp = defaults.integer(forKey: xpKey)
        bookmarkedPhraseKeys = Set(defaults.stringArray(forKey: bookmarksKey) ?? [])

        if let data = defaults.data(forKey: phraseProgressKey),
           let decoded = try? JSONDecoder().decode([String: PhraseProgress].self, from: data) {
            phraseProgress = decoded
        } else {
            phraseProgress = [:]
        }

        if let data = defaults.data(forKey: dailyActivityKey),
           let decoded = try? JSONDecoder().decode([String: DailyActivity].self, from: data) {
            dailyActivity = decoded
        } else {
            dailyActivity = [:]
        }

        if let data = defaults.data(forKey: savedLessonsKey),
           let decoded = try? JSONDecoder().decode([String: SavedLessonSession].self, from: data) {
            savedLessonSessions = decoded
        } else {
            savedLessonSessions = [:]
        }
    }

    func isCompleted(_ nodeID: String) -> Bool {
        completedNodeIDs.contains(nodeID)
    }

    func complete(nodeID: String, earnedXP: Int) {
        completedNodeIDs.insert(nodeID)
        savedLessonSessions.removeValue(forKey: nodeID)
        addXP(earnedXP)
        var today = dailyActivity[todayKey] ?? DailyActivity()
        today.sessions += 1
        dailyActivity[todayKey] = today
        persist()
    }

    func recordPracticeSession(earnedXP: Int, restoreHeart: Bool = true) {
        addXP(earnedXP)
        if restoreHeart {
            hearts = min(5, hearts + 1)
        }
        var today = dailyActivity[todayKey] ?? DailyActivity()
        today.sessions += 1
        dailyActivity[todayKey] = today
        persist()
    }

    func recordAttempt(course: LanguageCourse, phrase: PhraseEntry, correct: Bool) {
        let key = phrase.progressKey(course: course)
        var stats = phraseProgress[key] ?? PhraseProgress()
        stats.seen += 1
        stats.lastPractised = Date()
        if correct {
            stats.correct += 1
        } else {
            stats.wrong += 1
        }
        phraseProgress[key] = stats

        var today = dailyActivity[todayKey] ?? DailyActivity()
        if correct {
            today.correct += 1
        } else {
            today.wrong += 1
        }
        dailyActivity[todayKey] = today
        persist()
    }

    func stats(course: LanguageCourse, phrase: PhraseEntry) -> PhraseProgress {
        phraseProgress[phrase.progressKey(course: course)] ?? PhraseProgress()
    }

    func isBookmarked(course: LanguageCourse, phrase: PhraseEntry) -> Bool {
        bookmarkedPhraseKeys.contains(phrase.progressKey(course: course))
    }

    func toggleBookmark(course: LanguageCourse, phrase: PhraseEntry) {
        let key = phrase.progressKey(course: course)
        if bookmarkedPhraseKeys.contains(key) {
            bookmarkedPhraseKeys.remove(key)
        } else {
            bookmarkedPhraseKeys.insert(key)
        }
        persist()
    }

    func bookmarkedPhrases(course: LanguageCourse, from entries: [PhraseEntry]) -> [PhraseEntry] {
        entries.filter { isBookmarked(course: course, phrase: $0) }
    }

    func phrasesWithMistakes(course: LanguageCourse, from entries: [PhraseEntry]) -> [PhraseEntry] {
        entries
            .filter { stats(course: course, phrase: $0).wrong > 0 }
            .sorted {
                let lhs = stats(course: course, phrase: $0)
                let rhs = stats(course: course, phrase: $1)
                if lhs.wrong == rhs.wrong { return lhs.mastery < rhs.mastery }
                return lhs.wrong > rhs.wrong
            }
    }

    func weakestPhrases(course: LanguageCourse, from entries: [PhraseEntry], limit: Int = 100) -> [PhraseEntry] {
        let practised = entries.filter { stats(course: course, phrase: $0).seen > 0 }
        let source = practised.isEmpty ? entries : practised
        return Array(source.sorted {
            stats(course: course, phrase: $0).mastery < stats(course: course, phrase: $1).mastery
        }.prefix(limit))
    }

    @discardableResult
    func loseHeart() -> Int {
        hearts = max(0, hearts - 1)
        persist()
        return hearts
    }

    func gainHeart() {
        hearts = min(5, hearts + 1)
        persist()
    }

    func refillHearts() {
        hearts = 5
        persist()
    }

    @discardableResult
    func buyHeart(cost: Int = 100) -> Bool {
        guard hearts < 5, xp >= cost else { return false }
        xp -= cost
        hearts += 1
        persist()
        return true
    }

    func savedLessonSession(for nodeID: String) -> SavedLessonSession? {
        savedLessonSessions[nodeID]
    }

    func saveLessonSession(_ session: SavedLessonSession) {
        guard !completedNodeIDs.contains(session.nodeID) else { return }
        savedLessonSessions[session.nodeID] = session
        persist()
    }

    func clearSavedLessonSession(nodeID: String) {
        guard savedLessonSessions.removeValue(forKey: nodeID) != nil else { return }
        persist()
    }

    func lessonProgress(nodeID: String) -> Double {
        if completedNodeIDs.contains(nodeID) { return 1 }
        return savedLessonSessions[nodeID]?.progress ?? 0
    }

    var todayXP: Int {
        dailyActivity[todayKey]?.xp ?? 0
    }

    var todayActivity: DailyActivity {
        dailyActivity[todayKey] ?? DailyActivity()
    }

    var totalCorrect: Int {
        phraseProgress.values.reduce(0) { $0 + $1.correct }
    }

    var totalWrong: Int {
        phraseProgress.values.reduce(0) { $0 + $1.wrong }
    }

    var practisedPhraseCount: Int {
        phraseProgress.values.filter { $0.seen > 0 }.count
    }

    var currentStreak: Int {
        let calendar = Calendar.current
        var streak = 0
        var date = Date()

        if activity(on: date) == nil,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: date) {
            date = yesterday
        }

        while activity(on: date) != nil {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return streak
    }

    var longestStreak: Int {
        let activeDates = dailyActivity
            .filter { $0.value.sessions > 0 || $0.value.correct > 0 || $0.value.wrong > 0 }
            .keys
            .compactMap { Self.dayFormatter.date(from: $0) }
            .sorted()

        guard !activeDates.isEmpty else { return 0 }
        let calendar = Calendar.current
        var longest = 1
        var current = 1

        for index in 1..<activeDates.count {
            let previous = activeDates[index - 1]
            let date = activeDates[index]
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: previous), to: calendar.startOfDay(for: date)).day ?? 0
            if days == 1 {
                current += 1
                longest = max(longest, current)
            } else if days > 1 {
                current = 1
            }
        }
        return longest
    }

    func activityLastSevenDays() -> [(Date, DailyActivity)] {
        let calendar = Calendar.current
        return (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return (date, activity(on: date) ?? DailyActivity())
        }
    }

    func resetAllProgress() {
        completedNodeIDs = []
        hearts = 5
        xp = 0
        phraseProgress = [:]
        bookmarkedPhraseKeys = []
        dailyActivity = [:]
        savedLessonSessions = [:]
        persist()
    }

    private func addXP(_ amount: Int) {
        let safeAmount = max(0, amount)
        xp += safeAmount
        var today = dailyActivity[todayKey] ?? DailyActivity()
        today.xp += safeAmount
        dailyActivity[todayKey] = today
    }

    private var todayKey: String {
        Self.dayFormatter.string(from: Date())
    }

    private func activity(on date: Date) -> DailyActivity? {
        let key = Self.dayFormatter.string(from: date)
        guard let value = dailyActivity[key], value.sessions > 0 || value.correct > 0 || value.wrong > 0 else {
            return nil
        }
        return value
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func persist() {
        defaults.set(Array(completedNodeIDs), forKey: completedKey)
        defaults.set(hearts, forKey: heartsKey)
        defaults.set(xp, forKey: xpKey)
        defaults.set(Array(bookmarkedPhraseKeys), forKey: bookmarksKey)

        if let data = try? JSONEncoder().encode(phraseProgress) {
            defaults.set(data, forKey: phraseProgressKey)
        }
        if let data = try? JSONEncoder().encode(dailyActivity) {
            defaults.set(data, forKey: dailyActivityKey)
        }
        if let data = try? JSONEncoder().encode(savedLessonSessions) {
            defaults.set(data, forKey: savedLessonsKey)
        }
    }
}
