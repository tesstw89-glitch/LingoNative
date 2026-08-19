import SwiftUI
import WebKit

struct PracticeHubView: View {
    let corpus: Corpus
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                dailyGoalCard

                VStack(alignment: .leading, spacing: 12) {
                    Text("PRACTICE")
                        .font(.caption.weight(.black))
                        .tracking(1.2)
                        .foregroundStyle(Color.lingoMuted)

                    ForEach(PracticeMode.allCases) { mode in
                        practiceLink(mode)
                    }
                }

                if settings.heartsEnabled {
                    heartsCard
                }
            }
            .padding(20)
            .padding(.bottom, 50)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var dailyGoalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TODAY")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(progress.todayXP >= settings.dailyGoalXP ? "Daily goal complete" : "Daily goal")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: progress.todayXP >= settings.dailyGoalXP ? "checkmark.seal.fill" : "target")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
            }

            ProgressView(
                value: Double(min(progress.todayXP, settings.dailyGoalXP)),
                total: Double(max(1, settings.dailyGoalXP))
            )
            .tint(.white)

            Text("\(progress.todayXP) / \(settings.dailyGoalXP) XP · \(progress.todayActivity.correct) correct today")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(18)
        .background(corpus.course == .french ? Color.lingoBlue : Color.lingoGreen)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func practiceLink(_ mode: PracticeMode) -> some View {
        let pool = phrasePool(for: mode)
        let availableCount = mode == .matching ? lemmaPool.count : pool.count

        NavigationLink {
            practiceDestination(mode: mode, pool: pool)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: mode.systemImage)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(accent(for: mode))
                    .frame(width: 52, height: 52)
                    .background(accent(for: mode).opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(Color.lingoInk)
                    Text(subtitle(for: mode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.lingoMuted)
                    Text(availabilityText(for: mode, count: availableCount))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent(for: mode))
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.lingoMuted)
            }
            .padding(15)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.lingoLine, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .disabled(availableCount == 0)
        .opacity(availableCount == 0 ? 0.5 : 1)
    }

    @ViewBuilder
    private func practiceDestination(mode: PracticeMode, pool: [PhraseEntry]) -> some View {
        switch mode {
        case .speaking:
            LanguageTrainerSpeakingPracticeView(
                course: corpus.course,
                phrases: corpus.entries,
                sessionLength: settings.sessionLength,
                speechRate: settings.speechRate
            )
        case .matching:
            LanguageTrainerLemmaMatchView(
                course: corpus.course,
                lemmas: lemmaPool,
                speechRate: settings.speechRate
            )
        case .listening:
            AllTermsListeningPracticeView(
                course: corpus.course,
                phrases: corpus.entries,
                sessionLength: settings.sessionLength,
                speechRate: settings.speechRate,
                autoplayAudio: settings.autoplayAudio
            )
        default:
            QuizView(session: makeSession(mode: mode, pool: pool), progress: progress, settings: settings)
        }
    }

    private var heartsCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(progress.hearts) hearts")
                    .font(.headline.weight(.black))
                Text("Single-user rules: refill whenever you like.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.lingoMuted)
            }
            Spacer()
            Button("Refill") {
                progress.refillHearts()
            }
            .font(.subheadline.weight(.black))
            .disabled(progress.hearts == 5)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var lemmaPool: [Lemma] {
        var seen = Set<String>()
        return corpus.entries
            .flatMap(\.lemmas)
            .filter { lemma in
                let foreign = lemma.foreign.trimmingCharacters(in: .whitespacesAndNewlines)
                let english = lemma.english.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !foreign.isEmpty, !english.isEmpty else { return false }
                let key = PracticeTextNormalizer.key(foreign) + "||" + PracticeTextNormalizer.key(english)
                return seen.insert(key).inserted
            }
    }

    private func phrasePool(for mode: PracticeMode) -> [PhraseEntry] {
        let learned = corpus.entries.filter {
            progress.learningStage(course: corpus.course, phrase: $0) != .unseen
        }

        switch mode {
        case .retention:
            return progress.duePhrases(course: corpus.course, from: corpus.entries, limit: 250)
        case .quick:
            return learned.shuffled()
        case .bookmarks:
            return progress.bookmarkedPhrases(course: corpus.course, from: learned)
        case .mistakes:
            return progress.phrasesWithMistakes(course: corpus.course, from: learned)
        case .weak:
            return progress.weakestPhrases(course: corpus.course, from: learned)
        case .typing:
            return learned.filter {
                progress.learningStage(course: corpus.course, phrase: $0) >= .assistedRecall
            }
        case .listening, .speaking:
            return corpus.entries.filter {
                !$0.foreign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .matching:
            return corpus.entries.filter { !$0.lemmas.isEmpty }
        case .lemma:
            return learned.filter { !$0.lemmas.isEmpty }
        }
    }

    private func makeSession(mode: PracticeMode, pool: [PhraseEntry]) -> QuizSession {
        let types: Set<ExerciseType>
        switch mode {
        case .retention, .quick, .bookmarks, .mistakes, .weak:
            types = settings.enabledExerciseTypes
        case .typing:
            types = [.typing, .wordBank, .fillBlank]
        case .listening:
            types = [.listening]
        case .speaking:
            types = [.speaking]
        case .matching:
            types = [.matching]
        case .lemma:
            types = [.lemma]
        }

        return QuizSession(
            course: corpus.course,
            title: mode.title,
            subtitle: mode.subtitle,
            phrasePool: pool,
            allPhrases: corpus.entries,
            sessionSize: min(settings.sessionLength, max(1, pool.count)),
            exerciseTypes: types,
            completionNodeID: nil
        )
    }

    private func subtitle(for mode: PracticeMode) -> String {
        mode == .matching ? "Fast lemma matching" : mode.subtitle
    }

    private func availabilityText(for mode: PracticeMode, count: Int) -> String {
        if mode == .matching {
            return "\(count) lemma\(count == 1 ? "" : "s") available"
        }
        return "\(count) phrase\(count == 1 ? "" : "s") available"
    }

    private func accent(for mode: PracticeMode) -> Color {
        switch mode {
        case .retention: return .lingoPurple
        case .quick: return .lingoGreen
        case .bookmarks: return .lingoGold
        case .mistakes: return .lingoOrange
        case .weak: return .lingoPurple
        case .typing: return .lingoBlue
        case .listening: return .lingoGold
        case .speaking: return .red
        case .matching: return .lingoGreen
        case .lemma: return .lingoPurple
        }
    }
}

