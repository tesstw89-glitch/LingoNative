import Foundation
import Combine

@MainActor
final class ProgressStore: ObservableObject {
    struct LearningAttempt: Codable, Hashable, Identifiable {
        let id: UUID
        let timestamp: Date
        let course: LanguageCourse
        let phraseID: String
        let topicID: String
        let exerciseType: ExerciseType
        let direction: QuestionDirection
        let stageBefore: PhraseLearningStage
        let wasCorrect: Bool
        let responseTimeSeconds: Double
        let recallProbabilityBefore: Double
        let predictedCorrectProbability: Double
        let correctParts: Int
        let totalParts: Int
    }

    private struct LearnerModelState: Codable, Hashable {
        var weights: [String: Double] = [:]
        var observations: Int = 0
        var brierSum: Double = 0

        func predict(features: [String: Double]) -> Double {
            let score = features.reduce(0.0) { partial, item in
                partial + item.value * weight(for: item.key)
            }
            let clipped = max(-12.0, min(12.0, score))
            return 1.0 / (1.0 + exp(-clipped))
        }

        mutating func update(features: [String: Double], outcome: Bool) -> Double {
            let prediction = predict(features: features)
            let target = outcome ? 1.0 : 0.0
            let error = target - prediction
            let learningRate = max(0.025, 0.16 / sqrt(1.0 + Double(observations) / 40.0))

            for (key, value) in features {
                let current = weight(for: key)
                let regularized = current * 0.9998
                weights[key] = regularized + learningRate * error * value
            }

            observations += 1
            brierSum += pow(prediction - target, 2)
            return prediction
        }

        private func weight(for key: String) -> Double {
            weights[key] ?? Self.priorWeight(for: key)
        }

        private static func priorWeight(for key: String) -> Double {
            switch key {
            case "bias": return 0.90
            case "exercise.multipleChoice": return 0.90
            case "exercise.matching": return 0.75
            case "exercise.lemma": return 0.60
            case "exercise.wordBank": return 0.35
            case "exercise.fillBlank": return 0.05
            case "exercise.typing": return -0.55
            case "exercise.listening": return -0.65
            case "exercise.speaking": return -0.55
            case "stage.1": return -0.15
            case "stage.2": return 0.00
            case "stage.3": return 0.15
            case "stage.4": return 0.30
            case "stage.5": return 0.45
            case "direction.foreignToEnglish": return 0.25
            case "direction.englishToForeign": return -0.15
            case "recall": return 1.50
            case "accuracy": return 1.00
            case "length": return -0.70
            case "seenConfidence": return 0.40
            case "recentFailure": return -0.80
            case "hasLemmas": return 0.05
            default: return 0
            }
        }
    }

    @Published private(set) var completedNodeIDs: Set<String>
    @Published private(set) var hearts: Int
    @Published private(set) var xp: Int
    @Published private(set) var phraseProgress: [String: PhraseProgress]
    @Published private(set) var bookmarkedPhraseKeys: Set<String>
    @Published private(set) var dailyActivity: [String: DailyActivity]
    @Published private(set) var savedLessonSessions: [String: SavedLessonSession]
    @Published private(set) var attemptHistory: [LearningAttempt]

    private var learnerModels: [String: LearnerModelState]
    private let defaults: UserDefaults
    private let completedKey = "completedNodeIDs"
    private let heartsKey = "hearts"
    private let xpKey = "xp"
    private let phraseProgressKey = "phraseProgress.v2"
    private let bookmarksKey = "bookmarkedPhraseKeys"
    private let dailyActivityKey = "dailyActivity.v2"
    private let savedLessonsKey = "savedLessonSessions.v1"
    private let attemptHistoryKey = "learningAttempts.v1"
    private let learnerModelsKey = "adaptiveLearnerModels.v1"

    private let minHalfLifeDays = 15.0 / (24.0 * 60.0)
    private let maxHalfLifeDays = 274.0
    private let maxStoredAttempts = 20_000

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

        if let data = defaults.data(forKey: attemptHistoryKey),
           let decoded = try? JSONDecoder().decode([LearningAttempt].self, from: data) {
            attemptHistory = decoded
        } else {
            attemptHistory = []
        }

