import SwiftUI

struct SpeakingDottedUnderline: View {
    let color: Color

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0.5))
            path.addLine(to: CGPoint(x: 1000, y: 0.5))
        }
        .stroke(style: StrokeStyle(lineWidth: 1, dash: [1.5, 3.0]))
        .foregroundStyle(color)
        .frame(height: 1)
        .clipped()
    }
}

struct TranslucentSpeakingButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(tint.opacity(configuration.isPressed ? 0.16 : 0.08))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(tint.opacity(configuration.isPressed ? 0.8 : 0.45), lineWidth: 2)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
