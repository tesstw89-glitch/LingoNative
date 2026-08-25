from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
TOPIC_DATA = ROOT / "LingoNative/Resources/TopicData"
NESTED_TOPIC_DATA = TOPIC_DATA / "LingoNative-topic-data"
DEST = NESTED_TOPIC_DATA / "arabic_getting_around.json"
MANIFEST = TOPIC_DATA / "course_manifest.json"


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


def find_source() -> Path:
    candidates = [
        DEST,
        NESTED_TOPIC_DATA / "lebanese_getting_around.json",
        TOPIC_DATA / "lebanese_getting_around.json",
        ROOT / "lebanese_getting_around.json",
        ROOT / "LingoNative" / "lebanese_getting_around.json",
        Path.home() / "Downloads" / "lebanese_getting_around.json",
    ]

    for candidate in candidates:
        if candidate.exists() and candidate.is_file():
            return candidate

    # Also accept browser-style duplicate filenames such as
    # lebanese_getting_around(1).json in Downloads.
    downloads = Path.home() / "Downloads"
    if downloads.exists():
        matches = sorted(
            downloads.glob("lebanese_getting_around*.json"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        if matches:
            return matches[0]

    checked = "\n".join(f"  • {path}" for path in candidates)
    fail(
        "Could not find lebanese_getting_around.json. I checked:\n"
        f"{checked}\n\n"
        "Put the JSON in ~/Downloads or the LingoNative folder and run this script again."
    )


def load_and_validate(path: Path) -> list[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(
            f"{path.name} is not valid JSON:\n"
            f"line {exc.lineno}, column {exc.colno}: {exc.msg}"
        )

    if not isinstance(data, list) or not data:
        fail(f"{path.name} must be a non-empty JSON array.")

    required = ("foreign", "transliteration", "english", "tokens", "lemmas", "context")
    seen_pairs: set[tuple[str, str]] = set()

    for index, entry in enumerate(data, start=1):
        if not isinstance(entry, dict):
            fail(f"Entry {index} is not a JSON object.")

        for key in required:
            if key not in entry:
                fail(f"Entry {index} is missing required field '{key}'.")

        for key in ("foreign", "transliteration", "english", "context"):
            if not isinstance(entry[key], str):
                fail(f"Entry {index} field '{key}' must be a string.")

        if not entry["foreign"].strip():
            fail(f"Entry {index} has an empty foreign phrase.")
        if not entry["english"].strip():
            fail(f"Entry {index} has an empty English translation.")
        if not entry["context"].strip():
            fail(f"Entry {index} has an empty context.")

        if not isinstance(entry["tokens"], list):
            fail(f"Entry {index} field 'tokens' must be an array.")
        if not isinstance(entry["lemmas"], list):
            fail(f"Entry {index} field 'lemmas' must be an array.")

        for token in entry["tokens"]:
            if not isinstance(token, dict):
                fail(f"Entry {index} contains a non-object token.")
            if not isinstance(token.get("foreign"), str) or not isinstance(token.get("transliteration"), str):
                fail(f"Entry {index} has a malformed token.")

        for lemma in entry["lemmas"]:
            if not isinstance(lemma, dict):
                fail(f"Entry {index} contains a non-object lemma.")
            if not isinstance(lemma.get("foreign"), str) or not isinstance(lemma.get("english"), str):
                fail(f"Entry {index} has a malformed lemma.")
            transliteration = lemma.get("transliteration")
            if transliteration is not None and not isinstance(transliteration, str):
                fail(f"Entry {index} has a malformed lemma transliteration.")

        pair = (entry["foreign"].strip(), entry["english"].strip())
        if pair in seen_pairs:
            fail(f"Duplicate foreign/English phrase pair at entry {index}: {pair[0]}")
        seen_pairs.add(pair)

    return data


def unit_from_context(context: str) -> str:
    """Keep the topic + immediate subheading; leave narrower notes in context only."""
    pieces = [piece.strip() for piece in context.split("—")]
    if len(pieces) >= 2 and pieces[0] and pieces[1]:
        return f"{pieces[0]} — {pieces[1]}"
    return context.strip()


def make_app_corpus(entries: list[dict]) -> tuple[list[dict], int]:
    output: list[dict] = []
    unit_titles: set[str] = set()

    for entry in entries:
        cleaned = dict(entry)
        cleaned["unit"] = unit_from_context(entry["context"])
        unit_titles.add(cleaned["unit"])
        output.append(cleaned)

    return output, len(unit_titles)


def install_corpus(entries: list[dict]) -> None:
    NESTED_TOPIC_DATA.mkdir(parents=True, exist_ok=True)
    DEST.write_text(
        json.dumps(entries, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"✓ Installed {DEST.relative_to(ROOT)}")


def update_manifest() -> None:
    if not MANIFEST.exists():
        fail(f"Missing {MANIFEST.relative_to(ROOT)}")

    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(
            "course_manifest.json is invalid JSON:\n"
            f"line {exc.lineno}, column {exc.colno}: {exc.msg}"
        )

    topics = manifest.get("topics")
    if not isinstance(topics, list):
        fail("course_manifest.json has no valid 'topics' array.")

    topic = next(
        (
            item
            for item in topics
            if isinstance(item, dict) and item.get("id") == "getting_around"
        ),
        None,
    )
    if topic is None:
        fail("Could not find the existing 'getting_around' topic in course_manifest.json.")

    resources = topic.setdefault("resources", {})
    if not isinstance(resources, dict):
        fail("Getting Around has an invalid 'resources' value in course_manifest.json.")

    wanted = {
        "file": "arabic_getting_around.json",
        # Explicit unit fields in the installed corpus win. Context is the safe fallback.
        "unitStrategy": "context",
    }

    if resources.get("arabic") != wanted:
        resources["arabic"] = wanted
        MANIFEST.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print("✓ Registered Arabic under Getting Around in course_manifest.json")
    else:
        print("✓ Getting Around manifest already has the Arabic resource")


def main() -> None:
    source = find_source()
    source_entries = load_and_validate(source)
    app_entries, unit_count = make_app_corpus(source_entries)

    print(f"✓ Valid JSON: {len(source_entries)} Lebanese Getting Around phrases")
    print(f"✓ Rebuilt the old per-phrase unit labels into {unit_count} real units")

    install_corpus(app_entries)
    update_manifest()

    installed = load_and_validate(DEST)
    if len(installed) != len(source_entries):
        fail("Installed corpus phrase count does not match the source corpus.")

    installed_units = {entry.get("unit", "").strip() for entry in installed}
    if len(installed_units) != unit_count:
        fail("Installed unit count does not match the rebuilt unit structure.")

    print(f"✓ Verified {len(installed)} phrases across {unit_count} Getting Around units")
    print("✓ Source JSON was left untouched; only the app copy was normalised")
    print("\nNext: build with ⌘B and open Arabic → Getting Around.")


if __name__ == "__main__":
    main()
