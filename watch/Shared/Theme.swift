import SwiftUI

extension Color {
    static let brand = Color(red: 0.937, green: 0.267, blue: 0.267) // #ef4444, the web app's accent
    static let card = Color(white: 0.13)
    static let control = Color(white: 0.2)
}

/// Full-width red capsule, like the mockup's Start Workout / Log Set buttons.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = .brand
    var height: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(Capsule().fill(color))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Small grey capsule for secondary actions (-15s, +15s, Back).
struct PillButtonStyle: ButtonStyle {
    var color: Color = .control
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .background(Capsule().fill(color))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Round grey − / + button.
struct RoundIconButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.control))
        }
        .buttonStyle(.plain)
    }
}
