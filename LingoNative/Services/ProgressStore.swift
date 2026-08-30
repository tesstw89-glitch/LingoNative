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

        // Optional for backwards-compatible decoding of logs created before the FSRS layer.
        let memoryRatingRaw: Int?
        let timeZoneIdentifier: String?
        let dayStartHour: Int?

        var memoryRating: MemoryRating? {
            guard let memoryRatingRaw else { return nil }
            return MemoryRating(rawValue: memoryRatingRaw)
        }
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
            case "exercise.listenWrite": return -0.85
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
    @Published private(set) var conceptMemory: [String: MemoryState]

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
    private let conceptMemoryKey = "conceptMemory.fsrs.v1"

    private let minHalfLifeDays = 15.0 / (24.0 * 60.0)
    private let maxHalfLifeDays = 274.0
    private let maxStoredAttempts = 20_000

    // FSRS-6 canonical defaults. The course still decides WHAT is taught;
    // this layer only decides WHEN already-introduced memory should return.
    private let desiredRetention = 0.90
    private let maximumMemoryIntervalDays = 3_650.0
    private let fsrsW: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133,
        0.8334, 3.0194, 0.001, 1.8722, 0.1666,
        0.796, 1.4835, 0.0614, 0.2629, 1.6483,
        0.6014, 1.8729, 0.5425, 0.0912, 0.0658,
        0.1542
    ]

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

        if let data = defaults.data(forKey: conceptMemoryKey),
           let decoded = try? JSONDecoder().decode([String: MemoryState].self, from: data) {
            conceptMemory = decoded
        } else {
            conceptMemory = [:]
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
        totalParts: Int = 1,
        isLessonScaffold: Bool = false
    ) {
        let key = phrase.progressKey(course: course)
        var stats = phraseProgress[key] ?? PhraseProgress()
        let now = Date()
        let scaffoldSuccessesBefore = isLessonScaffold
            ? lessonScaffoldSuccessCount(course: course, phrase: phrase)
            : nil

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
        let resolvedCorrectParts = max(
            0,
            min(safeTotalParts, correctParts ?? (correct ? safeTotalParts : 0))
        )
        let memoryRating = inferredMemoryRating(
            phrase: phrase,
            correct: correct,
            exerciseType: exerciseType,
            responseTimeSeconds: responseTimeSeconds,
            correctParts: resolvedCorrectParts,
            totalParts: safeTotalParts
        )

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
                totalParts: safeTotalParts,
                memoryRatingRaw: memoryRating.rawValue,
                timeZoneIdentifier: TimeZone.current.identifier,
                dayStartHour: 4
            )
        )
        if attemptHistory.count > maxStoredAttempts {
            attemptHistory.removeFirst(attemptHistory.count - maxStoredAttempts)
        }

        stats.seen += 1
        if let scaffoldSuccessesBefore {
            // The scaffold is a staircase: two assisted successes unlock writing,
            // then the production/speaking steps complete initial teaching.
            stats.successfulRecallCount = scaffoldSuccessesBefore
            if correct {
                stats.correct += 1
                advanceLessonScaffold(&stats)
            } else {
                stats.wrong += 1
                preserveLessonScaffoldStage(&stats)
            }
        } else if correct {
            stats.correct += 1
            advanceLearningStage(&stats, after: exerciseType)
        } else {
            stats.wrong += 1
            regressLearningStage(&stats)
        }
        stats.lastReviewWasCorrect = correct

        // Keep the legacy HLR signal alive for backwards compatibility and for the
        // adaptive exercise model, while FSRS becomes the primary due-date scheduler.
        let adjustedHalfLife: Double
        if correct {
            let surprise = 1.0 - probabilityBeforeReview
            let growth = 1.35 + 1.65 * surprise
            adjustedHalfLife = previousHalfLife * growth
        } else {
            let retentionFactor = max(0.28, 0.52 - 0.18 * probabilityBeforeReview)
            adjustedHalfLife = previousHalfLife * retentionFactor
        }
        stats.halfLifeDays = min(maxHalfLifeDays, max(minHalfLifeDays, adjustedHalfLife))

        stats.memory = scheduledMemory(
            from: stats.memory,
            rating: memoryRating,
            at: now
        )
        stats.lastPractised = now
        phraseProgress[key] = stats

        // Concepts/chunks have their own memory schedule. A successful phrase recall is
        // positive evidence for its lemmas; explicit lemma exercises can also record failure.
        updateConceptMemory(
            course: course,
            phrase: phrase,
            rating: memoryRating,
            exerciseType: exerciseType,
            at: now
        )

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

    /// Number of the four mandatory active scaffold skills already cleared.
    /// Existing progress is migrated from the previous fixed order. If a phrase reached free
    /// writing before speaking became mandatory, it gets one speaking encounter to catch up.
    func lessonScaffoldSuccessCount(course: LanguageCourse, phrase: PhraseEntry) -> Int {
        let value = stats(course: course, phrase: phrase)
        let inferred: Int
        if let stored = value.successfulRecallCount {
            inferred = max(0, stored)
        } else {
            switch value.learningStage {
            case .unseen, .introduced: inferred = 0
            case .recognition: inferred = 1
            case .assistedRecall: inferred = 2
            case .freeRecall, .established: inferred = 3
            }
        }

        if inferred >= 4 {
            let hasSuccessfulSpeaking = attemptHistory.contains { attempt in
                attempt.course == course
                    && attempt.phraseID == phrase.id
                    && attempt.exerciseType == .speaking
                    && attempt.wasCorrect
            }
            if !hasSuccessfulSpeaking {
                return 3
            }
        }
        return min(4, inferred)
    }

    func recallProbability(course: LanguageCourse, phrase: PhraseEntry, at date: Date = Date()) -> Double {
        stats(course: course, phrase: phrase).recallProbability(at: date)
    }

    func memoryState(course: LanguageCourse, phrase: PhraseEntry) -> MemoryState? {
        stats(course: course, phrase: phrase).memory
    }

    func conceptMemoryState(course: LanguageCourse, lemma: Lemma) -> MemoryState? {
        conceptMemory[conceptKey(course: course, foreign: lemma.foreign)]
    }

    /// A lemma matching checkpoint is evidence about the chunk itself, not the
    /// synthetic matching question that happens to contain it.
    func recordLemmaMatch(
        course: LanguageCourse,
        lemma: Lemma,
        successfulOnFirstTry: Bool
    ) {
        let key = conceptKey(course: course, foreign: lemma.foreign)
        let rating: MemoryRating = successfulOnFirstTry ? .good : .hard
        conceptMemory[key] = scheduledMemory(
            from: conceptMemory[key],
            rating: rating,
            at: Date()
        )
        persist()
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
        let targetRetrievability = max(desiredRetention, threshold)

        return Array(entries
            .filter { phrase in
                let key = phrase.progressKey(course: course)
                guard !excludedKeys.contains(key) else { return false }

                let value = stats(course: course, phrase: phrase)

                // Curriculum safeguard: unseen future material can NEVER be pulled in by FSRS
                // or by a due lemma. The topic/unit system owns first exposure.
                guard value.learningStage != .unseen else { return false }

                if lessonScaffoldSuccessCount(course: course, phrase: phrase) < 4 {
                    return true
                }

                if value.lastReviewWasCorrect == false {
                    return true
                }

                if let memory = value.memory {
                    if memory.isDue(at: now) || memory.retrievability(at: now) <= targetRetrievability {
                        return true
                    }
                } else if value.recallProbability(at: now) <= threshold {
                    return true
                }

                // A due chunk can be reinforced through any ALREADY-INTRODUCED phrase
                // containing it, allowing concepts to move across topics without leaking future content.
                return hasDueConcept(
                    course: course,
                    phrase: phrase,
                    at: now,
                    targetRetrievability: targetRetrievability
                )
            }
            .sorted { lhs, rhs in
                reviewPriority(course: course, phrase: lhs, at: now)
                    > reviewPriority(course: course, phrase: rhs, at: now)
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
        persistSavedLessonSessions()
    }

    func clearSavedLessonSession(nodeID: String) {
        guard savedLessonSessions.removeValue(forKey: nodeID) != nil else { return }
        persistSavedLessonSessions()
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
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: previous),
                to: calendar.startOfDay(for: date)
            ).day ?? 0
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
        conceptMemory = [:]
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
        let scaffoldBoost = lessonScaffoldSuccessCount(course: course, phrase: phrase) < 4 ? 1.15 : 0

        let overdueBoost: Double
        if let memory = value.memory, memory.isDue(at: date) {
            let daysOverdue = max(0, date.timeIntervalSince(memory.due)) / 86_400.0
            overdueBoost = min(0.85, 0.20 + daysOverdue / max(1, memory.stability) * 0.35)
        } else {
            overdueBoost = 0
        }

        let conceptBoost = conceptReviewPriority(course: course, phrase: phrase, at: date)
        return forgetting + recentFailureBoost + errorBoost + scaffoldBoost + overdueBoost + conceptBoost
    }

    // MARK: - FSRS memory scheduling

    private func inferredMemoryRating(
        phrase: PhraseEntry,
        correct: Bool,
        exerciseType: ExerciseType,
        responseTimeSeconds: TimeInterval,
        correctParts: Int,
        totalParts: Int
    ) -> MemoryRating {
        guard correct else { return .again }

        let fraction = Double(correctParts) / Double(max(1, totalParts))
        if fraction < 0.999 { return .hard }

        let tokenCount = max(1, phrase.foreign.split(whereSeparator: { $0.isWhitespace }).count)
        let fastThreshold = min(9.0, 4.5 + Double(max(0, tokenCount - 1)) * 0.35)
        let isFreeProduction = exerciseType == .typing
            || exerciseType == .listenWrite
            || exerciseType == .speaking
            || exerciseType == .listening

        if isFreeProduction && responseTimeSeconds <= fastThreshold {
            return .easy
        }
        if responseTimeSeconds >= max(12.0, Double(tokenCount) * 1.8) {
            return .hard
        }
        return .good
    }

    private func scheduledMemory(
        from existing: MemoryState?,
        rating: MemoryRating,
        at date: Date
    ) -> MemoryState {
        if existing == nil {
            let stability = initialStability(for: rating)
            let difficulty = initialDifficulty(for: rating)
            let intervalDays: Double
            if rating == .again {
                intervalDays = 1.0 / (24.0 * 60.0)
            } else {
                intervalDays = fuzzedInterval(stability)
            }
            return MemoryState(
                stability: stability,
                difficulty: difficulty,
                due: date.addingTimeInterval(intervalDays * 86_400.0),
                lastReview: date,
                reps: 1,
                lapses: rating == .again ? 1 : 0,
                lastRatingRaw: rating.rawValue
            )
        }

        let old = existing!
        let elapsedDays = max(0, date.timeIntervalSince(old.lastReview)) / 86_400.0
        let retrievability = old.retrievability(at: date)
        let nextDifficultyValue = nextDifficulty(old: old.difficulty, rating: rating)

        let nextStabilityValue: Double
        if rating == .again {
            nextStabilityValue = nextForgetStability(
                difficulty: old.difficulty,
                stability: old.stability,
                retrievability: retrievability
            )
        } else if elapsedDays < (1.0 / 24.0) {
            nextStabilityValue = nextShortTermStability(
                stability: old.stability,
                rating: rating
            )
        } else {
            nextStabilityValue = nextRecallStability(
                difficulty: old.difficulty,
                stability: old.stability,
                retrievability: retrievability,
                rating: rating
            )
        }

        let intervalDays: Double
        if rating == .again {
            intervalDays = 10.0 / (24.0 * 60.0)
        } else {
            intervalDays = fuzzedInterval(
                min(maximumMemoryIntervalDays, max(0.001, nextStabilityValue * intervalModifier))
            )
        }

        return MemoryState(
            stability: min(maximumMemoryIntervalDays, max(0.001, nextStabilityValue)),
            difficulty: min(10.0, max(1.0, nextDifficultyValue)),
            due: date.addingTimeInterval(intervalDays * 86_400.0),
            lastReview: date,
            reps: old.reps + 1,
            lapses: old.lapses + (rating == .again ? 1 : 0),
            lastRatingRaw: rating.rawValue
        )
    }

    private var intervalModifier: Double {
        let decay = -fsrsW[20]
        let factor = exp(log(0.9) / decay) - 1.0
        return (pow(desiredRetention, 1.0 / decay) - 1.0) / factor
    }

    private func initialStability(for rating: MemoryRating) -> Double {
        max(0.001, fsrsW[rating.rawValue - 1])
    }

    private func initialDifficulty(for rating: MemoryRating) -> Double {
        let raw = fsrsW[4] - exp(Double(rating.rawValue - 1) * fsrsW[5]) + 1.0
        return min(10.0, max(1.0, raw))
    }

    private func initialDifficultyRaw(for rating: MemoryRating) -> Double {
        fsrsW[4] - exp(Double(rating.rawValue - 1) * fsrsW[5]) + 1.0
    }

    private func nextDifficulty(old: Double, rating: MemoryRating) -> Double {
        let delta = -fsrsW[6] * Double(rating.rawValue - 3)
        let damped = delta * (10.0 - old) / 9.0
        let moved = old + damped
        let meanReverted = fsrsW[7] * initialDifficultyRaw(for: .easy)
            + (1.0 - fsrsW[7]) * moved
        return min(10.0, max(1.0, meanReverted))
    }

    private func nextRecallStability(
        difficulty: Double,
        stability: Double,
        retrievability: Double,
        rating: MemoryRating
    ) -> Double {
        let hardPenalty = rating == .hard ? fsrsW[15] : 1.0
        let easyBonus = rating == .easy ? fsrsW[16] : 1.0
        let growth = 1.0
            + exp(fsrsW[8])
            * (11.0 - difficulty)
            * pow(max(0.001, stability), -fsrsW[9])
            * (exp((1.0 - retrievability) * fsrsW[10]) - 1.0)
            * hardPenalty
            * easyBonus
        return max(0.001, stability * growth)
    }

    private func nextForgetStability(
        difficulty: Double,
        stability: Double,
        retrievability: Double
    ) -> Double {
        let value = fsrsW[11]
            * pow(max(1.0, difficulty), -fsrsW[12])
            * (pow(max(0.001, stability) + 1.0, fsrsW[13]) - 1.0)
            * exp((1.0 - retrievability) * fsrsW[14])
        return max(0.001, min(stability, value))
    }

    private func nextShortTermStability(
        stability: Double,
        rating: MemoryRating
    ) -> Double {
        let part = Double(rating.rawValue) - 3.0 + fsrsW[18]
        let increase = pow(max(0.001, stability), -fsrsW[19]) * exp(fsrsW[17] * part)
        let masked = rating.rawValue >= MemoryRating.hard.rawValue ? max(increase, 1.0) : increase
        return max(0.001, stability * masked)
    }

    private func fuzzedInterval(_ days: Double) -> Double {
        let capped = min(maximumMemoryIntervalDays, max(0.001, days))
        guard capped >= 2.5 else { return capped }
        return min(maximumMemoryIntervalDays, max(1.0, capped * Double.random(in: 0.97...1.03)))
    }

    // MARK: - Lemma / chunk memory

    private func updateConceptMemory(
        course: LanguageCourse,
        phrase: PhraseEntry,
        rating: MemoryRating,
        exerciseType: ExerciseType,
        at date: Date
    ) {
        guard !phrase.lemmas.isEmpty else { return }

        for lemma in phrase.lemmas {
            let effectiveRating: MemoryRating

            if exerciseType == .lemma {
                effectiveRating = rating
            } else {
                // A whole-phrase miss does not prove every embedded chunk was forgotten.
                guard rating != .again else { continue }
                // Do not over-credit an embedded concept as "Easy" just because the full
                // sentence happened to be recalled quickly.
                effectiveRating = rating == .easy ? .good : rating
            }

            let key = conceptKey(course: course, foreign: lemma.foreign)
            conceptMemory[key] = scheduledMemory(
                from: conceptMemory[key],
                rating: effectiveRating,
                at: date
            )
        }
    }

    private func hasDueConcept(
        course: LanguageCourse,
        phrase: PhraseEntry,
        at date: Date,
        targetRetrievability: Double
    ) -> Bool {
        phrase.lemmas.contains { lemma in
            guard let state = conceptMemory[conceptKey(course: course, foreign: lemma.foreign)] else {
                return false
            }
            return state.isDue(at: date) || state.retrievability(at: date) <= targetRetrievability
        }
    }

    private func conceptReviewPriority(
        course: LanguageCourse,
        phrase: PhraseEntry,
        at date: Date
    ) -> Double {
        phrase.lemmas.compactMap { lemma -> Double? in
            guard let state = conceptMemory[conceptKey(course: course, foreign: lemma.foreign)] else {
                return nil
            }
            let forgetting = 1.0 - state.retrievability(at: date)
            let overdue = state.isDue(at: date) ? 0.25 : 0
            return forgetting + overdue
        }.max() ?? 0
    }

    private func conceptKey(course: LanguageCourse, foreign: String) -> String {
        "\(course.rawValue):lemma:\(normalizeConcept(foreign))"
    }

    private func normalizeConcept(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let allowed = CharacterSet.alphanumerics
        let scalars = folded.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : " " }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: - Learning stages and persistence

    private func advanceLessonScaffold(_ stats: inout PhraseProgress) {
        let wasEstablished = stats.learningStage == .established
        let count = min(4, max(0, (stats.successfulRecallCount ?? 0) + 1))
        stats.successfulRecallCount = count

        if wasEstablished {
            stats.learningStage = .established
            return
        }

        switch count {
        case 0:
            stats.learningStage = .introduced
        case 1:
            stats.learningStage = .recognition
        case 2, 3:
            stats.learningStage = .assistedRecall
        default:
            stats.learningStage = .freeRecall
        }
    }

    private func preserveLessonScaffoldStage(_ stats: inout PhraseProgress) {
        if stats.learningStage == .established { return }
        let count = min(4, max(0, stats.successfulRecallCount ?? 0))
        switch count {
        case 0:
            stats.learningStage = .introduced
        case 1:
            stats.learningStage = .recognition
        case 2, 3:
            stats.learningStage = .assistedRecall
        default:
            stats.learningStage = .freeRecall
        }
    }

    private func advanceLearningStage(_ stats: inout PhraseProgress, after type: ExerciseType) {
        switch type {
        case .introduction:
            if stats.learningStage == .unseen { stats.learningStage = .introduced }

        case .multipleChoice, .matching, .lemma:
            if stats.learningStage < .recognition { stats.learningStage = .recognition }

        case .wordBank:
            stats.successfulRecallCount = (stats.successfulRecallCount ?? 0) + 1
            if stats.learningStage < .recognition {
                stats.learningStage = .recognition
            } else if stats.learningStage == .recognition {
                stats.learningStage = .assistedRecall
            }

        case .fillBlank:
            break

        case .listening:
            stats.successfulRecallCount = (stats.successfulRecallCount ?? 0) + 1
            if stats.learningStage == .assistedRecall {
                if (stats.successfulRecallCount ?? 0) >= 3 {
                    stats.learningStage = .freeRecall
                }
            } else if stats.learningStage == .freeRecall,
                      (stats.successfulRecallCount ?? 0) >= 5 {
                stats.learningStage = .established
            }

        case .typing, .listenWrite, .speaking:
            stats.successfulRecallCount = (stats.successfulRecallCount ?? 0) + 1
            if stats.learningStage < .freeRecall {
                stats.learningStage = .freeRecall
            } else if (stats.successfulRecallCount ?? 0) >= 4 {
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
        case .freeRecall:
            stats.learningStage = .assistedRecall
            stats.successfulRecallCount = max(0, (stats.successfulRecallCount ?? 0) - 1)
        case .established:
            stats.learningStage = .freeRecall
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
        guard let value = dailyActivity[key],
              value.sessions > 0 || value.correct > 0 || value.wrong > 0 else {
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

    private func persistSavedLessonSessions() {
        if let data = try? JSONEncoder().encode(savedLessonSessions) {
            defaults.set(data, forKey: savedLessonsKey)
        }
    }

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
        if let data = try? JSONEncoder().encode(conceptMemory) {
            defaults.set(data, forKey: conceptMemoryKey)
        }
    }
}

// MARK: - Star store

final class StarStore: ObservableObject {
    @Published private(set) var starredKeys: Set<String>

    private let defaults: UserDefaults
    private let storageKey = "lingoNative.starredTermKeys.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        starredKeys = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    func isStarred(_ key: String) -> Bool {
        starredKeys.contains(key)
    }

    func toggle(_ key: String) {
        if starredKeys.contains(key) {
            starredKeys.remove(key)
        } else {
            starredKeys.insert(key)
        }
        defaults.set(Array(starredKeys).sorted(), forKey: storageKey)
    }

    static func phraseKey(course: LanguageCourse, phrase: PhraseEntry) -> String {
        "phrase:\(course.rawValue):\(phrase.id)"
    }

    static func lemmaKey(course: LanguageCourse, lemma: Lemma) -> String {
        lemmaKey(course: course, foreign: lemma.foreign, english: lemma.english)
    }

    static func lemmaKey(
        course: LanguageCourse,
        foreign: String,
        english: String
    ) -> String {
        "lemma:\(course.rawValue):\(component(foreign))||\(component(english))"
    }

    func isStarred(course: LanguageCourse, phrase: PhraseEntry) -> Bool {
        isStarred(Self.phraseKey(course: course, phrase: phrase))
    }

    func isStarred(course: LanguageCourse, lemma: Lemma) -> Bool {
        isStarred(Self.lemmaKey(course: course, lemma: lemma))
    }

    func starredPhrases(
        course: LanguageCourse,
        from phrases: [PhraseEntry]
    ) -> [PhraseEntry] {
        phrases.filter { isStarred(course: course, phrase: $0) }
    }

    func starredLemmas(
        course: LanguageCourse,
        from lemmas: [Lemma]
    ) -> [Lemma] {
        lemmas.filter { isStarred(course: course, lemma: $0) }
    }

    private static func component(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