private struct LanguageTrainerSpeakingPracticeView: View {
    let course: LanguageCourse
    let phrases: [PhraseEntry]
    let sessionLength: Int
    let speechRate: Double

    @StateObject private var speaker = SpeechSynthesizer()
    @StateObject private var recognizer = SpeechRecognizerService()
    @State private var queue: [PhraseEntry] = []
    @State private var index = 0
    @State private var recognisedIndices: Set<Int> = []
    @State private var mode: SpeakButtonMode = .speak
    @State private var graceSecondsLeft: Int?
    @State private var graceTask: Task<Void, Never>?
    @State private var isDone = false

    private enum SpeakButtonMode { case speak, keepGoing, next }
    private var current: PhraseEntry? { queue.indices.contains(index) ? queue[index] : nil }
    private var eligible: [PhraseEntry] {
        phrases.filter {
            !$0.foreign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        Group {
            if isDone { doneView }
            else if let current { mainView(current) }
            else { ContentUnavailableView("No speaking phrases", systemImage: "mic.slash.fill") }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Speaking")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if queue.isEmpty { startQueue() } }
        .onChange(of: recognizer.transcript) { _, transcript in handleTranscript(transcript) }
        .onDisappear {
            recognizer.stop(); speaker.stop(); cancelGrace()
        }
    }

    private func mainView(_ current: PhraseEntry) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Text("Question \(index + 1) / \(queue.count)")
                        .font(.subheadline.weight(.bold)).foregroundStyle(Color.lingoMuted)
                    Spacer()
                    if recognizer.isRecording {
                        Label("Listening…", systemImage: "waveform")
                            .font(.subheadline.weight(.bold)).foregroundStyle(Color.lingoPurple)
                    }
                }

                VStack(spacing: 8) {
                    Text("SAY THIS IN \(course.title.uppercased())")
                        .font(.caption2.weight(.black)).tracking(1).foregroundStyle(Color.lingoMuted)
                    Text(current.english)
                        .font(.title3.weight(.black)).foregroundStyle(Color.lingoInk)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18).frame(maxWidth: .infinity).background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.lingoLine, lineWidth: 2) }

                targetSentence(current.foreign)
                    .padding(18).frame(maxWidth: .infinity)
                    .background(Color.lingoPurple.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                if let seconds = graceSecondsLeft {
                    Text("Keep going… \(seconds)s").font(.subheadline.weight(.bold)).foregroundStyle(Color.lingoOrange)
                }
                if let error = recognizer.errorMessage, recognizer.isRecording {
                    Text(error).font(.caption.weight(.semibold)).foregroundStyle(Color.lingoWrong).multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button {
                        prepareForPlayback(); speaker.speak(current.foreign, course: course, rate: speechRate)
                    } label: {
                        Label("Hear it", systemImage: "speaker.wave.2.fill").font(.subheadline.weight(.black)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DuoButtonStyle(fill: Color.lingoBlue, shadow: Color.lingoBlue.opacity(0.65)))

                    Button { skip() } label: {
                        Text("SKIP").font(.subheadline.weight(.black)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DuoButtonStyle(fill: Color(.systemGray3), shadow: Color(.systemGray4)))
                }

                Button(action: handleMainButton) {
                    HStack(spacing: 9) {
                        if mode == .speak { Image(systemName: "mic.fill") }
                        Text(mainButtonTitle)
                    }
                    .font(.headline.weight(.black)).frame(maxWidth: .infinity)
                }
                .buttonStyle(DuoButtonStyle(fill: mainButtonFill, shadow: mainButtonShadow))
            }
            .padding(20).padding(.bottom, 30)
        }
    }

    private func targetSentence(_ sentence: String) -> some View {
        let words = sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return PracticeWordWrapLayout(spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                Button {
                    prepareForPlayback()
                    let spoken = PracticeTextNormalizer.cleanWordForSpeech(word)
                    if !spoken.isEmpty { speaker.speak(spoken, course: course, rate: speechRate) }
                } label: {
                    Text(word)
                        .font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 4)
                        .background(recognisedIndices.contains(idx) ? Color.cyan.opacity(0.33) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(recognisedIndices.contains(idx) ? Color.cyan : Color.white.opacity(0.55)).frame(height: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var mainButtonTitle: String {
        switch mode {
        case .speak: return "SPEAK"
        case .keepGoing: return "KEEP GOING…"
        case .next: return index == queue.count - 1 ? "FINISH" : "NEXT"
        }
    }
    private var mainButtonFill: Color {
        switch mode { case .speak: return .lingoPurple; case .keepGoing: return .lingoOrange; case .next: return .lingoGreen }
    }
    private var mainButtonShadow: Color {
        switch mode {
        case .speak: return Color.lingoPurple.opacity(0.65)
        case .keepGoing: return Color.lingoOrange.opacity(0.65)
        case .next: return Color.lingoGreen.opacity(0.65)
        }
    }

    private var doneView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(Color.lingoGreen)
            Text("Speaking complete!").font(.largeTitle.weight(.black)).foregroundStyle(Color.lingoInk)
            Text("You worked through \(queue.count) phrases from the full corpus.")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.lingoMuted).multilineTextAlignment(.center)
            Button("PRACTISE AGAIN") { startQueue() }
                .buttonStyle(DuoButtonStyle(fill: .lingoPurple, shadow: Color.lingoPurple.opacity(0.65)))
            Spacer()
        }
        .padding(24)
    }

    private func startQueue() {
        recognizer.stop(); cancelGrace()
        let pool = eligible.shuffled()
        queue = Array(pool.prefix(min(max(1, sessionLength), pool.count)))
        index = 0; isDone = queue.isEmpty; recognisedIndices = []; mode = .speak
        if !queue.isEmpty { loadCurrent() }
    }
    private func loadCurrent() {
        recognizer.stop(); cancelGrace(); recognisedIndices = []; mode = .speak
        guard let current else { return }
        speaker.speak(current.foreign, course: course, rate: speechRate)
    }
    private func handleMainButton() {
        switch mode {
        case .speak:
            speaker.stop(); Task { await recognizer.start(localeIdentifier: course.speechLocaleIdentifier) }
        case .keepGoing: break
        case .next: advance()
        }
    }
    private func advance() {
        recognizer.stop(); cancelGrace()
        if index + 1 >= queue.count { isDone = true }
        else { index += 1; loadCurrent() }
    }
    private func skip() { recognizer.stop(); cancelGrace(); advance() }
    private func prepareForPlayback() { recognizer.stop(); cancelGrace(); if mode != .next { mode = .speak } }

    private func handleTranscript(_ raw: String) {
        guard let current, mode != .next else { return }
        let canonical = PracticeTextNormalizer.alignedTokens(current.foreign, course: course)
        let heard = PracticeTextNormalizer.transcriptTokenSet(raw, course: course)
        var updated = recognisedIndices
        for (idx, token) in canonical.enumerated() where !token.isEmpty {
            if heard.contains(token) { updated.insert(idx) }
        }
        recognisedIndices = updated
        let important = PracticeTextNormalizer.importantIndices(canonical, course: course)
        let denominator = important.isEmpty ? canonical.indices.filter { !canonical[$0].isEmpty } : important
        guard !denominator.isEmpty else { return }
        let heardImportant = denominator.filter { recognisedIndices.contains($0) }.count
        let ratio = Double(heardImportant) / Double(denominator.count)
        if heardImportant == denominator.count {
            recognizer.stop(); cancelGrace(); mode = .next
        } else if ratio >= 0.75, graceSecondsLeft == nil {
            beginGrace()
        }
    }
    private func beginGrace() {
        mode = .keepGoing; graceSecondsLeft = 10; graceTask?.cancel()
        graceTask = Task { @MainActor in
            for remaining in stride(from: 9, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                graceSecondsLeft = remaining
            }
            guard !Task.isCancelled else { return }
            recognizer.stop(); graceSecondsLeft = nil; mode = .next
        }
    }
    private func cancelGrace() { graceTask?.cancel(); graceTask = nil; graceSecondsLeft = nil }
}

