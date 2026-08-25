from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
VM = ROOT / "LingoNative/ViewModels/QuizViewModel.swift"
PS = ROOT / "LingoNative/Services/ProgressStore.swift"

def die(s): raise SystemExit(f"\n❌ {s}\n")

def block(src, marker, new):
    s = src.find(marker)
    if s < 0: die(f"Couldn't find {marker}")
    b = src.find("{", s)
    if b < 0: die(f"Couldn't parse {marker}")
    d = 0; q = False; esc = False
    for i in range(b, len(src)):
        c = src[i]
        if q:
            if esc: esc = False
            elif c == "\\": esc = True
            elif c == '"': q = False
        else:
            if c == '"': q = True
            elif c == "{": d += 1
            elif c == "}":
                d -= 1
                if d == 0: return src[:s] + new.rstrip() + src[i+1:]
    die(f"Couldn't close {marker}")

def once(src, old, new, name):
    if new in src: return src
    if src.count(old) != 1: die(f"Couldn't patch {name}; found {src.count(old)} matches")
    return src.replace(old, new, 1)

vm = VM.read_text(); ps = PS.read_text()

# --- ProgressStore: the single source of truth for the 3-before-WRITE gate ---
ps_gate = r'''    func successfulLessonFormatKeys(course: LanguageCourse, phrase: PhraseEntry) -> Set<String> {
        Set(attemptHistory.lazy.filter {
            $0.course == course && $0.phraseID == phrase.id && $0.wasCorrect
        }.compactMap { attempt in
            switch attempt.exerciseType {
            case .wordBank:
                return attempt.direction == .foreignToEnglish ? "read-word-bank-f2e" : "read-word-bank-e2f"
            case .listening:
                return attempt.direction == .foreignToEnglish ? "listen-word-bank-f2e" : "listen-word-bank-e2f"
            case .listenWrite: return "listen-write"
            case .fillBlank: return "fill-blank"
            case .speaking: return "speaking"
            case .multipleChoice:
                guard course == .arabic else { return nil }
                return attempt.direction == .foreignToEnglish ? "arabic-mc-f2e" : "arabic-mc-e2f"
            case .lemma: return course == .arabic ? "arabic-lemma" : nil
            case .matching: return course == .arabic ? "arabic-matching" : nil
            case .typing, .introduction: return nil
            }
        })
    }

    func lessonScaffoldSuccessCount(course: LanguageCourse, phrase: PhraseEntry) -> Int {
        let attempts = attemptHistory.filter { $0.course == course && $0.phraseID == phrase.id }
        if attempts.isEmpty {
            let value = stats(course: course, phrase: phrase)
            if let stored = value.successfulRecallCount { return min(4, max(0, stored)) }
            switch value.learningStage {
            case .unseen, .introduced: return 0
            case .recognition: return 1
            case .assistedRecall: return 2
            case .freeRecall, .established: return 4
            }
        }
        let preWrite = min(3, successfulLessonFormatKeys(course: course, phrase: phrase).count)
        guard preWrite == 3 else { return preWrite }
        return attempts.contains { $0.wasCorrect && $0.exerciseType == .typing } ? 4 : 3
    }'''
ps = block(ps, "    func lessonScaffoldSuccessCount(course: LanguageCourse, phrase: PhraseEntry) -> Int", ps_gate)
ps = once(ps,
'''            stats.successfulRecallCount = scaffoldSuccessesBefore
            if correct {
                stats.correct += 1
                advanceLessonScaffold(&stats)
            } else {
                stats.wrong += 1
                preserveLessonScaffoldStage(&stats)
            }''',
'''            stats.successfulRecallCount = scaffoldSuccessesBefore
            if correct {
                stats.correct += 1
                stats.successfulRecallCount = lessonScaffoldSuccessCount(course: course, phrase: phrase)
                preserveLessonScaffoldStage(&stats)
            } else {
                stats.wrong += 1
                preserveLessonScaffoldStage(&stats)
            }''', "ProgressStore scaffold update")

# --- QuizViewModel: 3 varied formats, then WRITE, then done ---
m = re.search(r"private static let lessonFlowVersionBase = (\d+)", vm)
if not m: die("Couldn't find lessonFlowVersionBase")
if int(m.group(1)) < 11: vm = vm[:m.start(1)] + "11" + vm[m.end(1):]

