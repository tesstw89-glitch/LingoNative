import SwiftUI

struct CoursePickerView: View {
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LINGO NATIVE")
                        .font(.custom("Fredoka-SemiBold", size: 13))
                        .tracking(1.4)
                        .foregroundStyle(Color.lingoGreen)

                    Text("What are we practising?")
                        .font(.custom("Fredoka-Regular", size: 34))
                        .foregroundStyle(Color.lingoInk)

                    Text("Your everyday language course")
                        .font(.custom("Fredoka-Regular", size: 16))
                        .foregroundStyle(Color.lingoMuted)
                }

                HStack(spacing: 10) {
                    StatPill(
                        systemImage: "flame.fill",
                        value: "\(progress.currentStreak)",
                        tint: Color.lingoOrange
                    )

                    StatPill(
                        systemImage: "bolt.fill",
                        value: "\(progress.xp) XP",
                        tint: Color.lingoGold
                    )

                    if settings.heartsEnabled {
                        StatPill(
                            systemImage: "heart.fill",
                            value: "\(progress.hearts)",
                            tint: .red
                        )
                    }
                }

                VStack(spacing: 16) {
                    ForEach(LanguageCourse.allCases) { course in
                        NavigationLink {
                            CourseHomeView(
                                course: course,
                                progress: progress,
                                settings: settings
                            )
                        } label: {
                            CourseCard(course: course)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarHidden(true)
        .task {
            CourseCorpusCache.shared.prewarmFromDisk()
        }
    }
}

private struct CourseCard: View {
    let course: LanguageCourse

    var body: some View {
        HStack(spacing: 18) {
            flagView
                .frame(width: 66, height: 66)

            VStack(alignment: .leading, spacing: 5) {
                Text(course.title)
                    .font(.custom("Fredoka-Medium", size: 28))
                    .foregroundStyle(.white)

                Text(course == .arabic ? "Everyday Arabic · with transliteration" : "Rotating real-life topics")
                    .font(.custom("Fredoka-Regular", size: 16))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(18)
        .background(cardColor)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 0, y: 5)
    }

    @ViewBuilder
    private var flagView: some View {
        switch course {
        case .french:
            Image("French_flag")
                .resizable()
                .scaledToFit()
        case .spanish:
            Image("Spanish_flag")
                .resizable()
                .scaledToFit()
        case .arabic:
            Image("Arabic_flag")
                .resizable()
                .scaledToFit()
        }
    }

    private var cardColor: Color {
        switch course {
        case .french: return Color.lingoBlue
        case .spanish: return Color.lingoGreen
        case .arabic: return Color.lingoPurple
        }
    }
}
