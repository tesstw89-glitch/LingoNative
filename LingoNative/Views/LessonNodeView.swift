import SwiftUI

struct LessonNodeView: View {
    let number: Int
    let completed: Bool
    let unlocked: Bool
    let isCurrent: Bool
    let progress: Double
    let isLast: Bool

    var body: some View {
        ZStack {
            if isCurrent && !completed {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 7)
                    .frame(width: 94, height: 94)

                Circle()
                    .trim(from: 0, to: max(0.035, min(1, progress)))
                    .stroke(
                        Color.lingoGreen,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 94, height: 94)
            }

            Circle()
                .fill(completed ? Color.lingoGold : (unlocked ? Color.lingoGreen : Color(.systemGray5)))
                .frame(width: 78, height: 78)

            Circle()
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 2)
                .frame(width: 78, height: 78)

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
                Text(progress > 0 ? "CONTINUE" : "START")
                    .font(.caption2.weight(.black))
                    .tracking(0.6)
                    .foregroundStyle(Color.lingoGreenDark)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.lingoLine, lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 0, y: 3)
                    .offset(y: -39)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(number)")
                .font(.caption2.weight(.black))
                .foregroundStyle(unlocked || completed ? Color.lingoInk : Color.lingoMuted)
                .frame(width: 26, height: 26)
                .background(.white)
                .clipShape(Circle())
                .overlay { Circle().stroke(Color.lingoLine, lineWidth: 2) }
                .offset(x: 3, y: 3)
        }
        .shadow(color: Color.black.opacity(unlocked || completed ? 0.13 : 0), radius: 0, y: 5)
        .padding(.top, isCurrent && !completed ? 24 : 0)
    }
}