vm = block(vm, "    private enum LessonScaffoldExercise: Int, CaseIterable", r'''    private enum LessonScaffoldExercise: Int, CaseIterable {
        case exposureOne, exposureTwo, exposureThree, writeAnswer
    }

    private enum RomanceLessonFormat: String, CaseIterable {
        case readF2E = "read-word-bank-f2e"
        case readE2F = "read-word-bank-e2f"
        case listenF2E = "listen-word-bank-f2e"
        case listenE2F = "listen-word-bank-e2f"
        case listenWrite = "listen-write"
        case fillBlank = "fill-blank"
        case speaking = "speaking"
    }''')

vm = block(vm, "    private static func scaffoldSuccessCount(", r'''    private static func scaffoldSuccessCount(
        phrase: PhraseEntry, session: QuizSession, progressStore: ProgressStore
    ) -> Int {
        min(4, progressStore.lessonScaffoldSuccessCount(course: session.course, phrase: phrase))
    }''')

vm = block(vm, "    private static func makeNextLessonScaffoldQuestion(", r'''    private static func makeNextLessonScaffoldQuestion(
        phrase: PhraseEntry, completedCount: Int, index: Int,
        session: QuizSession, progressStore: ProgressStore
    ) -> QuizQuestion {
        if completedCount < 3 {
            return makePreWriteScaffoldQuestion(phrase: phrase, index: index, session: session, progressStore: progressStore)
        }
        return makeLessonScaffoldQuestion(.writeAnswer, phrase: phrase, index: index, session: session)
    }''')

vm = block(vm, "    private static func makePreWriteScaffoldQuestion(", r'''    private static func makePreWriteScaffoldQuestion(
        phrase: PhraseEntry, index: Int, session: QuizSession, progressStore: ProgressStore
    ) -> QuizQuestion {
        if session.course == .french || session.course == .spanish {
            let passed = progressStore.successfulLessonFormatKeys(course: session.course, phrase: phrase)
            let enabled = session.exerciseTypes.isEmpty ? Set(ExerciseType.userSelectableCases) : session.exerciseTypes
            func ok(_ f: RomanceLessonFormat) -> Bool {
                switch f {
                case .readF2E, .readE2F: return enabled.contains(.wordBank)
                case .listenF2E, .listenE2F: return enabled.contains(.listening)
                case .listenWrite: return enabled.contains(.listenWrite)
                case .fillBlank: return enabled.contains(.fillBlank)
                case .speaking: return enabled.contains(.speaking)
                }
            }
            let all = RomanceLessonFormat.allCases.filter(ok)
            let fresh = all.filter { !passed.contains($0.rawValue) }
            return makeRomanceLessonQuestion((fresh.isEmpty ? all : fresh).randomElement() ?? .readE2F,
                                             phrase: phrase, index: index, session: session)
        }

        // Arabic keeps its broader normal phrase pool; special matching checkpoints are elsewhere.
        let passed = Set(progressStore.attemptHistory.lazy.filter {
            $0.course == session.course && $0.phraseID == phrase.id && $0.wasCorrect
                && $0.exerciseType != .typing && $0.exerciseType != .introduction && $0.exerciseType != .matching
        }.map(\.exerciseType))
        let enabled = session.exerciseTypes.isEmpty ? Set(ExerciseType.userSelectableCases) : session.exerciseTypes
        let candidates = ExerciseType.userSelectableCases.filter {
            $0 != .typing && $0 != .introduction && $0 != .matching
                && enabled.contains($0)
                && ($0 != .lemma || !phrase.lemmas.isEmpty)
        }
        let fresh = candidates.filter { !passed.contains($0) }
        let type = (fresh.isEmpty ? candidates : fresh).randomElement() ?? .wordBank
        return makeQuestion(phrase: phrase, type: type, stage: .recognition, index: index,
                            phrasePool: session.phrasePool, allPhrases: session.allPhrases)
    }

    private static func makeRomanceLessonQuestion(
        _ f: RomanceLessonFormat, phrase: PhraseEntry, index: Int, session: QuizSession
    ) -> QuizQuestion {
        switch f {
        case .readF2E:
            return QuizQuestion(type: .wordBank, prompt: phrase.foreign, correctAnswer: phrase.english,
                                direction: .foreignToEnglish, phrase: phrase,
                                wordBankTokens: tokens(from: phrase.english).shuffled())
        case .readE2F:
            return QuizQuestion(type: .wordBank, prompt: phrase.english, correctAnswer: phrase.foreign,
                                direction: .englishToForeign, phrase: phrase,
                                wordBankTokens: tokens(from: phrase.foreign).shuffled())
        case .listenF2E:
            return QuizQuestion(type: .listening, prompt: "", correctAnswer: phrase.english,
                                direction: .foreignToEnglish, phrase: phrase,
                                wordBankTokens: tokens(from: phrase.english).shuffled())
        case .listenE2F:
            return QuizQuestion(type: .listening, prompt: "", correctAnswer: phrase.foreign,
                                direction: .englishToForeign, phrase: phrase,
                                wordBankTokens: tokens(from: phrase.foreign).shuffled())
        case .listenWrite:
            return makeQuestion(phrase: phrase, type: .listenWrite, stage: .recognition, index: index,
                                phrasePool: session.phrasePool, allPhrases: session.allPhrases)
        case .fillBlank:
            return makeQuestion(phrase: phrase, type: .fillBlank, stage: .recognition, index: index,
                                phrasePool: session.phrasePool, allPhrases: session.allPhrases)
        case .speaking:
            return makeQuestion(phrase: phrase, type: .speaking, stage: .recognition, index: index,
                                phrasePool: session.phrasePool, allPhrases: session.allPhrases)
        }
    }''')

