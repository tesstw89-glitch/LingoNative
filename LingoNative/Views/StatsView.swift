import SwiftUI

struct StatsView: View {
    let corpus: Corpus
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    private var courseStats: (seen: Int, correct: Int, wrong: Int, mastered: Int) {
        var seen = 0
        var correct = 0
        var wrong = 0
        var mastered = 0
        for phrase in corpus.entries {
            let stats = progress.stats(course: corpus.course, phrase: phrase)
            if stats.seen > 0 { seen += 1 }
            correct += stats.correct
            wrong += stats.wrong
            if stats.mastery >= 0.8 { mastered += 1 }
        }
        return (seen, correct, wrong, mastered)
    }

    private var courseAccuracy: Int {
        let attempts = courseStats.correct + courseStats.wrong
        guard attempts > 0 else { return 0 }
        return Int((Double(courseStats.correct) / Double(attempts) * 100).rounded())
    }

    private var completedLessons: Int {
        progress.completedNodeIDs.filter { $0.hasPrefix("\(corpus.course.rawValue)-unit-") }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                overviewGrid
                dailyQuests
                sevenDayActivity
                masteryCard
            }
            .padding(20)
            .padding(.bottom, 50)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var overviewGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(title: "XP", value: "\(progress.xp)", icon: "bolt.fill", tint: Color.lingoGold)
            metricCard(title: "Streak", value: "\(progress.currentStreak) days", icon: "flame.fill", tint: Color.lingoOrange)
            metricCard(title: "Accuracy", value: "\(courseAccuracy)%", icon: "scope", tint: Color.lingoGreen)
            metricCard(title: "Lessons", value: "\(completedLessons)", icon: "checkmark.seal.fill", tint: Color.lingoBlue)
        }
    }

    private func metricCard(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.weight(.black))
                .foregroundStyle(Color.lingoInk)
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(Color.lingoMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.lingoLine, lineWidth: 2)
        }
    }

    private var dailyQuests: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DAILY QUESTS")
                .font(.caption.weight(.black))
                .tracking(1.2)
                .foregroundStyle(Color.lingoMuted)

            questRow(
                title: "Earn \(settings.dailyGoalXP) XP",
                value: progress.todayXP,
                target: settings.dailyGoalXP,
                icon: "bolt.fill",
                tint: Color.lingoGold
            )
            questRow(
                title: "Get 10 answers right",
                value: progress.todayActivity.correct,
                target: 10,
                icon: "checkmark.circle.fill",
                tint: Color.lingoGreen
            )
            questRow(
                title: "Finish 2 sessions",
                value: progress.todayActivity.sessions,
                target: 2,
                icon: "flag.checkered",
                tint: Color.lingoPurple
            )
        }
    }

    private func questRow(title: String, value: Int, target: Int, icon: String, tint: Color) -> some View {
        let complete = value >= target
        return HStack(spacing: 13) {
            Image(systemName: complete ? "checkmark.circle.fill" : icon)
                .font(.title3)
                .foregroundStyle(complete ? Color.lingoGreen : tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.black))
                    Spacer()
                    Text("\(min(value, target))/\(target)")
                        .font(.caption.weight(.black))
                        .foregroundStyle(Color.lingoMuted)
                }
                ProgressView(value: Double(min(value, target)), total: Double(max(1, target)))
                    .tint(complete ? Color.lingoGreen : tint)
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sevenDayActivity: some View {
        let days = progress.activityLastSevenDays()
        let maxXP = max(1, days.map { $0.1.xp }.max() ?? 1)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("LAST 7 DAYS")
                    .font(.caption.weight(.black))
                    .tracking(1.2)
                    .foregroundStyle(Color.lingoMuted)
                Spacer()
                Text("Best streak: \(progress.longestStreak)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.lingoMuted)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, item in
                    let date = item.0
                    let activity = item.1
                    VStack(spacing: 7) {
                        Text("\(activity.xp)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.lingoMuted)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(activity.xp > 0 ? Color.lingoGreen : Color(.systemGray5))
                            .frame(height: max(6, CGFloat(activity.xp) / CGFloat(maxXP) * 90))
                        Text(Self.dayFormatter.string(from: date))
                            .font(.caption2.weight(.black))
                            .foregroundStyle(Color.lingoMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 130, alignment: .bottom)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var masteryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(corpus.course.flag) \(corpus.course.title.uppercased())")
                .font(.caption.weight(.black))
                .foregroundStyle(corpus.course == .french ? Color.lingoBlue : Color.lingoGreen)
            Text("\(courseStats.seen) of \(corpus.entries.count) phrases practised")
                .font(.headline.weight(.black))
                .foregroundStyle(Color.lingoInk)
            ProgressView(value: Double(courseStats.seen), total: Double(max(1, corpus.entries.count)))
                .tint(corpus.course == .french ? Color.lingoBlue : Color.lingoGreen)
            Text("\(courseStats.mastered) phrases at 80%+ mastery")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.lingoMuted)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
}