private struct LanguageTrainerLemmaMatchView: View {
    let course: LanguageCourse
    let lemmas: [Lemma]
    let speechRate: Double

    @StateObject private var speaker = SpeechSynthesizer()
    @State private var deck: [PracticeLemmaPair] = []
    @State private var visible: [PracticeLemmaPair] = []
    @State private var leftOrder: [String] = []
    @State private var rightOrder: [String] = []
    @State private var selectedLeft: String?
    @State private var selectedRight: String?
    @State private var dissolvingIDs: Set<String> = []
    @State private var secondsLeft = 120
    @State private var timeUp = false
    @State private var matches = 0
    @State private var soundEnabled = true
    @State private var runID = UUID()

    private let visibleCount = 6
    private var pairs: [PracticeLemmaPair] { lemmas.map { PracticeLemmaPair(lemma: $0) } }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Label(format(secondsLeft), systemImage: "timer")
                        .font(.subheadline.weight(.black)).foregroundStyle(Color.lingoInk)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("\(matches) matched").font(.subheadline.weight(.black)).foregroundStyle(Color.lingoGreen)
                    Spacer()
                    Button { soundEnabled.toggle() } label: {
                        Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.headline.weight(.bold)).foregroundStyle(.white).frame(width: 42, height: 42)
                            .background(soundEnabled ? Color.lingoGreen : Color.lingoWrong)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                HStack { Text(course.title.uppercased()); Spacer(); Text("ENGLISH") }
                    .font(.caption2.weight(.black)).tracking(1).foregroundStyle(Color.lingoMuted).padding(.horizontal, 4)
                HStack(alignment: .top, spacing: 12) {
                    matchColumn(ids: leftOrder, isLeft: true)
                    matchColumn(ids: rightOrder, isLeft: false)
                }
                Spacer(minLength: 0)
            }
            .padding(18)

            if timeUp {
                VStack(spacing: 14) {
                    Image(systemName: "timer.circle.fill").font(.system(size: 58)).foregroundStyle(Color.lingoGreen)
                    Text("Time's up!").font(.title.weight(.black)).foregroundStyle(Color.lingoInk)
                    Text("\(matches) lemma pair\(matches == 1 ? "" : "s") matched")
                        .font(.headline.weight(.bold)).foregroundStyle(Color.lingoMuted)
                    Button("PLAY AGAIN") { startGame() }
                        .buttonStyle(DuoButtonStyle(fill: .lingoGreen, shadow: Color.lingoGreen.opacity(0.65)))
                }
                .padding(24).frame(maxWidth: 340).background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8).padding(24)
            }
        }
        .navigationTitle("Matching").navigationBarTitleDisplayMode(.inline)
        .onAppear { if visible.isEmpty { startGame() } }
        .task(id: runID) {
            while !Task.isCancelled && !timeUp {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !timeUp else { return }
                    secondsLeft -= 1
                    if secondsLeft <= 0 { secondsLeft = 0; timeUp = true; selectedLeft = nil; selectedRight = nil }
                }
            }
        }
        .onDisappear { speaker.stop() }
    }

    private func matchColumn(ids: [String], isLeft: Bool) -> some View {
        VStack(spacing: 10) {
            ForEach(ids, id: \.self) { id in
                if let pair = visible.first(where: { $0.id == id }) {
                    Button { if isLeft { handleLeftTap(pair) } else { handleRightTap(pair) } } label: {
                        LemmaMatchToken(
                            text: isLeft ? pair.foreign : pair.english,
                            isSelected: isLeft ? selectedLeft == id : selectedRight == id,
                            accent: isLeft ? Color.lingoGreen : Color.lingoBlue
                        )
                    }
                    .buttonStyle(.plain)
                    .opacity(dissolvingIDs.contains(id) ? 0 : 1)
                    .scaleEffect(dissolvingIDs.contains(id) ? 0.92 : 1)
                    .animation(.easeInOut(duration: 0.22), value: dissolvingIDs)
                    .disabled(timeUp || !dissolvingIDs.isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func startGame() {
        deck = pairs.shuffled()
        visible = Array(deck.prefix(min(visibleCount, deck.count)))
        deck.removeFirst(min(visibleCount, deck.count))
        let ids = visible.map(\.id)
        leftOrder = ids.shuffled(); rightOrder = ids.shuffled()
        selectedLeft = nil; selectedRight = nil; dissolvingIDs = []
        secondsLeft = 120; timeUp = false; matches = 0; runID = UUID()
    }
    private func handleLeftTap(_ pair: PracticeLemmaPair) {
        guard !timeUp else { return }
        if soundEnabled { speaker.speak(pair.foreign, course: course, rate: speechRate) }
        selectedLeft = pair.id; resolveIfReady()
    }
    private func handleRightTap(_ pair: PracticeLemmaPair) { guard !timeUp else { return }; selectedRight = pair.id; resolveIfReady() }
    private func resolveIfReady() {
        guard let left = selectedLeft, let right = selectedRight else { return }
        if left == right {
            selectedLeft = nil; selectedRight = nil; matches += 1
            withAnimation(.easeInOut(duration: 0.22)) { dissolvingIDs.insert(left) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 240_000_000)
                replaceMatched(id: left); dissolvingIDs.remove(left)
            }
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                selectedLeft = nil; selectedRight = nil
            }
        }
    }
    private func replaceMatched(id: String) {
        visible.removeAll { $0.id == id }; leftOrder.removeAll { $0 == id }; rightOrder.removeAll { $0 == id }
        if let next = deck.first {
            deck.removeFirst(); visible.append(next)
            leftOrder.insert(next.id, at: Int.random(in: 0...leftOrder.count))
            rightOrder.insert(next.id, at: Int.random(in: 0...rightOrder.count))
        }
    }
    private func format(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

private struct PracticeLemmaPair: Identifiable, Hashable {
    let id: String
    let foreign: String
    let english: String
    init(lemma: Lemma) {
        foreign = lemma.foreign; english = lemma.english
        id = PracticeTextNormalizer.key(lemma.foreign) + "||" + PracticeTextNormalizer.key(lemma.english)
    }
}

private struct LemmaMatchToken: View {
    let text: String
    let isSelected: Bool
    let accent: Color
    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Color.lingoInk)
            .multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.65).padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68)
            .background(isSelected ? Color.lingoGold.opacity(0.25) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(isSelected ? Color.lingoGold : accent.opacity(0.7), lineWidth: isSelected ? 3 : 2) }
            .shadow(color: .black.opacity(0.06), radius: 0, y: 3)
    }
}

