import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

enum CorpusDatabaseError: LocalizedError {
    case missingDatabase
    case openFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)
    case unsupportedSchema(String)
    case missingCourse(LanguageCourse)
    case missingTopic(String)

    var errorDescription: String? {
        switch self {
        case .missingDatabase:
            return "The bundled SQLite corpus could not be found."
        case .openFailed(let message):
            return "The SQLite corpus could not be opened: \(message)"
        case .prepareFailed(let message):
            return "A corpus query could not be prepared: \(message)"
        case .bindFailed(let message):
            return "A corpus query parameter could not be bound: \(message)"
        case .stepFailed(let message):
            return "A corpus query failed: \(message)"
        case .unsupportedSchema(let value):
            return "Unsupported SQLite corpus schema: \(value)"
        case .missingCourse(let course):
            return "No SQLite course data was found for \(course.title)."
        case .missingTopic(let topicID):
            return "No SQLite topic data was found for \(topicID)."
        }
    }
}

final class CorpusDatabase {
    static let shared = CorpusDatabase()
    private static let expectedSchemaVersion = "1"

    private init() {}

    var isAvailable: Bool {
        databaseURL != nil
    }

    func loadCourseIndex(course: LanguageCourse) throws -> Corpus {
        try withDatabase { db in
            let blockSize = try courseBlockSize(db: db, course: course)
            let topics = try loadTopics(db: db, course: course)
            let unitRows = try loadUnitRows(db: db, course: course, topicID: nil)

            guard !topics.isEmpty, !unitRows.isEmpty else {
                throw CorpusDatabaseError.missingCourse(course)
            }

            let units = unitRows.map { row in
                LearningUnit(
                    id: row.id,
                    title: row.title,
                    topicID: row.topicID,
                    topicTitle: row.topicTitle,
                    topicIcon: row.topicIcon,
                    phrases: [],
                    phraseCount: row.phraseCount
                )
            }

            return Corpus(
                course: course,
                entries: [],
                units: units,
                topics: topics,
                blockSize: blockSize
            )
        }
    }

    func loadTopic(
        course: LanguageCourse,
        topicID: String
    ) throws -> Corpus {
        try withDatabase { db in
            let blockSize = try courseBlockSize(db: db, course: course)
            let topics = try loadTopics(db: db, course: course)
            guard let topic = topics.first(where: { $0.id == topicID }) else {
                throw CorpusDatabaseError.missingTopic(topicID)
            }

            let unitRows = try loadUnitRows(
                db: db,
                course: course,
                topicID: topicID
            )
            let bundle = try loadPhraseBundle(
                db: db,
                course: course,
                topicID: topicID,
                topicTitles: [topicID: topic.title]
            )

            let units = unitRows.map { row in
                LearningUnit(
                    id: row.id,
                    title: row.title,
                    topicID: row.topicID,
                    topicTitle: row.topicTitle,
                    topicIcon: row.topicIcon,
                    phrases: (bundle.phraseIDsByUnit[row.id] ?? []).compactMap {
                        bundle.entriesByID[$0]
                    }
                )
            }

            return Corpus(
                course: course,
                entries: units.flatMap(\.phrases),
                units: units,
                topics: [topic],
                blockSize: blockSize
            )
        }
    }

    func loadWholeCourse(course: LanguageCourse) throws -> Corpus {
        try withDatabase { db in
            let blockSize = try courseBlockSize(db: db, course: course)
            let topics = try loadTopics(db: db, course: course)
            let unitRows = try loadUnitRows(db: db, course: course, topicID: nil)

            guard !topics.isEmpty, !unitRows.isEmpty else {
                throw CorpusDatabaseError.missingCourse(course)
            }

            let topicTitles = Dictionary(
                uniqueKeysWithValues: topics.map { ($0.id, $0.title) }
            )
            let bundle = try loadPhraseBundle(
                db: db,
                course: course,
                topicID: nil,
                topicTitles: topicTitles
            )

            let units = unitRows.map { row in
                LearningUnit(
                    id: row.id,
                    title: row.title,
                    topicID: row.topicID,
                    topicTitle: row.topicTitle,
                    topicIcon: row.topicIcon,
                    phrases: (bundle.phraseIDsByUnit[row.id] ?? []).compactMap {
                        bundle.entriesByID[$0]
                    }
                )
            }

            return Corpus(
                course: course,
                entries: units.flatMap(\.phrases),
                units: units,
                topics: topics,
                blockSize: blockSize
            )
        }
    }

    func phraseCount(course: LanguageCourse) throws -> Int {
        try withDatabase { db in
            let rows: [Int] = try query(
                db: db,
                sql: "SELECT phrase_count FROM courses WHERE course = ? LIMIT 1",
                binds: [course.rawValue]
            ) { statement in
                Int(sqlite3_column_int64(statement, 0))
            }
            guard let value = rows.first else {
                throw CorpusDatabaseError.missingCourse(course)
            }
            return value
        }
    }

