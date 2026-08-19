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
        let session = makeSession(mode: mode, pool: pool)

        NavigationLink {
            QuizView(session: session, progress: progress, settings: settings)
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
                    Text(mode.subtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.lingoMuted)
                    Text("\(pool.count) phrase\(pool.count == 1 ? "" : "s") available")
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
        .disabled(pool.isEmpty)
        .opacity(pool.isEmpty ? 0.5 : 1)
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

    private func phrasePool(for mode: PracticeMode) -> [PhraseEntry] {
        switch mode {
        case .quick, .typing, .listening, .speaking, .matching:
            return corpus.entries
        case .bookmarks:
            return progress.bookmarkedPhrases(course: corpus.course, from: corpus.entries)
        case .mistakes:
            return progress.phrasesWithMistakes(course: corpus.course, from: corpus.entries)
        case .weak:
            return progress.weakestPhrases(course: corpus.course, from: corpus.entries)
        case .lemma:
            return corpus.entries.filter { !$0.lemmas.isEmpty }
        }
    }

    private func makeSession(mode: PracticeMode, pool: [PhraseEntry]) -> QuizSession {
        let types: Set<ExerciseType>
        switch mode {
        case .quick, .bookmarks:
            types = settings.enabledExerciseTypes
        case .mistakes, .weak:
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

    private func accent(for mode: PracticeMode) -> Color {
        switch mode {
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
