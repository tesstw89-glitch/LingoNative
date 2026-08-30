#!/usr/bin/env python3
from pathlib import Path
import argparse
import hashlib
import json
import os
import sqlite3
from collections import OrderedDict

SCHEMA_VERSION = 1

def die(message):
    raise SystemExit(f"❌ {message}")

def find_repo(explicit=None):
    root = Path(explicit).expanduser().resolve() if explicit else (Path.home() / "Downloads" / "LingoNative").resolve()
    if not (root / "LingoNative.xcodeproj").exists():
        die(f"Could not find LingoNative repo at {root}")
    return root

def find_resource(topic_dir, filename):
    for candidate in (topic_dir / "LingoNative-topic-data" / filename, topic_dir / filename):
        if candidate.exists():
            return candidate
    matches = list(topic_dir.rglob(filename))
    if len(matches) == 1:
        return matches[0]
    if not matches:
        die(f"Missing corpus resource: {filename}")
    die(f"Ambiguous corpus resource {filename}: {matches}")

def clean_text(value):
    return "" if value is None else str(value).strip()

def first_sentence(context):
    trimmed = clean_text(context)
    if not trimmed:
        return "Everyday language"
    piece = trimmed.split(". ", 1)[0]
    return piece.strip(" .\t\r\n") or trimmed

def make_unit_title(context, strategy):
    trimmed = clean_text(context)
    if not trimmed:
        return "Everyday language"
    first = first_sentence(trimmed)
    if strategy == "context":
        return trimmed
    if strategy == "firstSentence":
        return first
    if strategy == "beforeEmDash":
        return first.split(" — ", 1)[0].strip() or first
    if strategy == "afterEmDash":
        parts = first.split(" — ")
        return " — ".join(parts[1:]).strip() if len(parts) > 1 else first
    if strategy == "beforeColon":
        return first.split(":", 1)[0].strip() or first
    return trimmed

def string_id(value, fallback):
    return str(fallback) if value is None else str(value)

def stable_phrase_id(topic_id, raw_id, index):
    source = string_id(raw_id, index + 1)
    return source if topic_id == "opinions" else f"{topic_id}:{source}"

def stable_unit_id(course, topic_id, raw_unit_id, fallback_index):
    source = string_id(raw_unit_id, fallback_index + 1)
    return f"{course}-unit-{source}" if topic_id == "opinions" else f"{course}-{topic_id}-unit-{source}"

def interleave(groups, block_size):
    cursors = [0] * len(groups)
    output = []
    while True:
        added = False
        for i, group in enumerate(groups):
            start = cursors[i]
            if start >= len(group):
                continue
            end = min(start + block_size, len(group))
            output.extend(group[start:end])
            cursors[i] = end
            added = True
        if not added:
            return output

def create_schema(db):
    db.executescript("""
    PRAGMA journal_mode=OFF;
    PRAGMA synchronous=OFF;
    PRAGMA temp_store=MEMORY;
    PRAGMA foreign_keys=ON;
    PRAGMA page_size=4096;

    CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
    CREATE TABLE courses (
        course TEXT PRIMARY KEY,
        block_size INTEGER NOT NULL,
        topic_count INTEGER NOT NULL,
        unit_count INTEGER NOT NULL,
        phrase_count INTEGER NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE topics (
        course TEXT NOT NULL,
        topic_id TEXT NOT NULL,
        topic_order INTEGER NOT NULL,
        title TEXT NOT NULL,
        icon TEXT NOT NULL,
        phrase_count INTEGER NOT NULL,
        unit_count INTEGER NOT NULL,
        PRIMARY KEY (course, topic_id)
    ) WITHOUT ROWID;
    CREATE TABLE units (
        course TEXT NOT NULL,
        unit_id TEXT NOT NULL,
        topic_id TEXT NOT NULL,
        topic_title TEXT NOT NULL,
        topic_icon TEXT NOT NULL,
        topic_unit_order INTEGER NOT NULL,
        path_order INTEGER NOT NULL,
        title TEXT NOT NULL,
        phrase_count INTEGER NOT NULL,
        PRIMARY KEY (course, unit_id)
    ) WITHOUT ROWID;
    CREATE TABLE phrases (
        course TEXT NOT NULL,
        phrase_id TEXT NOT NULL,
        topic_id TEXT NOT NULL,
        unit_id TEXT NOT NULL,
        topic_position INTEGER NOT NULL,
        unit_position INTEGER NOT NULL,
        foreign_text TEXT NOT NULL,
        transliteration TEXT,
        english_text TEXT NOT NULL,
        context_text TEXT NOT NULL,
        PRIMARY KEY (course, phrase_id)
    ) WITHOUT ROWID;
    CREATE TABLE lemmas (
        course TEXT NOT NULL,
        topic_id TEXT NOT NULL,
        phrase_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        foreign_text TEXT NOT NULL,
        transliteration TEXT,
        english_text TEXT NOT NULL,
        PRIMARY KEY (course, phrase_id, position)
    ) WITHOUT ROWID;
    CREATE TABLE tokens (
        course TEXT NOT NULL,
        topic_id TEXT NOT NULL,
        phrase_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        foreign_text TEXT NOT NULL,
        transliteration TEXT,
        PRIMARY KEY (course, phrase_id, position)
    ) WITHOUT ROWID;

    CREATE INDEX idx_topics_course_order ON topics(course, topic_order);
    CREATE INDEX idx_units_course_path ON units(course, path_order);
    CREATE INDEX idx_units_course_topic ON units(course, topic_id, topic_unit_order);
    CREATE INDEX idx_phrases_course_topic ON phrases(course, topic_id, topic_position);
    CREATE INDEX idx_phrases_course_unit ON phrases(course, unit_id, unit_position);
    CREATE INDEX idx_lemmas_course_topic ON lemmas(course, topic_id, phrase_id, position);
    CREATE INDEX idx_tokens_course_topic ON tokens(course, topic_id, phrase_id, position);
    """)

