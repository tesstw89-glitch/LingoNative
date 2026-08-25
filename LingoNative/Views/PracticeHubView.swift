import SwiftUI

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
                        .font(.custom("Fredoka-SemiBold", size: 13))
                        .tracking(1.2)
                        .foregroundStyle(Color.lingoMuted)

                    ForEach(PracticeMode.allCases) { mode in
                        practiceLink(mode)
                    }

                    vocabPracticeLink
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
                        .font(.custom("Fredoka-SemiBold", size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(progress.todayXP >= settings.dailyGoalXP ? "Daily goal complete" : "Daily goal")
                        .font(.custom("Fredoka-Medium", size: 20))
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
                .font(.custom("Fredoka-Regular", size: 15))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(18)
        .background(corpus.course == .french ? Color.lingoBlue : Color.lingoGreen)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func practiceLink(_ mode: PracticeMode) -> some View {
        let pool = phrasePool(for: mode)
        let count = availabilityCount(for: mode, pool: pool)

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
                        .font(.custom("Fredoka-Medium", size: 18))
                        .foregroundStyle(Color.lingoInk)
                    Text(subtitle(for: mode))
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                    Text(availabilityText(for: mode, count: count))
                        .font(.custom("Fredoka-Medium", size: 13))
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
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1)
    }

    @ViewBuilder
    private func practiceDestination(mode: PracticeMode, pool: [PhraseEntry]) -> some View {
        switch mode {
        case .listening, .speaking:
            phraseScopeChooser(mode: mode, allPhrases: pool)

        case .matching:
            LanguageTrainerLemmaMatchView(
                course: corpus.course,
                lemmas: lemmaPool,
                speechRate: settings.speechRate,
                onFinished: { matchedCount in
                    progress.recordPracticeSession(
                        earnedXP: max(10, matchedCount * 2),
                        restoreHeart: settings.heartsEnabled
                    )
                }
            )

        default:
            QuizView(
                session: makeSession(mode: mode, pool: pool),
                progress: progress,
                settings: settings
            )
        }
    }

    private func phraseScopeChooser(
        mode: PracticeMode,
        allPhrases: [PhraseEntry]
    ) -> some View {
        let studied = allPhrases.filter {
            progress.learningStage(course: corpus.course, phrase: $0) != .unseen
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(mode.title.uppercased())
                        .font(.custom("Fredoka-SemiBold", size: 13))
                        .tracking(1.1)
                        .foregroundStyle(Color.lingoMuted)

                    Text("Which phrases?")
                        .font(.custom("Fredoka-Medium", size: 24))
                        .foregroundStyle(Color.lingoInk)

                    Text("Choose how much of your corpus to practise.")
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                }

                phraseScopeLink(
                    mode: mode,
                    title: "All phrases",
                    subtitle: "Practice from the whole corpus",
                    count: allPhrases.count,
                    phrases: allPhrases,
                    systemImage: "books.vertical.fill"
                )

                phraseScopeLink(
                    mode: mode,
                    title: "Phrases studied so far",
                    subtitle: "Only phrases you've already encountered",
                    count: studied.count,
                    phrases: studied,
                    systemImage: "checkmark.circle.fill"
                )
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func phraseScopeLink(
        mode: PracticeMode,
        title: String,
        subtitle: String,
        count: Int,
        phrases: [PhraseEntry],
        systemImage: String
    ) -> some View {
        let tint = accent(for: mode)

        return NavigationLink {
            scopedPracticeDestination(mode: mode, pool: phrases)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 54, height: 54)
                    .background(tint.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.custom("Fredoka-Medium", size: 19))
                        .foregroundStyle(Color.lingoInk)

                    Text(subtitle)
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)

                    Text("\(count) phrase\(count == 1 ? "" : "s") available")
                        .font(.custom("Fredoka-Medium", size: 13))
                        .foregroundStyle(tint)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.lingoMuted)
            }
            .padding(16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.lingoLine, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1)
    }

    @ViewBuilder
    private func scopedPracticeDestination(
        mode: PracticeMode,
        pool: [PhraseEntry]
    ) -> some View {
        switch mode {
        case .speaking:
            LanguageTrainerSpeakingPracticeView(
                course: corpus.course,
                phrases: pool,
                sessionLength: settings.sessionLength,
                speechRate: settings.speechRate,
                onFinished: { completedCount in
                    progress.recordPracticeSession(
                        earnedXP: max(10, completedCount * 5),
                        restoreHeart: settings.heartsEnabled
                    )
                }
            )

        case .listening:
            QuizView(
                session: makeSession(mode: mode, pool: pool),
                progress: progress,
                settings: settings
            )

        default:
            EmptyView()
        }
    }

    private var vocabPracticeLink: some View {
        let count = lemmaPool.count

        return NavigationLink {
            VocabPracticeChooserView(
                course: corpus.course,
                lemmas: lemmaPool,
                sessionLength: settings.sessionLength,
                speechRate: settings.speechRate,
                onFinished: { completedCount in
                    progress.recordPracticeSession(
                        earnedXP: max(10, completedCount * 5),
                        restoreHeart: settings.heartsEnabled
                    )
                }
            )
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "text.book.closed.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.lingoBlue)
                    .frame(width: 52, height: 52)
                    .background(Color.lingoBlue.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Practice Vocab")
                        .font(.custom("Fredoka-Medium", size: 18))
                        .foregroundStyle(Color.lingoInk)
                    Text("Write or listen & write · lemmas only")
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                    Text("\(count) lemma\(count == 1 ? "" : "s") available")
                        .font(.custom("Fredoka-Medium", size: 13))
                        .foregroundStyle(Color.lingoBlue)
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
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1)
    }

    private var heartsCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(progress.hearts) hearts")
                    .font(.custom("Fredoka-Medium", size: 17))
                Text("Single-user rules: refill whenever you like.")
                    .font(.custom("Fredoka-Regular", size: 13))
                    .foregroundStyle(Color.lingoMuted)
            }
            Spacer()
            Button("Refill") {
                progress.refillHearts()
            }
            .font(.custom("Fredoka-Medium", size: 15))
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

    private var speakingEligibleCount: Int {
        corpus.entries.filter {
            !$0.foreign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
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
            // These standalone drills are intentionally open-corpus: unseen material is allowed.
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

    private func availabilityCount(for mode: PracticeMode, pool: [PhraseEntry]) -> Int {
        switch mode {
        case .matching: return lemmaPool.count
        case .speaking: return speakingEligibleCount
        default: return pool.count
        }
    }

    private func subtitle(for mode: PracticeMode) -> String {
        switch mode {
        case .matching: return "Fast lemma matching"
        case .listening, .speaking: return "Choose all phrases or studied so far"
        default: return mode.subtitle
        }
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
        case .speaking: return .lingoPurple
        case .matching: return .lingoGreen
        case .lemma: return .lingoPurple
        }
    }
}

