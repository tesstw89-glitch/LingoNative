import SwiftUI

struct UnitSectionView: View {
    let unit: LearningUnit
    let unitIndex: Int
    let sectionNumber: Int
    let startsTopicBlock: Bool
    let course: LanguageCourse
    let allUnits: [LearningUnit]
    let allPhrases: [PhraseEntry]
    @ObservedObject var progress: ProgressStore
    @ObservedObject var settings: SettingsStore

    private let offsets: [CGFloat] = [0, 46, 72, 38, -16, -58, -76, -38]

    var body: some View {
        VStack(spacing: 22) {
            if startsTopicBlock {
                topicHeader
            }

            unitBanner

            VStack(spacing: 24) {
                ForEach(Array(unit.nodes().enumerated()), id: \.element.id) { nodeIndex, node in
                    let completed = progress.isCompleted(node.id)
                    let unlocked = isUnlocked(nodeIndex: nodeIndex)

                    Group {
                        if unlocked || completed {
                            NavigationLink {
                                QuizView(
                                    session: .lesson(
                                        course: course,
                                        unit: unit,
                                        node: node,
                                        allPhrases: allPhrases,
                                        exerciseTypes: settings.enabledExerciseTypes
                                    ),
                                    progress: progress,
                                    settings: settings
                                )
                            } label: {
                                LessonNodeView(number: nodeIndex + 1, completed: completed, unlocked: true)
                            }
                            .buttonStyle(.plain)
                        } else {
                            LessonNodeView(number: nodeIndex + 1, completed: false, unlocked: false)
                        }
                    }
                    .offset(x: offsets[nodeIndex % offsets.count])
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var topicHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: unit.topicIcon)
                .font(.headline.weight(.black))
                .foregroundStyle(topicAccent)
                .frame(width: 38, height: 38)
                .background(topicAccent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("SECTION \(sectionNumber)")
                    .font(.caption2.weight(.black))
                    .tracking(1.2)
                    .foregroundStyle(Color.lingoMuted)
                Text(unit.topicTitle)
                    .font(.title3.weight(.black))
                    .foregroundStyle(Color.lingoInk)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, sectionNumber == 1 ? 0 : 10)
    }

    private var unitBanner: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("UNIT \(unitIndex + 1)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white.opacity(0.85))
                Text(unit.title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(unit.phrases.count) phrases · \(unit.nodes().count) lesson\(unit.nodes().count == 1 ? "" : "s")")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 8)
            Image(systemName: unit.topicIcon)
                .font(.title2)
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(18)
        .background(topicAccent)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var topicAccent: Color {
        switch unit.topicID {
        case "clothes": return Color.lingoPurple
        case "places": return Color.lingoOrange
        case "opinions": return course == .french ? Color.lingoBlue : Color.lingoGreen
        default: return Color.lingoBlue
        }
    }

    private func isUnlocked(nodeIndex: Int) -> Bool {
        if unitIndex == 0 && nodeIndex == 0 { return true }

        if nodeIndex > 0 {
            let previous = unit.nodes()[nodeIndex - 1]
            return progress.isCompleted(previous.id)
        }

        guard unitIndex > 0 else { return true }
        let previousUnit = allUnits[unitIndex - 1]
        guard let lastNode = previousUnit.nodes().last else { return true }
        return progress.isCompleted(lastNode.id)
    }
}
