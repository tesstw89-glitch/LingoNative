import Foundation
import Combine

@MainActor
final class QuizViewModel: ObservableObject {
    @Published private(set) var questions: [QuizQuestion] = []
    @Published private(set) var currentIndex = 0
    @Published var selectedAnswer: String?
    @Published var typedAnswer = ""
    @Published var selectedWordIndices: [Int] = []
    @Published private(set) var status: QuizStatus = .unanswered
    @Published private(set) var mistakes = 0
    @Published private(set) var correctCount = 0

    let session: QuizSession
    private let initialQuestionCount: Int

    init(session: QuizSession, savedSession: SavedLessonSession? = nil) {
        self.session = session

        if let savedSession,
           let nodeID = session.completionNodeID,
           savedSession.nodeID == nodeID,
           savedSession.course == session.course,
           !savedSession.questions.isEmpty {
            questions = savedSession.questions
            currentIndex = min(savedSession.currentIndex, savedSession.questions.count)
            selectedAnswer = savedSession.selectedAnswer
            typedAnswer = savedSession.typedAnswer
            selectedWordIndices = savedSession.selectedWordIndices
            status = savedSession.status
            mistakes = savedSession.mistakes
            correctCount = savedSession.correctCount
            initialQuestionCount = max(1, savedSession.initialQuestionCount)
        } else {
            let generated = Self.makeQuestions(session: session)
            questions = generated
            initialQuestionCount = generated.count
        }
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
        max(10, correctCount * 10 + initialQuestionCount * 2 - mistakes * 2)
    }

    var responseIsReady: Bool {
        guard let question = currentQuestion else { return false }
        switch question.type {
        case .multipleChoice, .fillBlank, .matching, .lemma:
            return selectedAnswer != nil
        case .typing, .listening, .speaking:
            return !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .wordBank:
            return !selectedWordIndices.isEmpty
        }
    }

    var wordBankAnswer: String {
        guard let question = currentQuestion else { return "" }
        return selectedWordIndices.compactMap { index in
            guard question.wordBankTokens.indices.contains(index) else { return nil }
            return question.wordBankTokens[index]
        }.joined(separator: " ")
    }

    func snapshot() -> SavedLessonSession? {
        guard let nodeID = session.completionNodeID else { return nil }
        return SavedLessonSession(
            nodeID: nodeID,
            course: session.course,
            questions: questions,
            currentIndex: currentIndex,
            selectedAnswer: selectedAnswer,
            typedAnswer: typedAnswer,
            selectedWordIndices: selectedWordIndices,
            status: status,
            mistakes: mistakes,
            correctCount: correctCount,
            initialQuestionCount: initialQuestionCount,
            updatedAt: Date()
        )
    }

    func persistSnapshot(to progressStore: ProgressStore) {
        guard let snapshot = snapshot() else { return }
        progressStore.saveLessonSession(snapshot)
    }

    func select(_ answer: String) {
        guard status == .unanswered else { return }
        selectedAnswer = answer
    }

    func toggleWord(index: Int) {
        guard status == .unanswered,
              let question = currentQuestion,
              question.wordBankTokens.indices.contains(index) else { return }

        if let selectedIndex = selectedWordIndices.firstIndex(of: index) {
            selectedWordIndices.remove(at: selectedIndex)
        } else {
            selectedWordIndices.append(index)
        }
    }

    func clearWordBank() {
        guard status == .unanswered else { return }
        selectedWordIndices = []
    }

    func useTranscript(_ transcript: String) {
        guard status == .unanswered else { return }
        typedAnswer = transcript
    }

    func check(progressStore: ProgressStore, settings: SettingsStore) {
        guard let question = currentQuestion, responseIsReady else { return }

        let response: String
        switch question.type {
        case .multipleChoice, .fillBlank, .matching, .lemma:
            response = selectedAnswer ?? ""
        case .typing, .listening, .speaking:
            response = typedAnswer
        case .wordBank:
            response = wordBankAnswer
        }

        let correct = Self.answersMatch(response, question.correctAnswer)
        progressStore.recordAttempt(course: session.course, phrase: question.phrase, correct: correct)

        if correct {
            correctCount += 1
            status = .correct
        } else {
            mistakes += 1
            status = .wrong
            if settings.heartsEnabled && session.completionNodeID != nil {
                progressStore.loseHeart()
            }
        }

        persistSnapshot(to: progressStore)
    }

