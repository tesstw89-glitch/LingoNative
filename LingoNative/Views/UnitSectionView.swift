import SwiftUI

struct UnitSectionView: View {
    let unit: LearningUnit
    let unitIndex: Int
    let course: LanguageCourse
    let allUnits: [LearningUnit]
    let allPhrases: [PhraseEntry]
    @ObservedObject var progress: ProgressStore

    private let offsets: [CGFloat] = [0, 46, 72, 38, -16, -58, -76, -38]

    var body: some View {
        VStack(spacing: 22) {
            unitBanner

            VStack(spacing: 24) {
                ForEach(Array(unit.nodes().enumerated()), id: \.element.id) { nodeIndex, node in
                    let completed = progress.isCompleted(node.id)
                    let unlocked = isUnlocked(nodeIndex: nodeIndex)

                    Group {
                        if unlocked || completed {
                            NavigationLink {
                                QuizView(
                                    course: course,
                                    unit: unit,
                                    node: node,
                                    allPhrases: allPhrases,
                                    progress: progress
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
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(18)
        .background(course == .french ? Color.lingoBlue : Color.lingoGreen)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