vm = block(vm, "    private static func makeLessonScaffoldQuestion(", r'''    private static func makeLessonScaffoldQuestion(
        _ exercise: LessonScaffoldExercise, phrase: PhraseEntry, index: Int, session: QuizSession
    ) -> QuizQuestion {
        if exercise == .writeAnswer {
            return makeQuestion(phrase: phrase, type: .typing, stage: .assistedRecall, index: index,
                                phrasePool: session.phrasePool, allPhrases: session.allPhrases)
        }
        return makeQuestion(phrase: phrase, type: assistedFallbackType(for: phrase, session: session),
                            stage: .recognition, index: index,
                            phrasePool: session.phrasePool, allPhrases: session.allPhrases)
    }''')

vm = vm.replace(
"let isFreeWriting = question.type == .typing || question.type == .listenWrite\n                    let cooldown = isFreeWriting ? 6 : 4",
"let isDelayedWrite = question.type == .typing\n                    let cooldown = isDelayedWrite ? 6 : 4")

# Never add a second pending scaffold question for the same phrase. This is
# especially important after a missed WRITE: its exact retry is already queued
# behind the immediate drag/drop rescue.
continue_start = vm.find("    func continueAfterFeedback(progressStore: ProgressStore)")
completed_start = vm.find("            let completed = Self.scaffoldSuccessCount(", continue_start)
condition = "            if completed < LessonScaffoldExercise.allCases.count {"
condition_at = vm.find(condition, completed_start)
if continue_start < 0 or completed_start < 0 or condition_at < 0:
    die("Couldn't install pending-question loop guard")
guarded = """            let hasPendingSamePhrase = questions.dropFirst(currentIndex + 1).contains {
                $0.phrase.id == question.phrase.id
            }
            if completed < LessonScaffoldExercise.allCases.count && !hasPendingSamePhrase {"""
vm = vm[:condition_at] + guarded + vm[condition_at + len(condition):]

# One-word Fill Gap: use corpus distractors instead of excluding the format.
vm = vm.replace(
'''        guard rawTokens.count >= 2 else {
            return ("____", phrase.foreign, [phrase.foreign])
        }

''', "")
vm = vm.replace("if type == .fillBlank && tokenCount < 2 { return false }\n", "")

# The old helper treated Listen & Write as delayed WRITE. It is now a normal format.
vm = vm.replace(".subtracting([.introduction, .typing, .listenWrite])", ".subtracting([.introduction, .typing])")

for needle in ["RomanceLessonFormat", "successfulLessonFormatKeys", "case exposureOne", "case listenWrite = \"listen-write\""]:
    if needle not in vm: die(f"Quiz sanity check failed: {needle}")
for needle in ["successfulLessonFormatKeys", "return attempts.contains"]:
    if needle not in ps: die(f"Progress sanity check failed: {needle}")

VM.write_text(vm); PS.write_text(ps)
print("✓ Spanish/French: 7 ordinary formats are sampled equally")
print("✓ The two read directions and two listening directions count separately")
print("✓ Listen & Write is in the normal pool; plain WRITE is delayed")
print("✓ Plain WRITE unlocks only after 3 DISTINCT correct ordinary formats")
print("✓ The scaffold ends after successful WRITE — no infinite Compro loop")
print("✓ One-word phrases can receive Fill Gap")
print("✓ Arabic keeps its special chunk/conjugation checkpoint setup")
print("✓ Arabic synthetic checkpoint boards cannot unlock WRITE for a real phrase")
print("✓ Saved broken lesson queues are invalidated")
print("\nNext: build with ⌘B and start Spanish Lesson 1 again.")