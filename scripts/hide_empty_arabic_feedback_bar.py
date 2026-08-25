from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEW = ROOT / "LingoNative/Views/QuizView.swift"


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


if not VIEW.exists():
    fail(f"Missing {VIEW.relative_to(ROOT)}")

text = VIEW.read_text()

old = '''        .safeAreaInset(edge: .bottom) {
            feedbackBar(question: question)
        }'''

new = '''        .safeAreaInset(edge: .bottom) {
            if !(viewModel.isArabicPairMatchingBoard(question) && viewModel.status == .unanswered) {
                feedbackBar(question: question)
            }
        }'''

if new in text:
    print("✓ Empty Arabic matching feedback bar is already hidden")
    raise SystemExit(0)

count = text.count(old)
if count != 1:
    fail(f"Could not patch bottom feedback bar; expected 1 match, found {count}.")

text = text.replace(old, new, 1)
VIEW.write_text(text)

print("✓ Hidden the empty bottom bar while Arabic pair-matching is in progress")
print("✓ The normal feedback/NEXT bar still appears after the board is completed")
print("✓ Other exercise screens are unchanged")
print("\nNext: build with ⌘B and open an Arabic matching checkpoint.")
