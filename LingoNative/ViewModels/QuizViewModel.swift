import Foundation

@MainActor
final class QuizViewModel: ObservableObject {
    @Published private(set) var questions: [QuizQuestion] = []
    @Published private(set) var currentIndex = 0
    @Published var selectedAnswer: String?
    @Published private(set) var status: QuizStatus = .unanswered
    @Published private(set) var mistakes = 0

    let course: LanguageCourse
    let unit: LearningUnit
    let node: LessonNode

    init(course: LanguageCourse, unit: LearningUnit, node: LessonNode, allPhrases: [PhraseEntry]) {
        self.course = course
        self.unit = unit
        self.node = node
        self.questions = Self.makeQuestions(
            course: course,
            unit: unit,
            allPhrases: allPhrases,
            count: max(1, node.sessionSize)
        )
    }

    var currentQuestion: QuizQuestion? {
        guard questions.indices.contains(currentIndex) else { return nil }
        return questions[currentIndex]
    }

    var isFinished: Bool {
        currentIndex >= questions.count
    }

    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return min(1, Double(currentIndex) / Double(questions.count))
    }

    var earnedXP: Int {
        max(10, questions.count * 10 - mistakes * 2)
    }

    func select(_ answer: String) {
        guard status == .unanswered else { return }
        selectedAnswer = answer
    }

    func check(progressStore: ProgressStore) {
        guard let question = currentQuestion, let selectedAnswer else { return }

        if selectedAnswer == question.correctAnswer {
            status = .correct
        } else {
            mistakes += 1
            status = .wrong
            progressStore.loseHeart()
        }
    }

    func continueAfterFeedback() {
        switch status {
        case .correct:
            currentIndex += 1
            selectedAnswer = nil
            status = .unanswered
        case .wrong:
            selectedAnswer = nil
            status = .unanswered
        case .unanswered:
            break
        }
    }

    private static func makeQuestions(
        course: LanguageCourse,
        unit: LearningUnit,
        allPhrases: [PhraseEntry],
        count: Int
    ) -> [QuizQuestion] {
        let selectedPhrases = Array(unit.phrases.shuffled().prefix(min(count, unit.phrases.count)))

        return selectedPhrases.enumerated().map { index, phrase in
            let direction: QuestionDirection = index.isMultiple(of: 2)
                ? .foreignToEnglish
                : .englishToForeign

            let correct = answerText(for: phrase, direction: direction)
            let candidates = (unit.phrases.shuffled() + allPhrases.shuffled())
                .map { answerText(for: $0, direction: direction) }

            var seen = Set<String>([correct])
            var distractors: [String] = []

            for candidate in candidates where candidate != correct {
                if seen.insert(candidate).inserted {
                    distractors.append(candidate)
                }
                if distractors.count == 3 { break }
            }

            let options = ([correct] + distractors).shuffled()
            let prompt = direction == .foreignToEnglish ? phrase.foreign : phrase.english

            return QuizQuestion(
                prompt: prompt,
                options: options,
                correctAnswer: correct,
                direction: direction,
                phrase: phrase
            )
        }
    }

    private static func answerText(for phrase: PhraseEntry, direction: QuestionDirection) -> String {
        switch direction {
        case .foreignToEnglish: return phrase.english
        case .englishToForeign: return phrase.foreign
        }
    }
}