        if let data = defaults.data(forKey: learnerModelsKey),
           let decoded = try? JSONDecoder().decode([String: LearnerModelState].self, from: data) {
            learnerModels = decoded
        } else {
            learnerModels = [:]
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

    func recordExposure(course: LanguageCourse, phrase: PhraseEntry) {
        let key = phrase.progressKey(course: course)
        var stats = phraseProgress[key] ?? PhraseProgress()
        if stats.learningStage == .unseen {
            stats.learningStage = .introduced
            stats.halfLifeDays = PhraseLearningStage.introduced.defaultHalfLifeDays
        }
        stats.lastPractised = Date()
        phraseProgress[key] = stats
        persist()
    }

    func recordAttempt(
        course: LanguageCourse,
        phrase: PhraseEntry,
        correct: Bool,
        exerciseType: ExerciseType,
        direction: QuestionDirection,
        responseTimeSeconds: TimeInterval,
        correctParts: Int? = nil,
        totalParts: Int = 1
    ) {
        let key = phrase.progressKey(course: course)
        var stats = phraseProgress[key] ?? PhraseProgress()
        let now = Date()

        if stats.learningStage == .unseen {
            stats.learningStage = .introduced
        }

        let stageBefore = stats.learningStage
        let probabilityBeforeReview = stats.recallProbability(at: now)
        let previousHalfLife = stats.effectiveHalfLifeDays
        let features = learnerFeatures(
            phrase: phrase,
            exerciseType: exerciseType,
            direction: direction,
            stage: stageBefore,
            stats: stats,
            at: now
        )
        var learner = learnerModels[course.rawValue] ?? LearnerModelState()
        let predictedProbability = learner.update(features: features, outcome: correct)
        learnerModels[course.rawValue] = learner

        let safeTotalParts = max(1, totalParts)
        let resolvedCorrectParts = max(0, min(safeTotalParts, correctParts ?? (correct ? safeTotalParts : 0)))
        attemptHistory.append(
            LearningAttempt(
                id: UUID(),
                timestamp: now,
                course: course,
                phraseID: phrase.id,
                topicID: phrase.topicID,
                exerciseType: exerciseType,
                direction: direction,
                stageBefore: stageBefore,
                wasCorrect: correct,
                responseTimeSeconds: max(0, responseTimeSeconds),
                recallProbabilityBefore: probabilityBeforeReview,
                predictedCorrectProbability: predictedProbability,
                correctParts: resolvedCorrectParts,
                totalParts: safeTotalParts
            )
        )
        if attemptHistory.count > maxStoredAttempts {
            attemptHistory.removeFirst(attemptHistory.count - maxStoredAttempts)
        }

        stats.seen += 1
        if correct {
            stats.correct += 1
            advanceLearningStage(&stats, after: exerciseType)
        } else {
            stats.wrong += 1
            regressLearningStage(&stats)
        }
        stats.lastReviewWasCorrect = correct

        // Duolingo HLR models recall as p = 2^(-t/h). Their public repository trains
        // feature weights on a very large trace dataset; LingoNative instead adapts each
        // phrase's h online from the user's own successes/failures while using that same curve.
        let adjustedHalfLife: Double
        if correct {
            // A correct answer that was unlikely is stronger evidence than an easy immediate repeat.
            let surprise = 1.0 - probabilityBeforeReview
            let growth = 1.35 + 1.65 * surprise
            adjustedHalfLife = previousHalfLife * growth
        } else {
            // Failure shortens the interval substantially, then the stage system scaffolds the next test.
            let retentionFactor = max(0.28, 0.52 - 0.18 * probabilityBeforeReview)
            adjustedHalfLife = previousHalfLife * retentionFactor
        }
        stats.halfLifeDays = min(maxHalfLifeDays, max(minHalfLifeDays, adjustedHalfLife))
        stats.lastPractised = now
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

    func learningStage(course: LanguageCourse, phrase: PhraseEntry) -> PhraseLearningStage {
        stats(course: course, phrase: phrase).learningStage
    }

    func recallProbability(course: LanguageCourse, phrase: PhraseEntry, at date: Date = Date()) -> Double {
        stats(course: course, phrase: phrase).recallProbability(at: date)
    }

    func adaptiveObservationCount(course: LanguageCourse) -> Int {
        learnerModels[course.rawValue]?.observations ?? 0
    }

    func adaptiveMeanBrierScore(course: LanguageCourse) -> Double? {
        guard let model = learnerModels[course.rawValue], model.observations > 0 else { return nil }
        return model.brierSum / Double(model.observations)
    }

    func predictedSuccess(
        course: LanguageCourse,
        phrase: PhraseEntry,
        exerciseType: ExerciseType,
        direction: QuestionDirection,
        stage: PhraseLearningStage
    ) -> Double {
        let value = stats(course: course, phrase: phrase)
        let features = learnerFeatures(
            phrase: phrase,
            exerciseType: exerciseType,
            direction: direction,
            stage: stage,
            stats: value,
            at: Date()
        )
        return (learnerModels[course.rawValue] ?? LearnerModelState()).predict(features: features)
    }

    func duePhrases(
        course: LanguageCourse,
        from entries: [PhraseEntry],
        excluding excludedKeys: Set<String> = [],
        limit: Int = 30,
        threshold: Double = 0.86
    ) -> [PhraseEntry] {
        let now = Date()
        return Array(entries
            .filter { phrase in
                let key = phrase.progressKey(course: course)
                guard !excludedKeys.contains(key) else { return false }
                let value = stats(course: course, phrase: phrase)
                guard value.learningStage != .unseen else { return false }
                // Recognition is deliberately due immediately: the next encounter must be
                // the mandatory token-construction gate before any unaided production.
                if value.learningStage == .recognition { return true }
                return value.recallProbability(at: now) <= threshold || value.lastReviewWasCorrect == false
            }
            .sorted { lhs, rhs in
                reviewPriority(course: course, phrase: lhs, at: now) > reviewPriority(course: course, phrase: rhs, at: now)
            }
            .prefix(max(0, limit)))
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
        let practised = entries.filter { stats(course: course, phrase: $0).learningStage != .unseen }
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
        phraseProgress.values.filter { $0.learningStage != .unseen }.count
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
        attemptHistory = []
        learnerModels = [:]
        persist()
    }

    private func learnerFeatures(
        phrase: PhraseEntry,
        exerciseType: ExerciseType,
        direction: QuestionDirection,
        stage: PhraseLearningStage,
        stats: PhraseProgress,
        at date: Date
    ) -> [String: Double] {
        let tokenCount = max(1, phrase.foreign.split(whereSeparator: { $0.isWhitespace }).count)
        let accuracyPrior = stats.seen > 0 ? stats.accuracy : 0.65
        let seenConfidence = min(1.0, log(1.0 + Double(stats.seen)) / log(11.0))

        return [
            "bias": 1,
            "exercise.\(exerciseType.rawValue)": 1,
            "stage.\(stage.rawValue)": 1,
            "direction.\(direction.rawValue)": 1,
            "recall": stats.recallProbability(at: date) - 0.5,
            "accuracy": accuracyPrior - 0.5,
            "length": min(1.0, Double(tokenCount) / 12.0),
            "seenConfidence": seenConfidence,
            "recentFailure": stats.lastReviewWasCorrect == false ? 1 : 0,
            "hasLemmas": phrase.lemmas.isEmpty ? 0 : 1
        ]
    }

    private func reviewPriority(course: LanguageCourse, phrase: PhraseEntry, at date: Date) -> Double {
        let value = stats(course: course, phrase: phrase)
        let forgetting = 1.0 - value.recallProbability(at: date)
        let recentFailureBoost = value.lastReviewWasCorrect == false ? 0.55 : 0
        let errorBoost = min(0.35, Double(value.wrong) * 0.035)
        let tokenGateBoost = value.learningStage == .recognition ? 0.90 : 0
        return forgetting + recentFailureBoost + errorBoost + tokenGateBoost
    }

    private func advanceLearningStage(_ stats: inout PhraseProgress, after type: ExerciseType) {
        switch type {
        case .introduction:
            if stats.learningStage == .unseen { stats.learningStage = .introduced }
        case .multipleChoice, .matching, .lemma:
            if stats.learningStage < .recognition { stats.learningStage = .recognition }
        case .wordBank:
            // Word construction is a mandatory gate: only a successful token build can
            // unlock unaided target-language production.
            if stats.learningStage >= .recognition && stats.learningStage < .assistedRecall {
                stats.learningStage = .assistedRecall
            }
        case .fillBlank:
            // Cloze is useful practice but cannot substitute for the token-construction gate.
            break
        case .typing, .listening, .speaking:
            stats.successfulRecallCount = (stats.successfulRecallCount ?? 0) + 1
            if stats.learningStage < .freeRecall {
                stats.learningStage = .freeRecall
            } else if (stats.successfulRecallCount ?? 0) >= 3 {
                stats.learningStage = .established
            }
        }
    }

    private func regressLearningStage(_ stats: inout PhraseProgress) {
        switch stats.learningStage {
        case .unseen, .introduced:
            stats.learningStage = .introduced
        case .recognition:
            stats.learningStage = .introduced
        case .assistedRecall:
            stats.learningStage = .recognition
        case .freeRecall, .established:
            // A lapse in unaided recall requires rebuilding the phrase with tokens before
            // another unaided attempt is permitted.
            stats.learningStage = .recognition
            stats.successfulRecallCount = max(0, (stats.successfulRecallCount ?? 0) - 1)
        }
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
        if let data = try? JSONEncoder().encode(attemptHistory) {
            defaults.set(data, forKey: attemptHistoryKey)
        }
        if let data = try? JSONEncoder().encode(learnerModels) {
            defaults.set(data, forKey: learnerModelsKey)
        }
    }
}
