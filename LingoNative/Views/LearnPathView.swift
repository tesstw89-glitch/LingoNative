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
            Text("Opinions & Reactions")
                .font(.title2.weight(.black))
                .foregroundStyle(Color.lingoInk)
            Text("\(corpus.entries.count) phrases · \(corpus.units.count) units")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.lingoMuted)

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
}
