from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
TOPIC_DATA = ROOT / "LingoNative/Resources/TopicData"
NESTED_TOPIC_DATA = TOPIC_DATA / "LingoNative-topic-data"
MANIFEST = TOPIC_DATA / "course_manifest.json"

REQUIRED_FILES = {
    "arabic_clothes.json",
    "french_food.json",
    "spanish_food.json",
}


def fail(message: str) -> None:
    raise SystemExit(f"\n❌ {message}\n")


def main() -> None:
    missing = sorted(name for name in REQUIRED_FILES if not (NESTED_TOPIC_DATA / name).is_file())
    if missing:
        fail(
            "These corpus files are not in the bundled topic-data folder:\n"
            + "\n".join(f"  • {name}" for name in missing)
            + f"\n\nExpected folder: {NESTED_TOPIC_DATA.relative_to(ROOT)}"
        )

    if not MANIFEST.is_file():
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

    clothes = next(
        (topic for topic in topics if isinstance(topic, dict) and topic.get("id") == "clothes"),
        None,
    )
    if clothes is None:
        fail("Could not find the existing Clothes & Appearance topic.")

    clothes_resources = clothes.setdefault("resources", {})
    if not isinstance(clothes_resources, dict):
        fail("Clothes & Appearance has an invalid 'resources' value.")

    clothes_resources["arabic"] = {
        "file": "arabic_clothes.json",
        "unitStrategy": "context",
    }
    print("✓ Registered Arabic under Clothes & Appearance")

    food = next(
        (topic for topic in topics if isinstance(topic, dict) and topic.get("id") == "food"),
        None,
    )
    if food is None:
        food = {
            "id": "food",
            "title": "Food & Meals",
            "icon": "fork.knife",
            "resources": {},
        }
        topics.append(food)
        print("✓ Added Food & Meals topic")

    food_resources = food.setdefault("resources", {})
    if not isinstance(food_resources, dict):
        fail("Food & Meals has an invalid 'resources' value.")

    food_resources["french"] = {
        "file": "french_food.json",
        "unitStrategy": "beforeEmDash",
    }
    food_resources["spanish"] = {
        "file": "spanish_food.json",
        "unitStrategy": "context",
    }
    print("✓ Registered French under Food & Meals")
    print("✓ Registered Spanish under Food & Meals")

    MANIFEST.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    # Re-read and verify exactly what the app will see.
    check = json.loads(MANIFEST.read_text(encoding="utf-8"))
    check_topics = {topic.get("id"): topic for topic in check.get("topics", []) if isinstance(topic, dict)}

    if check_topics.get("clothes", {}).get("resources", {}).get("arabic", {}).get("file") != "arabic_clothes.json":
        fail("Arabic Clothes registration did not verify.")
    if check_topics.get("food", {}).get("resources", {}).get("french", {}).get("file") != "french_food.json":
        fail("French Food registration did not verify.")
    if check_topics.get("food", {}).get("resources", {}).get("spanish", {}).get("file") != "spanish_food.json":
        fail("Spanish Food registration did not verify.")

    print("\n✓ Manifest verified")
    print("✓ arabic_clothes.json is live")
    print("✓ french_food.json is live")
    print("✓ spanish_food.json is live")
    print("\nNext: build with ⌘B.")


if __name__ == "__main__":
    main()
