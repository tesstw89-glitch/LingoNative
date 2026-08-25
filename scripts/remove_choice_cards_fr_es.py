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

if "private static let lessonFlowVersionBase = 10" not in vm:
    if "private static let lessonFlowVersionBase = 9" not in vm:
        fail("Expected tune_lesson_variety.py to have been applied first (lessonFlowVersionBase = 9).")
    vm = vm.replace(
        "private static let lessonFlowVersionBase = 9",
        "private static let lessonFlowVersionBase = 10",
        1,
    )

# French / Spanish lessons should not contain either true Multiple Choice or the
# current generic Matching screen, because generic Matching is also just one prompt
# with four answer cards. Arabic pair-matching checkpoints are a different UI and stay.
vm = replace_once(
    vm,
    '''            if (session.course == .french || session.course == .spanish) && type == .multipleChoice {
                return false
            }
            if respectEnabled && !enabled.contains(type) { return false }''',
    '''            if (session.course == .french || session.course == .spanish)
                && (type == .multipleChoice || type == .matching) {
                return false
            }
            if respectEnabled && !enabled.contains(type) { return false }''',
    "French/Spanish pre-write choice-card removal",
)

vm = replace_once(
    vm,
    '''                if (course == .french || course == .spanish) && type == .multipleChoice {
                    return false
                }
                if course == .arabic && isLesson && type == .matching { return false }''',
    '''                if (course == .french || course == .spanish)
                    && (type == .multipleChoice || (type == .matching && (isLesson || allowed.count > 1))) {
                    return false
                }
                if course == .arabic && isLesson && type == .matching { return false }''',
    "French/Spanish adaptive choice-card removal",
)

vm = replace_once(
    vm,
    '''        if session.course == .arabic, allowed.contains(.multipleChoice) { return .multipleChoice }
        if allowed.contains(.matching) { return .matching }''',
    '''        if session.course == .arabic, allowed.contains(.multipleChoice) { return .multipleChoice }
        if session.course == .arabic, allowed.contains(.matching) { return .matching }''',
    "French/Spanish scaffold fallback matching removal",
)

# Keep explicit Matching practice available if the learner deliberately chooses that
# practice mode, but never let it leak into mixed French/Spanish lessons/practice.
if "type == .matching && (isLesson || allowed.count > 1)" not in vm:
    fail("Mixed French/Spanish Matching exclusion was not installed.")
if "session.course == .arabic, allowed.contains(.matching)" not in vm:
    fail("Scaffold fallback still permits French/Spanish Matching.")

VM.write_text(vm)

print("✓ French lessons no longer auto-generate Multiple Choice")
print("✓ French lessons no longer auto-generate the four-card pseudo-Matching screen")
print("✓ Spanish lessons no longer auto-generate either choice-card format")
print("✓ Explicit Matching practice is still available if deliberately selected")
print("✓ Arabic real pair-matching checkpoints are untouched")
print("✓ Lesson flow version bumped so saved French/Spanish queues are regenerated")
print("\nNext: build LingoNative with ⌘B and start a fresh lesson.")
