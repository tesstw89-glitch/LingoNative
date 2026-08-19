import SwiftUI

struct CoursePickerView: View {
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LINGO NATIVE")
                        .font(.caption.weight(.black))
                        .tracking(1.4)
                        .foregroundStyle(Color.lingoGreen)
                    Text("What are we practising?")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(Color.lingoInk)
                    Text("Your everyday language course")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.lingoMuted)
                }

                HStack(spacing: 10) {
                    StatPill(systemImage: "flame.fill", value: "\(progress.currentStreak)", tint: Color.lingoOrange)
                    StatPill(systemImage: "bolt.fill", value: "\(progress.xp) XP", tint: Color.lingoGold)
                    if settings.heartsEnabled {
                        StatPill(systemImage: "heart.fill", value: "\(progress.hearts)", tint: .red)
                    }
                }

                VStack(spacing: 16) {
                    ForEach(LanguageCourse.allCases) { course in
                        NavigationLink {
                            CourseHomeView(course: course, progress: progress, settings: settings)
                        } label: {
                            CourseCard(course: course)
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("LOCAL-ONLY")
                        .font(.caption.weight(.black))
                        .foregroundStyle(Color.lingoMuted)
                    Text("No account, no server, no subscription. Your course content and progress live on this iPhone.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.lingoMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarHidden(true)
    }
}

private struct CourseCard: View {
    let course: LanguageCourse

    var body: some View {
        HStack(spacing: 18) {
            Text(course.flag)
                .font(.system(size: 48))
                .frame(width: 66, height: 66)
                .background(Color.white)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(course.title)
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
                Text("Rotating real-life topics")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
        }
        .padding(18)
        .background(course == .french ? Color.lingoBlue : Color.lingoGreen)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 0, y: 5)
    }
}