    func continueAfterFeedback(progressStore: ProgressStore) {
        guard let question = currentQuestion else { return }

        if status == .wrong {
            questions.append(Self.retry(of: question))
        }

        if status != .unanswered {
            currentIndex += 1
            resetResponse()
            persistSnapshot(to: progressStore)
        }
    }

    private func resetResponse() {
        selectedAnswer = nil
        typedAnswer = ""
        selectedWordIndices = []
        status = .unanswered
    }

    private static func retry(of question: QuizQuestion) -> QuizQuestion {
        QuizQuestion(
            type: question.type,
            prompt: question.prompt,
            options: question.options.shuffled(),
            correctAnswer: question.correctAnswer,
            direction: question.direction,
            phrase: question.phrase,
            wordBankTokens: question.wordBankTokens.shuffled(),
            blankedText: question.blankedText
        )
    }

    private static func makeQuestions(session: QuizSession) -> [QuizQuestion] {
        guard !session.phrasePool.isEmpty else { return [] }
        let count = max(1, min(session.sessionSize, session.phrasePool.count))
        let selectedPhrases = Array(session.phrasePool.shuffled().prefix(count))
        let allowed = session.exerciseTypes.isEmpty ? Set([ExerciseType.multipleChoice]) : session.exerciseTypes

        return selectedPhrases.enumerated().map { index, phrase in
            let compatible = compatibleTypes(for: phrase, allowed: allowed)
            let type = compatible.randomElement() ?? .multipleChoice
            return makeQuestion(
                phrase: phrase,
                type: type,
                index: index,
                phrasePool: session.phrasePool,
                allPhrases: session.allPhrases
            )
        }
    }

    private static func compatibleTypes(for phrase: PhraseEntry, allowed: Set<ExerciseType>) -> [ExerciseType] {
        var types = Array(allowed)
        let tokenCount = tokens(from: phrase.foreign).count
        if tokenCount < 2 {
            types.removeAll { $0 == .wordBank || $0 == .fillBlank }
        }
        if phrase.lemmas.isEmpty {
            types.removeAll { $0 == .lemma }
        }
        return types.isEmpty ? [.multipleChoice] : types
    }

