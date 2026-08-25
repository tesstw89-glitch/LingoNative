from pathlib import Path
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
TOPIC_DATA = ROOT / "LingoNative/Resources/TopicData"
NESTED_TOPIC_DATA = TOPIC_DATA / "LingoNative-topic-data"
DEST = NESTED_TOPIC_DATA / "arabic_clothes.json"
MANIFEST = TOPIC_DATA / "course_manifest.json"


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


def find_source() -> Path:
    candidates = [
        DEST,
        TOPIC_DATA / "arabic_clothes.json",
        ROOT / "arabic_clothes.json",
        ROOT / "LingoNative" / "arabic_clothes.json",
        Path.home() / "Downloads" / "arabic_clothes.json",
    ]

    for candidate in candidates:
        if candidate.exists() and candidate.is_file():
            return candidate

    checked = "\n".join(f"  • {path}" for path in candidates)
    fail(
        "Could not find arabic_clothes.json. I checked:\n"
        f"{checked}\n\n"
        "Put arabic_clothes.json in the LingoNative-topic-data folder, ~/Downloads, or the LingoNative folder and run this script again."
    )


def validate_corpus(path: Path) -> tuple[list[dict], int]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(
            f"{path.name} is not valid JSON:\n"
            f"line {exc.lineno}, column {exc.colno}: {exc.msg}"
        )

    if not isinstance(data, list) or not data:
        fail(f"{path.name} must be a non-empty JSON array of phrase objects.")

    required = ("foreign", "english", "context")
    unit_count = 0

    for index, entry in enumerate(data, start=1):
        if not isinstance(entry, dict):
            fail(f"Entry {index} is not a JSON object.")

        for key in required:
            if key not in entry:
                fail(f"Entry {index} is missing required field '{key}'.")
            if not isinstance(entry[key], str):
                fail(f"Entry {index} field '{key}' must be a string.")

        if not entry["foreign"].strip():
            fail(f"Entry {index} has an empty 'foreign' value.")
        if not entry["english"].strip():
            fail(f"Entry {index} has an empty 'english' value.")

        if "unit" in entry and entry["unit"] is not None:
            if not isinstance(entry["unit"], str):
                fail(f"Entry {index} field 'unit' must be a string when present.")
            if entry["unit"].strip():
                unit_count += 1

        if "lemmas" in entry and entry["lemmas"] is not None and not isinstance(entry["lemmas"], list):
            fail(f"Entry {index} field 'lemmas' must be an array when present.")

        if "tokens" in entry and entry["tokens"] is not None and not isinstance(entry["tokens"], list):
            fail(f"Entry {index} field 'tokens' must be an array when present.")

    return data, unit_count


def install_corpus(source: Path) -> None:
    NESTED_TOPIC_DATA.mkdir(parents=True, exist_ok=True)

    try:
        same_file = source.resolve() == DEST.resolve()
    except FileNotFoundError:
        same_file = False

    if same_file:
        print(f"✓ Corpus already in the correct resource folder: {DEST.relative_to(ROOT)}")
        return

    shutil.copy2(source, DEST)
    print(f"✓ Copied {source} → {DEST.relative_to(ROOT)}")


def update_manifest() -> None:
    if not MANIFEST.exists():
        fail(f"Missing {MANIFEST.relative_to(ROOT)}")

    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(
            f"course_manifest.json is invalid JSON:\n"
            f"line {exc.lineno}, column {exc.colno}: {exc.msg}"
        )

    topics = manifest.get("topics")
    if not isinstance(topics, list):
        fail("course_manifest.json has no valid 'topics' array.")

    clothes = next(
        (
            topic
            for topic in topics
            if isinstance(topic, dict) and topic.get("id") == "clothes"
        ),
        None,
    )
    if clothes is None:
        fail("Could not find the existing 'clothes' topic in course_manifest.json.")

    resources = clothes.setdefault("resources", {})
    if not isinstance(resources, dict):
        fail("The Clothes topic has an invalid 'resources' value.")

    wanted = {
        "file": "arabic_clothes.json",
        # Explicit `unit` fields in the corpus take precedence in CorpusLoader.
        # `context` is the safest fallback for any entry that does not have one.
        "unitStrategy": "context",
    }

    if resources.get("arabic") == wanted:
        print("✓ Clothes manifest already points Arabic to arabic_clothes.json")
        return

    resources["arabic"] = wanted
    MANIFEST.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("✓ Added Arabic to Clothes & Appearance in course_manifest.json")


def main() -> None:
    source = find_source()
    entries, unit_count = validate_corpus(source)

    print(f"✓ Valid JSON: {len(entries)} Arabic clothes phrases")
    if unit_count:
        print(f"✓ {unit_count}/{len(entries)} entries have explicit unit labels")
    else:
        print("• No explicit unit labels found; Clothes units will fall back to context")

    install_corpus(source)
    update_manifest()

    installed_entries, _ = validate_corpus(DEST)
    if len(installed_entries) != len(entries):
        fail("Installed corpus phrase count does not match the source file.")

    print("✓ arabic_clothes.json is ready for the Arabic course")
    print("\nNext: build LingoNative with ⌘B and open Arabic → Clothes & Appearance.")


if __name__ == "__main__":
    main()
