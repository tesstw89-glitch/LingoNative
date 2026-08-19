import Foundation

enum CorpusLoaderError: LocalizedError {
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "Could not find bundled corpus: \(name).json"
        }
    }
}

enum CorpusLoader {
    static func load(course: LanguageCourse) throws -> Corpus {
        guard let url = Bundle.main.url(forResource: course.resourceName, withExtension: "json") else {
            throw CorpusLoaderError.missingResource(course.resourceName)
        }

        let data = try Data(contentsOf: url)
        let entries = try JSONDecoder().decode([PhraseEntry].self, from: data)

        var order: [String] = []
        var buckets: [String: [PhraseEntry]] = [:]

        for entry in entries {
            let title = entry.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Everyday reactions"
                : entry.context

            if buckets[title] == nil {
                order.append(title)
                buckets[title] = []
            }
            buckets[title, default: []].append(entry)
        }

        let units = order.enumerated().map { index, title in
            LearningUnit(
                id: "\(course.rawValue)-unit-\(index + 1)",
                title: title,
                phrases: buckets[title] ?? []
            )
        }

        return Corpus(course: course, entries: entries, units: units)
    }
}