private struct AllTermsListeningPracticeView: View {
    let course: LanguageCourse
    let phrases: [PhraseEntry]
    let sessionLength: Int
    let speechRate: Double
    let autoplayAudio: Bool

    @StateObject private var speaker = SpeechSynthesizer()
    @State private var queue: [PhraseEntry] = []
    @State private var index = 0
    @State private var typedAnswer = ""
    @State private var checked: Bool?
    @State private var isDone = false
    private var current: PhraseEntry? { queue.indices.contains(index) ? queue[index] : nil }

    var body: some View {
        Group {
            if isDone {
                VStack(spacing: 18) {
                    Spacer()
                    Image(systemName: "headphones.circle.fill").font(.system(size: 72)).foregroundStyle(Color.lingoGold)
                    Text("Listening complete!").font(.largeTitle.weight(.black)).foregroundStyle(Color.lingoInk)
                    Text("The next run will draw a fresh set from the whole corpus.")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.lingoMuted).multilineTextAlignment(.center)
                    Button("PRACTISE AGAIN") { startQueue() }
                        .buttonStyle(DuoButtonStyle(fill: .lingoGold, shadow: Color.lingoOrange))
                    Spacer()
                }
                .padding(24)
            } else if let current { listeningView(current) }
            else { ContentUnavailableView("No listening phrases", systemImage: "headphones") }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Listening").navigationBarTitleDisplayMode(.inline)
        .onAppear { if queue.isEmpty { startQueue() } }
        .onDisappear { speaker.stop() }
    }

