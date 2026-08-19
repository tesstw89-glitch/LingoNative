import SwiftUI

struct CoursePickerView: View {
    @ObservedObject var progress: ProgressStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LINGO NATIVE")
                        .font(.caption.weight(.black))
                        .tracking(1.4)
                        .foregroundStyle(.lingoGreen)
                    Text("What are we practising?")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(.lingoInk)
                    Text("Opinions & Reactions · prototype course")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.lingoMuted)
                }

                HStack(spacing: 10) {
                    StatPill(systemImage: "heart.fill", value: "\(progress.hearts)", tint: .red)
                    StatPill(systemImage: "bolt.fill", value: "\(progress.xp) XP", tint: .lingoGold)
                }

                VStack(spacing: 16) {
                    ForEach(LanguageCourse.allCases) { course in
                        NavigationLink {
                            LearnPathView(course: course, progress: progress)
                        } label: {
                            CourseCard(course: course)
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("V0.1")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.lingoMuted)
                    Text("The lesson path is generated directly from your source headings/contexts. Each tap creates a fresh random session from that unit’s phrase pool.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.lingoMuted)
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
                Text("Opinions & Reactions")
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
