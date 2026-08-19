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
    case multipleChoice
    case typing
    case wordBank
    case fillBlank
    case listening
    case speaking
    case matching
    case lemma

    var id: String { rawValue }

    var title: String {
        switch self {
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
        QuizSession(
            course: course,
            title: unit.title,
            subtitle: "\(unit.topicTitle) · Lesson \(node.index + 1)",
            phrasePool: unit.phrases,
            allPhrases: allPhrases,
            sessionSize: node.sessionSize,
            exerciseTypes: exerciseTypes,
            completionNodeID: node.id
        )
    }
}

struct PhraseProgress: Codable, Hashable {
    var seen: Int = 0
    var correct: Int = 0
    var wrong: Int = 0
    var lastPractised: Date?

    var accuracy: Double {
        guard seen > 0 else { return 0 }
        return Double(correct) / Double(seen)
    }

    var mastery: Double {
        guard seen > 0 else { return 0 }
        let confidence = min(1.0, Double(seen) / 6.0)
        return accuracy * confidence
    }
}

struct DailyActivity: Codable, Hashable {
    var xp: Int = 0
    var correct: Int = 0
    var wrong: Int = 0
    var sessions: Int = 0
}

enum PracticeMode: String, CaseIterable, Identifiable {
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
        case .quick: return "A fresh mixed session"
        case .bookmarks: return "Practise your bookmarks"
        case .mistakes: return "Retry phrases you’ve missed"
        case .weak: return "Prioritise your lowest mastery"
        case .typing: return "No multiple-choice safety net"
        case .listening: return "Hear it, then write it"
        case .speaking: return "Say the phrase aloud"
        case .matching: return "Fast translation matching"
        case .lemma: return "Drill saved chunks and lemmas"
        }
    }

    var systemImage: String {
        switch self {
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