    private func listeningView(_ current: PhraseEntry) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text("Question \(index + 1) / \(queue.count)").font(.subheadline.weight(.bold)).foregroundStyle(Color.lingoMuted)
                    Spacer()
                }

                VStack(spacing: 20) {
                    PracticeRemoteSVGView(url: PracticeLessonCharacter.forPhrase(current).url)
                        .frame(width: 96, height: 120).accessibilityHidden(true)
                    Button { speaker.speak(current.foreign, course: course, rate: speechRate) } label: {
                        ZStack {
                            Circle().fill(Color.lingoBlue).frame(width: 104, height: 104)
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 42, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)

                TextField("Type what you hear", text: $typedAnswer, axis: .vertical)
                    .font(.body.weight(.semibold)).padding(16).background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(checked == false ? Color.lingoWrong : Color.lingoLine, lineWidth: 2) }
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(checked != nil)

                if let checked {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(checked ? "Nicely done!" : "Correct answer", systemImage: checked ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                            .font(.headline.weight(.black))
                        Text(current.foreign).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(checked ? Color.lingoGreen : Color.lingoWrong)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background((checked ? Color.lingoCorrect : Color.lingoWrong).opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if checked == nil {
                    let isEmpty = typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button("CHECK") { checked = QuizViewModel.answersMatch(typedAnswer, current.foreign) }
                        .buttonStyle(DuoButtonStyle(fill: isEmpty ? Color(.systemGray4) : Color.lingoGreen, shadow: isEmpty ? Color(.systemGray3) : Color.lingoGreen.opacity(0.65)))
                        .disabled(isEmpty)
                } else {
                    Button(index == queue.count - 1 ? "FINISH" : "NEXT") { advance() }
                        .buttonStyle(DuoButtonStyle(fill: checked == true ? .lingoGreen : .lingoWrong, shadow: checked == true ? Color.lingoGreen.opacity(0.65) : Color.lingoWrong.opacity(0.65)))
                }
            }
            .padding(20).padding(.bottom, 30)
        }
    }

    private func startQueue() {
        let eligible = phrases.filter { !$0.foreign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.shuffled()
        queue = Array(eligible.prefix(min(max(1, sessionLength), eligible.count)))
        index = 0; typedAnswer = ""; checked = nil; isDone = queue.isEmpty
        if !queue.isEmpty { playCurrentIfNeeded() }
    }
    private func advance() {
        if index + 1 >= queue.count { isDone = true }
        else { index += 1; typedAnswer = ""; checked = nil; playCurrentIfNeeded() }
    }
    private func playCurrentIfNeeded() {
        guard autoplayAudio, let current else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            speaker.speak(current.foreign, course: course, rate: speechRate)
        }
    }
}