    private var databaseURL: URL? {
        let urls = [
            Bundle.main.url(
                forResource: "LingoNative",
                withExtension: "sqlite",
                subdirectory: "TopicData"
            ),
            Bundle.main.url(
                forResource: "LingoNative",
                withExtension: "sqlite"
            )
        ]
        return urls.compactMap { $0 }.first
    }

    private func withDatabase<T>(
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let url = databaseURL else {
            throw CorpusDatabaseError.missingDatabase
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(
            url.path,
            &database,
            flags,
            nil
        )

        guard result == SQLITE_OK, let database else {
            let message = errorMessage(database)
            if let database {
                sqlite3_close(database)
            }
            throw CorpusDatabaseError.openFailed(message)
        }

        defer {
            sqlite3_close(database)
        }

        sqlite3_busy_timeout(database, 1_500)
        try validateSchema(database)
        return try body(database)
    }

    private func validateSchema(_ db: OpaquePointer) throws {
        let values: [String] = try query(
            db: db,
            sql: "SELECT value FROM metadata WHERE key = 'schema_version' LIMIT 1",
            binds: []
        ) { statement in
            text(statement, 0)
        }

        guard let value = values.first,
              value == Self.expectedSchemaVersion else {
            throw CorpusDatabaseError.unsupportedSchema(
                values.first ?? "missing"
            )
        }
    }

    private struct UnitRow {
        let id: String
        let title: String
        let topicID: String
        let topicTitle: String
        let topicIcon: String
        let phraseCount: Int
    }

    private struct BarePhrase {
        let id: String
        let topicID: String
        let unitID: String
        let foreign: String
        let transliteration: String?
        let english: String
        let context: String
    }

    private struct PhraseBundle {
        let entriesByID: [String: PhraseEntry]
        let phraseIDsByUnit: [String: [String]]
    }

    private func courseBlockSize(
        db: OpaquePointer,
        course: LanguageCourse
    ) throws -> Int {
        let values: [Int] = try query(
            db: db,
            sql: "SELECT block_size FROM courses WHERE course = ? LIMIT 1",
            binds: [course.rawValue]
        ) { statement in
            Int(sqlite3_column_int(statement, 0))
        }

        guard let value = values.first else {
            throw CorpusDatabaseError.missingCourse(course)
        }
        return max(1, value)
    }

    private func loadTopics(
        db: OpaquePointer,
        course: LanguageCourse
    ) throws -> [LearningTopic] {
        try query(
            db: db,
            sql: """
                SELECT topic_id, title, icon, phrase_count, unit_count
                FROM topics
                WHERE course = ?
                ORDER BY topic_order
                """,
            binds: [course.rawValue]
        ) { statement in
            LearningTopic(
                id: text(statement, 0),
                title: text(statement, 1),
                icon: text(statement, 2),
                phraseCount: Int(sqlite3_column_int64(statement, 3)),
                unitCount: Int(sqlite3_column_int64(statement, 4))
            )
        }
    }

    private func loadUnitRows(
        db: OpaquePointer,
        course: LanguageCourse,
        topicID: String?
    ) throws -> [UnitRow] {
        let sql: String
        let binds: [String]

        if let topicID {
            sql = """
                SELECT unit_id, title, topic_id, topic_title, topic_icon, phrase_count
                FROM units
                WHERE course = ? AND topic_id = ?
                ORDER BY topic_unit_order
                """
            binds = [course.rawValue, topicID]
        } else {
            sql = """
                SELECT unit_id, title, topic_id, topic_title, topic_icon, phrase_count
                FROM units
                WHERE course = ?
                ORDER BY path_order
                """
            binds = [course.rawValue]
        }

        return try query(
            db: db,
            sql: sql,
            binds: binds
        ) { statement in
            UnitRow(
                id: text(statement, 0),
                title: text(statement, 1),
                topicID: text(statement, 2),
                topicTitle: text(statement, 3),
                topicIcon: text(statement, 4),
                phraseCount: Int(sqlite3_column_int64(statement, 5))
            )
        }
    }

    private func loadPhraseBundle(
        db: OpaquePointer,
        course: LanguageCourse,
        topicID: String?,
        topicTitles: [String: String]
    ) throws -> PhraseBundle {
        let phraseSQL: String
        let lemmaSQL: String
        let tokenSQL: String
        let binds: [String]

        if let topicID {
            phraseSQL = """
                SELECT phrase_id, topic_id, unit_id, foreign_text,
                       transliteration, english_text, context_text
                FROM phrases
                WHERE course = ? AND topic_id = ?
                ORDER BY unit_id, unit_position
                """
            lemmaSQL = """
                SELECT phrase_id, foreign_text, transliteration, english_text
                FROM lemmas
                WHERE course = ? AND topic_id = ?
                ORDER BY phrase_id, position
                """
            tokenSQL = """
                SELECT phrase_id, foreign_text, transliteration
                FROM tokens
                WHERE course = ? AND topic_id = ?
                ORDER BY phrase_id, position
                """
            binds = [course.rawValue, topicID]
        } else {
            phraseSQL = """
                SELECT phrase_id, topic_id, unit_id, foreign_text,
                       transliteration, english_text, context_text
                FROM phrases
                WHERE course = ?
                ORDER BY unit_id, unit_position
                """
            lemmaSQL = """
                SELECT phrase_id, foreign_text, transliteration, english_text
                FROM lemmas
                WHERE course = ?
                ORDER BY phrase_id, position
                """
            tokenSQL = """
                SELECT phrase_id, foreign_text, transliteration
                FROM tokens
                WHERE course = ?
                ORDER BY phrase_id, position
                """
            binds = [course.rawValue]
        }

        let barePhrases: [BarePhrase] = try query(
            db: db,
            sql: phraseSQL,
            binds: binds
        ) { statement in
            BarePhrase(
                id: text(statement, 0),
                topicID: text(statement, 1),
                unitID: text(statement, 2),
                foreign: text(statement, 3),
                transliteration: optionalText(statement, 4),
                english: text(statement, 5),
                context: text(statement, 6)
            )
        }

        let lemmaPairs: [(String, Lemma)] = try query(
            db: db,
            sql: lemmaSQL,
            binds: binds
        ) { statement in
            (
                text(statement, 0),
                Lemma(
                    foreign: text(statement, 1),
                    transliteration: optionalText(statement, 2),
                    english: text(statement, 3)
                )
            )
        }

        let tokenPairs: [(String, PhraseToken)] = try query(
            db: db,
            sql: tokenSQL,
            binds: binds
        ) { statement in
            (
                text(statement, 0),
                PhraseToken(
                    foreign: text(statement, 1),
                    transliteration: optionalText(statement, 2)
                )
            )
        }

        var lemmasByPhrase: [String: [Lemma]] = [:]
        for (phraseID, lemma) in lemmaPairs {
            lemmasByPhrase[phraseID, default: []].append(lemma)
        }

        var tokensByPhrase: [String: [PhraseToken]] = [:]
        for (phraseID, token) in tokenPairs {
            tokensByPhrase[phraseID, default: []].append(token)
        }

        var entriesByID: [String: PhraseEntry] = [:]
        var phraseIDsByUnit: [String: [String]] = [:]

        for row in barePhrases {
            let entry = PhraseEntry(
                id: row.id,
                topicID: row.topicID,
                topicTitle: topicTitles[row.topicID] ?? "",
                foreign: row.foreign,
                transliteration: row.transliteration,
                tokens: tokensByPhrase[row.id]?.isEmpty == false
                    ? tokensByPhrase[row.id]
                    : nil,
                english: row.english,
                lemmas: lemmasByPhrase[row.id] ?? [],
                context: row.context
            )
            entriesByID[row.id] = entry
            phraseIDsByUnit[row.unitID, default: []].append(row.id)
        }

        return PhraseBundle(
            entriesByID: entriesByID,
            phraseIDsByUnit: phraseIDsByUnit
        )
    }

    private func query<T>(
        db: OpaquePointer,
        sql: String,
        binds: [String],
        row: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            db,
            sql,
            -1,
            &statement,
            nil
        )

        guard prepareResult == SQLITE_OK,
              let statement else {
            throw CorpusDatabaseError.prepareFailed(
                errorMessage(db)
            )
        }

        defer {
            sqlite3_finalize(statement)
        }

        for (offset, value) in binds.enumerated() {
            let bindResult = value.withCString { pointer in
                sqlite3_bind_text(
                    statement,
                    Int32(offset + 1),
                    pointer,
                    -1,
                    sqliteTransient
                )
            }
            guard bindResult == SQLITE_OK else {
                throw CorpusDatabaseError.bindFailed(
                    errorMessage(db)
                )
            }
        }

        var output: [T] = []

        while true {
            let step = sqlite3_step(statement)
            switch step {
            case SQLITE_ROW:
                output.append(try row(statement))
            case SQLITE_DONE:
                return output
            default:
                throw CorpusDatabaseError.stepFailed(
                    errorMessage(db)
                )
            }
        }
    }

    private func text(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String {
        guard let pointer = sqlite3_column_text(
            statement,
            column
        ) else {
            return ""
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(
            decoding: UnsafeBufferPointer(
                start: pointer,
                count: count
            ),
            as: UTF8.self
        )
    }

    private func optionalText(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return text(statement, column)
    }

    private func errorMessage(_ db: OpaquePointer?) -> String {
        guard let db,
              let pointer = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }
        return String(cString: pointer)
    }
}