def build_database(repo, output):
    topic_dir = repo / "LingoNative" / "Resources" / "TopicData"
    manifest_path = topic_dir / "course_manifest.json"
    if not manifest_path.exists():
        die(f"Missing manifest: {manifest_path}")

    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    block_size = max(1, int(manifest.get("blockSize", 1)))
    topic_defs = manifest.get("topics", [])
    if not topic_defs:
        die("Manifest contains no topics")

    temp = output.with_name(output.name + ".tmp")
    if temp.exists():
        temp.unlink()
    output.parent.mkdir(parents=True, exist_ok=True)

    source_hash = hashlib.sha256(manifest_bytes)
    db = sqlite3.connect(temp)
    try:
        create_schema(db)
        db.execute("BEGIN")
        seen_phrase_ids = {}
        seen_unit_ids = {}

        for course in ("french", "spanish", "arabic"):
            topic_rows = []
            topic_unit_groups = []
            course_phrase_count = 0
            course_unit_count = 0
            course_topic_count = 0
            seen_phrase_ids[course] = set()
            seen_unit_ids[course] = set()

            for topic_order, topic in enumerate(topic_defs):
                topic_id = topic["id"]
                title = topic["title"]
                icon = topic["icon"]
                resource = (topic.get("resources") or {}).get(course)
                if not resource:
                    continue

                filename = resource["file"]
                strategy = resource.get("unitStrategy", "context")
                path = find_resource(topic_dir, filename)
                raw_bytes = path.read_bytes()
                source_hash.update(course.encode())
                source_hash.update(topic_id.encode())
                source_hash.update(raw_bytes)
                raw_entries = json.loads(raw_bytes)

                buckets = OrderedDict()
                unit_titles = {}
                explicit_unit_ids = {}

                for index, raw in enumerate(raw_entries):
                    phrase_id = stable_phrase_id(topic_id, raw.get("id"), index)
                    if phrase_id in seen_phrase_ids[course]:
                        die(f"Duplicate phrase ID in {course}: {phrase_id}")
                    seen_phrase_ids[course].add(phrase_id)

                    unit_title = clean_text(raw.get("unit")) or make_unit_title(raw.get("context", ""), strategy)
                    explicit = raw.get("unitID")
                    bucket_key = f"id:{explicit}" if explicit is not None else f"title:{unit_title}"
                    if bucket_key not in buckets:
                        buckets[bucket_key] = []
                        unit_titles[bucket_key] = unit_title
                        if explicit is not None:
                            explicit_unit_ids[bucket_key] = explicit
                    buckets[bucket_key].append((index, raw, phrase_id))

                topic_units = []
                for topic_unit_order, (bucket_key, members) in enumerate(buckets.items()):
                    unit_id = stable_unit_id(course, topic_id, explicit_unit_ids.get(bucket_key), topic_unit_order)
                    if unit_id in seen_unit_ids[course]:
                        die(f"Duplicate unit ID in {course}: {unit_id}")
                    seen_unit_ids[course].add(unit_id)

                    topic_units.append({
                        "course": course,
                        "unit_id": unit_id,
                        "topic_id": topic_id,
                        "topic_title": title,
                        "topic_icon": icon,
                        "topic_unit_order": topic_unit_order,
                        "title": unit_titles[bucket_key] or "Everyday language",
                        "phrase_count": len(members),
                    })

                    for unit_position, (topic_position, raw, phrase_id) in enumerate(members):
                        db.execute("""
                            INSERT INTO phrases (
                                course, phrase_id, topic_id, unit_id,
                                topic_position, unit_position,
                                foreign_text, transliteration, english_text, context_text
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, (
                            course, phrase_id, topic_id, unit_id,
                            topic_position, unit_position,
                            raw.get("foreign", ""), raw.get("transliteration"),
                            raw.get("english", ""), raw.get("context", ""),
                        ))

                        for pos, lemma in enumerate(raw.get("lemmas") or []):
                            db.execute("""
                                INSERT INTO lemmas (
                                    course, topic_id, phrase_id, position,
                                    foreign_text, transliteration, english_text
                                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                            """, (
                                course, topic_id, phrase_id, pos,
                                lemma.get("foreign", ""), lemma.get("transliteration"), lemma.get("english", ""),
                            ))

                        for pos, token in enumerate(raw.get("tokens") or []):
                            db.execute("""
                                INSERT INTO tokens (
                                    course, topic_id, phrase_id, position,
                                    foreign_text, transliteration
                                ) VALUES (?, ?, ?, ?, ?, ?)
                            """, (
                                course, topic_id, phrase_id, pos,
                                token.get("foreign", ""), token.get("transliteration"),
                            ))

                if not topic_units:
                    continue

                topic_unit_groups.append(topic_units)
                course_topic_count += 1
                course_unit_count += len(topic_units)
                course_phrase_count += len(raw_entries)
                topic_rows.append((course, topic_id, topic_order, title, icon, len(raw_entries), len(topic_units)))

            if not topic_unit_groups:
                continue

            path_units = interleave(topic_unit_groups, block_size)
            path_order_by_id = {unit["unit_id"]: i for i, unit in enumerate(path_units)}

            db.executemany("""
                INSERT INTO topics (
                    course, topic_id, topic_order, title, icon, phrase_count, unit_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, topic_rows)

            for topic_units in topic_unit_groups:
                for unit in topic_units:
                    db.execute("""
                        INSERT INTO units (
                            course, unit_id, topic_id, topic_title, topic_icon,
                            topic_unit_order, path_order, title, phrase_count
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, (
                        course, unit["unit_id"], unit["topic_id"], unit["topic_title"], unit["topic_icon"],
                        unit["topic_unit_order"], path_order_by_id[unit["unit_id"]], unit["title"], unit["phrase_count"],
                    ))

            db.execute("""
                INSERT INTO courses (course, block_size, topic_count, unit_count, phrase_count)
                VALUES (?, ?, ?, ?, ?)
            """, (course, block_size, course_topic_count, course_unit_count, course_phrase_count))

        db.executemany(
            "INSERT INTO metadata(key, value) VALUES (?, ?)",
            [
                ("schema_version", str(SCHEMA_VERSION)),
                ("source_sha256", source_hash.hexdigest()),
                ("generator", "build_lingonative_sqlite.py"),
            ],
        )
        db.commit()
        db.execute("ANALYZE")
        db.commit()
        result = db.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            die(f"SQLite integrity_check failed: {result}")
    finally:
        db.close()

    if output.exists():
        output.unlink()
    os.replace(temp, output)
    return source_hash.hexdigest()

def verify_database(output):
    db = sqlite3.connect(f"file:{output}?mode=ro", uri=True)
    try:
        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            die("SQLite integrity_check failed after reopen")
        schema = db.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()
        if not schema or int(schema[0]) != SCHEMA_VERSION:
            die(f"Unexpected schema version: {schema}")
        rows = db.execute("SELECT course, topic_count, unit_count, phrase_count FROM courses ORDER BY course").fetchall()
        if not rows:
            die("Database has no courses")
        for course, topics, units, phrases in rows:
            actual = (
                db.execute("SELECT COUNT(*) FROM topics WHERE course=?", (course,)).fetchone()[0],
                db.execute("SELECT COUNT(*) FROM units WHERE course=?", (course,)).fetchone()[0],
                db.execute("SELECT COUNT(*) FROM phrases WHERE course=?", (course,)).fetchone()[0],
            )
            if actual != (topics, units, phrases):
                die(f"Count mismatch for {course}: declared {(topics, units, phrases)}, actual {actual}")
        return rows
    finally:
        db.close()

def main():
    parser = argparse.ArgumentParser(description="Build LingoNative.sqlite from the existing JSON corpus.")
    parser.add_argument("--repo", help="Path to LingoNative repo")
    parser.add_argument("--output", help="Optional output path")
    args = parser.parse_args()

    repo = find_repo(args.repo)
    output = Path(args.output).expanduser().resolve() if args.output else repo / "LingoNative" / "Resources" / "TopicData" / "LingoNative.sqlite"

    print(f"📚 Repo: {repo}")
    print(f"🗄️  Building: {output}")
    source_hash = build_database(repo, output)
    rows = verify_database(output)
    size_mb = output.stat().st_size / (1024 * 1024)

    print("\n✅ SQLite corpus built and verified.")
    print(f"   Size: {size_mb:.2f} MB")
    print(f"   Source SHA-256: {source_hash}")
    for course, topics, units, phrases in rows:
        print(f"   {course}: {topics:,} topics · {units:,} units · {phrases:,} phrases")
    print("\nThe JSON source files were not changed.")

if __name__ == "__main__":
    main()