// MARK: - Lemma-only vocab practice

private enum VocabPracticeMode {
    case multipleChoice
    case write
    case listenWrite

    var title: String {
        switch self {
        case .multipleChoice: return "Multiple Choice"
        case .write: return "Write"
        case .listenWrite: return "Listen & Write"
        }
    }

    var subtitle: String {
        switch self {
        case .multipleChoice: return "See the meaning and choose the lemma"
        case .write: return "See the meaning and write the lemma"
        case .listenWrite: return "Hear the lemma and type what you hear"
        }
    }

    var systemImage: String {
        switch self {
        case .multipleChoice: return "checklist"
        case .write: return "square.and.pencil"
        case .listenWrite: return "headphones.circle.fill"
        }
    }
}

private struct VocabPracticeChooserView: View {
    let course: LanguageCourse
    let lemmas: [Lemma]
    let sessionLength: Int
    let speechRate: Double
    let onFinished: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("PRACTICE VOCAB")
                        .font(.custom("Fredoka-SemiBold", size: 13))
                        .tracking(1.1)
                        .foregroundStyle(Color.lingoMuted)
                    Text("Lemmas & chunks only")
                        .font(.custom("Fredoka-Medium", size: 24))
                        .foregroundStyle(Color.lingoInk)
                    Text("\(lemmas.count) available across your \(course.title) corpus")
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                }

                option(.multipleChoice, tint: .lingoGreen)
                option(.write, tint: .lingoBlue)
                option(.listenWrite, tint: .lingoGold)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Practice Vocab")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func option(_ mode: VocabPracticeMode, tint: Color) -> some View {
        NavigationLink {
            LanguageTrainerVocabPracticeView(
                mode: mode,
                course: course,
                lemmas: lemmas,
                sessionLength: sessionLength,
                speechRate: speechRate,
                onFinished: onFinished
            )
        } label: {
            HStack(spacing: 16) {
                Image(systemName: mode.systemImage)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 54, height: 54)
                    .background(tint.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title)
                        .font(.custom("Fredoka-Medium", size: 19))
                        .foregroundStyle(Color.lingoInk)
                    Text(mode.subtitle)
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.lingoMuted)
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.lingoLine, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct LanguageTrainerVocabPracticeView: View {
    let mode: VocabPracticeMode
    let course: LanguageCourse
    let lemmas: [Lemma]
    let sessionLength: Int
    let speechRate: Double
    let onFinished: (Int) -> Void

    @StateObject private var speaker = SpeechSynthesizer()
    @State private var queue: [Lemma] = []
    @State private var index = 0
    @State private var typedAnswer = ""
    @State private var choiceOptions: [Lemma] = []
    @State private var selectedChoiceID: String?
    @State private var feedback: VocabFeedback?
    @State private var correctCount = 0
    @State private var isDone = false
    @State private var didReportRun = false

    private enum VocabFeedback: Equatable {
        case correct
        case wrong
    }

    private var current: Lemma? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var body: some View {
        Group {
            if isDone {
                doneView
            } else if let current {
                mainView(current)
            } else {
                ContentUnavailableView("No vocab available", systemImage: "text.book.closed")
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if queue.isEmpty { startQueue() }
        }
        .onDisappear {
            speaker.stop()
        }
    }

    private func mainView(_ current: Lemma) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Text("Question \(index + 1) / \(queue.count)")
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                    Spacer()
                    Text("VOCAB")
                        .font(.custom("Fredoka-SemiBold", size: 12))
                        .tracking(1)
                        .foregroundStyle(Color.lingoBlue)
                }

                if mode == .write || mode == .multipleChoice {
                    VStack(spacing: 7) {
                        Text(mode == .multipleChoice
                             ? "CHOOSE THIS IN \(course.title.uppercased())"
                             : "WRITE THIS IN \(course.title.uppercased())")
                            .font(.custom("Fredoka-SemiBold", size: 12))
                            .tracking(1)
                            .foregroundStyle(Color.lingoMuted)
                        Text(current.english)
                            .font(.custom("Fredoka-Medium", size: 22))
                            .foregroundStyle(Color.lingoInk)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("TYPE WHAT YOU HEAR")
                            .font(.custom("Fredoka-SemiBold", size: 12))
                            .tracking(1)
                            .foregroundStyle(Color.lingoMuted)

                        Button {
                            speaker.stop()
                            speaker.speak(current.foreign, course: course, rate: speechRate)
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(Color.lingoGold.opacity(0.16))
                                    .frame(width: 104, height: 104)
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.system(size: 40, weight: .bold))
                                    .foregroundStyle(Color.lingoGold)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                }

                if mode == .multipleChoice {
                    multipleChoiceAnswerList
                } else {
                    answerInput
                }

                if let feedback {
                    feedbackCard(feedback, lemma: current)
                }

                Button(feedback == nil ? "CHECK" : (index == queue.count - 1 ? "FINISH" : "NEXT")) {
                    if feedback == nil {
                        check(current)
                    } else {
                        advance()
                    }
                }
                .font(.custom("Fredoka-Medium", size: 18))
                .buttonStyle(DuoButtonStyle(
                    fill: feedback == nil
                        ? (answerReady ? Color.lingoGreen : Color(.systemGray4))
                        : Color.lingoGreen,
                    shadow: feedback == nil
                        ? (answerReady ? Color.lingoGreenDark : Color(.systemGray3))
                        : Color.lingoGreenDark
                ))
                .disabled(feedback == nil && !answerReady)
            }
            .padding(20)
            .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private var answerInput: some View {
        if course == .arabic {
            VStack(spacing: 12) {
                Text(typedAnswer.isEmpty ? "Your answer…" : typedAnswer)
                    .font(
                        typedAnswer.isEmpty
                            ? .custom("Fredoka-Regular", size: 18)
                            : .custom("NotoSansArabic-Regular", size: 24)
                    )
                    .foregroundStyle(typedAnswer.isEmpty ? Color.lingoMuted : Color.lingoInk)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                    .environment(\.layoutDirection, .rightToLeft)

                if feedback == nil {
                    arabicKeyboard
                }
            }
        } else {
            TextField("Type your answer", text: $typedAnswer, axis: .vertical)
                .font(.custom("Fredoka-Regular", size: 17))
                .foregroundColor(Color.lingoInk)
                .tint(Color.lingoBlue)
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.lingoLine, lineWidth: 2)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(feedback != nil)
        }
    }

    private var answerReady: Bool {
        if mode == .multipleChoice {
            return selectedChoiceID != nil
        }
        return !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var multipleChoiceAnswerList: some View {
        VStack(spacing: 10) {
            ForEach(choiceOptions) { option in
                let selected = selectedChoiceID == option.id

                Button {
                    guard feedback == nil else { return }
                    selectedChoiceID = option.id
                } label: {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: course == .arabic ? .trailing : .leading, spacing: 3) {
                            Text(option.foreign)
                                .font(course == .arabic
                                      ? .custom("NotoSansArabic-Regular", size: 22)
                                      : .custom("Fredoka-Medium", size: 17))
                                .foregroundStyle(Color.lingoInk)
                                .multilineTextAlignment(course == .arabic ? .trailing : .leading)
                                .frame(maxWidth: .infinity, alignment: course == .arabic ? .trailing : .leading)

                            if course == .arabic,
                               let transliteration = option.transliteration,
                               !transliteration.isEmpty {
                                Text(transliteration)
                                    .font(.custom("Fredoka-Regular", size: 13))
                                    .foregroundStyle(Color.lingoMuted)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }

                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected ? Color.lingoGreen : Color.lingoMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(selected ? Color.lingoGreen : Color.lingoLine, lineWidth: selected ? 3 : 2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(feedback != nil)
            }
        }
    }

    private func feedbackCard(_ result: VocabFeedback, lemma: Lemma) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(
                    result == .correct ? "Correct" : "Not quite",
                    systemImage: result == .correct ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.custom("Fredoka-Medium", size: 17))
                .foregroundStyle(result == .correct ? Color.lingoGreenDark : Color.lingoWrong)
                Spacer()
                Button {
                    speaker.stop()
                    speaker.speak(lemma.foreign, course: course, rate: speechRate)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title3)
                        .foregroundStyle(Color.lingoBlue)
                }
                .buttonStyle(.plain)
            }

            Text(lemma.foreign)
                .font(course == .arabic
                      ? .custom("NotoSansArabic-Regular", size: 24)
                      : .custom("Fredoka-Medium", size: 20))
                .foregroundStyle(Color.lingoInk)
                .fixedSize(horizontal: false, vertical: true)

            if course == .arabic,
               let transliteration = lemma.transliteration,
               !transliteration.isEmpty {
                Text(transliteration)
                    .font(.custom("Fredoka-Regular", size: 14))
                    .foregroundStyle(Color.lingoMuted)
            }

            Text(lemma.english)
                .font(.custom("Fredoka-Regular", size: 15))
                .foregroundStyle(Color.lingoMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(result == .correct ? Color.lingoCorrect.opacity(0.12) : Color.lingoWrong.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var doneView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.lingoGreen)
            Text("Vocab practice complete!")
                .font(.custom("Fredoka-Medium", size: 30))
                .foregroundStyle(Color.lingoInk)
            Text("\(correctCount) / \(queue.count) correct")
                .font(.custom("Fredoka-Regular", size: 17))
                .foregroundStyle(Color.lingoMuted)
            Button("PRACTISE AGAIN") {
                startQueue()
            }
            .font(.custom("Fredoka-Medium", size: 17))
            .buttonStyle(DuoButtonStyle(
                fill: .lingoBlue,
                shadow: Color.lingoBlue.opacity(0.65)
            ))
            Spacer()
        }
        .padding(24)
    }

    private func startQueue() {
        speaker.stop()
        didReportRun = false

        var seen = Set<String>()
        let eligible = lemmas.shuffled().filter { lemma in
            let foreign = lemma.foreign.trimmingCharacters(in: .whitespacesAndNewlines)
            let english = lemma.english.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !foreign.isEmpty, !english.isEmpty else { return false }

            // Listen & Write does not need duplicate audio prompts for the same target form.
            let key = mode == .listenWrite
                ? PracticeTextNormalizer.key(foreign)
                : PracticeTextNormalizer.key(foreign) + "||" + PracticeTextNormalizer.key(english)
            return seen.insert(key).inserted
        }

        queue = Array(eligible.prefix(min(max(1, sessionLength), eligible.count)))
        index = 0
        correctCount = 0
        isDone = queue.isEmpty
        typedAnswer = ""
        feedback = nil
        if !queue.isEmpty { loadCurrent() }
    }

    private func loadCurrent() {
        typedAnswer = ""
        selectedChoiceID = nil
        choiceOptions = []
        feedback = nil

        guard let current else { return }

        if mode == .multipleChoice {
            var seenTargets = Set<String>()
            seenTargets.insert(PracticeTextNormalizer.key(current.foreign))

            let distractors = lemmas.shuffled().filter { candidate in
                guard candidate.id != current.id else { return false }
                let key = PracticeTextNormalizer.key(candidate.foreign)
                guard !key.isEmpty else { return false }
                return seenTargets.insert(key).inserted
            }

            choiceOptions = ([current] + Array(distractors.prefix(3))).shuffled()
            return
        }

        guard mode == .listenWrite else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard self.feedback == nil,
                  self.current?.id == current.id else { return }
            speaker.speak(current.foreign, course: course, rate: speechRate)
        }
    }

    private func check(_ lemma: Lemma) {
        guard feedback == nil, answerReady else { return }

        let isCorrect: Bool
        if mode == .multipleChoice {
            isCorrect = selectedChoiceID == lemma.id
        } else {
            isCorrect = QuizViewModel.answersMatch(typedAnswer, lemma.foreign)
        }

        if isCorrect {
            correctCount += 1
            feedback = .correct
        } else {
            feedback = .wrong
        }
    }

    private func advance() {
        speaker.stop()
        if index + 1 >= queue.count {
            isDone = true
            reportRunIfNeeded()
        } else {
            index += 1
            loadCurrent()
        }
    }

    private func reportRunIfNeeded() {
        guard !didReportRun else { return }
        didReportRun = true
        onFinished(queue.count)
    }

    // MARK: Arabic vocab keyboard

    private var arabicKeyboard: some View {
        let rows = [
            ["ض", "ص", "ث", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "د"],
            ["ش", "س", "ي", "ب", "ل", "ا", "ت", "ن", "م", "ك", "ط"],
            ["ئ", "ء", "ؤ", "ر", "ى", "ة", "و", "ز", "ظ"]
        ]

        return VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { key in
                        arabicKey(label: key, inserts: key)
                    }
                }
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(["أ", "إ", "آ", "ذ"], id: \.self) { key in
                    arabicKey(label: key, inserts: key)
                        .frame(width: 48)
                }
                arabicKey(label: "◌ّ", inserts: "ّ")
                    .frame(width: 48)
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Button {
                    guard !typedAnswer.isEmpty else { return }
                    typedAnswer.removeLast()
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.lingoInk)
                        .frame(width: 58, height: 44)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(typedAnswer.isEmpty)

                Button {
                    guard !typedAnswer.isEmpty, !typedAnswer.hasSuffix(" ") else { return }
                    typedAnswer.append(" ")
                } label: {
                    Text("SPACE")
                        .font(.custom("Fredoka-Medium", size: 13))
                        .tracking(0.8)
                        .foregroundStyle(Color.lingoInk)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.lingoLine, lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
                .disabled(typedAnswer.isEmpty || typedAnswer.hasSuffix(" "))
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.lingoLine, lineWidth: 1.5)
        }
    }

    private func arabicKey(label: String, inserts value: String) -> some View {
        Button {
            typedAnswer.append(contentsOf: value)
        } label: {
            Text(label)
                .font(.custom("NotoSansArabic-Medium", size: 20))
                .foregroundStyle(Color.lingoInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 43)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.lingoLine, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - LanguageTrainer-style speaking drill

private struct LanguageTrainerSpeakingPracticeView: View {
    let course: LanguageCourse
    let phrases: [PhraseEntry]
    let sessionLength: Int
    let speechRate: Double
    let onFinished: (Int) -> Void

    @StateObject private var speaker = SpeechSynthesizer()
    @StateObject private var recognizer = SpeechRecognizerService()
    @State private var queue: [PhraseEntry] = []
    @State private var index = 0
    @State private var recognisedIndices: Set<Int> = []
    @State private var mode: SpeakButtonMode = .speak
    @State private var graceSecondsLeft: Int?
    @State private var graceTask: Task<Void, Never>?
    @State private var isDone = false
    @State private var didReportRun = false

    private enum SpeakButtonMode { case speak, keepGoing, next }

    private var current: PhraseEntry? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    private var eligible: [PhraseEntry] {
        phrases.filter {
            !$0.foreign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        Group {
            if isDone {
                doneView
            } else if let current {
                mainView(current)
            } else {
                ContentUnavailableView("No speaking phrases", systemImage: "mic.slash.fill")
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Speaking")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if queue.isEmpty { startQueue() }
        }
        .onChange(of: recognizer.transcript) { _, transcript in
            handleTranscript(transcript)
        }
        .onDisappear {
            recognizer.stop()
            speaker.stop()
            cancelGrace()
        }
    }

    private func mainView(_ current: PhraseEntry) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Text("Question \(index + 1) / \(queue.count)")
                        .font(.custom("Fredoka-Regular", size: 15))
                        .foregroundStyle(Color.lingoMuted)
                    Spacer()
                    if recognizer.isRecording {
                        Label("Listening…", systemImage: "waveform")
                            .font(.custom("Fredoka-Medium", size: 15))
                            .foregroundStyle(Color.lingoPurple)
                    }
                }

                VStack(spacing: 8) {
                    Text("SAY THIS IN \(course.title.uppercased())")
                        .font(.custom("Fredoka-SemiBold", size: 12))
                        .tracking(1)
                        .foregroundStyle(Color.lingoMuted)
                    Text(current.english)
                        .font(.custom("Fredoka-Medium", size: 20))
                        .foregroundStyle(Color.lingoInk)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.lingoLine, lineWidth: 2)
                }

                targetSentence(current.foreign)
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .background(Color.lingoPurple.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                if let seconds = graceSecondsLeft {
                    Text("Keep going… \(seconds)s")
                        .font(.custom("Fredoka-Medium", size: 15))
                        .foregroundStyle(Color.lingoOrange)
                }

                if let error = recognizer.errorMessage, recognizer.isRecording {
                    Text(error)
                        .font(.custom("Fredoka-Regular", size: 13))
                        .foregroundStyle(Color.lingoWrong)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button {
                        prepareForPlayback()
                        speaker.speak(current.foreign, course: course, rate: speechRate)
                    } label: {
                        Label("Hear it", systemImage: "speaker.wave.2.fill")
                            .font(.custom("Fredoka-Medium", size: 15))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DuoButtonStyle(
                        fill: Color.lingoBlue,
                        shadow: Color.lingoBlue.opacity(0.65)
                    ))

                    Button {
                        skip()
                    } label: {
                        Text("SKIP")
                            .font(.custom("Fredoka-Medium", size: 15))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DuoButtonStyle(
                        fill: Color(.systemGray3),
                        shadow: Color(.systemGray4)
                    ))
                }

                Button(action: handleMainButton) {
                    HStack(spacing: 9) {
                        if mode == .speak { Image(systemName: "mic.fill") }
                        Text(mainButtonTitle)
                    }
                    .font(.custom("Fredoka-Medium", size: 18))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(DuoButtonStyle(fill: mainButtonFill, shadow: mainButtonShadow))
            }
            .padding(20)
            .padding(.bottom, 30)
        }
    }

    private func targetSentence(_ sentence: String) -> some View {
        let words = sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        return PracticeWordWrapLayout(spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Button {
                    prepareForPlayback()
                    let spoken = PracticeTextNormalizer.cleanWordForSpeech(word)
                    if !spoken.isEmpty {
                        speaker.speak(spoken, course: course, rate: speechRate)
                    }
                } label: {
                    Text(word)
                        .font(.custom("Fredoka-Medium", size: 21))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                        .background(recognisedIndices.contains(index) ? Color.cyan.opacity(0.34) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(recognisedIndices.contains(index) ? Color.cyan : Color.white.opacity(0.55))
                                .frame(height: 1)
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
        switch mode {
        case .speak: return .lingoPurple
        case .keepGoing: return .lingoOrange
        case .next: return .lingoGreen
        }
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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.lingoGreen)
            Text("Speaking complete!")
                .font(.custom("Fredoka-Medium", size: 32))
                .foregroundStyle(Color.lingoInk)
            Text("You worked through \(queue.count) phrases from the whole corpus.")
                .font(.custom("Fredoka-Regular", size: 15))
                .foregroundStyle(Color.lingoMuted)
                .multilineTextAlignment(.center)
            Button("PRACTISE AGAIN") {
                startQueue()
            }
            .font(.custom("Fredoka-Medium", size: 17))
            .buttonStyle(DuoButtonStyle(
                fill: .lingoPurple,
                shadow: Color.lingoPurple.opacity(0.65)
            ))
            Spacer()
        }
        .padding(24)
    }

    private func startQueue() {
        recognizer.stop()
        cancelGrace()
        didReportRun = false
        let pool = eligible.shuffled()
        queue = Array(pool.prefix(min(max(1, sessionLength), pool.count)))
        index = 0
        isDone = queue.isEmpty
        recognisedIndices = []
        mode = .speak
        if !queue.isEmpty { loadCurrent() }
    }

    private func loadCurrent() {
        recognizer.stop()
        cancelGrace()
        recognisedIndices = []
        mode = .speak
        guard let current else { return }
        speaker.speak(current.foreign, course: course, rate: speechRate)
    }

    private func handleMainButton() {
        switch mode {
        case .speak:
            beginListening()
        case .keepGoing:
            // iOS speech recognition may produce a final result while the grace timer is still
            // running. Tapping Keep Going starts a fresh recognition window without losing credit.
            if !recognizer.isRecording { beginListening() }
        case .next:
            advance()
        }
    }

    private func beginListening() {
        speaker.stop()
        Task {
            await recognizer.start(localeIdentifier: course.speechLocaleIdentifier)
        }
    }

    private func advance() {
        recognizer.stop()
        cancelGrace()
        if index + 1 >= queue.count {
            isDone = true
            reportRunIfNeeded()
        } else {
            index += 1
            loadCurrent()
        }
    }

    private func skip() {
        recognizer.stop()
        cancelGrace()
        advance()
    }

    private func prepareForPlayback() {
        recognizer.stop()
        cancelGrace()
        if mode != .next { mode = .speak }
    }

    private func handleTranscript(_ raw: String) {
        guard let current, mode != .next else { return }

        let canonical = PracticeTextNormalizer.alignedTokens(current.foreign, course: course)
        let heard = PracticeTextNormalizer.transcriptTokenSet(raw, course: course)
        var updated = recognisedIndices

        for (index, token) in canonical.enumerated() where !token.isEmpty {
            if heard.contains(token) { updated.insert(index) }
        }
        recognisedIndices = updated

        let important = PracticeTextNormalizer.importantIndices(canonical, course: course)
        let denominator = important.isEmpty
            ? canonical.indices.filter { !canonical[$0].isEmpty }
            : important
        guard !denominator.isEmpty else { return }

        let heardImportant = denominator.filter { recognisedIndices.contains($0) }.count
        let ratio = Double(heardImportant) / Double(denominator.count)

        if heardImportant == denominator.count {
            recognizer.stop()
            cancelGrace()
            mode = .next
        } else if ratio >= 0.75, graceSecondsLeft == nil {
            beginGrace()
        }
    }

    private func beginGrace() {
        mode = .keepGoing
        graceSecondsLeft = 10
        graceTask?.cancel()
        graceTask = Task { @MainActor in
            for remaining in stride(from: 9, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                graceSecondsLeft = remaining
            }
            guard !Task.isCancelled else { return }
            recognizer.stop()
            graceSecondsLeft = nil
            mode = .next
        }
    }

    private func cancelGrace() {
        graceTask?.cancel()
        graceTask = nil
        graceSecondsLeft = nil
    }

    private func reportRunIfNeeded() {
        guard !didReportRun else { return }
        didReportRun = true
        onFinished(queue.count)
    }
}

// MARK: - LanguageTrainer-style lemma matching drill

private struct LanguageTrainerLemmaMatchView: View {
    let course: LanguageCourse
    let lemmas: [Lemma]
    let speechRate: Double
    let onFinished: (Int) -> Void

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
    @State private var didReportRun = false

    private let visibleCount = 6

    private var pairs: [PracticeLemmaPair] {
        lemmas.map { PracticeLemmaPair(lemma: $0) }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Label(format(secondsLeft), systemImage: "timer")
                        .font(.custom("Fredoka-Medium", size: 15))
                        .foregroundStyle(Color.lingoInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text("\(matches) matched")
                        .font(.custom("Fredoka-Medium", size: 15))
                        .foregroundStyle(Color.lingoGreen)

                    Spacer()

                    Button {
                        soundEnabled.toggle()
                    } label: {
                        Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(soundEnabled ? Color.lingoGreen : Color.lingoWrong)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Text(course.title.uppercased())
                    Spacer()
                    Text("ENGLISH")
                }
                .font(.custom("Fredoka-SemiBold", size: 12))
                .tracking(1)
                .foregroundStyle(Color.lingoMuted)
                .padding(.horizontal, 4)

                HStack(alignment: .top, spacing: 12) {
                    matchColumn(ids: leftOrder, isLeft: true)
                    matchColumn(ids: rightOrder, isLeft: false)
                }

                Spacer(minLength: 0)
            }
            .padding(18)

            if timeUp {
                VStack(spacing: 14) {
                    Image(systemName: "timer.circle.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(Color.lingoGreen)
                    Text("Time's up!")
                        .font(.custom("Fredoka-Medium", size: 30))
                        .foregroundStyle(Color.lingoInk)
                    Text("\(matches) lemma pair\(matches == 1 ? "" : "s") matched")
                        .font(.custom("Fredoka-Regular", size: 17))
                        .foregroundStyle(Color.lingoMuted)
                    Button("PLAY AGAIN") {
                        startGame()
                    }
                    .font(.custom("Fredoka-Medium", size: 17))
                    .buttonStyle(DuoButtonStyle(
                        fill: .lingoGreen,
                        shadow: Color.lingoGreen.opacity(0.65)
                    ))
                }
                .padding(24)
                .frame(maxWidth: 340)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                .padding(24)
            }
        }
        .navigationTitle("Matching")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if visible.isEmpty { startGame() }
        }
        .task(id: runID) {
            while !Task.isCancelled && !timeUp {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !timeUp else { return }
                    secondsLeft -= 1
                    if secondsLeft <= 0 {
                        secondsLeft = 0
                        timeUp = true
                        selectedLeft = nil
                        selectedRight = nil
                        reportRunIfNeeded()
                    }
                }
            }
        }
        .onDisappear {
            speaker.stop()
        }
    }

    private func matchColumn(ids: [String], isLeft: Bool) -> some View {
        VStack(spacing: 10) {
            ForEach(ids, id: \.self) { id in
                if let pair = visible.first(where: { $0.id == id }) {
                    Button {
                        if isLeft { handleLeftTap(pair) }
                        else { handleRightTap(pair) }
                    } label: {
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
        leftOrder = ids.shuffled()
        rightOrder = ids.shuffled()
        selectedLeft = nil
        selectedRight = nil
        dissolvingIDs = []
        secondsLeft = 120
        timeUp = false
        matches = 0
        didReportRun = false
        runID = UUID()
    }

    private func handleLeftTap(_ pair: PracticeLemmaPair) {
        guard !timeUp else { return }
        if soundEnabled {
            speaker.speak(pair.foreign, course: course, rate: speechRate)
        }
        selectedLeft = pair.id
        resolveIfReady()
    }

    private func handleRightTap(_ pair: PracticeLemmaPair) {
        guard !timeUp else { return }
        selectedRight = pair.id
        resolveIfReady()
    }

    private func resolveIfReady() {
        guard let left = selectedLeft, let right = selectedRight else { return }

        if left == right {
            selectedLeft = nil
            selectedRight = nil
            matches += 1

            withAnimation(.easeInOut(duration: 0.22)) {
                dissolvingIDs.insert(left)
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 240_000_000)
                replaceMatched(id: left)
                dissolvingIDs.remove(left)
            }
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                selectedLeft = nil
                selectedRight = nil
            }
        }
    }

    private func replaceMatched(id: String) {
        visible.removeAll { $0.id == id }
        leftOrder.removeAll { $0 == id }
        rightOrder.removeAll { $0 == id }

        if let next = deck.first {
            deck.removeFirst()
            visible.append(next)
            leftOrder.insert(next.id, at: Int.random(in: 0...leftOrder.count))
            rightOrder.insert(next.id, at: Int.random(in: 0...rightOrder.count))
        }
    }

    private func reportRunIfNeeded() {
        guard !didReportRun else { return }
        didReportRun = true
        onFinished(matches)
    }

    private func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PracticeLemmaPair: Identifiable, Hashable {
    let id: String
    let foreign: String
    let english: String

    init(lemma: Lemma) {
        foreign = lemma.foreign
        english = lemma.english
        id = PracticeTextNormalizer.key(lemma.foreign) + "||" + PracticeTextNormalizer.key(lemma.english)
    }
}

private struct LemmaMatchToken: View {
    let text: String
    let isSelected: Bool
    let accent: Color

    var body: some View {
        Text(text)
            .font(.custom("Fredoka-Medium", size: 16))
            .foregroundStyle(Color.lingoInk)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.65)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68)
            .background(isSelected ? Color.lingoGold.opacity(0.25) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.lingoGold : accent.opacity(0.7), lineWidth: isSelected ? 3 : 2)
            }
            .shadow(color: .black.opacity(0.06), radius: 0, y: 3)
    }
}

