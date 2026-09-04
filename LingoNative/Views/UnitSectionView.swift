import SwiftUI
import UIKit

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

    @Environment(\.openURL) private var openURL

    @State private var isPreparingChatGPT = false
    @State private var showPromptError = false
    @State private var promptErrorMessage = ""

    private let offsets: [CGFloat] = [0, 46, 72, 38, -16, -58, -76, -38]

    private var nodes: [LessonNode] { unit.nodes() }
    private var normalNodes: [LessonNode] { nodes.filter { !$0.isReview } }
    private var reviewNode: LessonNode? { nodes.first { $0.isReview } }
    private var normalLessonCount: Int { normalNodes.count }

    private var reviewUnlocked: Bool {
        !normalNodes.isEmpty
            && normalNodes.allSatisfy { progress.isCompleted($0.id) }
    }

    private var reviewAnchorIndex: Int? {
        normalNodes.indices.max { lhs, rhs in
            offsets[lhs % offsets.count]
                < offsets[rhs % offsets.count]
        }
    }

    private var activeNodeInUnit: LessonNode? {
        guard let activeNodeID else { return nil }
        return normalNodes.first { $0.id == activeNodeID }
    }

    var body: some View {
        VStack(spacing: 22) {
            if startsTopicBlock {
                topicHeader
            }

            unitBanner

            VStack(spacing: 24) {
                ForEach(Array(normalNodes.enumerated()), id: \.element.id) { nodeIndex, node in
                    let completed = progress.isCompleted(node.id)
                    let unlocked = isNormalLessonUnlocked(nodeIndex: nodeIndex)
                    let current = node.id == activeNodeID

                    Group {
                        if unlocked || completed {
                            NavigationLink {
                                TopicLessonLoaderView(
                                    course: course,
                                    topicID: unit.topicID,
                                    unitID: unit.id,
                                    nodeID: node.id,
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
                                    isLast: nodeIndex == normalNodes.count - 1
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
                                isLast: nodeIndex == normalNodes.count - 1
                            )
                        }
                    }
                    .overlay {
                        if let reviewAnchorIndex,
                           nodeIndex == reviewAnchorIndex,
                           let reviewNode {
                            sideReviewButton(reviewNode)
                                .offset(x: -110)
                                .zIndex(20)
                        }
                    }
                    .id(node.id)
                    .offset(x: offsets[nodeIndex % offsets.count])
                }
            }
            .padding(.vertical, 4)
        }
        .alert("Couldn’t start ChatGPT practice", isPresented: $showPromptError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(promptErrorMessage)
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

            Spacer(minLength: 8)

            if ConversationPromptStore.supports(course: course, topicID: unit.topicID) {
                Button(action: startChatGPTPractice) {
                    VStack(spacing: 2) {
                        HStack(spacing: 5) {
                            if isPreparingChatGPT {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(topicAccent)
                            } else {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 12, weight: .bold))
                            }

                            Text(isPreparingChatGPT ? "PREPARING" : "PRACTISE")
                                .font(.custom("Fredoka-SemiBold", size: 11))
                                .tracking(0.4)
                        }

                        Text("with ChatGPT")
                            .font(.custom("Fredoka-Regular", size: 10))
                    }
                    .foregroundStyle(topicAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(topicAccent.opacity(0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(topicAccent.opacity(0.24), lineWidth: 1.5)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPreparingChatGPT)
                .accessibilityLabel("Practise \(unit.topicTitle) with ChatGPT")
                .accessibilityHint("Copies a conversation prompt and opens ChatGPT")
            }
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
                Text("\(unit.phraseCount) phrases · \(normalLessonCount) lesson\(normalLessonCount == 1 ? "" : "s") + review")
                    .font(.custom("Fredoka-Light", size: 14))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer(minLength: 8)

            if let activeNodeInUnit {
                NavigationLink {
                    TopicLessonLoaderView(
                        course: course,
                        topicID: unit.topicID,
                        unitID: unit.id,
                        nodeID: activeNodeInUnit.id,
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
        case "food":
            return Color.lingoBlue
        case "requests_favours":
            return Color.lingoPurple
        case "shopping_errands":
            return Color.lingoOrange
        case "work":
            return .teal
        case "plans":
            return Color.lingoGreen
        case "storytelling":
            return Color.lingoPurple
        case "health_body":
            return Color.lingoOrange
        case "tiny_social_interactions":
            return .teal
        case "parenting":
            return Color.lingoGreen
        case "me":
            return Color.lingoPurple
        case "technology":
            return .teal
        case "household_life":
            return Color.lingoOrange
        case "family":
            return Color.lingoGreen
        case "asking_about_other_people":
            return Color.lingoGreen
        case "culture_entertainment":
            return Color.lingoPurple
        case "feelings":
            return Color.lingoOrange
        case "friends_social_life":
            return .teal
        case "hobbies_interests":
            return Color.lingoGreen
        case "money":
            return Color.lingoOrange
        case "offers_suggestions":
            return Color.lingoPurple
        case "problems":
            return .teal
        case "weather":
            return Color.lingoGreen
        default:
            return Color.lingoBlue

        }
    }

    private func startChatGPTPractice() {
        guard !isPreparingChatGPT else { return }
        isPreparingChatGPT = true

        Task {
            do {
                let prompt = try await ConversationPromptStore.shared.randomPrompt(
                    course: course,
                    topicID: unit.topicID
                )

                await MainActor.run {
                    UIPasteboard.general.string = prompt
                    isPreparingChatGPT = false

                    guard let chatGPTURL = URL(string: "https://chatgpt.com/") else {
                        showPromptFailure("ChatGPT couldn’t be opened.")
                        return
                    }

                    openURL(chatGPTURL) { accepted in
                        if !accepted {
                            DispatchQueue.main.async {
                                showPromptFailure("The prompt was copied, but ChatGPT couldn’t be opened. You can open ChatGPT manually and paste it.")
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isPreparingChatGPT = false
                    showPromptFailure(error.localizedDescription)
                }
            }
        }
    }

    private func showPromptFailure(_ message: String) {
        promptErrorMessage = message
        showPromptError = true
    }

    @ViewBuilder
    private func sideReviewButton(_ node: LessonNode) -> some View {
        let completed = progress.isCompleted(node.id)
        let available = reviewUnlocked || completed

        Group {
            if available {
                NavigationLink {
                    TopicLessonLoaderView(
                        course: course,
                        topicID: unit.topicID,
                        unitID: unit.id,
                        nodeID: node.id,
                        progress: progress,
                        settings: settings
                    )
                } label: {
                    reviewAsset(completed: completed, available: true)
                }
                .buttonStyle(.plain)
            } else {
                reviewAsset(completed: false, available: false)
            }
        }
        .saturation(available ? 1 : 0)
        .accessibilityLabel(
            available
                ? "Review this unit"
                : "Finish the unit to unlock review"
        )
    }

    private func reviewAsset(
        completed: Bool,
        available: Bool
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Image("review")
                .resizable()
                .scaledToFit()
                .frame(width: 86, height: 86)

            if completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.lingoGreen)
                    .background(
                        Circle()
                            .fill(Color.white)
                    )
            }
        }
        .frame(width: 94, height: 94)
        .contentShape(Rectangle())
    }

    private func isNormalLessonUnlocked(nodeIndex: Int) -> Bool {
        if unitIndex == 0 && nodeIndex == 0 {
            return true
        }

        if nodeIndex > 0 {
            return progress.isCompleted(
                normalNodes[nodeIndex - 1].id
            )
        }

        guard unitIndex > 0 else {
            return true
        }

        let previousUnit = allUnits[unitIndex - 1]
        let previousNormalNodes = previousUnit.nodes().filter { !$0.isReview }

        guard let lastNormalNode = previousNormalNodes.last else {
            return true
        }

        return progress.isCompleted(lastNormalNode.id)
    }
}

private struct TopicLessonLoaderView: View {
    let course: LanguageCourse
    let topicID: String
    let unitID: String
    let nodeID: String
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore
    @State private var topicCorpus: Corpus?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let topicCorpus,
               let unit = topicCorpus.units.first(where: { $0.id == unitID }),
               let node = unit.nodes().first(where: { $0.id == nodeID }) {
                QuizView(
                    session: .similarityAwareLesson(
                        course: course,
                        unit: unit,
                        node: node,
                        allPhrases: topicCorpus.entries,
                        exerciseTypes: settings.effectiveExerciseTypes
                    ),
                    progress: progress,
                    settings: settings
                )
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn’t open this topic",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView("Opening topic…")
            }
        }
        .task {
            guard topicCorpus == nil else { return }
            TopicCorpusCache.shared.load(course: course, topicID: topicID) { result in
                switch result {
                case .success(let loaded): topicCorpus = loaded
                case .failure(let error): loadError = error.localizedDescription
                }
            }
        }
    }
}

@MainActor
final class TopicCorpusCache {
    static let shared = TopicCorpusCache()
    private var currentCourse: LanguageCourse?
    private var currentTopicID: String?
    private var currentCorpus: Corpus?
    private var requestID: UUID?

    func load(
        course: LanguageCourse,
        topicID: String,
        completion: @escaping (Result<Corpus, Error>) -> Void
    ) {
        if currentCourse == course,
           currentTopicID == topicID,
           let currentCorpus {
            completion(.success(currentCorpus))
            return
        }

        currentCourse = nil
        currentTopicID = nil
        currentCorpus = nil

        let id = UUID()
        requestID = id

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try CorpusLoader.loadTopic(course: course, topicID: topicID)
            }
            DispatchQueue.main.async {
                if self.requestID == id,
                   case .success(let loaded) = result {
                    self.currentCourse = course
                    self.currentTopicID = topicID
                    self.currentCorpus = loaded
                }
                completion(result)
            }
        }
    }

    func removeAll() {
        requestID = nil
        currentCourse = nil
        currentTopicID = nil
        currentCorpus = nil
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

        let resolvedExerciseTypes: Set<ExerciseType> =
            node.isReview
                ? [.typing]
                : exerciseTypes

        return QuizSession(
            course: course,
            title: node.isReview ? "\(unit.title) Review" : unit.title,
            subtitle: node.isReview
                ? "\(unit.topicTitle) · Write every phrase"
                : "\(unit.topicTitle) · Lesson \(node.index + 1)",
            phrasePool: nodePhrases,
            allPhrases: allPhrases,
            sessionSize: max(1, nodePhrases.count),
            exerciseTypes: resolvedExerciseTypes,
            completionNodeID: node.id
        )
    }
}

