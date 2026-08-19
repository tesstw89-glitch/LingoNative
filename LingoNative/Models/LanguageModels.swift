import Foundation

struct Lemma: Codable, Hashable {
    let foreign: String
    let english: String
}

struct PhraseEntry: Codable, Identifiable, Hashable {
    let id: Int
    let foreign: String
    let english: String
    let lemmas: [Lemma]
    let context: String
}

enum LanguageCourse: String, CaseIterable, Identifiable, Hashable {
    case french
    case spanish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .french: return "French"
        case .spanish: return "Spanish"
        }
    }

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

    var accentName: String {
        switch self {
        case .french: return "French"
        case .spanish: return "Spanish"
        }
    }
}

struct LearningUnit: Identifiable, Hashable {
    let id: String
    let title: String
    let phrases: [PhraseEntry]

    func nodes(sessionSize: Int = 10) -> [LessonNode] {
        let count = max(1, Int(ceil(Double(phrases.count) / Double(sessionSize))))
        return (0..<count).map { index in
            LessonNode(
                id: "\(id)-lesson-\(index + 1)",
                unitID: id,
                index: index,
                sessionSize: min(sessionSize, phrases.count)
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
}

enum QuestionDirection: Equatable {
    case foreignToEnglish
    case englishToForeign
}

struct QuizQuestion: Identifiable, Equatable {
    let id = UUID()
    let prompt: String
    let options: [String]
    let correctAnswer: String
    let direction: QuestionDirection
    let phrase: PhraseEntry
}

enum QuizStatus: Equatable {
    case unanswered
    case correct
    case wrong
}