// MARK: - Shared speaking-practice helpers

private enum PracticeTextNormalizer {
    private static let frenchStopWords: Set<String> = [
        "je", "j", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles",
        "le", "la", "les", "un", "une", "des", "du", "de", "d", "ce", "cet", "cette", "ces",
        "et", "ou", "mais", "que", "qui", "ne", "n", "pas", "y", "en", "mon", "ton", "son",
        "notre", "votre", "leur", "leurs", "au", "aux"
    ]

    private static let spanishStopWords: Set<String> = [
        "yo", "tu", "el", "ella", "nosotros", "nosotras", "vosotros", "vosotras", "ellos", "ellas",
        "la", "los", "las", "un", "una", "unos", "unas", "de", "del", "a", "al", "en", "y", "o",
        "pero", "que", "lo", "se", "me", "te", "nos", "os", "mi", "su", "sus", "por", "para"
    ]

    static func key(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanWordForSpeech(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
    }

    static func alignedTokens(_ sentence: String, course: LanguageCourse) -> [String] {
        sentence
            .split(whereSeparator: { $0.isWhitespace })
            .map { canonicalToken(String($0), course: course) }
    }

    static func transcriptTokenSet(_ transcript: String, course: LanguageCourse) -> Set<String> {
        Set(
            transcript
                .replacingOccurrences(of: "’", with: "'")
                .split(whereSeparator: { $0.isWhitespace })
                .map { canonicalToken(String($0), course: course) }
                .filter { !$0.isEmpty }
        )
    }

    static func importantIndices(_ tokens: [String], course: LanguageCourse) -> [Int] {
        let stopWords = course == .french ? frenchStopWords : spanishStopWords
        return tokens.enumerated().compactMap { index, token in
            guard !token.isEmpty else { return nil }
            return stopWords.contains(token) ? nil : index
        }
    }

    private static func canonicalToken(_ raw: String, course: LanguageCourse) -> String {
        var value = raw
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)

        if course == .french {
            let homophones = [
                "aux": "au", "ont": "on", "peux": "peu", "peut": "peu",
                "sont": "son", "sans": "sang", "vingt": "vin"
            ]
            if let mapped = homophones[value] { value = mapped }
        }
        return value
    }
}

private struct PracticeWordWrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
