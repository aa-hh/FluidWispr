import AppKit
import SwiftUI

/// Adapted from PR #837. Prompt presentation never takes focus or enters a modal loop.
@MainActor
final class UpdatePromptPresenter {
    static let shared = UpdatePromptPresenter()
    private var floatingPromptWindow: FloatingPromptPanel?
    private var floatingPromptQueue: [FloatingPrompt] = []
    private static let maxQueuedFloatingPrompts = 4

    /// `actions` run left to right: the last is the Primary (Return), the first is the
    /// Secondary (Esc), and a single action is both. `key` names the prompt for
    /// replacing and dismissing it, and is the panel's window title; it defaults to `title`.
    func presentFloatingPrompt(
        title: String,
        message: String,
        actions: [FloatingPromptAction],
        isAutomaticUpdateOffer: Bool = false,
        badge: UpdatePromptBadge? = nil,
        key: String? = nil
    ) {
        guard !actions.isEmpty else { return }
        let key = key ?? title
        if let index = self.floatingPromptQueue.firstIndex(where: { $0.key == key }) {
            let existing = self.floatingPromptQueue[index]
            let promotesToManual = existing.isAutomaticUpdateOffer && !isAutomaticUpdateOffer
            guard existing.message != message || existing.title != title || promotesToManual else { return }
            self.floatingPromptQueue[index] = FloatingPrompt(
                key: key,
                title: title,
                message: message,
                actions: actions,
                isAutomaticUpdateOffer: existing.isAutomaticUpdateOffer && isAutomaticUpdateOffer,
                badge: badge
            )
            if index == 0 {
                let wasKey = self.floatingPromptWindow?.isKeyWindow == true
                self.floatingPromptWindow?.close()
                self.floatingPromptWindow = nil
                self.showNextFloatingPromptIfIdle()
                if wasKey { self.floatingPromptWindow?.makeKey() }
            }
            return
        }
        guard self.floatingPromptQueue.count < Self.maxQueuedFloatingPrompts else {
            return
        }

        self.floatingPromptQueue.append(FloatingPrompt(
            key: key,
            title: title,
            message: message,
            actions: actions,
            isAutomaticUpdateOffer: isAutomaticUpdateOffer,
            badge: badge
        ))
        self.showNextFloatingPromptIfIdle()
    }

