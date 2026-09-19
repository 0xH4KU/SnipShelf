import SwiftUI

extension View {
    func buttonHover() -> some View { modifier(ButtonHover()) }
}

private struct ButtonHover: ViewModifier {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let active = hovering && isEnabled
        content
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.primary.opacity(active ? (contrast == .increased ? 0.16 : 0.08) : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: active)
    }
}
