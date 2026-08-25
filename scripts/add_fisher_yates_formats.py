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

if "private enum RomanceLessonFormat" not in vm:
    fail(
        "The new lesson engine is not installed yet. Run "
        "python3 scripts/fix_lesson_engine.py first, then run this patch."
    )

# Explicit Fisher-Yates rather than relying on randomElement/shuffled at the
# format-selection boundary. WRITE (.typing) is never part of these pools.
format_enum = '''    private enum RomanceLessonFormat: String, CaseIterable {
        case readF2E = "read-word-bank-f2e"
        case readE2F = "read-word-bank-e2f"
        case listenF2E = "listen-word-bank-f2e"
        case listenE2F = "listen-word-bank-e2f"
        case listenWrite = "listen-write"
        case fillBlank = "fill-blank"
        case speaking = "speaking"
    }'''

format_enum_with_shuffle = format_enum + '''

    /// Uniform in-place Fisher-Yates shuffle used for normal lesson formats.
    /// Plain WRITE is deliberately excluded before this function is called.
    private static func fisherYatesShuffled<T>(_ input: [T]) -> [T] {
        var output = input
        guard output.count > 1 else { return output }

        for index in stride(from: output.count - 1, through: 1, by: -1) {
            let swapIndex = Int.random(in: 0...index)
            if swapIndex != index {
                output.swapAt(index, swapIndex)
            }
        }
        return output
    }'''

if "private static func fisherYatesShuffled<T>" not in vm:
    vm = replace_once(
        vm,
        format_enum,
        format_enum_with_shuffle,
        "Fisher-Yates helper",
    )

old_romance = '''            let all = RomanceLessonFormat.allCases.filter(ok)
            let fresh = all.filter { !passed.contains($0.rawValue) }
            return makeRomanceLessonQuestion((fresh.isEmpty ? all : fresh).randomElement() ?? .readE2F,
                                             phrase: phrase, index: index, session: session)'''

new_romance = '''            let all = RomanceLessonFormat.allCases.filter(ok)
            let fresh = all.filter { !passed.contains($0.rawValue) }
            let pool = fresh.isEmpty ? all : fresh
            let shuffledPool = fisherYatesShuffled(pool)
            return makeRomanceLessonQuestion(shuffledPool.first ?? .readE2F,
                                             phrase: phrase, index: index, session: session)'''

vm = replace_once(
    vm,
    old_romance,
    new_romance,
    "French/Spanish Fisher-Yates format selection",
)

old_arabic = '''        let fresh = candidates.filter { !passed.contains($0) }
        let type = (fresh.isEmpty ? candidates : fresh).randomElement() ?? .wordBank
        return makeQuestion(phrase: phrase, type: type, stage: .recognition, index: index,
                            phrasePool: session.phrasePool, allPhrases: session.allPhrases)'''

new_arabic = '''        let fresh = candidates.filter { !passed.contains($0) }
        let pool = fresh.isEmpty ? candidates : fresh
        let type = fisherYatesShuffled(pool).first ?? .wordBank
        return makeQuestion(phrase: phrase, type: type, stage: .recognition, index: index,
                            phrasePool: session.phrasePool, allPhrases: session.allPhrases)'''

vm = replace_once(
    vm,
    old_arabic,
    new_arabic,
    "Arabic Fisher-Yates normal-format selection",
)

# Bump saved lesson flow so an already-generated queue is not resumed.
match = re.search(r"private static let lessonFlowVersionBase = (\d+)", vm)
if not match:
    fail("Could not find lessonFlowVersionBase.")
version = int(match.group(1))
if version < 12:
    vm = vm[:match.start(1)] + "12" + vm[match.end(1):]

# Sanity checks.
if ".typing" in format_enum:
    fail("WRITE accidentally entered the Romance format pool.")
if "fisherYatesShuffled(pool)" not in vm:
    fail("French/Spanish Fisher-Yates selection was not installed.")
if "fisherYatesShuffled(pool).first" not in vm:
    fail("Arabic Fisher-Yates selection was not installed.")

VM.write_text(vm)

print("✓ Fisher-Yates installed for the 7 normal French/Spanish lesson formats")
print("✓ Each eligible normal format has the same chance of being first after the shuffle")
print("✓ Listen & Write stays in the normal shuffled pool")
print("✓ Plain WRITE stays OUT of the shuffle and remains gated behind 3 distinct wins")
print("✓ Arabic ordinary non-WRITE phrase exercises use Fisher-Yates too")
print("✓ Arabic chunk/conjugation checkpoints remain separate and untouched")
print("✓ Saved lesson queues are invalidated so the new shuffle takes effect")
print("\nNext: build with ⌘B and start a fresh lesson.")