    private func showNextFloatingPromptIfIdle() {
        guard self.floatingPromptWindow == nil, let prompt = self.floatingPromptQueue.first else { return }

        let actions = prompt.actions
        let buttons = actions.enumerated().map { index, action in
            let isPrimary = index == actions.count - 1
            let button = FloatingPromptButton(title: action.title, kind: isPrimary ? .primary : .secondary) { [weak self] in
                guard let self, self.floatingPromptQueue.first?.id == prompt.id else { return }
                self.finishVisibleFloatingPrompt()
                action.handler()
                self.showNextFloatingPromptIfIdle()
            }
            if isPrimary {
                button.keyEquivalent = "\r"
            }
            return button
        }

        let content = UpdatePromptLayout.content(
            title: prompt.title,
            message: prompt.message,
            badge: prompt.badge,
            buttons: buttons
        )
        let panel = FloatingPromptPanel(
            contentRect: content.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = prompt.key
        if let cancelButton = buttons.first {
            panel.onCancel = { [weak cancelButton] in cancelButton?.performClick(nil) }
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        panel.initialFirstResponder = buttons.last
        panel.center()
        // Even our own search/editor field may be receiving dictation. Never make this key here.
        panel.orderFrontRegardless()
        self.floatingPromptWindow = panel
    }

    private func finishVisibleFloatingPrompt() {
        self.floatingPromptWindow?.close()
        self.floatingPromptWindow = nil
        if !self.floatingPromptQueue.isEmpty {
            self.floatingPromptQueue.removeFirst()
        }
    }

    func dismissAutomaticUpdateOffers() {
        self.dismissPrompts { $0.isAutomaticUpdateOffer }
    }

    func dismissUpdateOffers() {
        self.dismissPrompts { $0.key == "Update Available" }
    }

    func dismissUpdateCheckResults() {
        self.dismissPrompts {
            $0.key == "No Updates" || $0.key == "No Beta Updates" || $0.key == "Update Check Failed"
        }
    }

    private func dismissPrompts(where shouldDismiss: (FloatingPrompt) -> Bool) {
        let removesVisiblePrompt = self.floatingPromptQueue.first.map(shouldDismiss) == true
        self.floatingPromptQueue.removeAll(where: shouldDismiss)
        if removesVisiblePrompt {
            self.floatingPromptWindow?.close()
            self.floatingPromptWindow = nil
            self.showNextFloatingPromptIfIdle()
        }
    }

    func dismissAll() {
        self.floatingPromptWindow?.close()
        self.floatingPromptWindow = nil
        self.floatingPromptQueue.removeAll()
    }
}

struct FloatingPromptAction {
    let title: String
    let handler: @MainActor () -> Void
}

private struct FloatingPrompt {
    let id = UUID()
    let key: String
    let title: String
    let message: String
    let actions: [FloatingPromptAction]
    let isAutomaticUpdateOffer: Bool
    let badge: UpdatePromptBadge?
}

/// The "!" badge on the icon: `retry` for Install failed, `attention` for Check failed.
enum UpdatePromptBadge {
    case retry
    case attention
}

private final class FloatingPromptPanel: NSPanel {
    var onCancel: (@MainActor () -> Void)?

    override var canBecomeKey: Bool {
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        let onCancel = self.onCancel
        onCancel?()
    }
}

/// Record/Button at size 28 as an AppKit button: a capsule, Secondary or Primary.
final class FloatingPromptButton: NSButton {
    enum Kind {
        case primary
        case secondary
    }

    private let kind: Kind
    private let onClick: @MainActor () -> Void

    init(title: String, kind: Kind, onClick: @escaping @MainActor () -> Void) {
        self.kind = kind
        self.onClick = onClick
        super.init(frame: .zero)
        self.title = title
        self.isBordered = false
        self.font = .fluidSystemFont(ofSize: FWType.label.size, weight: .medium)
        self.target = self
        self.action = #selector(self.handleClick)
        let textWidth = ceil(NSAttributedString(string: title, attributes: [.font: self.font as Any]).size().width)
        self.setFrameSize(NSSize(width: max(textWidth + 2 * FWMetric.space4, ceil(super.fittingSize.width)), height: FWMetric.sizeControlM))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FloatingPromptButton is created in code only")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func draw(_: NSRect) {
        let capsule = NSBezierPath(roundedRect: self.bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: (self.bounds.height - 1) / 2, yRadius: (self.bounds.height - 1) / 2)
        let pressed = self.isHighlighted
        let labelColor: NSColor
        switch self.kind {
        case .primary:
            NSColor(FWColor.actionPrimary).setFill()
            capsule.fill()
            if pressed {
                NSColor(FWColor.actionOnPrimary).withAlphaComponent(0.08).setFill()
                capsule.fill()
            }
            labelColor = NSColor(FWColor.actionOnPrimary)
        case .secondary:
            NSColor(pressed ? FWColor.surfaceSelected : FWColor.surfaceSunken).setFill()
            capsule.fill()
            NSColor(FWColor.lineStrong).setStroke()
            capsule.lineWidth = FWMetric.lineHairline
            capsule.stroke()
            labelColor = NSColor(FWColor.textPrimary)
        }
        let label = NSAttributedString(string: self.title, attributes: [.font: self.font as Any, .foregroundColor: labelColor])
        let size = label.size()
        label.draw(at: NSPoint(x: (self.bounds.width - size.width) / 2, y: (self.bounds.height - size.height) / 2))
    }

    @objc private func handleClick() {
        let onClick = self.onClick
        onClick()
    }
}

/// Layout shared by the update prompts and the install panel: a solid raised surface
/// with the 52 pt icon, a Section title and a Body message, then an optional progress
/// track and a right-aligned button row (Secondary then Primary).
@MainActor
enum UpdatePromptLayout {
    static let margin: CGFloat = FWMetric.space6
    static let iconSize: CGFloat = 52
    static let textLeading: CGFloat = margin + iconSize + FWMetric.space5

    static func content(
        title: String,
        message: String,
        badge: UpdatePromptBadge?,
        buttons: [NSButton],
        progress: UpdatePromptProgressTrack.Style? = nil
    ) -> NSView {
        let buttonSpacing = FWMetric.space3
        let buttonsWidth = buttons.map(\.frame.width).reduce(0, +) + buttonSpacing * CGFloat(max(buttons.count - 1, 0))
        let panelWidth = max(420, Self.textLeading + buttonsWidth + Self.margin)
        let textWidth = panelWidth - Self.textLeading - Self.margin

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .fluidSystemFont(ofSize: FWType.section.size, weight: .semibold)
        titleLabel.textColor = NSColor(FWColor.textPrimary)
        titleLabel.preferredMaxLayoutWidth = textWidth
        let titleHeight = ceil(titleLabel.fittingSize.height)

        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .fluidSystemFont(ofSize: FWType.body.size)
        detail.textColor = NSColor(FWColor.textSecondary)
        detail.preferredMaxLayoutWidth = textWidth
        let detailHeight = ceil(detail.fittingSize.height)

        var y = Self.margin
        let buttonsY = y
        if !buttons.isEmpty { y += FWMetric.sizeControlM + FWMetric.space4 }
        var track: UpdatePromptProgressTrack?
        if let progress {
            let view = UpdatePromptProgressTrack(frame: NSRect(x: Self.textLeading, y: y, width: textWidth, height: 4), style: progress)
            track = view
            y += 4 + FWMetric.space3
        }
        let detailY = y
        let titleY = detailY + detailHeight + FWMetric.space2
        let panelHeight = max(titleY + titleHeight + Self.margin, 2 * Self.margin + Self.iconSize)

        let content = UpdatePromptSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        content.autoresizingMask = [.width, .height]
        titleLabel.frame = NSRect(x: Self.textLeading, y: titleY, width: textWidth, height: titleHeight)
        detail.frame = NSRect(x: Self.textLeading, y: detailY, width: textWidth, height: detailHeight)

        let icon = UpdatePromptIconView(
            frame: NSRect(x: Self.margin, y: panelHeight - Self.margin - Self.iconSize - 6, width: Self.iconSize + 6, height: Self.iconSize + 6),
            badge: badge
        )
        content.addSubview(icon)
        content.addSubview(titleLabel)
        content.addSubview(detail)
        if let track { content.addSubview(track) }

        var buttonTrailing = panelWidth - Self.margin
        for button in buttons.reversed() {
            let width = button.frame.width
            button.frame = NSRect(x: buttonTrailing - width, y: buttonsY, width: width, height: FWMetric.sizeControlM)
            buttonTrailing -= width + buttonSpacing
            content.addSubview(button)
        }
        return content
    }
}

/// The panel's solid `surface/raised` fill with a `line/rule` hairline and 14 pt corners.
/// Drawn rather than set on the layer, so it follows the system appearance.
final class UpdatePromptSurfaceView: NSView {
    override func draw(_: NSRect) {
        let radius = FWMetric.radiusContainer
        let shape = NSBezierPath(roundedRect: self.bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor(FWColor.surfaceRaised).setFill()
        shape.fill()
        NSColor(FWColor.lineRule).setStroke()
        shape.lineWidth = FWMetric.lineHairline
        shape.stroke()
    }
}

/// The 52 pt app tile: `pill/body` with the pill outline in Dark `text/primary`,
/// and the optional 18 pt "!" badge at (38, 38). The view is 6 pt larger than the
/// tile so the badge and its ring fit.
final class UpdatePromptIconView: NSView {
    private let badge: UpdatePromptBadge?

    init(frame: NSRect, badge: UpdatePromptBadge?) {
        self.badge = badge
        super.init(frame: frame)
        self.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("UpdatePromptIconView is created in code only")
    }

    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        NSColor(FWColor.pillBody).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 52, height: 52), xRadius: 12, yRadius: 12).fill()
        let outline = NSBezierPath(roundedRect: NSRect(x: 11, y: 19, width: 30, height: 14), xRadius: 7, yRadius: 7)
        outline.lineWidth = 2
        NSColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xEF / 255, alpha: 1).setStroke()
        outline.stroke()

