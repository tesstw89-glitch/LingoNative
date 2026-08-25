from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
TOPIC_DATA = ROOT / "LingoNative/Resources/TopicData"
CORPUS = TOPIC_DATA / "LingoNative-topic-data/arabic_clothes.json"
MANIFEST = TOPIC_DATA / "course_manifest.json"


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


if not CORPUS.exists():
    fail(f"Could not find {CORPUS.relative_to(ROOT)}")
if not MANIFEST.exists():
    fail(f"Could not find {MANIFEST.relative_to(ROOT)}")

try:
    entries = json.loads(CORPUS.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    fail(f"arabic_clothes.json is invalid JSON at line {exc.lineno}, column {exc.colno}: {exc.msg}")

if not isinstance(entries, list) or not entries:
    fail("arabic_clothes.json must be a non-empty JSON array")

for index, entry in enumerate(entries, start=1):
    if not isinstance(entry, dict):
        fail(f"Entry {index} is not an object")
    context = entry.get("context")
    if not isinstance(context, str) or not context.strip():
        fail(f"Entry {index} has no usable context, so it cannot be grouped into a unit")

old_unit_values = [
    entry.get("unit", "").strip()
    for entry in entries
    if isinstance(entry.get("unit"), str) and entry.get("unit", "").strip()
]
old_unique_units = len(set(old_unit_values))
contexts = [entry["context"].strip() for entry in entries]
unique_contexts = []
seen = set()
for context in contexts:
    if context not in seen:
        seen.add(context)
        unique_contexts.append(context)

# Explicit `unit` always overrides the manifest's unitStrategy in CorpusLoader.
# These Arabic clothes entries were using the individual English phrase as
# `unit`, producing almost one app unit per phrase. Remove that override and
# let the intended context labels define the units instead.
removed = 0
for entry in entries:
    if "unit" in entry:
        del entry["unit"]
        removed += 1

CORPUS.write_text(
    json.dumps(entries, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

try:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    fail(f"course_manifest.json is invalid JSON at line {exc.lineno}, column {exc.colno}: {exc.msg}")

clothes = next(
    (
        topic for topic in manifest.get("topics", [])
        if isinstance(topic, dict) and topic.get("id") == "clothes"
    ),
    None,
)
if clothes is None:
    fail("Could not find the Clothes topic in course_manifest.json")

resources = clothes.setdefault("resources", {})
if not isinstance(resources, dict):
    fail("The Clothes topic has an invalid resources object")

resources["arabic"] = {
    "file": "arabic_clothes.json",
    "unitStrategy": "context",
}

MANIFEST.write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

# Final sanity checks.
reloaded = json.loads(CORPUS.read_text(encoding="utf-8"))
if any("unit" in entry for entry in reloaded):
    fail("Sanity check failed: at least one explicit unit field remains")
final_contexts = {entry["context"].strip() for entry in reloaded}
if len(final_contexts) != len(unique_contexts):
    fail("Sanity check failed: context grouping changed unexpectedly")

print(f"✓ Arabic clothes phrases: {len(entries)}")
print(f"✓ Removed explicit unit fields from {removed} entries")
print(f"✓ Before: {old_unique_units} distinct explicit unit titles")
print(f"✓ After: {len(unique_contexts)} context-based units")
print("✓ Manifest now uses unitStrategy = context for Arabic Clothes")
print("✓ Phrase text, transliteration, tokens, lemmas and context were left untouched")
print("\nFirst few units:")
for title in unique_contexts[:8]:
    print(f"  • {title}")
print("\nNext: build with ⌘B and reopen Arabic → Clothes & Appearance.")
