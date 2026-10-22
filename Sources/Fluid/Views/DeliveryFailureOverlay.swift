import AppKit
import SwiftUI

/// Transient bottom-center panel for a transcript that could not be
/// delivered. Same panel, motion and styling as the microphone change
/// notice, so it reads as one system rather than a state of the
/// dictation overlay.
@MainActor
final class DeliveryFailureOverlayController {
    static let shared = DeliveryFailureOverlayController()

    enum Kind: Equatable {
        case noEditableTarget
        case pasteNotLanded
        case accessibilityNotTrusted
        case deliveryFailed

        /// Every failure the user can act on maps to a card; only an empty
        /// transcript has nothing to show.
        init?(failure: TextDeliveryFailure) {
            switch failure {
            case .noEditableTarget: self = .noEditableTarget
            case .pasteNotLanded: self = .pasteNotLanded
            case .accessibilityNotTrusted: self = .accessibilityNotTrusted
            case .clipboardSnapshotFailed, .clipboardWriteFailed, .pasteCommandFailed,
                 .targetUnavailable, .targetRestoreFailed: self = .deliveryFailed
            case .emptyText: return nil
            }
        }

        var title: String {
            switch self {
            case .noEditableTarget: "No text field was focused, so nothing was pasted"
            case .pasteNotLanded, .deliveryFailed: "The app didn’t accept the paste"
            case .accessibilityNotTrusted: "Turn on Accessibility so FluidWispr can paste"
            }
        }

        var offersAccessibilitySettings: Bool { self == .accessibilityNotTrusted }
    }

    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    private static let displayDuration: TimeInterval = 10
    private var panel: NSPanel?
    private var hostingView: NSHostingView<DeliveryFailureOverlayView>?
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    private init() {}

    func show(kind: Kind, transcript: String) {
        self.generation &+= 1
        let currentGeneration = self.generation
        self.dismissTask?.cancel()

        let rootView = DeliveryFailureOverlayView(
            kind: kind,
            transcript: transcript,
            displayDuration: Self.displayDuration,
            startedAt: Date(),
            onCopied: { [weak self] in
                self?.hide(after: 1.1)
            },
            onDismiss: { [weak self] in self?.hide() }
        )
        if let hostingView = self.hostingView {
            hostingView.rootView = rootView
        } else {
            self.createPanel(rootView: rootView)
        }
        guard let panel = self.panel else { return }
        self.resizeAndPositionPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.animate(duration: FWMotion.durationEnter) {
            panel.animator().alphaValue = 1
        }
        DebugLogger.shared.info("Delivery failure card shown kind=\(kind)", source: "DeliveryFailureOverlay")

        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.displayDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            self.hide()
        }
    }

    func hide(after delay: TimeInterval = 0) {
        self.generation &+= 1
        let hideGeneration = self.generation
        self.dismissTask?.cancel()
        self.dismissTask = nil
        guard let panel, panel.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == hideGeneration else { return }
            self.animate(duration: FWMotion.durationExit) {
                panel.animator().alphaValue = 0
            } completion: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == hideGeneration else { return }
                    self.panel?.orderOut(nil)
                    self.panel?.alphaValue = 1
                }
            }
        }
    }

    private func createPanel(rootView: DeliveryFailureOverlayView) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
    }

    private func resizeAndPositionPanel() {
        guard let panel, let hostingView,
              let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        guard size.width > 0, size.height > 0 else { return }
        hostingView.frame = NSRect(origin: .zero, size: size)
        let visibleFrame = screen.visibleFrame
        panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2, y: visibleFrame.minY + 10, width: size.width, height: size.height),
            display: true
        )
    }

    /// With Reduce Motion on, every change is a 130 ms crossfade.
    private func animate(duration: TimeInterval, changes: () -> Void, completion: (() -> Void)? = nil) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? FWMotion.durationReduceCrossfade : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        } completionHandler: {
            completion?()
        }
    }
}

/// The paste-failed card: near-black in both appearances, with the transcript on one
/// line, "Saved in History." and Record buttons, and a 10 s countdown line along the bottom.
private struct DeliveryFailureOverlayView: View {
    let kind: DeliveryFailureOverlayController.Kind
    let transcript: String
    let displayDuration: TimeInterval
    let startedAt: Date
    let onCopied: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: FWMetric.space3) {
            HStack(spacing: FWMetric.space3) {
                if self.kind.offersAccessibilitySettings {
                    Circle()
                        .fill(FWColor.stateAttention)
                        .frame(width: 8, height: 8)
                }
                Text(self.kind.title)
                    .recordText(FWType.label)
                    .foregroundStyle(FWColor.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: self.onDismiss) {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                        .foregroundStyle(FWColor.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(Capsule().fill(FWColor.surfaceSunken))
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }

            Text(self.transcriptPreview)
                .recordText(FWType.transcript)
                .foregroundStyle(FWColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: FWMetric.space3) {
                Text("Saved in History.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if self.didCopy {
                    HStack(spacing: FWMetric.space2) {
                        Image(systemName: "checkmark")
                            .font(.fluidSystem(size: 12, weight: .semibold))
                        Text("Copied")
                            .recordText(FWType.detailStrong)
                    }
                    .foregroundStyle(FWColor.stateDone)
                    .frame(height: FWMetric.sizeControlS)
                } else if self.kind.offersAccessibilitySettings {
                    Button("Copy", action: self.copy)
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                    Button("Open Settings", action: self.openAccessibilitySettings)
                        .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlS))
                        .help("Open Accessibility settings")
                } else {
                    Button("Copy", action: self.copy)
                        .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlS))
                }
            }
            .padding(.top, FWMetric.space2)
            .padding(.bottom, FWMetric.space4)
        }
        .padding(EdgeInsets(top: FWMetric.space4, leading: FWMetric.space5, bottom: 0, trailing: FWMetric.space4))
        .frame(width: 440)
        .overlay(alignment: .bottomLeading) {
            if !self.didCopy {
                self.countdown
            }
        }
        .recordNearBlack()
        .clipShape(RoundedRectangle(cornerRadius: FWMetric.radiusContainer))
        .overlay {
            RoundedRectangle(cornerRadius: FWMetric.radiusContainer)
                .strokeBorder(FWColor.lineRule, lineWidth: FWMetric.lineHairline)
                .environment(\.colorScheme, .dark)
        }
    }

    /// The 2 pt `line/spoken` line that shrinks from full width to nothing over the display time.
    private var countdown: some View {
        TimelineView(.animation(minimumInterval: self.reduceMotion ? 1 : 1 / 30)) { context in
            GeometryReader { proxy in
                Rectangle()
                    .fill(FWColor.lineSpoken)
                    .frame(width: proxy.size.width * self.remaining(at: context.date))
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    private func remaining(at date: Date) -> CGFloat {
        guard self.displayDuration > 0 else { return 0 }
        return CGFloat(max(0, min(1, 1 - date.timeIntervalSince(self.startedAt) / self.displayDuration)))
    }

    private var transcriptPreview: String {
        let trimmed = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Nothing was captured" : trimmed
    }

    private func openAccessibilitySettings() {
        guard let url = DeliveryFailureOverlayController.accessibilitySettingsURL else { return }
        NSWorkspace.shared.open(url)
        self.onDismiss()
    }

    private func copy() {
        guard !self.didCopy else { return }
        _ = ClipboardService.copyToClipboard(self.transcript)
        withAnimation(.easeOut(duration: FWMotion.durationSnap)) { self.didCopy = true }
        self.onCopied()
    }
}
