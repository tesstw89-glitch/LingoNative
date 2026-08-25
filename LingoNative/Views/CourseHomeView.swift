import SwiftUI
import UIKit

struct CourseHomeView: View {
    let course: LanguageCourse
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    @Environment(\.dismiss) private var dismiss

    @State private var corpus: Corpus?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let corpus {
                TabView {
                    LearnPathView(corpus: corpus, progress: progress, settings: settings)
                        .tabItem { Label("Learn", systemImage: "house.fill") }

                    PracticeHubView(corpus: corpus, progress: progress, settings: settings)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if RandomConversationPromptStore.supports(course: corpus.course) {
                                RandomChatGPTPracticeButton(corpus: corpus)
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 4)
                            }
                        }
                        .tabItem { Label("Practice", systemImage: "dumbbell.fill") }

                    BrowseView(corpus: corpus, progress: progress, settings: settings)
                        .tabItem { Label("Browse", systemImage: "books.vertical.fill") }

                    StatsView(corpus: corpus, progress: progress, settings: settings)
                        .tabItem { Label("Stats", systemImage: "chart.bar.fill") }

                    SettingsView(course: course, progress: progress, settings: settings)
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                }
                .tint(course == .french ? Color.lingoBlue : Color.lingoGreen)
                .environment(\.openURL, OpenURLAction { url in
                    if ChatGPTOpener.handles(url) {
                        ChatGPTOpener.open()
                        return .handled
                    }
                    return .systemAction
                })

            } else if let loadError {
                ContentUnavailableView(
                    "Couldn’t load the course",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )

            } else {
                ProgressView("Building your course…")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)

        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .medium))

                        Text("Back")
                            .font(.custom("Fredoka-Regular", size: 18))
                    }
                }
            }
        }

        .task {
            guard corpus == nil else { return }
            do {
                corpus = try CorpusLoader.load(course: course)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

@MainActor
private enum ChatGPTOpener {
    static func handles(_ url: URL) -> Bool {
        url.host?.lowercased() == "chatgpt.com"
    }

    static func open() {
        guard let appURL = URL(string: "chatgpt://"),
              let webURL = URL(string: "https://chatgpt.com/") else {
            return
        }

        UIApplication.shared.open(appURL, options: [:]) { opened in
            if !opened {
                UIApplication.shared.open(webURL)
            }
        }
    }
}

private struct RandomChatGPTPracticeButton: View {
    let corpus: Corpus

    @State private var isPreparing = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        Button(action: startPractice) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.62, green: 0.72, blue: 1.00),
                                    Color(red: 0.82, green: 0.89, blue: 1.00),
                                    Color.white
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 68, height: 68)
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.48), lineWidth: 1)
                        }
                        .shadow(color: Color(red: 0.66, green: 0.76, blue: 1.00).opacity(0.42), radius: 16)
                        .shadow(color: .white.opacity(0.22), radius: 5)

                    if isPreparing {
                        ProgressView()
                            .tint(.black.opacity(0.62))
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.black.opacity(0.48))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(isPreparing ? "CHOOSING A TOPIC…" : "RANDOM CONVERSATION")
                        .font(.custom("Fredoka-SemiBold", size: 14))
                        .tracking(0.7)
                        .foregroundStyle(.white)

                    Text("Practise with ChatGPT")
                        .font(.custom("Fredoka-Medium", size: 18))
                        .foregroundStyle(.white)

                    Text("Balanced across topics")
                        .font(.custom("Fredoka-Regular", size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .accessibilityLabel("Start a random ChatGPT conversation")
        .accessibilityHint("Selects a topic with equal probability, copies a conversation prompt, and opens ChatGPT")
        .alert("Couldn’t start random conversation", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func startPractice() {
        guard !isPreparing else { return }
        isPreparing = true

        let topicIDs = corpus.topics.map(\.id)

        Task {
            do {
                let prompt = try await RandomConversationPromptStore.shared.randomPrompt(
                    course: corpus.course,
                    topicIDs: topicIDs
                )

                await MainActor.run {
                    UIPasteboard.general.string = prompt
                    isPreparing = false
                    ChatGPTOpener.open()
                }
            } catch {
                await MainActor.run {
                    isPreparing = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

private actor RandomConversationPromptStore {
    static let shared = RandomConversationPromptStore()

    private var cache: [LanguageCourse: [String: [String]]] = [:]
    private var lastPromptIndex: [String: Int] = [:]

    static func supports(course: LanguageCourse) -> Bool {
        course == .french || course == .spanish
    }

    func randomPrompt(course: LanguageCourse, topicIDs: [String]) throws -> String {
        guard Self.supports(course: course) else {
            throw RandomConversationPromptError.unsupported
        }

        let bank: [String: [String]]
        if let cached = cache[course] {
            bank = cached
        } else {
            let loaded = try loadBank(for: course)
            cache[course] = loaded
            bank = loaded
        }

        // Deliberately choose the TOPIC first, with equal probability.
        // This prevents huge banks such as Food from dominating smaller topics.
        let availableTopicIDs = topicIDs.filter { topicID in
            guard let prompts = bank[topicID] else { return false }
            return !prompts.isEmpty
        }

        guard let selectedTopicID = availableTopicIDs.randomElement(),
              let prompts = bank[selectedTopicID],
              !prompts.isEmpty else {
            throw RandomConversationPromptError.noPrompts
        }

        let historyKey = "\(course.rawValue):\(selectedTopicID)"
        let previous = lastPromptIndex[historyKey]

        let availableIndices: [Int]
        if prompts.count > 1, let previous {
            availableIndices = prompts.indices.filter { $0 != previous }
        } else {
            availableIndices = Array(prompts.indices)
        }

        guard let selectedIndex = availableIndices.randomElement() else {
            throw RandomConversationPromptError.noPrompts
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
            throw RandomConversationPromptError.unsupported
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
            throw RandomConversationPromptError.missingResource(course)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = parse(text)

        guard !parsed.isEmpty else {
            throw RandomConversationPromptError.invalidResource(course)
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
}

private enum RandomConversationPromptError: LocalizedError {
    case unsupported
    case missingResource(LanguageCourse)
    case invalidResource(LanguageCourse)
    case noPrompts

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Random ChatGPT conversation practice isn’t available for this language yet."
        case .missingResource(let course):
            return "The \(course.title) conversation prompt bank isn’t bundled in this build yet."
        case .invalidResource(let course):
            return "The \(course.title) conversation prompt bank couldn’t be read."
        case .noPrompts:
            return "No conversation prompts were found for the available topics."
        }
    }
}
