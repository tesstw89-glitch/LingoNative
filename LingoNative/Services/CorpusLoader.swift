import Foundation

enum CorpusLoaderError: LocalizedError {
    case missingResource(String)
    case noTopics(LanguageCourse)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "Could not find bundled corpus: \(name).json"
        case .noTopics(let course):
            return "No bundled topics could be loaded for \(course.title)."
        }
    }
}

private struct CourseManifest: Decodable {
    let blockSize: Int
    let topics: [TopicDefinition]
}

private struct TopicDefinition: Decodable {
    let id: String
    let title: String
    let icon: String
    let resources: [String: TopicResource]
}

private struct TopicResource: Decodable {
    let file: String
    let unitStrategy: UnitStrategy
}

private enum UnitStrategy: String, Decodable {
    case context
    case firstSentence
    case beforeEmDash
    case afterEmDash
    case beforeColon
}

private struct RawPhraseEntry: Decodable {
    let id: FlexibleID?
    let foreign: String
    let transliteration: String?
    let tokens: [PhraseToken]?
    let english: String
    let lemmas: [Lemma]?
    let context: String
    let unit: String?
}

private enum FlexibleID: Decodable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var stringValue: String {
        switch self {
        case .int(let value): return String(value)
        case .string(let value): return value
        }
    }
}

enum CorpusLoader {
    static func load(course: LanguageCourse) throws -> Corpus {
        let manifest = loadManifest() ?? fallbackManifest
        var topicUnitGroups: [[LearningUnit]] = []
        var topics: [LearningTopic] = []

        for definition in manifest.topics {
            guard let resource = definition.resources[course.rawValue],
                  let rawEntries = try? loadRawEntries(resource.file) else {
                continue
            }

            let entries = rawEntries.enumerated().map { index, raw in
                let sourceID = raw.id?.stringValue ?? String(index + 1)
                let stableID = definition.id == "opinions"
                    ? sourceID
                    : "\(definition.id):\(sourceID)"

                return PhraseEntry(
                    id: stableID,
                    topicID: definition.id,
                    topicTitle: definition.title,
                    foreign: raw.foreign,
                    transliteration: raw.transliteration,
                    tokens: raw.tokens,
                    english: raw.english,
                    lemmas: raw.lemmas ?? [],
                    context: raw.context
                )
            }

            var order: [String] = []
            var buckets: [String: [PhraseEntry]] = [:]

            for (index, entry) in entries.enumerated() {
                let raw = rawEntries[index]
                let unitTitle = raw.unit?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? makeUnitTitle(context: entry.context, strategy: resource.unitStrategy)

                if buckets[unitTitle] == nil {
                    order.append(unitTitle)
                    buckets[unitTitle] = []
                }
                buckets[unitTitle, default: []].append(entry)
            }

            let units = order.enumerated().map { index, title in
                let unitID = definition.id == "opinions"
                    ? "\(course.rawValue)-unit-\(index + 1)"
                    : "\(course.rawValue)-\(definition.id)-unit-\(index + 1)"

                return LearningUnit(
                    id: unitID,
                    title: title,
                    topicID: definition.id,
                    topicTitle: definition.title,
                    topicIcon: definition.icon,
                    phrases: buckets[title] ?? []
                )
            }

            guard !units.isEmpty else { continue }
            topicUnitGroups.append(units)
            topics.append(
                LearningTopic(
                    id: definition.id,
                    title: definition.title,
                    icon: definition.icon,
                    phraseCount: entries.count,
                    unitCount: units.count
                )
            )
        }

        guard !topicUnitGroups.isEmpty else {
            throw CorpusLoaderError.noTopics(course)
        }

        let safeBlockSize = max(1, manifest.blockSize)
        let units = interleave(topicUnitGroups, blockSize: safeBlockSize)
        let entries = units.flatMap(\.phrases)

        return Corpus(
            course: course,
            entries: entries,
            units: units,
            topics: topics,
            blockSize: safeBlockSize
        )
    }

    private static func loadManifest() -> CourseManifest? {
        let urls = [
            Bundle.main.url(forResource: "course_manifest", withExtension: "json", subdirectory: "TopicData"),
            Bundle.main.url(forResource: "course_manifest", withExtension: "json")
        ]

        for url in urls.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               let manifest = try? JSONDecoder().decode(CourseManifest.self, from: data) {
                return manifest
            }
        }
        return nil
    }

    private static func loadRawEntries(_ filename: String) throws -> [RawPhraseEntry] {
        let ns = filename as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension.isEmpty ? "json" : ns.pathExtension

        let urls = [
            Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "TopicData/LingoNative-topic-data"),
            Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "TopicData"),
            Bundle.main.url(forResource: base, withExtension: ext)
        ]

        guard let url = urls.compactMap({ $0 }).first else {
            throw CorpusLoaderError.missingResource(filename)
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([RawPhraseEntry].self, from: data)
    }

    private static func makeUnitTitle(context: String, strategy: UnitStrategy) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Everyday language" }

        let firstSentence = trimmed
            .components(separatedBy: ". ")
            .first?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            ?? trimmed

        switch strategy {
        case .context:
            return trimmed
        case .firstSentence:
            return firstSentence
        case .beforeEmDash:
            return firstSentence.components(separatedBy: " — ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? firstSentence
        case .afterEmDash:
            let pieces = firstSentence.components(separatedBy: " — ")
            return pieces.count > 1 ? pieces.dropFirst().joined(separator: " — ").trimmingCharacters(in: .whitespacesAndNewlines) : firstSentence
        case .beforeColon:
            return firstSentence.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? firstSentence
        }
    }

    private static func interleave(_ groups: [[LearningUnit]], blockSize: Int) -> [LearningUnit] {
        var cursors = Array(repeating: 0, count: groups.count)
        var output: [LearningUnit] = []

        while true {
            var addedAnything = false

            for index in groups.indices {
                let start = cursors[index]
                guard start < groups[index].count else { continue }

                let end = min(start + blockSize, groups[index].count)
                output.append(contentsOf: groups[index][start..<end])
                cursors[index] = end
                addedAnything = true
            }

            if !addedAnything { break }
        }

        return output
    }

    private static let fallbackManifest = CourseManifest(
        blockSize: 1,
        topics: [
            TopicDefinition(
                id: "opinions",
                title: "Opinions & Reactions",
                icon: "bubble.left.and.bubble.right.fill",
                resources: [
                    "french": TopicResource(file: "french_opinions.json", unitStrategy: .context),
                    "spanish": TopicResource(file: "spanish_opinions.json", unitStrategy: .context),
                    "arabic": TopicResource(file: "arabic_opinions.json", unitStrategy: .context)
                ]
            )
        ]
    )
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
