import SwiftUI

struct LessonNodeView: View {
    let number: Int
    let completed: Bool
    let unlocked: Bool
    let isCurrent: Bool
    let progress: Double
    let isLast: Bool

    private var nodeFill: Color {
        completed ? Color.lingoGold : (unlocked ? Color.lingoGreen : Color(.systemGray5))
    }

    private var nodeBase: Color {
        if completed {
            return Color(red: 0.82, green: 0.62, blue: 0.05)
        }
        if unlocked {
            return Color.lingoGreenDark
        }
        return Color(.systemGray4)
    }

    var body: some View {
        ZStack {
            if isCurrent && !completed {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 7)
                    .frame(width: 98, height: 98)

                Circle()
                    .trim(from: 0, to: max(0.035, min(1, progress)))
                    .stroke(
                        Color.lingoGreen,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 98, height: 98)
            }

            // A proper raised base instead of a generic drop shadow.
            Circle()
                .fill(nodeBase)
                .frame(width: 80, height: 80)
                .offset(y: 7)

            Circle()
                .fill(nodeFill)
                .frame(width: 80, height: 80)

            Circle()
                .strokeBorder(Color.white.opacity(unlocked || completed ? 0.22 : 0.10), lineWidth: 2)
                .frame(width: 80, height: 80)

            if completed {
                Image(systemName: "checkmark")
                    .font(.title.weight(.black))
                    .foregroundStyle(.white)
            } else if unlocked && isLast {
                Image(systemName: "crown.fill")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
            } else if unlocked {
                Image(systemName: "star.fill")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "lock.fill")
                    .font(.title3.weight(.black))
                    .foregroundStyle(Color(.systemGray2))
            }
        }
        .overlay(alignment: .top) {
            if isCurrent && !completed {
                VStack(spacing: -1) {
                    Text(progress > 0 ? "CONTINUE" : "START")
                        .font(.caption.weight(.black))
                        .tracking(0.5)
                        .foregroundStyle(Color.lingoGreenDark)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color.lingoLine, lineWidth: 2)
                        }
                        .shadow(color: .black.opacity(0.10), radius: 0, y: 3)

                    StartBubbleTail()
                        .fill(Color(.systemBackground))
                        .frame(width: 18, height: 9)
                        .overlay {
                            StartBubbleTail()
                                .stroke(Color.lingoLine, lineWidth: 1.5)
                        }
                }
                .offset(y: -48)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(number)")
                .font(.caption2.weight(.black))
                .foregroundStyle(unlocked || completed ? Color.lingoInk : Color.lingoMuted)
                .frame(width: 26, height: 26)
                .background(Color(.systemBackground))
                .clipShape(Circle())
                .overlay { Circle().stroke(Color.lingoLine, lineWidth: 2) }
                .offset(x: 4, y: 6)
        }
        .padding(.top, isCurrent && !completed ? 34 : 0)
        .padding(.bottom, 7)
    }
}

private struct StartBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
