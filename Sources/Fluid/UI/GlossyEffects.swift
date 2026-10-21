import SwiftUI

// MARK: - Button Hover Extension

extension View {
    func buttonHoverEffect() -> some View {
        modifier(ButtonHoverModifier())
    }
}

struct ButtonHoverModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(self.isHovered ? FluidInteractionVisuals.hoverScale : 1.0)
            .shadow(
                color: self.theme.palette.accent.opacity(self.isHovered ? 0.35 : 0.0),
                radius: self.isHovered ? 8 : 0,
                x: 0,
                y: self.isHovered ? 3 : 0
            )
            .onHover { hovering in
                self.isHovered = hovering
            }
            .animation(FluidInteractionVisuals.hoverAnimation, value: self.isHovered)
    }
}

// Removed CursorFollowingGlow - was causing performance issues
// struct CursorFollowingGlow: View {
//     @EnvironmentObject var mouseTracker: MousePositionTracker
//     let size: CGFloat
//     let intensity: Double
//
//     init(size: CGFloat = 300, intensity: Double = 0.2) {
//         self.size = size
//         self.intensity = intensity
//     }
//
//     var body: some View {
//         GeometryReader { geometry in
//             let relativeX = mouseTracker.relativePosition.x
//             let relativeY = mouseTracker.relativePosition.y
//
//             RadialGradient(
//                 colors: [
//                     Color.white.opacity(intensity * 0.6),
//                     Color.white.opacity(intensity * 0.3),
//                     Color.white.opacity(intensity * 0.1),
//                     Color.clear
//                 ],
//                 center: UnitPoint(x: relativeX, y: relativeY),
//                 startRadius: size * 0.1,
//                 endRadius: size * 0.5
//             )
//             .blendMode(.overlay)
//             .allowsHitTesting(false)
//             .animation(.easeInOut(duration: 0.25), value: mouseTracker.mousePosition)
//         }
//     }
// }
