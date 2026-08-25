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

# This patch is intended to run after fix_exercise_gate_v2.py.
if "private static let lessonFlowVersionBase = 8" not in vm:
    if "private static let lessonFlowVersionBase = 7" not in vm:
        fail("Expected the write-gate fix (lessonFlowVersionBase = 7) to be present first.")
    vm = vm.replace(
        "private static let lessonFlowVersionBase = 7",
        "private static let lessonFlowVersionBase = 8",
        1,
    )

old_spreader = '''    /// Keep free-writing encounters separated whenever the queue contains
    /// other exercise types. A typing-only drill is intentionally unchanged.
    private static func spreadTypingQuestions(_ input: [QuizQuestion]) -> [QuizQuestion] {
        guard input.count >= 3 else { return input }

        var output = input
        let isFreeWriting: (QuizQuestion) -> Bool = {
            $0.type == .typing || $0.type == .listenWrite
        }
        guard output.contains(where: { !isFreeWriting($0) }) else { return output }

        var index = 1
        while index < output.count {
            if isFreeWriting(output[index - 1]),
               isFreeWriting(output[index]),
               let swapIndex = ((index + 1)..<output.count).first(where: {
                   !isFreeWriting(output[$0])
               }) {
                output.swapAt(index, swapIndex)
            }
            index += 1
        }
        return output
    }'''

new_spreader = '''    /// Interleave all exercise types across the queue instead of relying on a plain shuffle.
    /// Normally avoids immediate repeats; when one type heavily dominates, allows pairs so the
    /// minority types stay distributed rather than being exhausted early and leaving a long tail.
    /// Arabic pair checkpoints remain anchored at their deliberate positions.
    private static func spreadExerciseTypes(
        _ input: [QuizQuestion],
        previousType: ExerciseType? = nil
    ) -> [QuizQuestion] {
        guard input.count >= 2 else { return input }

        func interleaveSegment(
            _ segment: [QuizQuestion],
            previousType: ExerciseType?
        ) -> [QuizQuestion] {
            guard segment.count >= 2 else { return segment }

            var buckets = Dictionary(grouping: segment.shuffled(), by: \\.type)
            var output: [QuizQuestion] = []
            var lastType = previousType
            var runLength = previousType == nil ? 0 : 1

            while !buckets.isEmpty {
                let active = buckets.keys.filter { !(buckets[$0]?.isEmpty ?? true) }
                guard !active.isEmpty else { break }

                var candidates = active
                if let lastType,
                   let lastRemaining = buckets[lastType]?.count {
                    let alternatives = active.filter { $0 != lastType }
                    if !alternatives.isEmpty {
                        let otherRemaining = alternatives.reduce(0) {
                            $0 + (buckets[$1]?.count ?? 0)
                        }

                        // Never permit a run of three while another type is available.
                        // Also avoid even a pair when the current type is not so dominant
                        // that spacing it now would create a larger clump later.
                        if runLength >= 2 || lastRemaining <= otherRemaining + 1 {
                            candidates = alternatives
                        }
                    }
                }

                guard let chosenType = candidates.shuffled().max(by: {
                    (buckets[$0]?.count ?? 0) < (buckets[$1]?.count ?? 0)
                }),
                var bucket = buckets[chosenType],
                let next = bucket.popLast() else { break }

                if bucket.isEmpty {
                    buckets.removeValue(forKey: chosenType)
                } else {
                    buckets[chosenType] = bucket
                }

                output.append(next)
                if chosenType == lastType {
                    runLength += 1
                } else {
                    lastType = chosenType
                    runLength = 1
                }
            }

            return output
        }

        var output: [QuizQuestion] = []
        var segment: [QuizQuestion] = []
        var lastType = previousType

        func flushSegment() {
            guard !segment.isEmpty else { return }
            let balanced = interleaveSegment(segment, previousType: lastType)
            output.append(contentsOf: balanced)
            if let finalType = balanced.last?.type {
                lastType = finalType
            }
            segment.removeAll(keepingCapacity: true)
        }

        for question in input {
            if isArabicPairMatchingQuestion(question) {
                flushSegment()
                output.append(question)
                lastType = question.type
            } else {
                segment.append(question)
            }
        }
        flushSegment()
        return output
    }'''

vm = replace_once(vm, old_spreader, new_spreader, "global exercise interleaver")

# Initial lesson queue.
vm = vm.replace(
    "var balanced = spreadTypingQuestions(lessonQuestions.shuffled())",
    "var balanced = spreadExerciseTypes(lessonQuestions.shuffled())",
)

# Mixed practice queue too, not just lessons.
old_practice = '''        return corePhrases.enumerated().map { index, phrase in
            makeQuestionForCurrentStage(
                phrase: phrase,
                index: index,
                session: session,
                progressStore: progressStore,
                allowedOverride: allowed
            )
        }.shuffled()'''
new_practice = '''        let practiceQuestions = corePhrases.enumerated().map { index, phrase in
            makeQuestionForCurrentStage(
                phrase: phrase,
                index: index,
                session: session,
                progressStore: progressStore,
                allowedOverride: allowed
            )
        }
        return spreadExerciseTypes(practiceQuestions.shuffled())'''
vm = replace_once(vm, old_practice, new_practice, "mixed-practice interleaving")

old_upcoming = '''    private func spreadUpcomingTypingQuestions() {
        let start = currentIndex + 1
        guard start < questions.count else { return }

        let future = Array(questions[start..<questions.count])
        let balanced = Self.spreadTypingQuestions(future)
        questions.replaceSubrange(start..<questions.count, with: balanced)
    }'''

new_upcoming = '''    private func rebalanceUpcomingExerciseTypes() {
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

vm = replace_once(vm, old_upcoming, new_upcoming, "dynamic queue rebalancer")
vm = vm.replace("spreadUpcomingTypingQuestions()", "rebalanceUpcomingExerciseTypes()")

# Sanity checks: the old typing-only balancer must be completely gone.
if "spreadTypingQuestions" in vm or "spreadUpcomingTypingQuestions" in vm:
    fail("Old typing-only shuffle logic is still present after patching.")
if "spreadExerciseTypes" not in vm or "rebalanceUpcomingExerciseTypes" not in vm:
    fail("New exercise interleaving logic was not installed correctly.")

VM.write_text(vm)

print("✓ Exercise types are balanced across the whole lesson queue")
print("✓ Three identical exercise types in a row are prevented whenever another type exists")
print("✓ Repeats are usually avoided entirely when the type counts allow it")
print("✓ Immediate write-remediation and Arabic matching checkpoints stay anchored")
print("✓ Mixed practice sessions use the same interleaving logic")
print("✓ Lesson flow version bumped so an already-saved clumpy queue is discarded")
print("\nNext: build LingoNative with ⌘B.")