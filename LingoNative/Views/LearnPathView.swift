import SwiftUI

struct LearnPathView: View {
    let corpus: Corpus
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    @Environment(\.dismiss) private var dismiss
    @State private var didAutoScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 34) {
                    header

                    ForEach(Array(corpus.units.enumerated()), id: \.element.id) { index, unit in
                        UnitSectionView(
                            unit: unit,
                            unitIndex: index,
                            sectionNumber: sectionNumber(at: index),
                            startsTopicBlock: startsTopicBlock(at: index),
                            activeNodeID: activeNodeID,
                            course: corpus.course,
                            allUnits: corpus.units,
                            allPhrases: corpus.entries,
                            progress: progress,
                            settings: settings
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 60)
            }
            .background(Color(.systemGroupedBackground))
            .onAppear {
                guard !didAutoScroll else { return }
                didAutoScroll = true
                scrollToActive(using: proxy, animated: false)
            }
            .onChange(of: activeNodeID) { _, _ in
                scrollToActive(using: proxy, animated: true)
            }
        }
        .navigationTitle("Learn")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(corpus.course == .french ? "French_flag" : "Spanish_flag")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.black))
                            .foregroundStyle(Color.lingoMuted)
                    }
                }
                .accessibilityLabel("Change language")
            }

            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(corpus.course.title)
                        .font(.subheadline.weight(.black))
                    if let activeTopicTitle {
                        Text(activeTopicTitle)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.lingoMuted)
                    }
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if settings.heartsEnabled {
                        Label("\(progress.hearts)", systemImage: "heart.fill")
                            .foregroundStyle(.red)
                    }
                    Label("\(progress.xp)", systemImage: "bolt.fill")
                        .foregroundStyle(Color.lingoGold)
                }
                .font(.subheadline.weight(.black))
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(corpus.course == .french ? "French_flag" : "Spanish_flag")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
               .foregroundStyle(Color.lingoInk)
            Text("\(corpus.topics.count) topics · \(corpus.entries.count) phrases · \(corpus.units.count) units")
                .font(.custom("Fredoka-Medium", size: 16))
                .foregroundStyle(Color.lingoMuted)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(corpus.topics) { topic in
                        Label(topic.title, systemImage: topic.icon)
                            .font(.custom("Fredoka-SemiBold", size: 14))
                            .foregroundStyle(topicAccent(topic.id))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(topicAccent(topic.id).opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            goalsCard
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var goalsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Today’s goals", systemImage: "target")
                    .font(.custom("Fredoka-Medium", size: 18))
                Spacer()
                if progress.currentStreak > 0 {
                    Label("\(progress.currentStreak)", systemImage: "flame.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(Color.lingoOrange)
                }
            }

            ForEach(dailyQuests) { quest in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(quest.title, systemImage: quest.icon)
                            .font(.custom("Fredoka-Light", size: 16))                            .foregroundStyle(Color.lingoInk)
                        Spacer()
                        Text("\(min(quest.value, quest.goal))/\(quest.goal)")
                            .font(.custom("Fredoka-Light", size: 15))                            .foregroundStyle(quest.complete ? Color.lingoGreenDark : Color.lingoMuted)
                    }

                    ProgressView(value: Double(min(quest.value, quest.goal)), total: Double(max(1, quest.goal)))
                        .tint(quest.complete ? Color.lingoGreen : (corpus.course == .french ? Color.lingoBlue : Color.lingoGreen))
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.lingoLine, lineWidth: 2)
        }
    }

    private var dailyQuests: [DailyQuestRow] {
        let today = progress.todayActivity
        return [
            DailyQuestRow(
                id: "xp",
                title: "Earn \(settings.dailyGoalXP) XP",
                icon: "bolt.fill",
                value: progress.todayXP,
                goal: settings.dailyGoalXP
            ),
            DailyQuestRow(
                id: "sessions",
                title: "Finish 2 sessions",
                icon: "checkmark.seal.fill",
                value: today.sessions,
                goal: 2
            ),
            DailyQuestRow(
                id: "correct",
                title: "Get 10 answers right",
                icon: "sparkles",
                value: today.correct,
                goal: 10
            )
        ]
    }

    private var activeNodeID: String? {
        for unit in corpus.units {
            for node in unit.nodes() where !progress.isCompleted(node.id) {
                return node.id
            }
        }
        return nil
    }

    private var activeTopicTitle: String? {
        guard let activeNodeID else { return corpus.units.last?.topicTitle }
        return corpus.units.first { unit in
            unit.nodes().contains { $0.id == activeNodeID }
        }?.topicTitle
    }

    private func scrollToActive(using proxy: ScrollViewProxy, animated: Bool) {
        guard let activeNodeID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if animated {
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(activeNodeID, anchor: .center)
                }
            } else {
                proxy.scrollTo(activeNodeID, anchor: .center)
            }
        }
    }

    private func startsTopicBlock(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return corpus.units[index - 1].topicID != corpus.units[index].topicID
    }

    private func sectionNumber(at index: Int) -> Int {
        guard index > 0 else { return 1 }
        var section = 1
        for offset in 1...index where corpus.units[offset - 1].topicID != corpus.units[offset].topicID {
            section += 1
        }
        return section
    }

    private func topicAccent(_ topicID: String) -> Color {
        switch topicID {
        case "clothes": return Color.lingoPurple
        case "places": return Color.lingoOrange
        case "getting_around": return .teal
        case "opinions": return corpus.course == .french ? Color.lingoBlue : Color.lingoGreen
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
        default: return Color.lingoBlue
        }
    }
}

private struct DailyQuestRow: Identifiable {
    let id: String
    let title: String
    let icon: String
    let value: Int
    let goal: Int

    var complete: Bool { value >= goal }
}
