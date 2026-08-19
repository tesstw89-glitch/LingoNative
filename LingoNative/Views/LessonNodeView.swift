import SwiftUI

struct LessonNodeView: View {
    let number: Int
    let completed: Bool
    let unlocked: Bool

    var body: some View {
        ZStack {
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
    }
}
