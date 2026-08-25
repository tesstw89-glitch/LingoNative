from pathlib import Path
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
TOPIC_DATA = ROOT / "LingoNative/Resources/TopicData"
NESTED_TOPIC_DATA = TOPIC_DATA / "LingoNative-topic-data"
DEST = NESTED_TOPIC_DATA / "spanish_food.json"
MANIFEST = TOPIC_DATA / "course_manifest.json"


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


def find_source() -> Path:
    candidates = [
        DEST,
        TOPIC_DATA / "spanish_food.json",
        ROOT / "spanish_food.json",
        ROOT / "LingoNative" / "spanish_food.json",
        Path.home() / "Downloads" / "spanish_food.json",
    ]

    for candidate in candidates:
        if candidate.exists() and candidate.is_file():
            return candidate

    downloads = Path.home() / "Downloads"
    if downloads.exists():
        matches = sorted(
            downloads.glob("spanish_food*.json"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        if matches:
            return matches[0]

    checked = "\n".join(f"  • {path}" for path in candidates)
    fail(
        "Could not find spanish_food.json. I checked:\n"
        f"{checked}\n\n"
        "Put spanish_food.json in ~/Downloads or the LingoNative folder and run this script again."
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

    required = ("foreign", "english", "lemmas", "context")
    seen_foreign: set[str] = set()
    seen_pairs: set[tuple[str, str]] = set()

    for index, entry in enumerate(data, start=1):
        if not isinstance(entry, dict):
            fail(f"Entry {index} is not a JSON object.")

        for key in required:
            if key not in entry:
                fail(f"Entry {index} is missing required field '{key}'.")

        for key in ("foreign", "english", "context"):
            if not isinstance(entry[key], str):
                fail(f"Entry {index} field '{key}' must be a string.")

        foreign = entry["foreign"].strip()
        english = entry["english"].strip()
        context = entry["context"].strip()

        if not foreign:
            fail(f"Entry {index} has an empty Spanish phrase.")
        if not english:
            fail(f"Entry {index} has an empty English translation.")
        if not context:
            fail(f"Entry {index} has an empty context.")

        if not isinstance(entry["lemmas"], list):
            fail(f"Entry {index} field 'lemmas' must be an array.")

        for lemma in entry["lemmas"]:
            if not isinstance(lemma, dict):
                fail(f"Entry {index} contains a non-object lemma.")
            if not isinstance(lemma.get("foreign"), str) or not isinstance(lemma.get("english"), str):
                fail(f"Entry {index} has a malformed lemma.")

        if foreign in seen_foreign:
            fail(f"Duplicate Spanish phrase at entry {index}: {foreign}")
        seen_foreign.add(foreign)

        pair = (foreign, english)
        if pair in seen_pairs:
            fail(f"Duplicate Spanish/English phrase pair at entry {index}: {foreign}")
        seen_pairs.add(pair)

    return data


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

    topic = next(
        (
            item
            for item in topics
            if isinstance(item, dict) and item.get("id") == "food"
        ),
        None,
    )

    if topic is None:
        topic = {
            "id": "food",
            "title": "Food & Meals",
            "icon": "fork.knife",
            "resources": {},
        }
        topics.append(topic)
        print("✓ Added the Food & Meals topic to course_manifest.json")

    resources = topic.setdefault("resources", {})
    if not isinstance(resources, dict):
        fail("Food & Meals has an invalid 'resources' value in course_manifest.json.")

    wanted = {
        "file": "spanish_food.json",
        # This corpus has meaningful context headings and no bogus per-phrase unit field,
        # so each context group becomes the unit title.
        "unitStrategy": "context",
    }

    if resources.get("spanish") != wanted:
        resources["spanish"] = wanted
        print("✓ Registered Spanish under Food & Meals")
    else:
        print("✓ Food & Meals already points Spanish to spanish_food.json")

    MANIFEST.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    source = find_source()
    entries = load_and_validate(source)
    unit_titles = {entry["context"].strip() for entry in entries}

    print(f"✓ Valid JSON: {len(entries)} Spanish Food & Meals phrases")
    print(f"✓ {len(unit_titles)} context-based units")

    install_corpus(source)
    update_manifest()

    installed = load_and_validate(DEST)
    if len(installed) != len(entries):
        fail("Installed corpus phrase count does not match the source corpus.")

    installed_units = {entry["context"].strip() for entry in installed}
    if installed_units != unit_titles:
        fail("Installed context/unit set does not match the source corpus.")

    print(f"✓ Verified {len(installed)} phrases across {len(unit_titles)} Food & Meals units")
    print("✓ Source JSON was left untouched")
    print("\nNext: build with ⌘B and open Spanish → Food & Meals.")


if __name__ == "__main__":
    main()