    private static func makeQuestion(
        phrase: PhraseEntry,
        type: ExerciseType,
        index: Int,
        phrasePool: [PhraseEntry],
        allPhrases: [PhraseEntry]
    ) -> QuizQuestion {
        switch type {
        case .multipleChoice:
            let direction: QuestionDirection = index.isMultiple(of: 2) ? .foreignToEnglish : .englishToForeign
            let correct = answerText(for: phrase, direction: direction)
            let options = answerOptions(correct: correct, direction: direction, phrasePool: phrasePool, allPhrases: allPhrases)
            return QuizQuestion(
                type: .multipleChoice,
                prompt: direction == .foreignToEnglish ? phrase.foreign : phrase.english,
                options: options,
                correctAnswer: correct,
                direction: direction,
                phrase: phrase
            )

        case .typing:
            let direction: QuestionDirection = Bool.random() ? .englishToForeign : .foreignToEnglish
            return QuizQuestion(
                type: .typing,
                prompt: direction == .foreignToEnglish ? phrase.foreign : phrase.english,
                correctAnswer: answerText(for: phrase, direction: direction),
                direction: direction,
                phrase: phrase
            )

        case .wordBank:
            return QuizQuestion(
                type: .wordBank,
                prompt: phrase.english,
                correctAnswer: phrase.foreign,
                direction: .englishToForeign,
                phrase: phrase,
                wordBankTokens: tokens(from: phrase.foreign).shuffled()
            )

        case .fillBlank:
            let cloze = makeCloze(for: phrase, phrasePool: phrasePool, allPhrases: allPhrases)
            return QuizQuestion(
                type: .fillBlank,
                prompt: phrase.english,
                options: cloze.options,
                correctAnswer: cloze.answer,
                direction: .englishToForeign,
                phrase: phrase,
                blankedText: cloze.text
            )

        case .listening:
            return QuizQuestion(
                type: .listening,
                prompt: phrase.english,
                correctAnswer: phrase.foreign,
                direction: .englishToForeign,
                phrase: phrase
            )

        case .speaking:
            return QuizQuestion(
                type: .speaking,
                prompt: phrase.english,
                correctAnswer: phrase.foreign,
                direction: .englishToForeign,
                phrase: phrase
            )

        case .matching:
            let direction: QuestionDirection = Bool.random() ? .foreignToEnglish : .englishToForeign
            let correct = answerText(for: phrase, direction: direction)
            return QuizQuestion(
                type: .matching,
                prompt: direction == .foreignToEnglish ? phrase.foreign : phrase.english,
                options: answerOptions(correct: correct, direction: direction, phrasePool: phrasePool, allPhrases: allPhrases),
                correctAnswer: correct,
                direction: direction,
                phrase: phrase
            )

        case .lemma:
            let lemma = phrase.lemmas.randomElement()!
            var candidates = (phrasePool.shuffled() + allPhrases.shuffled())
                .flatMap(\.lemmas)
                .map(\.english)
                .filter { $0 != lemma.english }
            var seen = Set<String>([lemma.english])
            candidates = candidates.filter { seen.insert($0).inserted }
            let options = ([lemma.english] + candidates.prefix(3)).shuffled()
            return QuizQuestion(
                type: .lemma,
                prompt: lemma.foreign,
                options: options,
                correctAnswer: lemma.english,
                direction: .foreignToEnglish,
                phrase: phrase
            )
        }
    }

    private static func answerOptions(
        correct: String,
        direction: QuestionDirection,
        phrasePool: [PhraseEntry],
        allPhrases: [PhraseEntry]
    ) -> [String] {
        let candidates = (phrasePool.shuffled() + allPhrases.shuffled())
            .map { answerText(for: $0, direction: direction) }

        var seen = Set<String>([correct])
        var distractors: [String] = []
        for candidate in candidates where candidate != correct {
            if seen.insert(candidate).inserted {
                distractors.append(candidate)
            }
            if distractors.count == 3 { break }
        }
        return ([correct] + distractors).shuffled()
    }

    private static func makeCloze(
        for phrase: PhraseEntry,
        phrasePool: [PhraseEntry],
        allPhrases: [PhraseEntry]
    ) -> (text: String, answer: String, options: [String]) {
        let rawTokens = tokens(from: phrase.foreign)
        guard rawTokens.count >= 2 else {
            return ("____", phrase.foreign, [phrase.foreign])
        }

        let eligible = rawTokens.indices.filter { cleanedWord(rawTokens[$0]).count >= 2 }
        let targetIndex = eligible.randomElement() ?? rawTokens.indices.last!
        let answer = cleanedWord(rawTokens[targetIndex])

        let blanked = rawTokens.enumerated().map { index, token in
            index == targetIndex ? "____" : token
        }.joined(separator: " ")

        let candidateWords = (phrasePool.shuffled() + allPhrases.shuffled())
            .flatMap { tokens(from: $0.foreign) }
            .map(cleanedWord)
            .filter { $0.count >= 2 && $0 != answer }

        var seen = Set<String>([answer])
        var distractors: [String] = []
        for word in candidateWords {
            if seen.insert(word).inserted {
                distractors.append(word)
            }
            if distractors.count == 3 { break }
        }

        return (blanked, answer, ([answer] + distractors).shuffled())
    }

    private static func tokens(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func cleanedWord(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    private static func answerText(for phrase: PhraseEntry, direction: QuestionDirection) -> String {
        switch direction {
        case .foreignToEnglish: return phrase.english
        case .englishToForeign: return phrase.foreign
        }
    }

    static func answersMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    private static func normalize(_ text: String) -> String {
        let lower = text.lowercased()
        let allowed = CharacterSet.letters.union(.decimalDigits)
        let scalars = lower.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
