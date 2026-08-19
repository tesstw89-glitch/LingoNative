import SwiftUI

struct LearnPathView: View {
    let corpus: Corpus
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 34) {
                header

                ForEach(Array(corpus.units.enumerated()), id: \.element.id) { index, unit in
                    UnitSectionView(
                        unit: unit,
                        unitIndex: index,
                        sectionNumber: sectionNumber(at: index),
                        startsTopicBlock: startsTopicBlock(at: index),
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
        .navigationTitle("Learn")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            Text(corpus.course.flag)
                .font(.system(size: 48))
            Text("Everyday \(corpus.course.title)")
                .font(.title2.weight(.black))
                .foregroundStyle(Color.lingoInk)
            Text("\(corpus.topics.count) topics · \(corpus.entries.count) phrases · \(corpus.units.count) units")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.lingoMuted)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(corpus.topics) { topic in
                        Label(topic.title, systemImage: topic.icon)
                            .font(.caption2.weight(.black))
                            .foregroundStyle(topicAccent(topic.id))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(topicAccent(topic.id).opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Daily goal", systemImage: "target")
                        .font(.caption.weight(.black))
                    Spacer()
                    Text("\(min(progress.todayXP, settings.dailyGoalXP))/\(settings.dailyGoalXP) XP")
                        .font(.caption.weight(.black))
                }
                ProgressView(value: Double(min(progress.todayXP, settings.dailyGoalXP)), total: Double(max(1, settings.dailyGoalXP)))
                    .tint(corpus.course == .french ? Color.lingoBlue : Color.lingoGreen)
            }
            .padding(14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.lingoLine, lineWidth: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
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
        case "opinions": return corpus.course == .french ? Color.lingoBlue : Color.lingoGreen
        default: return Color.lingoBlue
        }
    }
}
