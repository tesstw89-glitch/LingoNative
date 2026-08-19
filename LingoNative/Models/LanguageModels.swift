import Foundation

struct Lemma: Codable, Hashable, Identifiable {
    var id: String { "\(foreign)|\(english)" }
    let foreign: String
    let english: String
}

struct PhraseEntry: Identifiable, Hashable, Codable {
    let id: String
    let topicID: String
    let topicTitle: String
    let foreign: String
    let english: String
    let lemmas: [Lemma]
    let context: String

    func progressKey(course: LanguageCourse) -> String {
        "\(course.rawValue):\(id)"
    }
}

enum LanguageCourse: String, CaseIterable, Identifiable, Hashable, Codable {
    case french
    case spanish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .french: return "French"
        case .spanish: return "Spanish"
        }
    }

    var targetLanguageName: String { title }

    var flag: String {
        switch self {
        case .french: return "🇫🇷"
        case .spanish: return "🇪🇸"
        }
    }

    var resourceName: String {
        switch self {
        case .french: return "french_opinions"
        case .spanish: return "spanish_opinions"
        }
    }

    var speechLocaleIdentifier: String {
        switch self {
        case .french: return "fr-FR"
        case .spanish: return "es-ES"
        }
    }
}

struct LearningTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let phraseCount: Int
    let unitCount: Int
}

struct LearningUnit: Identifiable, Hashable {
    let id: String
    let title: String
    let topicID: String
    let topicTitle: String
    let topicIcon: String
    let phrases: [PhraseEntry]

    func nodes(sessionSize: Int = 10) -> [LessonNode] {
        let safeSessionSize = max(1, sessionSize)
        let count = max(1, Int(ceil(Double(phrases.count) / Double(safeSessionSize))))
        return (0..<count).map { index in
            LessonNode(
                id: "\(id)-lesson-\(index + 1)",
                unitID: id,
                index: index,
                sessionSize: min(safeSessionSize, max(1, phrases.count))
            )
        }
    }

    func phrases(for node: LessonNode) -> [PhraseEntry] {
        guard !phrases.isEmpty else { return [] }
        let start = node.index * max(1, node.sessionSize)
        guard start < phrases.count else { return [] }
        let end = min(phrases.count, start + max(1, node.sessionSize))
        return Array(phrases[start..<end])
    }
}

struct LessonNode: Identifiable, Hashable {
    let id: String
    let unitID: String
    let index: Int
    let sessionSize: Int
}

struct Corpus {
    let course: LanguageCourse
    let entries: [PhraseEntry]
    let units: [LearningUnit]
    let topics: [LearningTopic]
    let blockSize: Int
}

enum QuestionDirection: String, Codable, CaseIterable, Equatable {
    case foreignToEnglish
    case englishToForeign
}

enum ExerciseType: String, Codable, CaseIterable, Identifiable, Hashable {
    case introduction
    case multipleChoice
    case typing
    case wordBank
    case fillBlank
    case listening
    case speaking
    case matching
    case lemma

    var id: String { rawValue }

    static var userSelectableCases: [ExerciseType] {
        allCases.filter { $0 != .introduction }
    }

    var title: String {
        switch self {
        case .introduction: return "New phrase"
        case .multipleChoice: return "Multiple choice"
        case .typing: return "Typing"
        case .wordBank: return "Word bank"
        case .fillBlank: return "Fill the gap"
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        case .matching: return "Matching"
        case .lemma: return "Lemma / chunk"
        }
    }

    var systemImage: String {
        switch self {
        case .introduction: return "sparkles"
        case .multipleChoice: return "checklist"
        case .typing: return "keyboard"
        case .wordBank: return "square.grid.3x3.fill"
        case .fillBlank: return "rectangle.and.pencil.and.ellipsis"
        case .listening: return "speaker.wave.2.fill"
        case .speaking: return "mic.fill"
        case .matching: return "rectangle.grid.2x2.fill"
        case .lemma: return "text.book.closed.fill"
        }
    }
}

struct QuizQuestion: Identifiable, Equatable, Codable {
    let id: UUID
    let type: ExerciseType
    let prompt: String
    let options: [String]
    let correctAnswer: String
    let direction: QuestionDirection
    let phrase: PhraseEntry
    let wordBankTokens: [String]
    let blankedText: String?

    init(
        id: UUID = UUID(),
        type: ExerciseType,
        prompt: String,
        options: [String] = [],
        correctAnswer: String,
        direction: QuestionDirection,
        phrase: PhraseEntry,
        wordBankTokens: [String] = [],
        blankedText: String? = nil
    ) {
        self.id = id
        self.type = type
        self.prompt = prompt
        self.options = options
        self.correctAnswer = correctAnswer
        self.direction = direction
        self.phrase = phrase
        self.wordBankTokens = wordBankTokens
        self.blankedText = blankedText
    }
}

enum QuizStatus: String, Codable, Equatable {
    case unanswered
    case correct
    case wrong
}

struct SavedLessonSession: Codable, Equatable {
    let nodeID: String
    let course: LanguageCourse
    let flowVersion: Int?
    let questions: [QuizQuestion]
    let currentIndex: Int
    let selectedAnswer: String?
    let typedAnswer: String
    let selectedWordIndices: [Int]
    let status: QuizStatus
    let mistakes: Int
    let correctCount: Int
    let initialQuestionCount: Int
    let updatedAt: Date

    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return min(1, Double(currentIndex) / Double(questions.count))
    }
}

