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
    private var questionStartedAt = Date()
    private static let lessonFlowVersionBase = 2

    private enum LessonScaffoldExercise: CaseIterable {
        case visibleBuild
        case audioBuild
        case listenWrite
        case speaking
    }

    init(
        session: QuizSession,
        savedSession: SavedLessonSession? = nil,
        progressStore: ProgressStore
    ) {
        self.session = session

        if let savedSession,
           let nodeID = session.completionNodeID,
           savedSession.nodeID == nodeID,
           savedSession.course == session.course,
           savedSession.flowVersion == Self.lessonFlowVersion(for: session),
           !savedSession.questions.isEmpty,
           !savedSession.questions.contains(where: { $0.type == .introduction }) {
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
            let generated = Self.makeQuestions(session: session, progressStore: progressStore)
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
        case .introduction:
            return true
        case .multipleChoice, .fillBlank, .matching, .lemma:
            return selectedAnswer != nil
        case .typing, .speaking:
            return !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .listening:
            if question.wordBankTokens.isEmpty {
                return !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return !selectedWordIndices.isEmpty
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

    private var isOpenCorpusListeningPractice: Bool {
        Self.isOpenCorpusListeningPractice(session)
    }

    func snapshot() -> SavedLessonSession? {
        guard let nodeID = session.completionNodeID else { return nil }
        return SavedLessonSession(
            nodeID: nodeID,
            course: session.course,
            flowVersion: Self.lessonFlowVersion(for: session),
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

    func placeWordAtEnd(index: Int) {
        guard status == .unanswered,
              let question = currentQuestion,
              question.wordBankTokens.indices.contains(index) else { return }
        selectedWordIndices.removeAll { $0 == index }
        selectedWordIndices.append(index)
    }

    func moveWord(index: Int, before targetIndex: Int) {
        guard status == .unanswered,
              let question = currentQuestion,
              question.wordBankTokens.indices.contains(index),
              question.wordBankTokens.indices.contains(targetIndex),
              index != targetIndex else { return }

        selectedWordIndices.removeAll { $0 == index }
        guard let destination = selectedWordIndices.firstIndex(of: targetIndex) else {
            selectedWordIndices.append(index)
            return
        }
        selectedWordIndices.insert(index, at: destination)
    }

    func returnWordToBank(index: Int) {
        guard status == .unanswered else { return }
        selectedWordIndices.removeAll { $0 == index }
    }

    func clearWordBank() {
        guard status == .unanswered else { return }
        selectedWordIndices = []
    }

    func useTranscript(_ transcript: String) {
        guard status == .unanswered else { return }
        typedAnswer = transcript
    }

    func acceptSpeakingRecognition(
        progressStore: ProgressStore,
        settings: SettingsStore
    ) {
        guard let question = currentQuestion,
              question.type == .speaking,
              status == .unanswered else { return }

        typedAnswer = question.correctAnswer
        check(
            progressStore: progressStore,
            settings: settings
        )
    }

    func acknowledgeIntroduction(progressStore: ProgressStore) {
        guard let question = currentQuestion,
              question.type == .introduction,
              status == .unanswered else { return }
        progressStore.recordExposure(course: session.course, phrase: question.phrase)
        status = .correct
        persistSnapshot(to: progressStore)
    }

    func check(progressStore: ProgressStore, settings: SettingsStore) {
        guard let question = currentQuestion, responseIsReady else { return }
        guard question.type != .introduction else {
            acknowledgeIntroduction(progressStore: progressStore)
            return
        }

        let response: String
        switch question.type {
        case .introduction:
            response = ""
        case .multipleChoice, .fillBlank, .matching, .lemma:
            response = selectedAnswer ?? ""
        case .typing, .speaking:
            response = typedAnswer
        case .listening:
            response = question.wordBankTokens.isEmpty ? typedAnswer : wordBankAnswer
        case .wordBank:
            response = wordBankAnswer
        }

        let correct = Self.answersMatch(response, question.correctAnswer)
        let parts = Self.partialCredit(
            for: question,
            selectedWordIndices: selectedWordIndices,
            responseWasCorrect: correct
        )
        let responseTime = max(0.2, Date().timeIntervalSince(questionStartedAt))

        if !isOpenCorpusListeningPractice {
            let trackedType: ExerciseType = question.type == .listening && !question.wordBankTokens.isEmpty
                ? .wordBank
                : question.type
            let isLessonScaffold = session.completionNodeID != nil
                && Self.isLessonScaffoldQuestion(question)
                && progressStore.lessonScaffoldSuccessCount(
                    course: session.course,
                    phrase: question.phrase
                ) < LessonScaffoldExercise.allCases.count

            progressStore.recordAttempt(
                course: session.course,
                phrase: question.phrase,
                correct: correct,
                exerciseType: trackedType,
                direction: question.direction,
                responseTimeSeconds: responseTime,
                correctParts: parts.correct,
                totalParts: parts.total,
                isLessonScaffold: isLessonScaffold
            )
        }

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
            let retry: QuizQuestion
            if isOpenCorpusListeningPractice {
                retry = Self.makeQuestion(
                    phrase: question.phrase,
                    type: .listening,
                    stage: .assistedRecall,
                    index: questions.count,
                    phrasePool: session.phrasePool,
                    allPhrases: session.allPhrases
                )
            } else if session.completionNodeID != nil,
                      Self.isLessonScaffoldQuestion(question),
                      progressStore.lessonScaffoldSuccessCount(
                        course: session.course,
                        phrase: question.phrase
                      ) < LessonScaffoldExercise.allCases.count {
                retry = Self.makeExactScaffoldRetry(
                    for: question,
                    index: questions.count,
                    session: session
                )
            } else {
                retry = Self.makeQuestionForCurrentStage(
                    phrase: question.phrase,
                    index: questions.count,
                    session: session,
                    progressStore: progressStore
                )
            }
            questions.append(retry)
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
        questionStartedAt = Date()
    }

    private static func isOpenCorpusListeningPractice(_ session: QuizSession) -> Bool {
        session.completionNodeID == nil
            && session.title == PracticeMode.listening.title
            && session.exerciseTypes == Set([.listening])
    }

    private static func lessonFlowVersion(for session: QuizSession) -> Int {
        lessonFlowVersionBase
            + (criticalExerciseEnabled(.listening, in: session) ? 0 : 100)
            + (criticalExerciseEnabled(.speaking, in: session) ? 0 : 200)
    }

    private static func criticalExerciseEnabled(_ type: ExerciseType, in session: QuizSession) -> Bool {
        guard type == .listening || type == .speaking else { return true }
        if session.exerciseTypes.isEmpty { return true }
        return session.exerciseTypes.contains(type)
    }

    private static func makeQuestions(session: QuizSession, progressStore: ProgressStore) -> [QuizQuestion] {
        guard !session.phrasePool.isEmpty else { return [] }

        if isOpenCorpusListeningPractice(session) {
            let selected = Array(session.phrasePool.shuffled().prefix(max(1, min(session.sessionSize, session.phrasePool.count))))
            return selected.enumerated().map { index, phrase in
                makeQuestion(
                    phrase: phrase,
                    type: .listening,
                    stage: .assistedRecall,
                    index: index,
                    phrasePool: session.phrasePool,
                    allPhrases: session.allPhrases
                )
            }
        }

        let allowed = session.exerciseTypes.isEmpty
            ? Set(ExerciseType.userSelectableCases)
            : session.exerciseTypes.subtracting([.introduction])

        let corePhrases: [PhraseEntry]
        if session.completionNodeID != nil {
            corePhrases = session.phrasePool.shuffled()
        } else {
            let learned = session.phrasePool.filter {
                progressStore.learningStage(course: session.course, phrase: $0) != .unseen
            }
            guard !learned.isEmpty else { return [] }
            corePhrases = Array(learned.prefix(max(1, min(session.sessionSize, learned.count))))
        }

        if session.completionNodeID != nil {
            var lessonQuestions: [QuizQuestion] = []
            for (index, phrase) in corePhrases.enumerated() {
                let completed = progressStore.lessonScaffoldSuccessCount(
                    course: session.course,
                    phrase: phrase
                )
                if completed < LessonScaffoldExercise.allCases.count {
                    lessonQuestions.append(contentsOf: makeLessonScaffoldQuestions(
                        phrase: phrase,
                        completedCount: completed,
                        index: index * LessonScaffoldExercise.allCases.count,
                        session: session
                    ))
                } else {
                    lessonQuestions.append(makeQuestionForCurrentStage(
                        phrase: phrase,
                        index: index,
                        session: session,
                        progressStore: progressStore,
                        allowedOverride: allowed
                    ))
                }
            }

            let excluded = Set(corePhrases.map { $0.progressKey(course: session.course) })
            let reviewPhrases = progressStore.duePhrases(
                course: session.course,
                from: session.allPhrases,
                excluding: excluded,
                limit: 3,
                threshold: 0.86
            )
            for (offset, phrase) in reviewPhrases.enumerated() {
                let completed = progressStore.lessonScaffoldSuccessCount(
                    course: session.course,
                    phrase: phrase
                )
                if completed < LessonScaffoldExercise.allCases.count {
                    lessonQuestions.append(contentsOf: makeLessonScaffoldQuestions(
                        phrase: phrase,
                        completedCount: completed,
                        index: (corePhrases.count + offset) * LessonScaffoldExercise.allCases.count,
                        session: session
                    ))
                } else {
                    lessonQuestions.append(makeQuestionForCurrentStage(
                        phrase: phrase,
                        index: corePhrases.count + offset,
                        session: session,
                        progressStore: progressStore,
                        allowedOverride: allowed
                    ))
                }
            }

            return lessonQuestions.shuffled()
        }

        return corePhrases.enumerated().map { index, phrase in
            makeQuestionForCurrentStage(
                phrase: phrase,
                index: index,
                session: session,
                progressStore: progressStore,
                allowedOverride: allowed
            )
        }.shuffled()
    }

    private static func makeLessonScaffoldQuestions(
        phrase: PhraseEntry,
        completedCount: Int,
        index: Int,
        session: QuizSession
    ) -> [QuizQuestion] {
        let safeCompleted = max(0, min(LessonScaffoldExercise.allCases.count, completedCount))
        return LessonScaffoldExercise.allCases
            .dropFirst(safeCompleted)
            .shuffled()
            .enumerated()
            .map { offset, exercise in
                makeLessonScaffoldQuestion(
                    exercise,
                    phrase: phrase,
                    index: index + offset,
                    session: session
                )
            }
    }

    private static func makeLessonScaffoldQuestion(
        _ exercise: LessonScaffoldExercise,
        phrase: PhraseEntry,
        index: Int,
        session: QuizSession
    ) -> QuizQuestion {
        let requestedType: ExerciseType
        let stage: PhraseLearningStage

        switch exercise {
        case .visibleBuild:
            requestedType = .wordBank
            stage = .introduced
        case .audioBuild:
            requestedType = .listening
            stage = .recognition
        case .listenWrite:
            requestedType = .listening
            stage = .assistedRecall
        case .speaking:
            requestedType = .speaking
            stage = .assistedRecall
        }

        let effectiveType = scaffoldExerciseType(
            requestedType,
            in: session
        )

        return makeQuestion(
            phrase: phrase,
            type: effectiveType,
            stage: stage,
            index: index,
            phrasePool: session.phrasePool,
            allPhrases: session.allPhrases
        )
    }

    private static func scaffoldExerciseType(
        _ requestedType: ExerciseType,
        in session: QuizSession
    ) -> ExerciseType {
        guard requestedType == .listening || requestedType == .speaking else {
            return requestedType
        }
        guard !criticalExerciseEnabled(requestedType, in: session) else {
            return requestedType
        }

        var replacements: [ExerciseType] = [.wordBank, .typing]

        if criticalExerciseEnabled(.listening, in: session), requestedType != .listening {
            replacements.append(.listening)
        }
        if criticalExerciseEnabled(.speaking, in: session), requestedType != .speaking {
            replacements.append(.speaking)
        }

        return replacements.randomElement() ?? .typing
    }

    private static func isLessonScaffoldQuestion(_ question: QuizQuestion) -> Bool {
        question.type != .introduction
    }

    private static func makeExactScaffoldRetry(
        for question: QuizQuestion,
        index: Int,
        session: QuizSession
    ) -> QuizQuestion {
        let stage: PhraseLearningStage
        if question.type == .listening {
            stage = question.wordBankTokens.isEmpty ? .assistedRecall : .recognition
        } else {
            stage = .assistedRecall
        }
        return makeQuestion(
            phrase: question.phrase,
            type: question.type,
            stage: stage,
            index: index,
            phrasePool: session.phrasePool,
            allPhrases: session.allPhrases
        )
    }

    private static func makeQuestionForCurrentStage(
        phrase: PhraseEntry,
        index: Int,
        session: QuizSession,
        progressStore: ProgressStore,
        allowedOverride: Set<ExerciseType>? = nil
    ) -> QuizQuestion {
        let stage = progressStore.learningStage(course: session.course, phrase: phrase)
        let allowed = allowedOverride ?? (session.exerciseTypes.isEmpty
            ? Set(ExerciseType.userSelectableCases)
            : session.exerciseTypes.subtracting([.introduction]))
        let type = exerciseType(
            for: phrase,
            stage: stage,
            allowed: allowed,
            course: session.course,
            progressStore: progressStore,
            index: index,
            isLesson: session.completionNodeID != nil
        )
        return makeQuestion(
            phrase: phrase,
            type: type,
            stage: stage,
            index: index,
            phrasePool: session.phrasePool,
            allPhrases: session.allPhrases
        )
    }

    private static func exerciseType(
        for phrase: PhraseEntry,
        stage: PhraseLearningStage,
        allowed: Set<ExerciseType>,
        course: LanguageCourse,
        progressStore: ProgressStore,
        index: Int,
        isLesson: Bool
    ) -> ExerciseType {
        let tokenCount = tokens(from: phrase.foreign).count
        let hasLemmas = !phrase.lemmas.isEmpty

        func compatible(_ candidates: [ExerciseType]) -> [ExerciseType] {
            candidates.filter { type in
                guard allowed.contains(type) else { return false }
                if type == .fillBlank && tokenCount < 2 { return false }
                if type == .lemma && !hasLemmas { return false }
                return true
            }
        }

        if isLesson {
            switch stage {
            case .unseen, .introduced, .recognition, .assistedRecall, .freeRecall:
                return .typing
            case .established:
                let core: [ExerciseType] = [.typing, .listening, .wordBank, .speaking]
                let criticalFiltered = core.filter { type in
                    if type == .listening || type == .speaking {
                        return allowed.contains(type)
                    }
                    return true
                }
                return adaptiveChoice(
                    criticalFiltered,
                    phrase: phrase,
                    stage: stage,
                    course: course,
                    progressStore: progressStore,
                    index: index
                ) ?? .typing
            }
        }

        switch stage {
        case .unseen, .introduced:
            let candidates = compatible([.multipleChoice, .matching, .lemma, .wordBank])
            return adaptiveChoice(
                candidates.isEmpty ? [.wordBank] : candidates,
                phrase: phrase,
                stage: stage,
                course: course,
                progressStore: progressStore,
                index: index
            ) ?? .wordBank
        case .recognition:
            return .wordBank
        case .assistedRecall:
            let candidates = compatible([.fillBlank, .wordBank, .typing, .listening, .speaking])
            return adaptiveChoice(
                candidates.isEmpty ? [.wordBank] : candidates,
                phrase: phrase,
                stage: stage,
                course: course,
                progressStore: progressStore,
                index: index
            ) ?? .wordBank
        case .freeRecall, .established:
            let candidates = compatible(Array(allowed))
            return adaptiveChoice(
                candidates.isEmpty ? [.typing, .listening, .wordBank] : candidates,
                phrase: phrase,
                stage: stage,
                course: course,
                progressStore: progressStore,
                index: index
            ) ?? .typing
        }
    }

    private static func adaptiveChoice(
        _ candidates: [ExerciseType],
        phrase: PhraseEntry,
        stage: PhraseLearningStage,
        course: LanguageCourse,
        progressStore: ProgressStore,
        index: Int
    ) -> ExerciseType? {
        guard !candidates.isEmpty else { return nil }

        guard progressStore.adaptiveObservationCount(course: course) >= 60 else {
            return candidates.randomElement()
        }
        if Int.random(in: 0..<8) == 0 {
            return candidates.randomElement()
        }

        let target = 0.78
        return candidates.min { lhs, rhs in
            let lhsDirection = predictedDirection(for: lhs, stage: stage, index: index)
            let rhsDirection = predictedDirection(for: rhs, stage: stage, index: index)
            let lhsProbability = progressStore.predictedSuccess(
                course: course,
                phrase: phrase,
                exerciseType: lhs,
                direction: lhsDirection,
                stage: stage
            )
            let rhsProbability = progressStore.predictedSuccess(
                course: course,
                phrase: phrase,
                exerciseType: rhs,
                direction: rhsDirection,
                stage: stage
            )
            return abs(lhsProbability - target) < abs(rhsProbability - target)
        }
    }

    private static func predictedDirection(
        for type: ExerciseType,
        stage: PhraseLearningStage,
        index: Int
    ) -> QuestionDirection {
        switch type {
        case .introduction, .lemma:
            return .foreignToEnglish
        case .multipleChoice, .matching:
            if stage <= .recognition { return .foreignToEnglish }
            return index.isMultiple(of: 2) ? .foreignToEnglish : .englishToForeign
        case .typing, .wordBank, .fillBlank, .listening, .speaking:
            return .englishToForeign
        }
    }

    private static func makeQuestion(
        phrase: PhraseEntry,
        type: ExerciseType,
        stage: PhraseLearningStage,
        index: Int,
        phrasePool: [PhraseEntry],
        allPhrases: [PhraseEntry]
    ) -> QuizQuestion {
        switch type {
        case .introduction:
            return QuizQuestion(
                type: .introduction,
                prompt: phrase.foreign,
                correctAnswer: phrase.foreign,
                direction: .foreignToEnglish,
                phrase: phrase
            )

        case .multipleChoice:
            let direction: QuestionDirection = stage <= .recognition
                ? .foreignToEnglish
                : (index.isMultiple(of: 2) ? .foreignToEnglish : .englishToForeign)
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
            return QuizQuestion(
                type: .typing,
                prompt: phrase.english,
                correctAnswer: phrase.foreign,
                direction: .englishToForeign,
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
            let isAudioTokenBuild = stage == .recognition
            return QuizQuestion(
                type: .listening,
                prompt: phrase.english,
                correctAnswer: phrase.foreign,
                direction: .englishToForeign,
                phrase: phrase,
                wordBankTokens: isAudioTokenBuild ? tokens(from: phrase.foreign).shuffled() : []
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
            let direction: QuestionDirection = stage <= .recognition
                ? .foreignToEnglish
                : (index.isMultiple(of: 2) ? .foreignToEnglish : .englishToForeign)
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
            guard let lemma = phrase.lemmas.randomElement() else {
                return makeQuestion(
                    phrase: phrase,
                    type: .multipleChoice,
                    stage: stage,
                    index: index,
                    phrasePool: phrasePool,
                    allPhrases: allPhrases
                )
            }
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

    private static func partialCredit(
        for question: QuizQuestion,
        selectedWordIndices: [Int],
        responseWasCorrect: Bool
    ) -> (correct: Int, total: Int) {
        let isTokenBuild = question.type == .wordBank
            || (question.type == .listening && !question.wordBankTokens.isEmpty)
        guard isTokenBuild else {
            return (responseWasCorrect ? 1 : 0, 1)
        }

        let answerTokens = tokens(from: question.correctAnswer)
        let responseTokens = selectedWordIndices.compactMap { index in
            question.wordBankTokens.indices.contains(index) ? question.wordBankTokens[index] : nil
        }
        let total = max(1, max(answerTokens.count, responseTokens.count))
        let matchingPositions = zip(answerTokens, responseTokens).reduce(0) { count, pair in
            count + (normalize(pair.0) == normalize(pair.1) ? 1 : 0)
        }
        return (matchingPositions, total)
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