private enum PracticeLessonCharacter: String, CaseIterable {
    case girl, boy, woman, man, robot, zombie
    var url: URL {
        URL(string: "https://raw.githubusercontent.com/sanidhyy/duolingo-clone/268221c205148c07bfb22f9adf3b46bdcd048d9a/public/\(rawValue).svg")!
    }
    static func forPhrase(_ phrase: PhraseEntry) -> PracticeLessonCharacter {
        let total = phrase.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return allCases[total % allCases.count]
    }
}

private struct PracticeRemoteSVGView: UIViewRepresentable {
    let url: URL
    final class Coordinator { var loadedURL: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.isOpaque = false; webView.backgroundColor = .clear; webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false; webView.isUserInteractionEnabled = false
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden}img{width:100%;height:100%;object-fit:contain}</style>
        </head><body><img src="\(url.absoluteString)"></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}

private enum PracticeTextNormalizer {
    private static let frenchStopWords: Set<String> = [
        "je", "j", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "le", "la", "les", "un", "une", "des", "du", "de", "d", "ce", "cet", "cette", "ces", "et", "ou", "mais", "que", "qui", "ne", "n", "pas", "y", "en", "mon", "ton", "son", "notre", "votre", "leur", "leurs", "au", "aux"
    ]
    private static let spanishStopWords: Set<String> = [
        "yo", "tu", "el", "ella", "nosotros", "nosotras", "vosotros", "vosotras", "ellos", "ellas", "la", "los", "las", "un", "una", "unos", "unas", "de", "del", "a", "al", "en", "y", "o", "pero", "que", "lo", "se", "me", "te", "nos", "os", "mi", "su", "sus", "por", "para"
    ]
    static func key(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func cleanWordForSpeech(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
    }
    static func alignedTokens(_ sentence: String, course: LanguageCourse) -> [String] {
        sentence.split(whereSeparator: { $0.isWhitespace }).map { canonicalToken(String($0), course: course) }
    }
    static func transcriptTokenSet(_ transcript: String, course: LanguageCourse) -> Set<String> {
        Set(transcript.replacingOccurrences(of: "’", with: "'").split(whereSeparator: { $0.isWhitespace })
            .map { canonicalToken(String($0), course: course) }.filter { !$0.isEmpty })
    }
    static func importantIndices(_ tokens: [String], course: LanguageCourse) -> [Int] {
        let stopWords = course == .french ? frenchStopWords : spanishStopWords
        return tokens.enumerated().compactMap { idx, token in
            guard !token.isEmpty else { return nil }
            return stopWords.contains(token) ? nil : idx
        }
    }
    private static func canonicalToken(_ raw: String, course: LanguageCourse) -> String {
        var value = raw.lowercased().folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        if course == .french {
            let homophones = ["aux": "au", "ont": "on", "peux": "peu", "peut": "peu", "sont": "son", "sans": "sang", "vingt": "vin"]
            if let mapped = homophones[value] { value = mapped }
        }
        return value
    }
}

private struct PracticeWordWrapLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
