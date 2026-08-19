import SwiftUI

struct StatPill: View {
    let systemImage: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            Text(value)
                .font(.headline.weight(.black))
                .foregroundStyle(Color.lingoInk)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(Color.lingoLine, lineWidth: 2)
        }
    }
}
