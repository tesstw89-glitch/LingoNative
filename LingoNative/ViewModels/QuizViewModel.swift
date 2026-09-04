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
    @Published private(set) var isCheckingAlternative = false
    @Published private(set) var aiAlternativeAccepted = false
    @Published private(set) var matchingLeftSelection: Int?
    @Published private(set) var matchingRightSelection: Int?
    @Published private(set) var matchingWrongLeftIndex: Int?
    @Published private(set) var matchingWrongRightIndex: Int?

    private var matchingMissedLeftIndices: Set<Int> = []

    let session: QuizSession
    private let initialQuestionCount: Int
    private var questionStartedAt = Date()
    private static let lessonFlowVersionBase = 11

    private struct PendingAIAlternative {
        let questionID: UUID
        let responseTime: Double
        let trackedType: ExerciseType
        let correctParts: Int
        let totalParts: Int
        let isLessonScaffold: Bool
    }

    private var pendingAIAlternative: PendingAIAlternative?
    private struct PendingManualReview {
        let questionID: UUID
        let responseTime: Double
        let trackedType: ExerciseType
        let totalParts: Int
        let isLessonScaffold: Bool
    }

    private var pendingManualReview: PendingManualReview?

    var canOverrideWrong: Bool {
        pendingManualReview != nil && status == .wrong
    }

    var shouldShowReferenceAnswer: Bool {
        guard status == .correct,
              let question = currentQuestion,
              question.direction == .englishToForeign else {
            return false
        }

        let response = responseText(for: question)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !response.isEmpty else { return false }

        // Ignore superficial differences such as spaces, punctuation and case.
        // If the accepted target-language wording itself differs from the
        // corpus answer, show the corpus/reference answer in feedback.
        return Self.normalize(response) != Self.normalize(question.correctAnswer)
    }
    /// New phrases clear two distinct non-writing formats before free production.
    /// UNDERSTAND -> BUILD -> WRITE -> SPEAK.
    /// The legacy variedRecall slot remains in the enum but is deliberately skipped.
    private enum LessonScaffoldExercise: Int, CaseIterable {
        case comprehension
        case assistedBuild
        case variedRecall
        case writeAnswer
        case speaking
    }

    private struct LebaneseVerbForm: Decodable {
        let arabic: String
        let transliteration: String?
        let english: String
    }

    private struct LebaneseVerbLemma: Decodable {
        let arabic: String
        let transliteration: String?
        let english: String
    }

    private struct LebaneseVerbRecord: Decodable {
        let id: Int
        let lemma: LebaneseVerbLemma
        let past: [String: LebaneseVerbForm]
        let present: [String: LebaneseVerbForm]
        let bare_subjunctive: [String: LebaneseVerbForm]
        let progressive: [String: LebaneseVerbForm]
        let future: [String: LebaneseVerbForm]
        let past_habitual: [String: LebaneseVerbForm]
        let conditionals: [String: [String: LebaneseVerbForm]]
    }

    private struct LebaneseVerbCorpus: Decodable {
        let verbs: [LebaneseVerbRecord]
    }

    private struct ConjugationFamily {
        let key: String
        let title: String
        let conditional: Bool
        let usedWith: String?
    }

    private static let arabicConjugationCheckpointTopicID = "__arabic_conjugation_match__"

    private static let bareImperfectUsedWith =
        "USED WITH: بدّي (baddé) — I want; بدّك (baddak/baddik) — you want; لازم (lézem) — must / have to; فيني (fīné) — I can; ما فيني (ma fīné) — I can’t; رح (raḥ) — will / going to; خلّيني (khallīné) — let me; خلّيه (khallīh) — let him; ممكن (momken) — possible / can; بقدر (baʾdar) — I can / am able to"

    private static let conjugationFamilies: [ConjugationFamily] = [
        .init(key: "past", title: "Past", conditional: false, usedWith: nil),
        .init(key: "present", title: "Present (b-/m- imperfect)", conditional: false, usedWith: nil),
        .init(key: "bare_subjunctive", title: "Bare / non-b imperfect", conditional: false, usedWith: bareImperfectUsedWith),
        .init(key: "progressive", title: "Progressive (عم)", conditional: false, usedWith: nil),
        .init(key: "future", title: "Future (رح)", conditional: false, usedWith: nil),
        .init(key: "past_habitual", title: "Past habitual", conditional: false, usedWith: nil),
        .init(key: "if_real_present", title: "Real if-clause (إذا + present)", conditional: true, usedWith: nil),
        .init(key: "if_real_past_form", title: "Real future if-clause (إذا + past form)", conditional: true, usedWith: nil),
        .init(key: "if_unreal_hypothetical", title: "Hypothetical if-clause (لو)", conditional: true, usedWith: nil),
        .init(key: "if_past_counterfactual", title: "Past counterfactual if-clause (لو)", conditional: true, usedWith: nil),
        .init(key: "would_hypothetical", title: "Hypothetical result (would)", conditional: true, usedWith: nil),
        .init(key: "would_have", title: "Past counterfactual result (would have)", conditional: true, usedWith: nil)
    ]

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
           Self.savedLessonFlowIsCompatible(savedSession.flowVersion, session: session),
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

    /// Regenerate this practice session from question one.
    /// Used by Emergency Refill after the learner reaches three confirmed mistakes.
    func restartSession(progressStore: ProgressStore) {
        questions = Self.makeQuestions(session: session, progressStore: progressStore)
        currentIndex = 0
        selectedAnswer = nil
        typedAnswer = ""
        selectedWordIndices = []
        status = .unanswered
        mistakes = 0
        correctCount = 0
        isCheckingAlternative = false
        aiAlternativeAccepted = false
        matchingLeftSelection = nil
        matchingRightSelection = nil
        matchingWrongLeftIndex = nil
        matchingWrongRightIndex = nil
        matchingMissedLeftIndices = []
        pendingAIAlternative = nil
        pendingManualReview = nil
        questionStartedAt = Date()
        persistSnapshot(to: progressStore)
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
        case .multipleChoice, .lemma:
            return selectedAnswer != nil
        case .fillBlank:
            return !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .matching:
            if Self.isArabicPairMatchingQuestion(question) {
                return !question.wordBankTokens.isEmpty
                    && selectedWordIndices.count == question.wordBankTokens.count
            }
            return selectedAnswer != nil
        case .typing, .listenWrite, .speaking:
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

        // AI-rescued answers are deliberately not committed until the learner
        // chooses NEXT or “I got this wrong”.
        let savedStatus: QuizStatus =
            pendingAIAlternative == nil && pendingManualReview == nil
                ? status
                : .unanswered

        return SavedLessonSession(
            nodeID: nodeID,
            course: session.course,
            flowVersion: Self.lessonFlowVersion(for: session),
            questions: questions,
            currentIndex: currentIndex,
            selectedAnswer: selectedAnswer,
            typedAnswer: typedAnswer,
            selectedWordIndices: selectedWordIndices,
            status: savedStatus,
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

    func isArabicLemmaCheckpoint(_ question: QuizQuestion) -> Bool {
        Self.isArabicLemmaCheckpointQuestion(question)
    }

    func isArabicConjugationCheckpoint(_ question: QuizQuestion) -> Bool {
        Self.isArabicConjugationCheckpointQuestion(question)
    }

    func isArabicPairMatchingBoard(_ question: QuizQuestion) -> Bool {
        Self.isArabicPairMatchingQuestion(question)
    }

    func selectArabicLemmaMatchLeft(
        index: Int,
        progressStore: ProgressStore
    ) {
        guard status == .unanswered,
              let question = currentQuestion,
              Self.isArabicPairMatchingQuestion(question),
              question.wordBankTokens.indices.contains(index),
              !selectedWordIndices.contains(index) else { return }

        matchingWrongLeftIndex = nil
        matchingWrongRightIndex = nil
        matchingLeftSelection = matchingLeftSelection == index ? nil : index
        resolveArabicLemmaMatchIfReady(progressStore: progressStore)
    }

    func selectArabicLemmaMatchRight(
        index: Int,
        progressStore: ProgressStore
    ) {
        guard status == .unanswered,
              let question = currentQuestion,
              Self.isArabicPairMatchingQuestion(question),
              question.options.indices.contains(index) else { return }

        let english = question.options[index]
        if let lemma = question.phrase.lemmas.first(where: { $0.english == english }),
           let leftIndex = question.wordBankTokens.firstIndex(of: lemma.foreign),
           selectedWordIndices.contains(leftIndex) {
            return
        }

        matchingWrongLeftIndex = nil
        matchingWrongRightIndex = nil
        matchingRightSelection = matchingRightSelection == index ? nil : index
        resolveArabicLemmaMatchIfReady(progressStore: progressStore)
    }

    private func resolveArabicLemmaMatchIfReady(progressStore: ProgressStore) {
        guard let question = currentQuestion,
              Self.isArabicPairMatchingQuestion(question),
              let leftIndex = matchingLeftSelection,
              let rightIndex = matchingRightSelection,
              question.wordBankTokens.indices.contains(leftIndex),
              question.options.indices.contains(rightIndex) else { return }

        let foreign = question.wordBankTokens[leftIndex]
        let english = question.options[rightIndex]

        if let lemma = question.phrase.lemmas.first(where: {
            $0.foreign == foreign && $0.english == english
        }) {
            if Self.isArabicLemmaCheckpointQuestion(question) {
                let firstTry = !matchingMissedLeftIndices.contains(leftIndex)
                progressStore.recordLemmaMatch(
                    course: session.course,
                    lemma: lemma,
                    successfulOnFirstTry: firstTry
                )
            }

            if !selectedWordIndices.contains(leftIndex) {
                selectedWordIndices.append(leftIndex)
            }

            matchingLeftSelection = nil
            matchingRightSelection = nil
            matchingWrongLeftIndex = nil
            matchingWrongRightIndex = nil

            if selectedWordIndices.count == question.wordBankTokens.count {
                correctCount += 1
                status = .correct
                persistSnapshot(to: progressStore)
            }
            return
        }

        matchingMissedLeftIndices.insert(leftIndex)
        matchingWrongLeftIndex = leftIndex
        matchingWrongRightIndex = rightIndex
        matchingLeftSelection = nil
        matchingRightSelection = nil

        let questionID = question.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self,
                  self.currentQuestion?.id == questionID else { return }
            if self.matchingWrongLeftIndex == leftIndex {
                self.matchingWrongLeftIndex = nil
            }
            if self.matchingWrongRightIndex == rightIndex {
                self.matchingWrongRightIndex = nil
            }
        }
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

    /// Deterministic checker retained for speaking/listening/assisted tasks.
    func check(progressStore: ProgressStore, settings: SettingsStore) {
        guard let question = currentQuestion, responseIsReady else { return }
        guard question.type != .introduction else {
            acknowledgeIntroduction(progressStore: progressStore)
            return
        }

        let response = responseText(for: question)
        let responseTime = max(0.2, Date().timeIntervalSince(questionStartedAt))
        resolveAnswer(
            question: question,
            correct: Self.answersMatch(response, question.correctAnswer),
            responseTime: responseTime,
            progressStore: progressStore,
            settings: settings
        )
    }

    /// Exact matches remain instant. Only a non-exact free-typing answer that survives
    /// the deterministic semantic guardrails wakes the local Qwen model.
    func checkEnhanced(
        progressStore: ProgressStore,
        settings: SettingsStore
    ) async {
        guard let question = currentQuestion,
              responseIsReady,
              !isCheckingAlternative else { return }

        guard question.type != .introduction else {
            acknowledgeIntroduction(progressStore: progressStore)
            return
        }

        let response = responseText(for: question)
        let responseTime = max(0.2, Date().timeIntervalSince(questionStartedAt))

        if Self.answersMatch(response, question.correctAnswer) {
            resolveAnswer(
                question: question,
                correct: true,
                responseTime: responseTime,
                progressStore: progressStore,
                settings: settings
            )
            return
        }

        let canUseAI = settings.enhancedAnswerCheckingEnabled
            && question.type == .typing
            && question.direction == .englishToForeign
            && FileManager.default.fileExists(atPath: LocalAIModelFiles.modelURL.path)

        guard canUseAI else {
            resolveAnswer(
                question: question,
                correct: false,
                responseTime: responseTime,
                progressStore: progressStore,
                settings: settings
            )
            return
        }

        if let conflict = LocalSemanticGuardrails.clearConflict(
            course: session.course,
            reference: question.correctAnswer,
            learner: response
        ) {
            print("LingoNative AI rescue blocked by guardrail: \(conflict)")
            resolveAnswer(
                question: question,
                correct: false,
                responseTime: responseTime,
                progressStore: progressStore,
                settings: settings
            )
            return
        }

        isCheckingAlternative = true
        let questionID = question.id

        let register: String
        switch session.course {
        case .french:
            register = "informal everyday spoken French"
        case .spanish:
            register = "informal everyday Madrid Spanish"
        case .arabic:
            register = "informal everyday urban Lebanese Arabic"
        }

        let result = await LocalLanguageJudge.shared.judge(
            language: session.course.title,
            register: register,
            english: question.phrase.english,
            reference: question.correctAnswer,
            learner: response,
            context: question.phrase.context
        )

        isCheckingAlternative = false

        guard let liveQuestion = currentQuestion,
              liveQuestion.id == questionID,
              status == .unanswered else { return }

        if result.verdict == "ACCEPT" {
            let metadata = attemptMetadata(
                for: liveQuestion,
                progressStore: progressStore
            )

            pendingAIAlternative = PendingAIAlternative(
                questionID: questionID,
                responseTime: responseTime,
                trackedType: metadata.trackedType,
                correctParts: 1,
                totalParts: 1,
                isLessonScaffold: metadata.isLessonScaffold
            )

            aiAlternativeAccepted = true
            status = .correct

            print(
                String(
                    format: "LingoNative AI accepted alternative in %.2fs",
                    result.elapsedSeconds
                )
            )

            // snapshot() deliberately persists this as unanswered until the learner confirms.
            persistSnapshot(to: progressStore)
        } else {
            if let error = result.errorMessage {
                print("LingoNative AI fallback failed safely: \(error)")
            }

            resolveAnswer(
                question: liveQuestion,
                correct: false,
                responseTime: responseTime,
                progressStore: progressStore,
                settings: settings
            )
        }
    }
    func overridePendingWrongAsCorrect(progressStore: ProgressStore) {
        guard let pending = pendingManualReview,
              let question = currentQuestion,
              question.id == pending.questionID,
              status == .wrong else { return }

        if !isOpenCorpusListeningPractice {
            progressStore.recordAttempt(
                course: session.course,
                phrase: question.phrase,
                correct: true,
                exerciseType: pending.trackedType,
                direction: question.direction,
                responseTimeSeconds: pending.responseTime,
                correctParts: pending.totalParts,
                totalParts: pending.totalParts,
                isLessonScaffold: pending.isLessonScaffold
            )
        }

        correctCount += 1
        pendingManualReview = nil
        status = .correct
        persistSnapshot(to: progressStore)
    }

    func confirmPendingWrong(
        progressStore: ProgressStore,
        settings: SettingsStore
    ) {
        guard let pending = pendingManualReview,
              let question = currentQuestion,
              question.id == pending.questionID,
              status == .wrong else { return }

        if !isOpenCorpusListeningPractice {
            progressStore.recordAttempt(
                course: session.course,
                phrase: question.phrase,
                correct: false,
                exerciseType: pending.trackedType,
                direction: question.direction,
                responseTimeSeconds: pending.responseTime,
                correctParts: 0,
                totalParts: pending.totalParts,
                isLessonScaffold: pending.isLessonScaffold
            )
        }

        mistakes += 1

        if settings.heartsEnabled && session.completionNodeID != nil {
            progressStore.loseHeart()
        }

        pendingManualReview = nil
        persistSnapshot(to: progressStore)
    }
    /// Learner agrees with the AI rescue. Only now does FSRS get a success.
    func confirmAIAlternativeCorrect(progressStore: ProgressStore) {
        guard let pending = pendingAIAlternative,
              let question = currentQuestion,
              question.id == pending.questionID,
              status == .correct,
              aiAlternativeAccepted else { return }

        if !isOpenCorpusListeningPractice {
            progressStore.recordAttempt(
                course: session.course,
                phrase: question.phrase,
                correct: true,
                exerciseType: pending.trackedType,
                direction: question.direction,
                responseTimeSeconds: pending.responseTime,
                correctParts: pending.correctParts,
                totalParts: pending.totalParts,
                isLessonScaffold: pending.isLessonScaffold
            )
        }

        correctCount += 1
        pendingAIAlternative = nil
        aiAlternativeAccepted = false
        persistSnapshot(to: progressStore)
    }

    /// Learner spots that Qwen was too generous. Record a normal miss and retry it later.
    func markAIAlternativeWrong(
        progressStore: ProgressStore,
        settings: SettingsStore
    ) {
        guard let pending = pendingAIAlternative,
              let question = currentQuestion,
              question.id == pending.questionID,
              status == .correct,
              aiAlternativeAccepted else { return }

        if !isOpenCorpusListeningPractice {
            progressStore.recordAttempt(
                course: session.course,
                phrase: question.phrase,
                correct: false,
                exerciseType: pending.trackedType,
                direction: question.direction,
                responseTimeSeconds: pending.responseTime,
                correctParts: 0,
                totalParts: max(1, pending.totalParts),
                isLessonScaffold: pending.isLessonScaffold
            )
        }

        mistakes += 1
        if settings.heartsEnabled && session.completionNodeID != nil {
            progressStore.loseHeart()
        }

        pendingAIAlternative = nil
        aiAlternativeAccepted = false
        status = .wrong
        persistSnapshot(to: progressStore)
    }

    private func responseText(for question: QuizQuestion) -> String {
        switch question.type {
        case .introduction:
            return ""
        case .multipleChoice, .matching, .lemma:
            return selectedAnswer ?? ""
        case .typing, .fillBlank, .listenWrite, .speaking:
            return typedAnswer
        case .listening:
            return question.wordBankTokens.isEmpty ? typedAnswer : wordBankAnswer
        case .wordBank:
            return wordBankAnswer
        }
    }

    private func attemptMetadata(
        for question: QuizQuestion,
        progressStore: ProgressStore
    ) -> (trackedType: ExerciseType, isLessonScaffold: Bool) {
        // Track the exercise the learner actually experienced. This matters for the
        // three-distinct-types gate: a listening question with word tiles is still Listening.
        let trackedType: ExerciseType = question.type

        let isLessonScaffold = session.completionNodeID != nil
            && Self.scaffoldSuccessCount(
                phrase: question.phrase,
                session: session,
                progressStore: progressStore
            ) < LessonScaffoldExercise.allCases.count

        return (trackedType, isLessonScaffold)
    }

    private func resolveAnswer(
        question: QuizQuestion,
        correct: Bool,
        responseTime: Double,
        progressStore: ProgressStore,
        settings: SettingsStore
    ) {
        let parts = Self.partialCredit(
            for: question,
            selectedWordIndices: selectedWordIndices,
            responseWasCorrect: correct
        )
        // Free-typing misses wait for the learner to confirm whether they
        // were genuinely wrong. This allows tiny punctuation/apostrophe issues
        // to be manually marked correct without damaging FSRS or costing a heart.
        if !correct,
           (
               (question.type == .typing && question.direction == .englishToForeign) ||
               question.type == .listenWrite ||
               question.type == .wordBank ||
               (question.type == .listening && question.wordBankTokens.isEmpty)
           ) {

            let metadata = attemptMetadata(
                for: question,
                progressStore: progressStore
            )

            pendingManualReview = PendingManualReview(
                questionID: question.id,
                responseTime: responseTime,
                trackedType: metadata.trackedType,
                totalParts: max(1, parts.total),
                isLessonScaffold: metadata.isLessonScaffold
            )

            status = .wrong
            persistSnapshot(to: progressStore)
            return
        }
        if !isOpenCorpusListeningPractice {
            let metadata = attemptMetadata(
                for: question,
                progressStore: progressStore
            )

            progressStore.recordAttempt(
                course: session.course,
                phrase: question.phrase,
                correct: correct,
                exerciseType: metadata.trackedType,
                direction: question.direction,
                responseTimeSeconds: responseTime,
                correctParts: parts.correct,
                totalParts: parts.total,
                isLessonScaffold: metadata.isLessonScaffold
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
        guard pendingAIAlternative == nil,
              pendingManualReview == nil,
              let question = currentQuestion else { return }

        let isArabicLemmaCheckpoint = Self.isArabicLemmaCheckpointQuestion(question)
        let isArabicConjugationCheckpoint = Self.isArabicConjugationCheckpointQuestion(question)
        let isArabicPairCheckpoint = isArabicLemmaCheckpoint || isArabicConjugationCheckpoint

        if !isArabicPairCheckpoint && status == .wrong {
            // Immediate rescue: a missed WRITE is followed by the same phrase as drag-and-drop.
            // This is EXTRA remediation only; the original write retry still comes back later.
            if !session.isUnitReview
                && (question.type == .typing || question.type == .listenWrite) {
                let rescue = Self.makeQuestion(
                    phrase: question.phrase,
                    type: .wordBank,
                    stage: .recognition,
                    index: currentIndex + 1,
                    phrasePool: session.phrasePool,
                    allPhrases: session.allPhrases
                )
                questions.insert(rescue, at: min(currentIndex + 1, questions.count))
            }

            // A miss always comes back later in the same lesson.
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
            } else {
                retry = Self.makeExactRetry(for: question)
            }
            questions.append(retry)
        }

        if status != .unanswered {
            if !isArabicPairCheckpoint {
                insertArabicLemmaCheckpointIfNeeded()
            }
            rebalanceUpcomingExerciseTypes()
            currentIndex += 1
            resetResponse()
            persistSnapshot(to: progressStore)
        }
    }

    private func insertArabicLemmaCheckpointIfNeeded() {
        guard session.course == .arabic,
              !session.isUnitReview,
              session.completionNodeID != nil,
              currentIndex < questions.count,
              !Self.isArabicLemmaCheckpointQuestion(questions[currentIndex]) else { return }

        let recentLemmas = recentArabicCheckpointLemmas()
        guard recentLemmas.count >= 8 else { return }

        let insertionIndex = min(currentIndex + 1, questions.count)
        if questions.indices.contains(insertionIndex),
           Self.isArabicLemmaCheckpointQuestion(questions[insertionIndex]) {
            return
        }

        let checkpoint = Self.makeArabicLemmaCheckpointQuestion(
            lemmas: recentLemmas,
            anchor: questions[currentIndex].phrase
        )
        questions.insert(checkpoint, at: insertionIndex)
    }

    /// Collect matchable chunks from questions that have actually appeared since
    /// the previous checkpoint. Duplicate Arabic surfaces or duplicate English
    /// meanings are ignored so the matching board never contains ambiguous pairs.
    private func recentArabicCheckpointLemmas() -> [Lemma] {
        guard currentIndex < questions.count else { return [] }

        let appeared = Array(questions.prefix(currentIndex + 1))
        let previousCheckpoint = appeared.lastIndex(where: {
            Self.isArabicLemmaCheckpointQuestion($0)
        })
        let start = (previousCheckpoint ?? -1) + 1

        var seenForeign = Set<String>()
        var seenEnglish = Set<String>()
        var output: [Lemma] = []

        for question in appeared.dropFirst(start)
        where !Self.isArabicLemmaCheckpointQuestion(question)
            && !Self.isArabicConjugationCheckpointQuestion(question) {
            for lemma in question.phrase.lemmas {
                let foreign = lemma.foreign.trimmingCharacters(in: .whitespacesAndNewlines)
                let english = lemma.english.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !foreign.isEmpty,
                      !english.isEmpty,
                      !seenForeign.contains(foreign),
                      !seenEnglish.contains(english) else { continue }

                seenForeign.insert(foreign)
                seenEnglish.insert(english)
                output.append(lemma)
            }
        }

        return output
    }

    private func rebalanceUpcomingExerciseTypes() {
        let start = currentIndex + 1
        guard start < questions.count else { return }

        // A missed free-write gets an immediate word-bank rescue. That one intentional
        // same-phrase repetition stays fixed; everything after it respects the normal cooldown.
        let hasImmediateRescue = status == .wrong
            && (currentQuestion?.type == .typing || currentQuestion?.type == .listenWrite)
        let fixedCount = hasImmediateRescue ? 1 : 0
        let balanceStart = min(questions.count, start + fixedCount)
        guard balanceStart < questions.count else { return }

        let historyStart = max(0, currentIndex - 7)
        var recent = Array(questions[historyStart...currentIndex])
        if fixedCount == 1, questions.indices.contains(start) {
            recent.append(questions[start])
        }

        let future = Array(questions[balanceStart..<questions.count])
        let balanced = Self.spreadExerciseTypes(
            future,
            recentQuestions: recent
        )
        questions.replaceSubrange(balanceStart..<questions.count, with: balanced)
    }

    private func resetResponse() {
        selectedAnswer = nil
        typedAnswer = ""
        selectedWordIndices = []
        status = .unanswered
        isCheckingAlternative = false
        aiAlternativeAccepted = false
        matchingLeftSelection = nil
        matchingRightSelection = nil
        matchingWrongLeftIndex = nil
        matchingWrongRightIndex = nil
        matchingMissedLeftIndices = []
        pendingAIAlternative = nil
        pendingManualReview = nil
        questionStartedAt = Date()
    }

    private static func isOpenCorpusListeningPractice(_ session: QuizSession) -> Bool {
        session.completionNodeID == nil
            && session.title == PracticeMode.listening.title
            && session.exerciseTypes == Set([.listening])
    }

    private static func lessonFlowVersion(for session: QuizSession) -> Int {
        // Saved lesson questions must respect the CURRENT audio-exercise settings.
        // If Listening or Speaking is toggled, rebuild the saved question queue
        // rather than resurrecting questions that are now disabled.
        lessonFlowVersionBase
            + (session.course == .arabic ? 1700 : 0)
            + (session.isUnitReview ? 401 : 0)
            + (!criticalExerciseEnabled(.listening, in: session) ? 100 : 0)
            + (!criticalExerciseEnabled(.speaking, in: session) ? 200 : 0)
    }

    private static func savedLessonFlowIsCompatible(
        _ savedVersion: Int?,
        session: QuizSession
    ) -> Bool {
        guard let savedVersion else { return false }
        return savedVersion == lessonFlowVersion(for: session)
    }

    private static func criticalExerciseEnabled(_ type: ExerciseType, in session: QuizSession) -> Bool {
        guard type == .listening || type == .speaking else { return true }
        if session.exerciseTypes.isEmpty { return true }
        return session.exerciseTypes.contains(type)
    }

    private static func successfulExerciseTypes(
        phrase: PhraseEntry,
        session: QuizSession,
        progressStore: ProgressStore
    ) -> Set<ExerciseType> {
        Set(
            progressStore.attemptHistory.lazy
                .filter {
                    $0.course == session.course
                        && $0.phraseID == phrase.id
                        && $0.wasCorrect
                }
                .map(\.exerciseType)
        )
    }

    /// WRITE is a hard gate: it cannot appear until this exact phrase has been answered
    /// correctly in two distinct non-writing exercise types.
    private static func scaffoldSuccessCount(
        phrase: PhraseEntry,
        session: QuizSession,
        progressStore: ProgressStore
    ) -> Int {
        let successful = successfulExerciseTypes(
            phrase: phrase,
            session: session,
            progressStore: progressStore
        )
        let preWrite = successful.subtracting([.introduction, .typing, .listenWrite])
        let distinctPreWriteCount = min(2, preWrite.count)

        guard distinctPreWriteCount == 2 else {
            return distinctPreWriteCount
        }
        guard successful.contains(.typing) else {
            return 3
        }

        // If speech is disabled, writing completes the initial scaffold. If it is enabled,
        // speaking remains the final production step unless it was already cleared earlier.
        if !criticalExerciseEnabled(.speaking, in: session) {
            return LessonScaffoldExercise.allCases.count
        }
        return successful.contains(.speaking)
            ? LessonScaffoldExercise.allCases.count
            : 4
    }

    private static func makeQuestions(session: QuizSession, progressStore: ProgressStore) -> [QuizQuestion] {
        guard !session.phrasePool.isEmpty else { return [] }

        if session.isUnitReview {
            return session.phrasePool
                .shuffled()
                .enumerated()
                .map { index, phrase in
                    makeQuestion(
                        phrase: phrase,
                        type: .typing,
                        stage: .freeRecall,
                        index: index,
                        phrasePool: session.phrasePool,
                        allPhrases: session.allPhrases
                    )
                }
        }

        if isOpenCorpusListeningPractice(session) {
            let selected = Array(
                session.phrasePool.shuffled().prefix(
                    max(1, min(session.sessionSize, session.phrasePool.count))
                )
            )
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
            corePhrases = Array(
                learned.prefix(max(1, min(session.sessionSize, learned.count)))
            )
        }

        if session.completionNodeID != nil {
            var lessonQuestions: [QuizQuestion] = []

            // New/current phrases: create only the NEXT scaffold step. Further steps are appended
            // after success, so production can never jump ahead of two distinct non-writing successes.
            for (index, phrase) in corePhrases.enumerated() {
                let completed = scaffoldSuccessCount(
                    phrase: phrase,
                    session: session,
                    progressStore: progressStore
                )
                if completed < LessonScaffoldExercise.allCases.count {
                    lessonQuestions.append(
                        makeNextLessonScaffoldQuestion(
                            phrase: phrase,
                            completedCount: completed,
                            index: index,
                            session: session,
                        progressStore: progressStore
                        )
                    )
                } else {
                    lessonQuestions.append(
                        makeQuestionForCurrentStage(
                            phrase: phrase,
                            index: index,
                            session: session,
                            progressStore: progressStore,
                            allowedOverride: allowed
                        )
                    )
                }
            }

            // Every lesson carries forward genuinely due material. Recent failures are always
            // first-class review candidates, even if the user corrected them on the retry.
            let reinforcement = reinforcementPhrases(
                session: session,
                corePhrases: corePhrases,
                progressStore: progressStore
            )

            for (offset, phrase) in reinforcement.enumerated() {
                let index = corePhrases.count + offset
                let completed = scaffoldSuccessCount(
                    phrase: phrase,
                    session: session,
                    progressStore: progressStore
                )
                if completed < LessonScaffoldExercise.allCases.count {
                    lessonQuestions.append(
                        makeNextLessonScaffoldQuestion(
                            phrase: phrase,
                            completedCount: completed,
                            index: index,
                            session: session,
                        progressStore: progressStore
                        )
                    )
                } else {
                    lessonQuestions.append(
                        makeQuestionForCurrentStage(
                            phrase: phrase,
                            index: index,
                            session: session,
                            progressStore: progressStore,
                            allowedOverride: allowed
                        )
                    )
                }
            }

            // Unit reviews cover the whole unit, then deliberately give the weakest third
            // (plus anything recently missed) one extra production-weighted encounter.
            if session.isUnitReview {
                let boosted = unitReviewBoostPhrases(
                    corePhrases: corePhrases,
                    session: session,
                    progressStore: progressStore
                )
                for (offset, phrase) in boosted.enumerated() {
                    lessonQuestions.append(
                        makeQuestionForCurrentStage(
                            phrase: phrase,
                            index: corePhrases.count + reinforcement.count + offset,
                            session: session,
                            progressStore: progressStore,
                            allowedOverride: allowed
                        )
                    )
                }
            }

            var balanced = spreadExerciseTypes(lessonQuestions.shuffled())

            if session.course == .arabic,
               let conjugation = makeArabicConjugationMatchQuestion() {
                let insertionIndex: Int
                if balanced.count <= 1 {
                    insertionIndex = balanced.count
                } else {
                    insertionIndex = Int.random(in: 1..<balanced.count)
                }
                balanced.insert(conjugation, at: insertionIndex)
            }

            return balanced
        }

        let practiceQuestions = corePhrases.enumerated().map { index, phrase in
            makeQuestionForCurrentStage(
                phrase: phrase,
                index: index,
                session: session,
                progressStore: progressStore,
                allowedOverride: allowed
            )
        }
        return spreadExerciseTypes(practiceQuestions.shuffled())
    }

    /// Keep the lesson varied without turning it into a visible ABAB pattern.
    /// Phrase spacing is more important than strict type alternation: normal repeats need
    /// four intervening questions, while free writing waits for six when alternatives exist.
    private static func spreadExerciseTypes(
        _ input: [QuizQuestion],
        recentQuestions: [QuizQuestion] = []
    ) -> [QuizQuestion] {
        guard input.count >= 2 else { return input }

        func arrangeSegment(
            _ segment: [QuizQuestion],
            historySeed: [QuizQuestion]
        ) -> [QuizQuestion] {
            guard segment.count >= 2 else { return segment }

            var remaining = segment.shuffled()
            var output: [QuizQuestion] = []
            var history = Array(historySeed.suffix(8))

            while !remaining.isEmpty {
                var candidates = Array(remaining.indices)

                // Same phrase: normally leave four other questions between encounters.
                // WRITE / Listen & write waits even longer so production does not arrive
                // immediately after the second qualifying non-write success.
                let phraseSafe = candidates.filter { index in
                    let question = remaining[index]
                    let isFreeWriting = question.type == .typing || question.type == .listenWrite
                    let cooldown = isFreeWriting ? 6 : 4
                    return !history.suffix(cooldown).contains(where: {
                        $0.phrase.id == question.phrase.id
                    })
                }
                if !phraseSafe.isEmpty {
                    candidates = phraseSafe
                }

                // Hard ceiling: never make a run of three identical exercise types if
                // there is any other type available at this point in the queue.
                if history.count >= 2,
                   let last = history.last?.type,
                   history[history.count - 2].type == last {
                    let alternatives = candidates.filter { remaining[$0].type != last }
                    if !alternatives.isEmpty {
                        candidates = alternatives
                    }
                }

                // Soft preference only. Most of the time change type, but deliberately
                // allow occasional doubles so the lesson does not feel mechanically rotated.
                if let lastType = history.last?.type,
                   Int.random(in: 0..<100) < 65 {
                    let different = candidates.filter { remaining[$0].type != lastType }
                    if !different.isEmpty {
                        candidates = different
                    }
                }

                guard let chosenIndex = candidates.randomElement() else { break }
                let next = remaining.remove(at: chosenIndex)
                output.append(next)
                history.append(next)
                if history.count > 8 {
                    history.removeFirst(history.count - 8)
                }
            }

            return output
        }

        var output: [QuizQuestion] = []
        var segment: [QuizQuestion] = []
        var history = Array(recentQuestions.suffix(8))

        func flushSegment() {
            guard !segment.isEmpty else { return }
            let arranged = arrangeSegment(segment, historySeed: history)
            output.append(contentsOf: arranged)
            history.append(contentsOf: arranged)
            if history.count > 8 {
                history.removeFirst(history.count - 8)
            }
            segment.removeAll(keepingCapacity: true)
        }

        for question in input {
            if isArabicPairMatchingQuestion(question) {
                flushSegment()
                output.append(question)
                history.append(question)
                if history.count > 8 {
                    history.removeFirst(history.count - 8)
                }
            } else {
                segment.append(question)
            }
        }
        flushSegment()
        return output
    }

    private static func reinforcementPhrases(
        session: QuizSession,
        corePhrases: [PhraseEntry],
        progressStore: ProgressStore
    ) -> [PhraseEntry] {
        var seen = Set(corePhrases.map { $0.progressKey(course: session.course) })
        var output: [PhraseEntry] = []

        let failureIDs = recentFailurePhraseIDs(
            course: session.course,
            progressStore: progressStore
        )

        for phrase in session.allPhrases where failureIDs.contains(phrase.id) {
            let key = phrase.progressKey(course: session.course)
            guard seen.insert(key).inserted else { continue }
            output.append(phrase)
        }

        // No arbitrary "three reviews only" ceiling: if more material is genuinely due,
        // the lesson is allowed to grow so reinforcement is not silently dropped.
        let threshold = session.isUnitReview ? 0.92 : 0.86
        let due = progressStore.duePhrases(
            course: session.course,
            from: session.allPhrases,
            excluding: seen,
            limit: session.allPhrases.count,
            threshold: threshold
        )

        for phrase in due {
            let stats = progressStore.stats(course: session.course, phrase: phrase)
            let trulyDue = scaffoldSuccessCount(
                phrase: phrase,
                session: session,
                progressStore: progressStore
            ) < LessonScaffoldExercise.allCases.count
                || stats.recallProbability() <= threshold
                || stats.lastReviewWasCorrect == false

            guard trulyDue else { continue }
            let key = phrase.progressKey(course: session.course)
            guard seen.insert(key).inserted else { continue }
            output.append(phrase)
        }

        return output
    }

    private static func recentFailurePhraseIDs(
        course: LanguageCourse,
        progressStore: ProgressStore
    ) -> Set<String> {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return Set(
            progressStore.attemptHistory.lazy
                .filter {
                    $0.course == course
                        && !$0.wasCorrect
                        && $0.timestamp >= cutoff
                }
                .map(\.phraseID)
        )
    }

    private static func unitReviewBoostPhrases(
        corePhrases: [PhraseEntry],
        session: QuizSession,
        progressStore: ProgressStore
    ) -> [PhraseEntry] {
        let eligible = corePhrases.filter {
            scaffoldSuccessCount(
                phrase: $0,
                session: session,
                progressStore: progressStore
            ) >= LessonScaffoldExercise.allCases.count
        }
        guard !eligible.isEmpty else { return [] }

        let failureIDs = recentFailurePhraseIDs(
            course: session.course,
            progressStore: progressStore
        )
        let weakestCount = max(1, Int(ceil(Double(eligible.count) * 0.35)))
        let weakest = eligible.sorted {
            progressStore.stats(course: session.course, phrase: $0).mastery
                < progressStore.stats(course: session.course, phrase: $1).mastery
        }.prefix(weakestCount)

        var seen = Set<String>()
        var output: [PhraseEntry] = []

        for phrase in eligible where failureIDs.contains(phrase.id) {
            if seen.insert(phrase.id).inserted { output.append(phrase) }
        }
        for phrase in weakest {
            if seen.insert(phrase.id).inserted { output.append(phrase) }
        }
        return output
    }

    private static func makeNextLessonScaffoldQuestion(
        phrase: PhraseEntry,
        completedCount: Int,
        index: Int,
        session: QuizSession,
        progressStore: ProgressStore
    ) -> QuizQuestion {
        if completedCount < 3 {
            return makePreWriteScaffoldQuestion(
                phrase: phrase,
                index: index,
                session: session,
                progressStore: progressStore
            )
        }

        let safeCompleted = max(
            0,
            min(LessonScaffoldExercise.allCases.count - 1, completedCount)
        )
        let exercise = LessonScaffoldExercise.allCases[safeCompleted]
        return makeLessonScaffoldQuestion(
            exercise,
            phrase: phrase,
            index: index,
            session: session
        )
    }

    /// Pick a fresh compatible format for the first two successful encounters.
    /// This both enforces the WRITE gate and stops new lessons bunching into one exercise type.
    private static func makePreWriteScaffoldQuestion(
        phrase: PhraseEntry,
        index: Int,
        session: QuizSession,
        progressStore: ProgressStore
    ) -> QuizQuestion {
        let alreadyPassed = successfulExerciseTypes(
            phrase: phrase,
            session: session,
            progressStore: progressStore
        ).subtracting([.introduction, .typing, .listenWrite])

        let enabled = session.exerciseTypes.isEmpty
            ? Set(ExerciseType.userSelectableCases)
            : session.exerciseTypes.subtracting([.introduction])
        let tokenCount = tokens(from: phrase.foreign).count
        let hasLemmas = !phrase.lemmas.isEmpty

        func compatible(_ type: ExerciseType, respectEnabled: Bool) -> Bool {
            if type == .introduction || type == .typing || type == .listenWrite { return false }
            if (session.course == .french || session.course == .spanish)
                && (type == .multipleChoice || type == .matching) {
                return false
            }
            if respectEnabled && !enabled.contains(type) { return false }
            if type == .listening && !criticalExerciseEnabled(.listening, in: session) { return false }
            if type == .speaking && !criticalExerciseEnabled(.speaking, in: session) { return false }
            if session.course == .arabic && type == .matching { return false }
            if type == .fillBlank && tokenCount < 2 { return false }
            if type == .lemma && !hasLemmas { return false }
            return true
        }

        let enabledCandidates = ExerciseType.userSelectableCases.filter {
            compatible($0, respectEnabled: true)
        }
        let broadCandidates = ExerciseType.userSelectableCases.filter {
            compatible($0, respectEnabled: false)
        }

        // Never weaken the two-type rule. If the enabled set is unusually narrow,
        // pull in another compatible non-writing format instead of unlocking WRITE early.
        let candidateBase = Set(enabledCandidates).union(alreadyPassed).count >= 2
            ? enabledCandidates
            : broadCandidates
        let fresh = candidateBase.filter { !alreadyPassed.contains($0) }
        let pool = fresh.isEmpty ? candidateBase : fresh
        let type = adaptiveChoice(
            pool.isEmpty ? [.wordBank] : pool,
            phrase: phrase,
            stage: .recognition,
            course: session.course,
            progressStore: progressStore,
            index: index
        ) ?? .wordBank

        return makeQuestion(
            phrase: phrase,
            type: type,
            stage: .recognition,
            index: index,
            phrasePool: session.phrasePool,
            allPhrases: session.allPhrases
        )
    }

    private static func makeLessonScaffoldQuestion(
        _ exercise: LessonScaffoldExercise,
        phrase: PhraseEntry,
        index: Int,
        session: QuizSession
    ) -> QuizQuestion {
        let type: ExerciseType
        let stage: PhraseLearningStage

        switch exercise {
        case .comprehension:
            // First encounter: read the target-language phrase and build its English meaning.
            return QuizQuestion(
                type: .wordBank,
                prompt: phrase.foreign,
                correctAnswer: phrase.english,
                direction: .foreignToEnglish,
                phrase: phrase,
                wordBankTokens: tokens(from: phrase.english).shuffled()
            )

        case .assistedBuild:
            // Second encounter: rebuild the target-language sentence.
            // Prefer audio + tokens; if listening is disabled, use a visible word bank.
            if criticalExerciseEnabled(.listening, in: session) {
                type = .listening
            } else {
                type = .wordBank
            }
            stage = .recognition

        case .variedRecall:
            type = assistedFallbackType(for: phrase, session: session)
            stage = .recognition

        case .writeAnswer:
            type = .typing
            stage = .assistedRecall

        case .speaking:
            if criticalExerciseEnabled(.speaking, in: session) {
                type = .speaking
            } else if criticalExerciseEnabled(.listening, in: session) {
                type = .listening
            } else {
                type = .typing
            }
            stage = .freeRecall
        }

        return makeQuestion(
            phrase: phrase,
            type: type,
            stage: stage,
            index: index,
            phrasePool: session.phrasePool,
            allPhrases: session.allPhrases
        )
    }

    private static func assistedFallbackType(
        for phrase: PhraseEntry,
        session: QuizSession
    ) -> ExerciseType {
        let allowed = session.exerciseTypes.isEmpty
            ? Set(ExerciseType.userSelectableCases)
            : session.exerciseTypes.subtracting([.introduction])

        if session.course == .arabic, allowed.contains(.multipleChoice) { return .multipleChoice }
        if session.course == .arabic, allowed.contains(.matching) { return .matching }
        if allowed.contains(.lemma), !phrase.lemmas.isEmpty { return .lemma }
        if allowed.contains(.fillBlank), tokens(from: phrase.foreign).count >= 2 { return .fillBlank }
        return .wordBank
    }

    private static func isArabicConjugationCheckpointQuestion(_ question: QuizQuestion) -> Bool {
        question.type == .matching
            && question.phrase.topicID == arabicConjugationCheckpointTopicID
            && !question.wordBankTokens.isEmpty
            && !question.phrase.lemmas.isEmpty
    }

    private static func isArabicPairMatchingQuestion(_ question: QuizQuestion) -> Bool {
        isArabicLemmaCheckpointQuestion(question)
            || isArabicConjugationCheckpointQuestion(question)
    }

    private static func loadLebaneseVerbCorpus() -> [LebaneseVerbRecord] {
        let urls = [
            Bundle.main.url(
                forResource: "lebanese_200_verbs",
                withExtension: "json",
                subdirectory: "TopicData"
            ),
            Bundle.main.url(forResource: "lebanese_200_verbs", withExtension: "json")
        ]

        guard let url = urls.compactMap({ $0 }).first,
              let data = try? Data(contentsOf: url),
              let corpus = try? JSONDecoder().decode(LebaneseVerbCorpus.self, from: data) else {
            return []
        }
        return corpus.verbs
    }

    private static func forms(
        for family: ConjugationFamily,
        verb: LebaneseVerbRecord
    ) -> [String: LebaneseVerbForm] {
        if family.conditional {
            return verb.conditionals[family.key] ?? [:]
        }

        switch family.key {
        case "past": return verb.past
        case "present": return verb.present
        case "bare_subjunctive": return verb.bare_subjunctive
        case "progressive": return verb.progressive
        case "future": return verb.future
        case "past_habitual": return verb.past_habitual
        default: return [:]
        }
    }

    private static func makeArabicConjugationMatchQuestion() -> QuizQuestion? {
        let verbs = loadLebaneseVerbCorpus()
        guard let verb = verbs.randomElement(),
              let family = conjugationFamilies.randomElement() else { return nil }

        let rawForms = forms(for: family, verb: verb)
        let personOrder = ["ana", "enta_m", "ente_f", "huwwe", "hiyye", "nehna", "ento", "henne"]

        // Identical Arabic surfaces (e.g. masculine/feminine syncretism) make a
        // tap-to-match game ambiguous. Keep only one card per Arabic surface and
        // one per English answer, then choose six random unambiguous pairs.
        var seenArabic = Set<String>()
        var seenEnglish = Set<String>()
        var candidates: [Lemma] = []

        for person in personOrder.shuffled() {
            guard let form = rawForms[person] else { continue }
            let arabic = form.arabic.trimmingCharacters(in: .whitespacesAndNewlines)
            let english = form.english.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !arabic.isEmpty,
                  !english.isEmpty,
                  seenArabic.insert(arabic).inserted,
                  seenEnglish.insert(english).inserted else { continue }

            let transliteration = form.transliteration?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let transliteration,
                  !transliteration.isEmpty else { continue }

            candidates.append(
                Lemma(
                    foreign: arabic,
                    transliteration: transliteration,
                    english: english
                )
            )
        }

        let pairs = Array(candidates.shuffled().prefix(6))
        guard pairs.count == 6 else { return nil }

        let phrase = PhraseEntry(
            id: "arabic-conjugation-match-\(UUID().uuidString)",
            topicID: arabicConjugationCheckpointTopicID,
            topicTitle: family.title,
            foreign: verb.lemma.arabic,
            transliteration: verb.lemma.transliteration?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            tokens: nil,
            english: verb.lemma.english,
            lemmas: pairs,
            context: ""
        )

        return QuizQuestion(
            type: .matching,
            prompt: "Conjugation match",
            options: pairs.map(\.english).shuffled(),
            correctAnswer: "all-pairs-matched",
            direction: .foreignToEnglish,
            phrase: phrase,
            wordBankTokens: pairs.map(\.foreign).shuffled(),
            blankedText: family.usedWith
        )
    }

    private static let arabicLemmaCheckpointPrompt = "Match the recent chunks"

    private static func isArabicLemmaCheckpointQuestion(_ question: QuizQuestion) -> Bool {
        question.type == .matching
            && question.prompt == arabicLemmaCheckpointPrompt
            && !question.wordBankTokens.isEmpty
            && !question.phrase.lemmas.isEmpty
    }

    private static func makeArabicLemmaCheckpointQuestion(
        lemmas: [Lemma],
        anchor: PhraseEntry
    ) -> QuizQuestion {
        let syntheticPhrase = PhraseEntry(
            id: "arabic-lemma-match-\(UUID().uuidString)",
            topicID: anchor.topicID,
            topicTitle: anchor.topicTitle,
            foreign: "",
            transliteration: nil,
            tokens: nil,
            english: "Recent chunks matched",
            lemmas: lemmas,
            context: ""
        )

        return QuizQuestion(
            type: .matching,
            prompt: arabicLemmaCheckpointPrompt,
            options: lemmas.map(\.english).shuffled(),
            correctAnswer: "all-pairs-matched",
            direction: .foreignToEnglish,
            phrase: syntheticPhrase,
            wordBankTokens: lemmas.map(\.foreign).shuffled()
        )
    }

    private static func makeExactRetry(for question: QuizQuestion) -> QuizQuestion {
        QuizQuestion(
            type: question.type,
            prompt: question.prompt,
            options: question.options,
            correctAnswer: question.correctAnswer,
            direction: question.direction,
            phrase: question.phrase,
            wordBankTokens: question.wordBankTokens,
            blankedText: question.blankedText
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
            isLesson: session.completionNodeID != nil,
            preferProduction: session.isUnitReview
        )
        if type == .wordBank,
           stage >= .recognition,
           index.isMultiple(of: 2) {
            return QuizQuestion(
                type: .wordBank,
                prompt: phrase.foreign,
                correctAnswer: phrase.english,
                direction: .foreignToEnglish,
                phrase: phrase,
                wordBankTokens: tokens(from: phrase.english).shuffled()
            )
        }

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
        isLesson: Bool,
        preferProduction: Bool
    ) -> ExerciseType {
        let tokenCount = tokens(from: phrase.foreign).count
        let hasLemmas = !phrase.lemmas.isEmpty

        func compatible(_ candidates: [ExerciseType]) -> [ExerciseType] {
            candidates.filter { type in
                guard allowed.contains(type) else { return false }
                if (course == .french || course == .spanish)
                    && (type == .multipleChoice || (type == .matching && (isLesson || allowed.count > 1))) {
                    return false
                }
                if course == .arabic && isLesson && type == .matching { return false }
                if type == .fillBlank && tokenCount < 2 { return false }
                if type == .lemma && !hasLemmas { return false }
                return true
            }
        }

        if isLesson {
            switch stage {
            case .unseen, .introduced, .recognition:
                let assisted = compatible([.multipleChoice, .matching, .lemma, .wordBank])
                return adaptiveChoice(
                    assisted.isEmpty ? [.wordBank] : assisted,
                    phrase: phrase,
                    stage: stage,
                    course: course,
                    progressStore: progressStore,
                    index: index
                ) ?? .wordBank

            case .assistedRecall:
                // The mandatory scaffold already contains one free-write encounter.
                // Mixed lesson review should not pile more typing on top when another
                // active-recall format is available.
                let nonTyping = compatible([.wordBank, .listening, .speaking, .fillBlank])
                let fallback = compatible(Array(allowed))
                return adaptiveChoice(
                    nonTyping.isEmpty ? (fallback.isEmpty ? [.wordBank] : fallback) : nonTyping,
                    phrase: phrase,
                    stage: stage,
                    course: course,
                    progressStore: progressStore,
                    index: index
                ) ?? .wordBank

            case .freeRecall, .established:
                let productionCore: [ExerciseType] = preferProduction
                    ? [.listening, .listenWrite, .speaking, .fillBlank, .wordBank]
                    : [.listening, .listenWrite, .wordBank, .speaking, .fillBlank]
                let candidates = compatible(productionCore)
                let fallback = compatible(Array(allowed))
                return adaptiveChoice(
                    candidates.isEmpty ? (fallback.isEmpty ? [.wordBank] : fallback) : candidates,
                    phrase: phrase,
                    stage: stage,
                    course: course,
                    progressStore: progressStore,
                    index: index
                ) ?? .wordBank
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
            let nonTyping = compatible([.fillBlank, .wordBank, .listening, .speaking])
            let fallback = compatible(Array(allowed))
            return adaptiveChoice(
                nonTyping.isEmpty ? (fallback.isEmpty ? [.wordBank] : fallback) : nonTyping,
                phrase: phrase,
                stage: stage,
                course: course,
                progressStore: progressStore,
                index: index
            ) ?? .wordBank

        case .freeRecall, .established:
            // Mixed practice deliberately avoids extra free typing. Typing remains
            // available when it is the explicitly selected drill / only allowed type.
            let nonTyping = compatible(Array(allowed).filter { $0 != .typing })
            let fallback = compatible(Array(allowed))
            return adaptiveChoice(
                nonTyping.isEmpty ? (fallback.isEmpty ? [.wordBank] : fallback) : nonTyping,
                phrase: phrase,
                stage: stage,
                course: course,
                progressStore: progressStore,
                index: index
            ) ?? .wordBank
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
        case .typing, .wordBank, .fillBlank, .listening, .listenWrite, .speaking:
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
            let options = answerOptions(
                correct: correct,
                direction: direction,
                phrasePool: phrasePool,
                allPhrases: allPhrases
            )
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
            let cloze = makeCloze(
                for: phrase,
                phrasePool: phrasePool,
                allPhrases: allPhrases
            )
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
            // Listening is audio comprehension + construction, not another dictation box.
            return QuizQuestion(
                type: .listening,
                prompt: phrase.english,
                correctAnswer: phrase.foreign,
                direction: .englishToForeign,
                phrase: phrase,
                wordBankTokens: tokens(from: phrase.foreign).shuffled()
            )

        case .listenWrite:
            // True dictation: audio only, then free typing from scratch.
            return QuizQuestion(
                type: .listenWrite,
                prompt: "",
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
            let direction: QuestionDirection = stage <= .recognition
                ? .foreignToEnglish
                : (index.isMultiple(of: 2) ? .foreignToEnglish : .englishToForeign)
            let correct = answerText(for: phrase, direction: direction)
            return QuizQuestion(
                type: .matching,
                prompt: direction == .foreignToEnglish ? phrase.foreign : phrase.english,
                options: answerOptions(
                    correct: correct,
                    direction: direction,
                    phrasePool: phrasePool,
                    allPhrases: allPhrases
                ),
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

    private static let clozeExcludedWords: Set<String> = [
        // Spanish articles / determiners
        "el", "la", "los", "las",
        "un", "una", "unos", "unas",
        "este", "esta", "estos", "estas",
        "ese", "esa", "esos", "esas",
        "esto", "eso", "aquello",
        "mi", "mis", "tu", "tus", "su", "sus", "sí", "no",

        // Spanish pronouns / clitics
        "yo", "tú", "tu", "él", "ella",
        "nosotros", "nosotras", "vosotros", "vosotras",
        "ellos", "ellas",
        "me", "te", "se", "nos", "os",
        "lo", "le", "les",

        // Spanish very basic connectors / prepositions
        "y", "e", "o", "u",
        "a", "de", "del", "al", "en", "con",
        "que", "pero",

        // Spanish very basic copula / auxiliary forms
        "es", "son", "está", "estan", "están",
        "hay", "ha", "han",

        // French articles / determiners
        "le", "la", "les",
        "un", "une", "des",
        "du", "de", "d",
        "ce", "cet", "cette", "ces",
        "mon", "ma", "mes",
        "ton", "ta", "tes",
        "son", "sa", "ses",
        "notre", "nos", "votre", "vos",
        "leur", "leurs",

        // French pronouns / clitics
        "je", "j", "tu", "il", "elle", "on",
        "nous", "vous", "ils", "elles",
        "me", "m", "te", "t", "se", "s",
        "y", "en", "le", "la", "les",
        "lui",

        // French basic connectors / prepositions
        "et", "ou", "mais", "que", "qui",
        "à", "a", "au", "aux",
        "de", "du", "des", "en",

        // French basic copula / auxiliary forms
        "est", "es", "sont",
        "ai", "as", "a", "avons", "avez", "ont"
    ]

    private static func clozeKey(_ token: String) -> String {
        cleanedWord(token)
            .lowercased()
            .folding(
                options: [.diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .replacingOccurrences(of: "’", with: "'")
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

        let basicEligible = rawTokens.indices.filter {
            cleanedWord(rawTokens[$0]).count >= 2
        }

        let useful = basicEligible.filter {
            !clozeExcludedWords.contains(clozeKey(rawTokens[$0]))
        }

        // Prefer a more substantial lexical word when possible,
        // without making length itself a hard requirement.
        let preferred = useful.filter {
            cleanedWord(rawTokens[$0]).count >= 4
        }

        let targetPool: [Int]
        if !preferred.isEmpty {
            targetPool = preferred
        } else if !useful.isEmpty {
            targetPool = useful
        } else {
            // Safety fallback: never make cloze generation fail just because
            // a very short phrase contains only excluded function words.
            targetPool = basicEligible
        }

        let targetIndex = targetPool.randomElement() ?? rawTokens.indices.last!
        let answer = cleanedWord(rawTokens[targetIndex])
        let answerKey = clozeKey(answer)

        let blanked = rawTokens.enumerated().map { index, token in
            index == targetIndex ? "____" : token
        }.joined(separator: " ")

        let candidateWords = (phrasePool.shuffled() + allPhrases.shuffled())
            .flatMap { tokens(from: $0.foreign) }
            .map(cleanedWord)
            .filter {
                $0.count >= 2
                    && clozeKey($0) != answerKey
                    && !clozeExcludedWords.contains(clozeKey($0))
            }

        var seen = Set<String>([answerKey])
        var distractors: [String] = []

        for word in candidateWords {
            let key = clozeKey(word)

            if seen.insert(key).inserted {
                distractors.append(word)
            }

            if distractors.count == 3 {
                break
            }
        }

        return (
            blanked,
            answer,
            ([answer] + distractors).shuffled()
        )
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
            question.wordBankTokens.indices.contains(index)
                ? question.wordBankTokens[index]
                : nil
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

    private static func answerText(
        for phrase: PhraseEntry,
        direction: QuestionDirection
    ) -> String {
        switch direction {
        case .foreignToEnglish: return phrase.english
        case .englishToForeign: return phrase.foreign
        }
    }

    private static func slashAlternativeKey(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    
        return String(
            folded.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }
        )
    }
    
    /// Corpus forms such as "garé(e)" mean that the parenthetical agreement
    /// ending is optional. Accept both "garé" and "garée"; never require "(e)".
    private static func optionalAgreementForms(_ text: String) -> [String] {
        let pattern = #"(?i)\((e|s|es)\)"#
        let omitted = text.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
        let included = text.replacingOccurrences(
            of: pattern,
            with: "$1",
            options: .regularExpression
        )

        if omitted == included {
            return [text]
        }

        return Array(Set([omitted, included]))
    }

    private static func slashAlternativeKeys(_ text: String) -> [String] {
        text
            .components(separatedBy: "/")
            .flatMap { optionalAgreementForms($0) }
            .map { slashAlternativeKey($0) }
            .filter { !$0.isEmpty }
    }
    
    private static func deterministicEquivalentKey(_ text: String) -> String {
        var value = text
            .lowercased()
            .folding(
                options: [.diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .replacingOccurrences(of: "’", with: "'")

        let replacements: [(String, String)] = [
            (#"\bil\s+n'y\s+en\s+a\b"#, "y en a"),
            (#"\bil\s+y\s+en\s+a\b"#, "y en a"),
            (#"\bil\s+n'y\s+a\b"#, "y a"),
            (#"\bil\s+y\s+a\b"#, "y a"),

            (#"\bil\s+faudrait\b"#, "faudrait"),
            (#"\bil\s+faut\b"#, "faut"),
            (#"\bil\s+vaut\s+mieux\b"#, "vaut mieux"),

            (#"\bt'as\b"#, "tu as"),
            (#"\bt'es\b"#, "tu es"),
            (#"\bt'avais\b"#, "tu avais"),
            (#"\bt'etais\b"#, "tu etais"),

            (#"\bj'suis\b"#, "je suis"),
            (#"\bj'vais\b"#, "je vais"),
            (#"\bj'peux\b"#, "je peux"),
            (#"\bj'veux\b"#, "je veux"),
            (#"\bj'sais\b"#, "je sais"),
            (#"\bj'crois\b"#, "je crois"),
            (#"\bj'te\b"#, "je te"),
            (#"\bj'me\b"#, "je me")
        ]

        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        value = value.replacingOccurrences(
            of: #"\bne\s+(?=[^.!?]{0,80}\b(?:pas|plus|jamais|rien|personne|aucun|aucune|guere|que)\b)"#,
            with: "",
            options: .regularExpression
        )

        value = value.replacingOccurrences(
            of: #"\bn'(?=[^.!?]{0,80}\b(?:pas|plus|jamais|rien|personne|aucun|aucune|guere|que)\b)"#,
            with: "",
            options: .regularExpression
        )

        return normalize(value)
    }

    static func answersMatch(_ lhs: String, _ rhs: String) -> Bool {
        // A slash in the corpus means "either translation is valid", not
        // "the learner must reproduce both alternatives in this order".
        let lhsAlternatives = slashAlternativeKeys(lhs)
        let rhsAlternatives = slashAlternativeKeys(rhs)
    
        if rhsAlternatives.count > 1 {
            // One valid alternative on its own is enough.
            if lhsAlternatives.count == 1,
               rhsAlternatives.contains(lhsAlternatives[0]) {
                return true
            }
    
            // If both/all alternatives were built, their order is irrelevant.
            if lhsAlternatives.count == rhsAlternatives.count,
               Set(lhsAlternatives) == Set(rhsAlternatives) {
                return true
            }
        }

        if deterministicEquivalentKey(lhs) == deterministicEquivalentKey(rhs) {
            return true
        }

        return normalize(lhs) == normalize(rhs)
    }

    private static func normalize(_ text: String) -> String {
        let lower = text.lowercased()
        let allowed = CharacterSet.letters.union(.decimalDigits)
        let scalars = lower.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