/// Loads the standalone conversation prompts that are bundled inside TopicData.
/// A tap selects a random prompt from the learner's current language + topic.
private actor ConversationPromptStore {
    static let shared = ConversationPromptStore()

    private var cache: [LanguageCourse: [String: [String]]] = [:]
    private var lastPromptIndex: [String: Int] = [:]

    static func supports(course: LanguageCourse, topicID: String) -> Bool {
        guard course == .french || course == .spanish else { return false }
        return supportedTopicIDs.contains(topicID)
    }

    func randomPrompt(course: LanguageCourse, topicID: String) throws -> String {
        guard Self.supports(course: course, topicID: topicID) else {
            throw ConversationPromptError.unsupported
        }

        let bank: [String: [String]]
        if let cached = cache[course] {
            bank = cached
        } else {
            let loaded = try loadBank(for: course)
            cache[course] = loaded
            bank = loaded
        }

        guard let prompts = bank[topicID], !prompts.isEmpty else {
            throw ConversationPromptError.noPrompts(topicID)
        }

        let historyKey = "\(course.rawValue):\(topicID)"
        let previous = lastPromptIndex[historyKey]

        let availableIndices: [Int]
        if prompts.count > 1, let previous {
            availableIndices = prompts.indices.filter { $0 != previous }
        } else {
            availableIndices = Array(prompts.indices)
        }

        guard let selectedIndex = availableIndices.randomElement() else {
            throw ConversationPromptError.noPrompts(topicID)
        }

        lastPromptIndex[historyKey] = selectedIndex
        return prompts[selectedIndex]
    }

    private func loadBank(for course: LanguageCourse) throws -> [String: [String]] {
        let resourceName: String
        switch course {
        case .french:
            resourceName = "LingoNative_French_All_Practice_Prompts"
        case .spanish:
            resourceName = "LingoNative_Spanish_All_Practice_Prompts"
        case .arabic:
            throw ConversationPromptError.unsupported
        }

        let possibleURLs = [
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "txt",
                subdirectory: "TopicData/ConversationPrompts"
            ),
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "txt",
                subdirectory: "ConversationPrompts"
            ),
            Bundle.main.url(forResource: resourceName, withExtension: "txt")
        ]

        guard let url = possibleURLs.compactMap({ $0 }).first else {
            throw ConversationPromptError.missingResource(course)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = parse(text)

        guard !parsed.isEmpty else {
            throw ConversationPromptError.invalidResource(course)
        }

        return parsed
    }

    private func parse(_ text: String) -> [String: [String]] {
        let lines = text.components(separatedBy: .newlines)
        var output: [String: [String]] = [:]
        var currentTopicID: String?
        var collectingPrompt = false
        var promptLines: [String] = []

        func flushPrompt() {
            guard collectingPrompt, let currentTopicID else {
                promptLines.removeAll(keepingCapacity: true)
                return
            }

            let prompt = promptLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !prompt.isEmpty {
                output[currentTopicID, default: []].append(prompt)
            }

            promptLines.removeAll(keepingCapacity: true)
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("### TOPIC:") {
                flushPrompt()
                collectingPrompt = false

                let marker = String(trimmed.dropFirst("### TOPIC:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentTopicID = Self.topicID(forMarker: marker)
                continue
            }

            guard currentTopicID != nil else { continue }

            if trimmed.hasPrefix("PROMPT "), trimmed.contains(" — ") {
                flushPrompt()
                collectingPrompt = true
                continue
            }

            guard collectingPrompt else { continue }

            if Self.isDivider(trimmed) {
                continue
            }

            promptLines.append(rawLine)
        }

        flushPrompt()
        return output
    }

    private static func topicID(forMarker marker: String) -> String? {
        switch marker.uppercased() {
        case "OPINIONS": return "opinions"
        case "CLOTHES & APPEARANCE": return "clothes"
        case "PLACES": return "places"
        case "GETTING AROUND": return "getting_around"
        case "FOOD & MEALS": return "food"
        default: return nil
        }
    }

    private static func isDivider(_ line: String) -> Bool {
        guard line.count >= 10 else { return false }
        return line.allSatisfy { character in
            character == "=" || character == "#"
        }
    }

    private static let supportedTopicIDs: Set<String> = [
        "opinions",
        "clothes",
        "places",
        "getting_around",
        "food"
    ]
}

private enum ConversationPromptError: LocalizedError {
    case unsupported
    case missingResource(LanguageCourse)
    case invalidResource(LanguageCourse)
    case noPrompts(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "ChatGPT conversation practice isn’t available for this topic yet."
        case .missingResource(let course):
            return "The \(course.title) conversation prompt bank isn’t bundled in this build yet."
        case .invalidResource(let course):
            return "The \(course.title) conversation prompt bank couldn’t be read."
        case .noPrompts:
            return "No conversation prompts were found for this topic."
        }
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
