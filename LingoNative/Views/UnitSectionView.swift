import SwiftUI

struct UnitSectionView: View {
    let unit: LearningUnit
    let unitIndex: Int
    let sectionNumber: Int
    let startsTopicBlock: Bool
    let activeNodeID: String?
    let course: LanguageCourse
    let allUnits: [LearningUnit]
    let allPhrases: [PhraseEntry]
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    private let offsets: [CGFloat] = [0, 46, 72, 38, -16, -58, -76, -38]

    private var nodes: [LessonNode] { unit.nodes() }
    private var normalLessonCount: Int { nodes.filter { !$0.isReview }.count }

    private var activeNodeInUnit: LessonNode? {
        guard let activeNodeID else { return nil }
        return nodes.first { $0.id == activeNodeID }
    }

    var body: some View {
        VStack(spacing: 22) {
            if startsTopicBlock {
                topicHeader
            }

            unitBanner

            VStack(spacing: 24) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { nodeIndex, node in
                    let completed = progress.isCompleted(node.id)
                    let unlocked = isUnlocked(nodeIndex: nodeIndex)
                    let current = node.id == activeNodeID

                    Group {
                        if unlocked || completed {
                            NavigationLink {
                                QuizView(
                                    session: .similarityAwareLesson(
                                        course: course,
                                        unit: unit,
                                        node: node,
                                        allPhrases: allPhrases,
                                        exerciseTypes: settings.enabledExerciseTypes
                                    ),
                                    progress: progress,
                                    settings: settings
                                )
                            } label: {
                                LessonNodeView(
                                    number: nodeIndex + 1,
                                    completed: completed,
                                    unlocked: true,
                                    isCurrent: current,
                                    progress: progress.lessonProgress(nodeID: node.id),
                                    isLast: nodeIndex == nodes.count - 1
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            LessonNodeView(
                                number: nodeIndex + 1,
                                completed: false,
                                unlocked: false,
                                isCurrent: false,
                                progress: 0,
                                isLast: nodeIndex == nodes.count - 1
                            )
                        }
                    }
                    .id(node.id)
                    .offset(x: offsets[nodeIndex % offsets.count])
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var topicHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: unit.topicIcon)
                .font(.headline.weight(.black))
                .foregroundStyle(topicAccent)
                .frame(width: 38, height: 38)
                .background(topicAccent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("SECTION \(sectionNumber)")
                    .font(.custom("Fredoka-Regular", size: 12))
                    .tracking(1.2)
                    .foregroundStyle(Color.lingoMuted)
                Text(unit.topicTitle)
                    .font(.custom("Fredoka-Medium", size: 20))
                    .foregroundStyle(Color.lingoInk)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, sectionNumber == 1 ? 0 : 10)
    }

    private var unitBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("UNIT \(unitIndex + 1)")
                    .font(.custom("Fredoka-Bold", size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                Text(unit.title)
                    .font(.custom("Fredoka-Medium", size: 18))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(unit.phrases.count) phrases · \(normalLessonCount) lesson\(normalLessonCount == 1 ? "" : "s") + review")
                    .font(.custom("Fredoka-Light", size: 14))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer(minLength: 8)

            if let activeNodeInUnit {
                NavigationLink {
                    QuizView(
                        session: .similarityAwareLesson(
                            course: course,
                            unit: unit,
                            node: activeNodeInUnit,
                            allPhrases: allPhrases,
                            exerciseTypes: settings.enabledExerciseTypes
                        ),
                        progress: progress,
                        settings: settings
                    )
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: progress.lessonProgress(nodeID: activeNodeInUnit.id) > 0 ? "play.fill" : "arrow.right")
                            .font(.system(size: 14, weight: .regular))

                        Text(progress.lessonProgress(nodeID: activeNodeInUnit.id) > 0 ? "RESUME" : (activeNodeInUnit.isReview ? "REVIEW" : "START"))
                            .font(.custom("Fredoka-Regular", size: 10))
                    }
                    .foregroundStyle(topicAccent)
                    .frame(width: 66, height: 58)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 4)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: unit.topicIcon)
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .padding(18)
        .background(topicAccent)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var topicAccent: Color {
        switch unit.topicID {
        case "clothes": return Color.lingoPurple
        case "places": return Color.lingoOrange
        case "getting_around": return .teal
        case "opinions": return course == .french ? Color.lingoBlue : Color.lingoGreen
        default: return Color.lingoBlue
        }
    }

    private func isUnlocked(nodeIndex: Int) -> Bool {
        if unitIndex == 0 && nodeIndex == 0 { return true }

        if nodeIndex > 0 {
            let previous = nodes[nodeIndex - 1]
            return progress.isCompleted(previous.id)
        }

        guard unitIndex > 0 else { return true }
        let previousUnit = allUnits[unitIndex - 1]
        guard let lastNode = previousUnit.nodes().last else { return true }
        return progress.isCompleted(lastNode.id)
    }
}

private extension QuizSession {
    static func similarityAwareLesson(
        course: LanguageCourse,
        unit: LearningUnit,
        node: LessonNode,
        allPhrases: [PhraseEntry],
        exerciseTypes: Set<ExerciseType>
    ) -> QuizSession {
        let nodePhrases = node.isReview
            ? unit.phrases
            : SimilarityAwareLessonDealer.phrases(in: unit, for: node)

        return QuizSession(
            course: course,
            title: node.isReview ? "\(unit.title) Review" : unit.title,
            subtitle: node.isReview
                ? "\(unit.topicTitle) · Unit Review"
                : "\(unit.topicTitle) · Lesson \(node.index + 1)",
            phrasePool: nodePhrases,
            allPhrases: allPhrases,
            sessionSize: max(1, nodePhrases.count),
            exerciseTypes: exerciseTypes,
            completionNodeID: node.id
        )
    }
}

/// Deals each unit's phrases across its lessons instead of slicing the source file into
/// consecutive blocks. This keeps the unit/subheading intact while separating near-duplicate
/// wording and translation families wherever the number of lessons allows it.
private enum SimilarityAwareLessonDealer {
    private struct TextFingerprint {
        let normalized: String
        let tokens: Set<String>
        let bigrams: Set<String>
    }

    private struct PhraseFingerprint {
        let foreign: TextFingerprint
        let english: TextFingerprint
    }

    static func phrases(in unit: LearningUnit, for node: LessonNode) -> [PhraseEntry] {
        if node.isReview { return unit.phrases }
        let buckets = deal(unit.phrases, sessionSize: max(1, node.sessionSize))
        guard buckets.indices.contains(node.index) else { return [] }
        return buckets[node.index]
    }

    private static func deal(_ phrases: [PhraseEntry], sessionSize: Int) -> [[PhraseEntry]] {
        guard !phrases.isEmpty else { return [] }

        let lessonCount = max(1, Int(ceil(Double(phrases.count) / Double(sessionSize))))
        guard lessonCount > 1 else { return [phrases] }

        let baseCapacity = phrases.count / lessonCount
        let remainder = phrases.count % lessonCount
        let capacities = (0..<lessonCount).map { index in
            baseCapacity + (index < remainder ? 1 : 0)
        }

        let fingerprints = phrases.map {
            PhraseFingerprint(
                foreign: fingerprint($0.foreign),
                english: fingerprint($0.english)
            )
        }

        var buckets = Array(repeating: [PhraseEntry](), count: lessonCount)
        var bucketIndices = Array(repeating: [Int](), count: lessonCount)

        for phraseIndex in phrases.indices {
            var bestBucket: Int?
            var bestScore = Double.greatestFiniteMagnitude

            for bucketIndex in 0..<lessonCount where buckets[bucketIndex].count < capacities[bucketIndex] {
                let maxSimilarity = bucketIndices[bucketIndex]
                    .map { existingIndex in
                        phraseSimilarity(fingerprints[phraseIndex], fingerprints[existingIndex])
                    }
                    .max() ?? 0

                // Only strong resemblance should outweigh ordinary card-dealing balance.
                // This avoids treating common little words as a "duplicate family".
                let duplicatePenalty = max(0, maxSimilarity - 0.52) * 100.0
                let fillRatio = capacities[bucketIndex] > 0
                    ? Double(buckets[bucketIndex].count) / Double(capacities[bucketIndex])
                    : 1.0
                let score = duplicatePenalty + fillRatio * 3.0 + Double(bucketIndex) * 0.000_001

                if score < bestScore {
                    bestScore = score
                    bestBucket = bucketIndex
                }
            }

            if let bestBucket {
                buckets[bestBucket].append(phrases[phraseIndex])
                bucketIndices[bestBucket].append(phraseIndex)
            }
        }

        return buckets
    }

    private static func phraseSimilarity(_ lhs: PhraseFingerprint, _ rhs: PhraseFingerprint) -> Double {
        max(
            textSimilarity(lhs.foreign, rhs.foreign),
            textSimilarity(lhs.english, rhs.english)
        )
    }

    private static func textSimilarity(_ lhs: TextFingerprint, _ rhs: TextFingerprint) -> Double {
        guard !lhs.normalized.isEmpty, !rhs.normalized.isEmpty else { return 0 }
        if lhs.normalized == rhs.normalized { return 1 }

        let tokenIntersection = lhs.tokens.intersection(rhs.tokens).count
        let minimumTokenCount = min(lhs.tokens.count, rhs.tokens.count)
        let tokenUnion = lhs.tokens.union(rhs.tokens).count

        let containment = minimumTokenCount > 0
            ? Double(tokenIntersection) / Double(minimumTokenCount)
            : 0
        let jaccard = tokenUnion > 0
            ? Double(tokenIntersection) / Double(tokenUnion)
            : 0
        let tokenScore = containment * 0.75 + jaccard * 0.25

        let bigramIntersection = lhs.bigrams.intersection(rhs.bigrams).count
        let bigramDenominator = lhs.bigrams.count + rhs.bigrams.count
        let dice = bigramDenominator > 0
            ? (2.0 * Double(bigramIntersection)) / Double(bigramDenominator)
            : 0

        return max(tokenScore, dice * 0.9)
    }

    private static func fingerprint(_ text: String) -> TextFingerprint {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let words = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.count > 1 || trimmed.allSatisfy(\.isNumber)
            }
        let normalized = words.joined(separator: " ")
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        let characters = Array(compact)

        var bigrams = Set<String>()
        if characters.count >= 2 {
            for index in 0..<(characters.count - 1) {
                bigrams.insert(String(characters[index...index + 1]))
            }
        } else if !compact.isEmpty {
            bigrams.insert(compact)
        }

        return TextFingerprint(
            normalized: normalized,
            tokens: Set(words),
            bigrams: bigrams
        )
    }
}