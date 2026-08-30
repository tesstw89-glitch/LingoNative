import SwiftUI

struct StatsView: View {
    let corpus: Corpus
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    private var courseStats: (seen: Int, correct: Int, wrong: Int, mastered: Int) {
        let prefix = "\(corpus.course.rawValue):"
        let values = progress.phraseProgress
            .filter { $0.key.hasPrefix(prefix) }
            .map(\.value)

        let seen = values.filter { $0.seen > 0 }.count
        let correct = values.reduce(0) { $0 + $1.correct }
        let wrong = values.reduce(0) { $0 + $1.wrong }
        let mastered = values.filter { $0.mastery >= 0.8 }.count

        return (seen, correct, wrong, mastered)
    }

    private var totalPhraseCount: Int {
        corpus.topics.reduce(0) { $0 + $1.phraseCount }
    }

    private var courseAccuracy: Int {
        let attempts = courseStats.correct + courseStats.wrong
        guard attempts > 0 else { return 0 }

        return Int(
            (
                Double(courseStats.correct)
                / Double(attempts)
                * 100
            ).rounded()
        )
    }

    private var completedLessons: Int {
        progress.completedNodeIDs
            .filter {
                $0.hasPrefix("\(corpus.course.rawValue)-unit-")
            }
            .count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                overviewGrid
                dailyQuests
                sevenDayActivity
                adaptiveLearningCard
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
        LazyVGrid(
            columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ],
            spacing: 12
        ) {
            metricCard(
                title: "XP",
                value: "\(progress.xp)",
                icon: "bolt.fill",
                tint: Color.lingoGold
            )

            metricCard(
                title: "Streak",
                value: "\(progress.currentStreak) days",
                icon: "flame.fill",
                tint: Color.lingoOrange
            )

            metricCard(
                title: "Accuracy",
                value: "\(courseAccuracy)%",
                icon: "scope",
                tint: Color.lingoGreen
            )

            metricCard(
                title: "Lessons",
                value: "\(completedLessons)",
                icon: "checkmark.seal.fill",
                tint: Color.lingoBlue
            )
        }
    }

    private func metricCard(
        title: String,
        value: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)

            Text(value)
                .font(.custom("Fredoka-Medium", size: 26))
                .foregroundStyle(Color.lingoInk)

            Text(title)
                .font(.custom("Fredoka-SemiBold", size: 13))
                .foregroundStyle(Color.lingoMuted)
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .padding(16)
        .background(Color.white)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
            .stroke(
                Color.lingoLine,
                lineWidth: 2
            )
        }
    }

    private var dailyQuests: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DAILY QUESTS")
                .font(.custom("Fredoka-SemiBold", size: 13))
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

    private func questRow(
        title: String,
        value: Int,
        target: Int,
        icon: String,
        tint: Color
    ) -> some View {
        let complete = value >= target

        return HStack(spacing: 13) {
            Image(
                systemName:
                    complete
                    ? "checkmark.circle.fill"
                    : icon
            )
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(
                complete
                    ? Color.lingoGreen
                    : tint
            )
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.custom("Fredoka-Medium", size: 15))
                        .foregroundStyle(Color.lingoInk)

                    Spacer()

                    Text("\(min(value, target))/\(target)")
                        .font(.custom("Fredoka-Regular", size: 13))
                        .foregroundStyle(Color.lingoMuted)
                }

                ProgressView(
                    value: Double(min(value, target)),
                    total: Double(max(1, target))
                )
                .tint(
                    complete
                        ? Color.lingoGreen
                        : tint
                )
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
        )
    }

    private var sevenDayActivity: some View {
        let days = progress.activityLastSevenDays()

        let maxXP = max(
            1,
            days.map { $0.1.xp }.max() ?? 1
        )

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("LAST 7 DAYS")
                    .font(.custom("Fredoka-SemiBold", size: 13))
                    .tracking(1.2)
                    .foregroundStyle(Color.lingoMuted)

                Spacer()

                Text("Best streak: \(progress.longestStreak)")
                    .font(.custom("Fredoka-Regular", size: 13))
                    .foregroundStyle(Color.lingoMuted)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(
                    Array(days.enumerated()),
                    id: \.offset
                ) { _, item in

                    let date = item.0
                    let activity = item.1

                    VStack(spacing: 7) {
                        Text("\(activity.xp)")
                            .font(.custom("Fredoka-Regular", size: 12))
                            .foregroundStyle(Color.lingoMuted)

                        RoundedRectangle(
                            cornerRadius: 6,
                            style: .continuous
                        )
                        .fill(
                            activity.xp > 0
                                ? Color.lingoGreen
                                : Color(.systemGray5)
                        )
                        .frame(
                            height: max(
                                6,
                                CGFloat(activity.xp)
                                / CGFloat(maxXP)
                                * 90
                            )
                        )

                        Text(
                            Self.dayFormatter.string(
                                from: date
                            )
                        )
                        .font(.custom("Fredoka-Medium", size: 12))
                        .foregroundStyle(Color.lingoMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(
                height: 130,
                alignment: .bottom
            )
        }
        .padding(16)
        .background(Color.white)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
        )
    }

    private var adaptiveLearningCard: some View {
        let observations =
            progress.adaptiveObservationCount(
                course: corpus.course
            )

        let active = observations >= 60

        let accent =
            active
                ? Color.lingoGreen
                : Color.lingoPurple

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)

                Text(
                    active
                        ? "ADAPTIVE LEARNER · ACTIVE"
                        : "ADAPTIVE LEARNER · SHADOW MODE"
                )
                .font(.custom("Fredoka-SemiBold", size: 13))
                .tracking(0.8)
                .foregroundStyle(accent)
            }

            if active {
                Text(
                    "Learnt from \(observations) answered exercises"
                )
                .font(.custom("Fredoka-Medium", size: 18))
                .foregroundStyle(Color.lingoInk)

                Text(
                    "It now chooses among exercises your learning stage allows, aiming for about a 78% predicted chance of success while still exploring occasionally."
                )
                .font(.custom("Fredoka-Regular", size: 15))
                .foregroundStyle(Color.lingoMuted)

            } else {
                Text(
                    "\(observations) of 60 answers collected"
                )
                .font(.custom("Fredoka-Medium", size: 18))
                .foregroundStyle(Color.lingoInk)

                ProgressView(
                    value: Double(observations),
                    total: 60
                )
                .tint(accent)

                Text(
                    "For now it only predicts in the background. At 60 answers it starts helping choose difficulty — never bypassing the learning-stage or token-construction gates."
                )
                .font(.custom("Fredoka-Regular", size: 15))
                .foregroundStyle(Color.lingoMuted)
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
            .stroke(
                accent.opacity(0.25),
                lineWidth: 2
            )
        }
    }

    private var masteryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "\(corpus.course.flag) \(corpus.course.title.uppercased())"
            )
            .font(.custom("Fredoka-SemiBold", size: 13))
            .foregroundStyle(
                corpus.course == .french
                    ? Color.lingoBlue
                    : Color.lingoGreen
            )

            Text(
                "\(courseStats.seen) of \(totalPhraseCount) phrases practised"
            )
            .font(.custom("Fredoka-Medium", size: 18))
            .foregroundStyle(Color.lingoInk)

            ProgressView(
                value: Double(courseStats.seen),
                total: Double(
                    max(1, totalPhraseCount)
                )
            )
            .tint(
                corpus.course == .french
                    ? Color.lingoBlue
                    : Color.lingoGreen
            )

            Text(
                "\(courseStats.mastered) phrases at 80%+ mastery"
            )
            .font(.custom("Fredoka-Regular", size: 15))
            .foregroundStyle(Color.lingoMuted)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
}
