from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEW = ROOT / "LingoNative/Views/QuizView.swift"


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


if not VIEW.exists():
    fail(f"Missing {VIEW.relative_to(ROOT)}")

view = VIEW.read_text()

old_keys = '        let extraKeys = ["أ", "إ", "آ", "ذ"]'
new_keys = '        let extraKeys = ["أ", "إ", "آ", "ذ", "ّ"]'

if new_keys not in view:
    count = view.count(old_keys)
    if count != 1:
        fail(f"Could not find the Arabic extra-key row; expected 1 match, found {count}.")
    view = view.replace(old_keys, new_keys, 1)

old_label = '''        } label: {
            Text(key)
                .font(.custom("NotoSansArabic-Medium", size: 20))'''
new_label = '''        } label: {
            // Show a dotted-circle preview so the standalone shadda is visible,
            // while appendArabicKey still inserts only the real combining mark.
            Text(key == "ّ" ? "◌ّ" : key)
                .font(.custom("NotoSansArabic-Medium", size: 20))'''

if new_label not in view:
    count = view.count(old_label)
    if count != 1:
        fail(f"Could not update Arabic key display; expected 1 match, found {count}.")
    view = view.replace(old_label, new_label, 1)

VIEW.write_text(view)

print("✓ Added shadda to the Arabic keyboard")
print("✓ The key displays as ◌ّ so it is easy to see")
print("✓ Tapping it inserts only the real shadda: ّ")
print("✓ No other Arabic keyboard keys were changed")
print("\nNext: build LingoNative with ⌘B.")
