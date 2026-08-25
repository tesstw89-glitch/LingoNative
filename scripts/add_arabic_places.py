from pathlib import Path
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
TOPIC_DATA = ROOT / "LingoNative/Resources/TopicData"
NESTED_TOPIC_DATA = TOPIC_DATA / "LingoNative-topic-data"
DEST = NESTED_TOPIC_DATA / "arabic_places.json"
MANIFEST = TOPIC_DATA / "course_manifest.json"


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


def find_source() -> Path:
    candidates = [
        DEST,
        TOPIC_DATA / "arabic_places.json",
        ROOT / "arabic_places.json",
        ROOT / "LingoNative" / "arabic_places.json",
        Path.home() / "Downloads" / "arabic_places.json",
        Path.home() / "Downloads" / "lebanese_places_ar_second_pass.json",
        Path.home() / "Downloads" / "lebanese_places_ar_second_pass(1).json",
        Path.home() / "Downloads" / "lebanese_places_ar_second_pass(2).json",
    ]

    for candidate in candidates:
        if candidate.exists() and candidate.is_file():
            return candidate

    checked = "\n".join(f"  • {path}" for path in candidates)
    fail(
        "Could not find the Arabic Places corpus. I checked:\n"
        f"{checked}\n\n"
        "Rename it arabic_places.json and put it in ~/Downloads, the repo root, "
        "or LingoNative/Resources/TopicData/LingoNative-topic-data, then run this script again."
    )


def validate_corpus(path: Path) -> tuple[list[dict], list[str]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(
            f"{path.name} is not valid JSON:\n"
            f"line {exc.lineno}, column {exc.colno}: {exc.msg}"
        )

    if not isinstance(data, list) or not data:
        fail(f"{path.name} must be a non-empty JSON array of phrase objects.")

    required = ("foreign", "transliteration", "english", "tokens", "lemmas", "context", "unit")
    seen_pairs: set[tuple[str, str]] = set()
    units: list[str] = []
    seen_units: set[str] = set()

    for index, entry in enumerate(data, start=1):
        if not isinstance(entry, dict):
            fail(f"Entry {index} is not a JSON object.")

        for key in required:
            if key not in entry:
                fail(f"Entry {index} is missing required field '{key}'.")

        for key in ("foreign", "transliteration", "english", "context", "unit"):
            if not isinstance(entry[key], str):
                fail(f"Entry {index} field '{key}' must be a string.")

        if not entry["foreign"].strip():
            fail(f"Entry {index} has an empty 'foreign' value.")
        if not entry["english"].strip():
            fail(f"Entry {index} has an empty 'english' value.")
        if not entry["unit"].strip():
            fail(f"Entry {index} has an empty 'unit' value.")

        if not isinstance(entry["tokens"], list):
            fail(f"Entry {index} field 'tokens' must be an array.")
        if not isinstance(entry["lemmas"], list):
            fail(f"Entry {index} field 'lemmas' must be an array.")

        for token_index, token in enumerate(entry["tokens"], start=1):
            if not isinstance(token, dict):
                fail(f"Entry {index}, token {token_index} is not an object.")
            if not isinstance(token.get("foreign"), str) or not isinstance(token.get("transliteration"), str):
                fail(f"Entry {index}, token {token_index} needs string foreign/transliteration values.")

        for lemma_index, lemma in enumerate(entry["lemmas"], start=1):
            if not isinstance(lemma, dict):
                fail(f"Entry {index}, lemma {lemma_index} is not an object.")
            for key in ("foreign", "transliteration", "english"):
                if not isinstance(lemma.get(key), str):
                    fail(f"Entry {index}, lemma {lemma_index} needs string '{key}'.")

        pair = (entry["foreign"].strip(), entry["english"].strip())
        if pair in seen_pairs:
            fail(f"Duplicate foreign/English phrase pair at entry {index}: {pair[0]}")
        seen_pairs.add(pair)

        unit = entry["unit"].strip()
        if unit not in seen_units:
            seen_units.add(unit)
            units.append(unit)

    return data, units


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
            "course_manifest.json is invalid JSON:\n"
            f"line {exc.lineno}, column {exc.colno}: {exc.msg}"
        )

    topics = manifest.get("topics")
    if not isinstance(topics, list):
        fail("course_manifest.json has no valid 'topics' array.")

    places = next(
        (
            topic
            for topic in topics
            if isinstance(topic, dict) and topic.get("id") == "places"
        ),
        None,
    )
    if places is None:
        fail("Could not find the existing 'places' topic in course_manifest.json.")

    resources = places.setdefault("resources", {})
    if not isinstance(resources, dict):
        fail("The Places topic has an invalid 'resources' value.")

    wanted = {
        "file": "arabic_places.json",
        # Every entry in this corpus already has an explicit unit. CorpusLoader
        # uses that first; context is simply the safe fallback.
        "unitStrategy": "context",
    }

    if resources.get("arabic") == wanted:
        print("✓ Places manifest already points Arabic to arabic_places.json")
        return

    resources["arabic"] = wanted
    MANIFEST.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("✓ Added Arabic to Places in course_manifest.json")


def main() -> None:
    source = find_source()
    entries, units = validate_corpus(source)

    print(f"✓ Valid JSON: {len(entries)} Arabic Places phrases")
    print(f"✓ Explicit unit structure: {len(units)} units")

    install_corpus(source)
    update_manifest()

    installed_entries, installed_units = validate_corpus(DEST)
    if len(installed_entries) != len(entries):
        fail("Installed corpus phrase count does not match the source file.")
    if installed_units != units:
        fail("Installed corpus unit order does not match the source file.")

    print("✓ arabic_places.json is ready for the Arabic course")
    print("\nNext: build LingoNative with ⌘B and open Arabic → Places.")


if __name__ == "__main__":
    main()
