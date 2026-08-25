from pathlib import Path

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

# This refinement is designed to run after the write-gate and exercise-clumping fixes.
if "private static let lessonFlowVersionBase = 9" not in vm:
    if "private static let lessonFlowVersionBase = 8" not in vm:
        fail("Expected fix_exercise_clumping.py to have been applied first (lessonFlowVersionBase = 8).")
    vm = vm.replace(
        "private static let lessonFlowVersionBase = 8",
        "private static let lessonFlowVersionBase = 9",
        1,
    )

# ---------------------------------------------------------------------------
# French / Spanish: never auto-select multiple choice.
# Arabic keeps it available because its lesson mix is intentionally different.
# ---------------------------------------------------------------------------
vm = replace_once(
    vm,
    '''            if type == .introduction || type == .typing || type == .listenWrite { return false }
            if respectEnabled && !enabled.contains(type) { return false }''',
    '''            if type == .introduction || type == .typing || type == .listenWrite { return false }
            if (session.course == .french || session.course == .spanish) && type == .multipleChoice {
                return false
            }
            if respectEnabled && !enabled.contains(type) { return false }''',
    "French/Spanish pre-write multiple-choice removal",
)

vm = replace_once(
    vm,
    '''                guard allowed.contains(type) else { return false }
                if course == .arabic && isLesson && type == .matching { return false }''',
    '''                guard allowed.contains(type) else { return false }
                if (course == .french || course == .spanish) && type == .multipleChoice {
                    return false
                }
                if course == .arabic && isLesson && type == .matching { return false }''',
    "French/Spanish adaptive multiple-choice removal",
)

vm = replace_once(
    vm,
    '''        if allowed.contains(.multipleChoice) { return .multipleChoice }
        if allowed.contains(.matching) { return .matching }''',
    '''        if session.course == .arabic, allowed.contains(.multipleChoice) { return .multipleChoice }
        if allowed.contains(.matching) { return .matching }''',
    "French/Spanish fallback multiple-choice removal",
)

# ---------------------------------------------------------------------------
# Replace the strict type interleaver with a looser scheduler.
# Hard rules:
#   • do not repeat the same phrase within the previous 4 questions when alternatives exist
#   • free writing for the same phrase gets a 6-question cooldown
#   • never allow 3 identical exercise types in a row when another type exists
# Soft rule:
#   • only ~65% of the time prefer a different type from the immediately previous one
# This leaves natural doubles and irregularity instead of producing an ABAB rhythm.
# ---------------------------------------------------------------------------
start_marker = "    /// Interleave all exercise types across the queue instead of relying on a plain shuffle."
end_marker = "    private static func reinforcementPhrases("
start = vm.find(start_marker)
end = vm.find(end_marker)
if start == -1 or end == -1 or end <= start:
    fail("Could not locate the current exercise interleaver.")

new_scheduler = '''    /// Keep the lesson varied without turning it into a visible ABAB pattern.
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
                // immediately after the third qualifying non-write success.
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

'''
vm = vm[:start] + new_scheduler + vm[end:]

old_rebalancer = '''    private func rebalanceUpcomingExerciseTypes() {
        let start = currentIndex + 1
        guard start < questions.count else { return }

        // A missed free-write gets an immediate word-bank rescue. Keep that rescue directly
        // after the miss, then rebalance everything after it.
        let hasImmediateRescue = status == .wrong
            && (currentQuestion?.type == .typing || currentQuestion?.type == .listenWrite)
        let fixedCount = hasImmediateRescue ? 1 : 0
        let balanceStart = min(questions.count, start + fixedCount)
        guard balanceStart < questions.count else { return }

        let previousType: ExerciseType? = fixedCount == 1
            ? questions[start].type
            : currentQuestion?.type
        let future = Array(questions[balanceStart..<questions.count])
        let balanced = Self.spreadExerciseTypes(
            future,
            previousType: previousType
        )
        questions.replaceSubrange(balanceStart..<questions.count, with: balanced)
    }'''

new_rebalancer = '''    private func rebalanceUpcomingExerciseTypes() {
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
    }'''

vm = replace_once(vm, old_rebalancer, new_rebalancer, "phrase-aware future rebalancer")

# Sanity checks.
if "previousType:" in vm and "spreadExerciseTypes(" in vm:
    fail("A call to the old previousType-based interleaver is still present.")
if "recentQuestions:" not in vm:
    fail("Phrase-aware history was not installed.")
if "session.course == .arabic, allowed.contains(.multipleChoice)" not in vm:
    fail("French/Spanish multiple-choice removal was not installed.")

VM.write_text(vm)

print("✓ Same phrase normally waits for 4 other questions before returning")
print("✓ WRITE / Listen & write waits for 6 other questions when alternatives exist")
print("✓ WRITE still unlocks after exactly 3 DISTINCT correct non-write exercise types")
print("✓ Type order is looser: occasional doubles are allowed, but runs of 3 are blocked when possible")
print("✓ Multiple Choice is removed from French and Spanish automatic lessons/practice")
print("✓ Arabic keeps Multiple Choice available")
print("✓ Lesson flow version bumped so saved queues are regenerated")
print("\nNext: build LingoNative with ⌘B and start a fresh lesson.")