struct QuizSession {
    let course: LanguageCourse
    let title: String
    let subtitle: String
    let phrasePool: [PhraseEntry]
    let allPhrases: [PhraseEntry]
    let sessionSize: Int
    let exerciseTypes: Set<ExerciseType>
    let completionNodeID: String?

    static func lesson(
        course: LanguageCourse,
        unit: LearningUnit,
        node: LessonNode,
        allPhrases: [PhraseEntry],
        exerciseTypes: Set<ExerciseType>
    ) -> QuizSession {
        let nodePhrases = unit.phrases(for: node)
        return QuizSession(
            course: course,
            title: unit.title,
            subtitle: "\(unit.topicTitle) · Lesson \(node.index + 1)",
            phrasePool: nodePhrases,
            allPhrases: allPhrases,
            sessionSize: max(1, nodePhrases.count),
            exerciseTypes: exerciseTypes,
            completionNodeID: node.id
        )
    }
}

enum PhraseLearningStage: Int, Codable, CaseIterable, Comparable {
    case unseen = 0
    case introduced = 1
    case recognition = 2
    case assistedRecall = 3
    case freeRecall = 4
    case established = 5

    static func < (lhs: PhraseLearningStage, rhs: PhraseLearningStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .unseen: return "Unseen"
        case .introduced: return "Introduced"
        case .recognition: return "Recognition"
        case .assistedRecall: return "Assisted recall"
        case .freeRecall: return "Free recall"
        case .established: return "Established"
        }
    }

    var defaultHalfLifeDays: Double {
        switch self {
        case .unseen: return 15.0 / (24.0 * 60.0)
        case .introduced: return 0.25
        case .recognition: return 0.75
        case .assistedRecall: return 2.0
        case .freeRecall: return 7.0
        case .established: return 21.0
        }
    }
}

struct PhraseProgress: Codable, Hashable {
    var seen: Int = 0
    var correct: Int = 0
    var wrong: Int = 0
    var lastPractised: Date?

    // Optional for backwards-compatible decoding of progress saved before staged learning/HLR.
    var learningStageRaw: Int?
    var halfLifeDays: Double?
    var successfulRecallCount: Int?
    var lastReviewWasCorrect: Bool?

    var learningStage: PhraseLearningStage {
        get {
            if let raw = learningStageRaw, let stage = PhraseLearningStage(rawValue: raw) {
                return stage
            }
            // Migrate existing users' historical stats conservatively rather than resetting them to unseen.
            guard seen > 0 else { return .unseen }
            if correct >= 6 && accuracy >= 0.82 { return .freeRecall }
            if correct >= 3 && accuracy >= 0.70 { return .assistedRecall }
            return .recognition
        }
        set { learningStageRaw = newValue.rawValue }
    }

    var effectiveHalfLifeDays: Double {
        max(15.0 / (24.0 * 60.0), min(274.0, halfLifeDays ?? learningStage.defaultHalfLifeDays))
    }

    func recallProbability(at date: Date = Date()) -> Double {
        guard let lastPractised, learningStage != .unseen else { return 0 }
        let seconds = max(0, date.timeIntervalSince(lastPractised))
        let days = seconds / 86_400.0
        // Duolingo HLR recall equation: p = 2^(-t / h).
        return max(0.0001, min(0.9999, pow(2.0, -days / effectiveHalfLifeDays)))
    }

    var accuracy: Double {
        guard seen > 0 else { return 0 }
        return Double(correct) / Double(seen)
    }

    var mastery: Double {
        guard seen > 0 else { return 0 }
        let confidence = min(1.0, Double(seen) / 6.0)
        let stageWeight = Double(learningStage.rawValue) / Double(PhraseLearningStage.established.rawValue)
        return accuracy * confidence * (0.55 + 0.45 * stageWeight)
    }
}

struct DailyActivity: Codable, Hashable {
    var xp: Int = 0
    var correct: Int = 0
    var wrong: Int = 0
    var sessions: Int = 0
}

enum PracticeMode: String, CaseIterable, Identifiable {
    case retention
    case quick
    case bookmarks
    case mistakes
    case weak
    case typing
    case listening
    case speaking
    case matching
    case lemma

    var id: String { rawValue }

    var title: String {
        switch self {
        case .retention: return "Spaced review"
        case .quick: return "Quick practice"
        case .bookmarks: return "Saved phrases"
        case .mistakes: return "Mistakes"
        case .weak: return "Weak spots"
        case .typing: return "Typing drill"
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        case .matching: return "Matching"
        case .lemma: return "Lemma / chunk"
        }
    }

    var subtitle: String {
        switch self {
        case .retention: return "HLR review: what your memory needs now"
        case .quick: return "A fresh mixed session"
        case .bookmarks: return "Practise your bookmarks"
        case .mistakes: return "Retry phrases you’ve missed"
        case .weak: return "Prioritise your lowest mastery"
        case .typing: return "Production, once a phrase is ready"
        case .listening: return "Hear it, then write it"
        case .speaking: return "Say the phrase aloud"
        case .matching: return "Fast translation matching"
        case .lemma: return "Drill saved chunks and lemmas"
        }
    }

    var systemImage: String {
        switch self {
        case .retention: return "brain.head.profile.fill"
        case .quick: return "bolt.fill"
        case .bookmarks: return "bookmark.fill"
        case .mistakes: return "arrow.counterclockwise.circle.fill"
        case .weak: return "target"
        case .typing: return "keyboard.fill"
        case .listening: return "headphones"
        case .speaking: return "mic.circle.fill"
        case .matching: return "rectangle.grid.2x2.fill"
        case .lemma: return "text.book.closed.fill"
        }
    }
}