import SwiftUI

struct DuoButtonStyle: ButtonStyle {
    var fill: Color = .lingoGreen
    var shadow: Color = .lingoGreenDark
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Fredoka-Medium", size: 18))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.04), lineWidth: 1)
            }
            .offset(y: configuration.isPressed ? 4 : 0)
            .background(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(shadow)
                    .offset(y: 4)
            }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
