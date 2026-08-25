from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/fix_exercise_gate.py"

if not HELPER.exists():
    raise SystemExit(f"\n❌ Missing {HELPER.relative_to(ROOT)}\n")

source = HELPER.read_text()

# The original matcher also saw the function definition as a call because the
# definition later contains `session: session` in its body. Exclude definitions
# explicitly so we patch only the three real call sites.
old_pattern_start = r"r'(makeNextLessonScaffoldQuestion\(\n"
new_pattern_start = r"r'((?<!func )makeNextLessonScaffoldQuestion\(\n"

if old_pattern_start not in source:
    raise SystemExit("\n❌ Could not find the expected scaffold-call matcher in fix_exercise_gate.py\n")

source = source.replace(old_pattern_start, new_pattern_start, 1)

scope = {
    "__file__": str(HELPER),
    "__name__": "__main__",
}
exec(compile(source, str(HELPER), "exec"), scope)
