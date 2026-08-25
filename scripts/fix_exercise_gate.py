from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
VM = ROOT / "LingoNative/ViewModels/QuizViewModel.swift"


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        fail(f"Could not apply {label}; expected 1 match, found {count}.")
    return text.replace(old, new, 1)


if not VM.exists():
    fail(f"Missing {VM.relative_to(ROOT)}")

vm = VM.read_text()

vm = replace_once(
    vm,
    "    private static let lessonFlowVersionBase = 6",
    "    private static let lessonFlowVersionBase = 7",
    "lesson flow version",
)

vm = replace_once(
    vm,
    '''    /// New phrases move from comprehension into assisted production, then free production.
    /// UNDERSTAND -> BUILD -> WRITE -> SPEAK.
    private enum LessonScaffoldExercise: Int, CaseIterable {
        case comprehension
        case assistedBuild
        case writeAnswer
        case speaking
    }''',
    '''    /// New phrases clear three distinct non-writing formats before free production.
    /// UNDERSTAND -> BUILD -> VARY -> WRITE -> SPEAK.
    private enum LessonScaffoldExercise: Int, CaseIterable {
        case comprehension
        case assistedBuild
        case variedRecall
        case writeAnswer
        case speaking
    }''',
    "five-step scaffold enum",
)

vm = replace_once(
    vm,
    '''        let trackedType: ExerciseType = question.type == .listening && !question.wordBankTokens.isEmpty
            ? .wordBank
            : question.type''',
    '''        // Track the exercise the learner actually experienced. This matters for the
        // three-distinct-types gate: a listening question with word tiles is still Listening.
        let trackedType: ExerciseType = question.type''',
    "experienced exercise type tracking",
)

vm = replace_once(
    vm,
    '''    /// ProgressStore keeps a speaking migration safeguard. Respect it when speaking is enabled,
    /// but allow the fourth scaffold step to count when the user has deliberately disabled speech.
    private static func scaffoldSuccessCount(
        phrase: PhraseEntry,
        session: QuizSession,
        progressStore: ProgressStore
    ) -> Int {
        if !criticalExerciseEnabled(.speaking, in: session),
           let stored = progressStore.stats(course: session.course, phrase: phrase).successfulRecallCount {
            return min(LessonScaffoldExercise.allCases.count, max(0, stored))
        }
        return min(
            LessonScaffoldExercise.allCases.count,
            progressStore.lessonScaffoldSuccessCount(course: session.course, phrase: phrase)
        )
    }''',
    '''    private static func successfulExerciseTypes(
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
                .map(\\.exerciseType)
        )
    }

    /// WRITE is a hard gate: it cannot appear until this exact phrase has been answered
    /// correctly in three distinct non-writing exercise types.
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
        let distinctPreWriteCount = min(3, preWrite.count)

        guard distinctPreWriteCount == 3 else {
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
    }''',
    "three-distinct-types write gate",
)

# Add ProgressStore to all three dynamic scaffold-question call sites.
if "progressStore: ProgressStore\n    ) -> QuizQuestion" not in vm:
    pattern = re.compile(
        r'(makeNextLessonScaffoldQuestion\(\n(?:[^\n]*\n)*?\s+session: session)(\n\s*\))'
    )
    vm, count = pattern.subn(
        r'\1,\n                        progressStore: progressStore\2',
        vm,
    )
    if count != 3:
        fail(f"Could not update scaffold call sites; expected 3 matches, found {count}.")

vm = replace_once(
    vm,
    '''    private static func makeNextLessonScaffoldQuestion(
        phrase: PhraseEntry,
        completedCount: Int,
        index: Int,
        session: QuizSession
    ) -> QuizQuestion {
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
    }''',
    '''    private static func makeNextLessonScaffoldQuestion(
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

    /// Pick a fresh compatible format for the first three successful encounters.
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

        // Never weaken the three-type rule. If the enabled set is unusually narrow,
        // pull in another compatible non-writing format instead of unlocking WRITE early.
        let candidateBase = Set(enabledCandidates).union(alreadyPassed).count >= 3
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
    }''',
    "dynamic pre-write exercise picker",
)

vm = replace_once(
    vm,
    '''        case .writeAnswer:
            type = .typing
            stage = .assistedRecall''',
    '''        case .variedRecall:
            type = assistedFallbackType(for: phrase, session: session)
            stage = .recognition

        case .writeAnswer:
            type = .typing
            stage = .assistedRecall''',
    "varied-recall switch case",
)

vm = vm.replace(
    "production can never jump ahead of the two assisted encounters.",
    "production can never jump ahead of three distinct non-writing successes.",
)
vm = vm.replace(
    "That guarantees free writing cannot appear until two assisted successes exist.",
    "That guarantees free writing cannot appear until three distinct non-writing successes exist.",
)

VM.write_text(vm)

print("✓ WRITE is locked until 3 distinct non-writing exercise types are correct")
print("✓ Pre-write exercises prefer types that phrase has not already passed")
print("✓ Listening with word tiles now counts as Listening for the gate")
print("✓ Lesson flow version bumped so stale saved queues are regenerated")
print("\nNext: build LingoNative with ⌘B.")
