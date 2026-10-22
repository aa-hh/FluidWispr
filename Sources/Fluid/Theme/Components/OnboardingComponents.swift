import AppKit
import SwiftUI

enum FluidOnboardingLayout {
    static let footerHorizontalInset: CGFloat = 56
    static let footerBottomInset: CGFloat = 56
}

struct OnboardingModelInfoTooltip: View {
    let text: String
    let font: Font

    var body: some View {
        Text(self.text)
            .font(self.font)
            .foregroundStyle(.white.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(width: 260, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.075, green: 0.085, blue: 0.11))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.16), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct FluidOnboardingLandingPrimaryButton: NSViewRepresentable {
    static let size = CGSize(width: 236, height: 56)

    let title: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: self.action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = LandingPrimaryNSButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.wantsLayer = true
        button.focusRingType = .none
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
        button.setAccessibilityLabel(self.title)
        button.update(title: self.title, isHighlighted: false)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = self.action

        guard let button = button as? LandingPrimaryNSButton else {
            button.title = self.title
            button.setAccessibilityLabel(self.title)
            return
        }

        button.setAccessibilityLabel(self.title)
        button.update(title: self.title, isHighlighted: button.isHighlighted)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            self.action()
        }
    }
}

private final class LandingPrimaryNSButton: NSButton {
    private static let normalColor = NSColor(srgbRed: 0.16, green: 0.49, blue: 1.0, alpha: 1.0)
    private static let highlightedColor = NSColor(srgbRed: 0.10, green: 0.40, blue: 0.92, alpha: 1.0)
    private static let hoverColor = NSColor(srgbRed: 0.20, green: 0.54, blue: 1.0, alpha: 1.0)
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override var isHighlighted: Bool {
        didSet {
            self.update(title: self.title, isHighlighted: self.isHighlighted)
        }
    }

    override var intrinsicContentSize: NSSize {
        FluidOnboardingLandingPrimaryButton.size
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard self.isEnabled, !self.isHidden, self.alphaValue > 0, self.bounds.contains(point) else {
            return nil
        }

        return self
    }

    override func layout() {
        super.layout()
        self.layer?.cornerRadius = self.bounds.height / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self)
        self.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        self.isHovering = true
        self.update(title: self.title, isHighlighted: self.isHighlighted)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        self.isHovering = false
        self.update(title: self.title, isHighlighted: self.isHighlighted)
    }

    func update(title: String, isHighlighted: Bool) {
        self.title = title
        self.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.fluidSystemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        self.alignment = .center
        self.layer?.masksToBounds = false
        self.layer?.backgroundColor = self.backgroundColor(isHighlighted: isHighlighted).cgColor
        self.layer?.cornerRadius = self.bounds.height > 0 ? self.bounds.height / 2 : 28
        self.layer?.shadowColor = Self.normalColor.withAlphaComponent(0.34).cgColor
        self.layer?.shadowOpacity = isHighlighted ? 0.20 : 0.34
        self.layer?.shadowRadius = isHighlighted ? 8 : 14
        self.layer?.shadowOffset = NSSize(width: 0, height: isHighlighted ? 4 : 7)
    }

    private func backgroundColor(isHighlighted: Bool) -> NSColor {
        if isHighlighted {
            return Self.highlightedColor
        }

        return self.isHovering ? Self.hoverColor : Self.normalColor
    }
}

enum FluidOnboardingLandingColors {
    static let blue = FluidBrandColors.blue
}

private struct OnboardingSelectableSurfaceModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let isSelected: Bool
    let cornerRadius: CGFloat?
    let padding: CGFloat?
    let selectedBorderOpacity: Double?

    func body(content: Content) -> some View {
        let surface = self.theme.metrics.onboardingSurface
        let radius = self.cornerRadius ?? surface.optionCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .padding(self.padding ?? surface.optionPadding)
            .background(
                shape
                    .fill(self.theme.palette.cardBackground.opacity(
                        self.isSelected ? surface.selectedFillOpacity : surface.normalFillOpacity
                    ))
                    .overlay(
                        shape.stroke(
                            self.isSelected
                                ? self.theme.palette.accent.opacity(self.selectedBorderOpacity ?? surface.selectedBorderOpacity)
                                : self.theme.palette.cardBorder.opacity(surface.normalBorderOpacity),
                            lineWidth: 1
                        )
                    )
            )
            .contentShape(shape)
    }
}

private struct OnboardingEditorSurfaceModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        let surface = self.theme.metrics.onboardingSurface
        let radius = self.cornerRadius ?? surface.editorCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .padding(surface.editorPadding)
            .background(
                shape
                    .fill(self.theme.palette.cardBackground)
                    .overlay(
                        shape.stroke(self.theme.palette.cardBorder.opacity(surface.editorBorderOpacity), lineWidth: 1)
                    )
            )
    }
}

private struct OnboardingProminentButtonModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let controlSize: ControlSize?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let controlSize {
            content
                .buttonStyle(.borderedProminent)
                .controlSize(controlSize)
                .tint(self.theme.palette.accent)
        } else {
            content
                .buttonStyle(.borderedProminent)
                .tint(self.theme.palette.accent)
        }
    }
}

private struct OnboardingSecondaryButtonModifier: ViewModifier {
    let controlSize: ControlSize?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let controlSize {
            content
                .fluidOutlinedButton()
                .controlSize(controlSize)
        } else {
            content
                .fluidOutlinedButton()
        }
    }
}

extension View {
    func fluidOnboardingSelectableSurface(
        isSelected: Bool,
        cornerRadius: CGFloat? = nil,
        padding: CGFloat? = nil,
        selectedBorderOpacity: Double? = nil
    ) -> some View {
        self.modifier(OnboardingSelectableSurfaceModifier(
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            padding: padding,
            selectedBorderOpacity: selectedBorderOpacity
        ))
    }

    func fluidOnboardingEditorSurface(cornerRadius: CGFloat? = nil) -> some View {
        self.modifier(OnboardingEditorSurfaceModifier(cornerRadius: cornerRadius))
    }

    func fluidOnboardingProminentButton(controlSize: ControlSize? = nil) -> some View {
        self.modifier(OnboardingProminentButtonModifier(controlSize: controlSize))
    }

    func fluidOnboardingSecondaryButton(controlSize: ControlSize? = nil) -> some View {
        self.modifier(OnboardingSecondaryButtonModifier(controlSize: controlSize))
    }
}