        guard let badge else { return }
        NSColor(FWColor.surfaceRaised).setFill()
        NSBezierPath(ovalIn: NSRect(x: 36, y: 36, width: 22, height: 22)).fill()
        NSColor(badge == .retry ? FWColor.stateRetry : FWColor.stateAttention).setFill()
        NSBezierPath(ovalIn: NSRect(x: 38, y: 38, width: 18, height: 18)).fill()
        let mark = NSAttributedString(string: "!", attributes: [
            .font: NSFont.fluidSystemFont(ofSize: FWType.smallStrong.size, weight: .medium),
            .foregroundColor: NSColor(FWColor.surfaceRaised),
        ])
        let size = mark.size()
        mark.draw(at: NSPoint(x: 47 - size.width / 2, y: 47 - size.height / 2))
    }
}

/// The install panel's 4 pt track in `surface/sunken`. Downloading moves a 96 pt
/// `text/secondary` segment across it (still with Reduce Motion on); Restarting
/// fills it with `state/done`.
final class UpdatePromptProgressTrack: NSView {
    enum Style {
        case downloading
        case restarting
    }

    let style: Style
    private var timer: Timer?
    private var phase: CGFloat = 0

    init(frame: NSRect, style: Style) {
        self.style = style
        super.init(frame: frame)
        guard style == .downloading, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.phase = (self.phase + 1.0 / 45).truncatingRemainder(dividingBy: 1)
                self.needsDisplay = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("UpdatePromptProgressTrack is created in code only")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    override func draw(_: NSRect) {
        let radius = self.bounds.height / 2
        let track = NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius)
        NSColor(FWColor.surfaceSunken).setFill()
        track.fill()
        track.addClip()
        switch self.style {
        case .restarting:
            NSColor(FWColor.stateDone).setFill()
            track.fill()
        case .downloading:
            let segment: CGFloat = 96
            let x = -segment + (self.bounds.width + segment) * self.phase
            NSColor(FWColor.textSecondary).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: segment, height: self.bounds.height), xRadius: radius, yRadius: radius).fill()
        }
    }
}
