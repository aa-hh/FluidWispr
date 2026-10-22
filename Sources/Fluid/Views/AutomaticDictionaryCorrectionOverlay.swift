import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class DictionaryCorrectionOverlayController {
    static let shared = DictionaryCorrectionOverlayController()

    private static let displayDurationNanoseconds: UInt64 = 10_000_000_000
    private static let successDurationNanoseconds: UInt64 = 1_400_000_000
    private static let presentationDuration: TimeInterval = 0.05
    private static let dismissalDuration: TimeInterval = 0.05

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AutomaticDictionaryCorrectionOverlayView>?
    private var session: AutomaticDictionaryTrainingSession?
    private var sessionCancellable: AnyCancellable?
    private var dismissTask: Task<Void, Never>?
    private var outcomeHandler: ((AutomaticDictionarySuggestionOutcome) -> Void)?
    private var generation: UInt64 = 0

    private init() {}

    var isPresented: Bool {
        self.panel?.isVisible == true
    }

    func transientOverlayLayoutDidChange() {
        guard self.isPresented else { return }
        self.resizeAndPositionPanel(animated: true)
    }

    func show(
        candidate: AutomaticDictionaryCorrectionCandidate,
        onOutcome: @escaping (AutomaticDictionarySuggestionOutcome) -> Void
    ) {
        self.generation &+= 1
        self.dismissTask?.cancel()
        self.session?.cancel()
        self.outcomeHandler = onOutcome

        let session = AutomaticDictionaryTrainingSession(
            candidate: candidate,
            asr: AppServices.shared.asr
        )
        session.onInteraction = { [weak self] in
            self?.keepVisible()
        }
        session.onSuccess = { [weak self] in
            self?.reportOutcome(.accepted)
            self?.scheduleSuccessDismissal()
        }
        self.session = session

        let rootView = AutomaticDictionaryCorrectionOverlayView(
            session: session,
            displayDuration: Double(Self.displayDurationNanoseconds) / 1_000_000_000,
            onDismiss: { [weak self] in
                self?.dismiss()
            },
            onIgnore: { [weak self] in
                self?.reportOutcome(.ignored)
                self?.hide()
            },
            onFrequencyChange: { [weak self] frequency in
                SettingsStore.shared.automaticDictionarySuggestionFrequency = frequency
                self?.scheduleChoiceDismissal()
            },
            onDisableSuggestions: { [weak self] in
                SettingsStore.shared.automaticDictionaryLearningEnabled = false
                self?.hide()
            }
        )

        if let hostingView = self.hostingView {
            hostingView.rootView = rootView
        } else {
            self.createPanel(rootView: rootView)
        }

        self.sessionCancellable = session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeAndPositionPanel(animated: true)
                }
            }

        guard let panel = self.panel else { return }
        self.resizeAndPositionPanel(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.presentationDuration
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }

        self.scheduleChoiceDismissal()
    }

    private func scheduleChoiceDismissal() {
        self.keepVisible()
        let currentGeneration = self.generation
        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.displayDurationNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.generation == currentGeneration,
                  self.session?.screen == .choice
            else {
                return
            }
            self.reportOutcome(.timedOut)
            self.hide()
        }
    }

    func hide() {
        self.generation &+= 1
        let hideGeneration = self.generation
        self.dismissTask?.cancel()
        self.dismissTask = nil
        self.session?.cancel()
        guard let panel, panel.isVisible else {
            self.clearSession()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.dismissalDuration
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == hideGeneration else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
                self.clearSession()
            }
        }
    }

    func dismiss() {
        self.reportOutcome(.dismissed)
        self.hide()
    }

    private func keepVisible() {
        self.dismissTask?.cancel()
        self.dismissTask = nil
    }

    private func scheduleSuccessDismissal() {
        self.keepVisible()
        let successGeneration = self.generation
        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.successDurationNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.generation == successGeneration
            else {
                return
            }
            self.hide()
        }
    }

    private func clearSession() {
        self.sessionCancellable?.cancel()
        self.sessionCancellable = nil
        self.session = nil
        self.outcomeHandler = nil
    }

    private func reportOutcome(_ outcome: AutomaticDictionarySuggestionOutcome) {
        guard let outcomeHandler = self.outcomeHandler else { return }
        self.outcomeHandler = nil
        outcomeHandler(outcome)
    }

    private func createPanel(rootView: AutomaticDictionaryCorrectionOverlayView) {
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
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView
    }

    private func resizeAndPositionPanel(animated: Bool) {
        guard let panel, let hostingView,
              let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        else {
            return
        }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        guard size.width > 0, size.height > 0 else { return }
        hostingView.frame = NSRect(origin: .zero, size: size)

        let visibleFrame = screen.visibleFrame
        let requestedY = visibleFrame.minY + CGFloat(SettingsStore.shared.overlayBottomOffset)
        let microphoneToastY = MicrophoneChangeOverlayController.shared.topEdge(on: screen).map { $0 + 10 }
        let stackedY = max(requestedY, microphoneToastY ?? requestedY)
        let y = max(visibleFrame.minY + 10, min(stackedY, visibleFrame.maxY - size.height - 40))
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: y,
            width: size.width,
            height: size.height
        )

        guard animated, panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

enum MicrophoneChangePresentation: Hashable {
    case startupSelection
    case selectionChange
    case activeChange
}

struct MicrophoneChangeNotice: Hashable {
    let previousName: String?
    let currentName: String?
    let presentation: MicrophoneChangePresentation
}

@MainActor
final class MicrophoneChangeOverlayController {
    static let shared = MicrophoneChangeOverlayController()

    private static let displayDurationNanoseconds: UInt64 = 5_000_000_000
    private static let supportedBundleIdentifiers = [
        "com.FluidApp.app",
        "com.FluidApp.app.debug",
    ]
    private var panel: NSPanel?
    private var hostingView: NSHostingView<MicrophoneChangeOverlayView>?
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    private init() {}

    func show(_ notice: MicrophoneChangeNotice) {
        guard Self.supportsAlerts(bundleIdentifier: Bundle.main.bundleIdentifier),
              SettingsStore.shared.showMicrophoneChangeAlerts
        else { return }
        self.generation &+= 1
        let currentGeneration = self.generation
        self.dismissTask?.cancel()

        let rootView = MicrophoneChangeOverlayView(
            notice: notice,
            displayDuration: Double(Self.displayDurationNanoseconds) / 1_000_000_000,
            startedAt: Date(),
            onSettings: { [weak self] in
                self?.hide()
                NotificationCenter.default.post(name: .openMicrophoneSettingsRequested, object: nil)
            },
            onDisable: { [weak self] in
                self?.disableFutureAlerts()
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
        DebugLogger.shared.debug(
            "Showing microphone change overlay frame=\(NSStringFromRect(panel.frame))",
            source: "MicrophoneChangeOverlay"
        )
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.animate(duration: 0.12) {
            panel.animator().alphaValue = 1
        }
        DictionaryCorrectionOverlayController.shared.transientOverlayLayoutDidChange()

        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.displayDurationNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.generation == currentGeneration
            else { return }
            self.hide()
        }
    }

    nonisolated static func supportsAlerts(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return self.supportedBundleIdentifiers.contains(bundleIdentifier)
    }

    func disableFutureAlerts() {
        SettingsStore.shared.showMicrophoneChangeAlerts = false
        self.hide()
    }

    func hide() {
        self.generation &+= 1
        let hideGeneration = self.generation
        self.dismissTask?.cancel()
        self.dismissTask = nil
        guard let panel else { return }
        guard panel.isVisible else {
            self.releasePanel()
            return
        }
        self.animate(duration: 0.1) {
            panel.animator().alphaValue = 0
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                self?.finishHide(generation: hideGeneration)
            }
        }
        // AppKit can reach alpha=0 without delivering the animation completion
        // (notably for an inactive nonactivating panel). Bound the hosted timeline.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.finishHide(generation: hideGeneration)
        }
    }

    private func finishHide(generation: UInt64) {
        guard self.generation == generation, self.panel != nil else { return }
        self.releasePanel()
        DictionaryCorrectionOverlayController.shared.transientOverlayLayoutDidChange()
    }

    private func releasePanel() {
        self.panel?.orderOut(nil)
        self.panel?.contentView = nil
        self.hostingView = nil
        self.panel = nil
    }

    func topEdge(on screen: NSScreen) -> CGFloat? {
        guard let panel, panel.isVisible, panel.frame.intersects(screen.frame) else { return nil }
        return panel.frame.maxY
    }

    private func createPanel(rootView: MicrophoneChangeOverlayView) {
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
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: visibleFrame.minY + 10,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }

    private func animate(
        duration: TimeInterval,
        changes: () -> Void,
        completion: (() -> Void)? = nil
    ) {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else {
            changes()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        } completionHandler: {
            completion?()
        }
    }
}

private struct MicrophoneChangeOverlayView: View {
    let notice: MicrophoneChangeNotice
    let displayDuration: TimeInterval
    let startedAt: Date
    let onSettings: () -> Void
    let onDisable: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCloseHovered = false
    @State private var isDisableHovered = false
    @State private var isSettingsHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: self.notice.currentName == nil ? "mic.slash.fill" : "mic.fill")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 24, height: 24)

                Text(self.title)
                    .font(.fluidSystem(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))

                Spacer(minLength: 8)

                Button(action: self.onDismiss) {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(self.isCloseHovered ? 0.95 : 0.68))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(self.isCloseHovered ? 0.13 : 0.06)))
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .onHover { self.isCloseHovered = $0 }
                .help("Dismiss")
                .accessibilityLabel("Dismiss microphone change")
            }

            Text(self.detailText)
                .font(.fluidSystem(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(self.explanation)
                    .font(.fluidSystem(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button("Do not show again", action: self.onDisable)
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isDisableHovered))
                    .onHover { self.isDisableHovered = $0 }
                    .help("Turn off microphone change alerts")

                Button("Settings", action: self.onSettings)
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isSettingsHovered))
                    .onHover { self.isSettingsHovered = $0 }
                    .help("Open microphone settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 540)
        .background(TransientOverlayBackground())
        .overlay(alignment: .bottomLeading) {
            TransientOverlayCountdownBar(
                startedAt: self.startedAt,
                duration: self.displayDuration,
                reduceMotion: self.reduceMotion
            )
        }
        .preferredColorScheme(.dark)
        .id(self.notice)
    }

    private var detailText: String {
        if self.notice.presentation == .startupSelection,
           let currentName = self.notice.currentName
        {
            return currentName
        }
        switch (self.notice.previousName, self.notice.currentName) {
        case let (previous?, current?):
            return "\(previous)  →  \(current)"
        case let (previous?, nil):
            return "\(previous) is no longer available"
        case let (nil, current?):
            return "Now using \(current)"
        case (nil, nil):
            return "Connect or restore a microphone in Settings"
        }
    }

    private var title: String {
        if self.notice.presentation == .startupSelection {
            return "Microphone selected"
        }
        return self.notice.currentName == nil ? "Microphone unavailable" : "Microphone changed"
    }

    private var explanation: String {
        if self.notice.currentName == nil {
            return "Choose an available microphone in Settings."
        }
        if self.notice.presentation == .startupSelection {
            return "FluidWispr will try this microphone first when you dictate."
        }
        if self.notice.presentation == .selectionChange {
            return "FluidWispr selected this microphone for capture."
        }
        return "FluidWispr confirmed this microphone is capturing audio."
    }
}

struct TransientOverlaySettingsButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fluidSystem(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : 0.9))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.20 : self.isHovered ? 0.14 : 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(configuration.isPressed ? 0.28 : 0.12),
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct TransientOverlayCountdownBar: View {
    let startedAt: Date
    let duration: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: self.reduceMotion ? 1 : 1 / 30)) { context in
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: proxy.size.width * self.remainingProgress(at: context.date))
                }
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 14)
        .padding(.bottom, 3)
        .allowsHitTesting(false)
    }

    private func remainingProgress(at date: Date) -> CGFloat {
        guard self.duration > 0 else { return 0 }
        return CGFloat(max(0, min(1, 1 - date.timeIntervalSince(self.startedAt) / self.duration)))
    }
}

struct TransientOverlayBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.15), .white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
    }
}

extension Notification.Name {
    static let openMicrophoneSettingsRequested = Notification.Name("OpenMicrophoneSettingsRequested")
}

private struct AutomaticDictionaryCorrectionOverlayView: View {
    @AppStorage("DictionarySharedFeatureMatcherEnabled") private var pronunciationEnabled = false
    @ObservedObject var session: AutomaticDictionaryTrainingSession
    @ObservedObject private var settings = SettingsStore.shared

    let displayDuration: TimeInterval
    let onDismiss: () -> Void
    let onIgnore: () -> Void
    let onFrequencyChange: (SettingsStore.AutomaticDictionarySuggestionFrequency) -> Void
    let onDisableSuggestions: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: FWMetric.radiusContainer, style: .continuous)
    }

    var body: some View {
        Group {
            switch self.session.screen {
            case .choice:
                self.choiceContent
            case .training:
                self.trainingContent
            case .success:
                self.successContent
            }
        }
        .padding(FWMetric.space5)
        .frame(width: 460, alignment: .leading)
        .background(self.panelShape.fill(FWColor.surfaceRaised))
        .overlay(alignment: .bottomTrailing) {
            if self.session.screen == .choice, !self.reduceMotion {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(FWColor.lineStrong)
                        .frame(width: proxy.size.width * self.progress, height: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay { self.panelShape.strokeBorder(FWColor.lineRule, lineWidth: FWMetric.lineHairline) }
        .recordNearBlack()
        .clipShape(self.panelShape)
        .preferredColorScheme(.dark)
        .animation(FWMotion.motion(reduced: self.reduceMotion), value: self.session.screen)
        .onAppear {
            self.startProgressAnimation()
        }
        .onChange(of: self.pronunciationEnabled) { _, enabled in
            if !enabled { self.session.disablePronunciationTraining() }
        }
    }

    private var correctionChoiceDescription: String {
        if self.session.candidate.negativeCorrection != nil {
            return "Confirm only if you said a different word. For a spelling change, edit the word in your dictionary instead."
        }
        return self.pronunciationEnabled
            ? "Save only this correction, or teach FluidWispr how you say it."
            : "Save this correction to your dictionary."
    }

    private var choiceContent: some View {
        VStack(alignment: .leading, spacing: FWMetric.space4) {
            self.header(title: self.session.candidate.negativeCorrection == nil ? "Learn this word?" : "Was this a wrong match?", allowsBack: false)

            self.correctionPair

            Text(self.correctionChoiceDescription)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: FWMetric.space3) {
                if self.session.candidate.negativeCorrection != nil {
                    Button("That was a wrong match", action: self.session.confirmWrongMatch)
                        .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                        .disabled(!self.pronunciationEnabled || self.session.capturePhase != .idle)
                    Button("Ignore", action: self.onIgnore)
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                } else {
                    Button("Add this correction", action: self.session.addOnlyCorrection)
                        .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                    if self.pronunciationEnabled {
                        Button("Train by voice", action: self.session.beginTraining)
                            .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                    }
                    RecordIconButton(icon: .more, action: self.showMoreOptions)
                        .accessibilityLabel("More correction options")
                }
            }
            if self.session.hasError {
                Text(self.session.statusMessage)
                    .recordText(FWType.detailStrong)
                    .foregroundStyle(FWColor.stateAttention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.opacity)
    }

    private func showMoreOptions() {
        let askAfter = NSMenu()
        for frequency in SettingsStore.AutomaticDictionarySuggestionFrequency.allCases {
            askAfter.addItem(DictionaryMenuItem(
                "After \(frequency.displayName)",
                isChecked: self.settings.automaticDictionarySuggestionFrequency == frequency
            ) {
                self.onFrequencyChange(frequency)
                self.startProgressAnimation()
            })
        }
        let askAfterItem = NSMenuItem(title: "Ask after", action: nil, keyEquivalent: "")
        askAfterItem.submenu = askAfter

        let menu = NSMenu()
        menu.addItem(DictionaryMenuItem("Ignore this correction", handler: self.onIgnore))
        menu.addItem(askAfterItem)
        menu.addItem(.separator())
        menu.addItem(DictionaryMenuItem("Stop asking", isDestructive: true, handler: self.onDisableSuggestions))
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private var trainingContent: some View {
        VStack(alignment: .leading, spacing: FWMetric.space4) {
            self.header(title: "Train by voice", allowsBack: true)

            self.correctionPair

            self.hairline

            Text("Say “\(self.session.candidate.correctedText)” in your normal voice, then pause. FluidWispr listens again on its own until it hears it right 3 times in a row.")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: FWMetric.space4) {
                HStack(spacing: FWMetric.space2) {
                    ForEach(0..<CustomDictionaryTrainingMerge.readyCoveredCount, id: \.self) { index in
                        RecordMark(state: index < self.session.readinessProgress ? .done : .waiting)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(self.session.readinessProgress) of \(CustomDictionaryTrainingMerge.readyCoveredCount) correct")

                self.trainingStatus
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(self.session.recordButtonTitle, action: self.session.toggleCapture)
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                    .disabled(!self.session.canUseRecordButton || self.session.isReady)
            }

            self.hairline

            HStack(spacing: FWMetric.space3) {
                Text("Final output")
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textTertiary)
                Text(self.session.finalOutputText)
                    .recordText(FWType.transcript)
                    .foregroundStyle(self.session.lastOutput.isEmpty ? FWColor.textTertiary : FWColor.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if self.session.isReady {
                    RecordMark(state: .done)
                    Text("Ready")
                        .recordText(FWType.detailStrong)
                        .foregroundStyle(FWColor.stateDone)
                }
            }

            if !self.session.variants.isEmpty {
                Text("Captured: \(self.session.variants.joined(separator: ", "))")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: FWMetric.space3) {
                Button("Add replacement", action: self.session.addTrainedReplacement)
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                    .disabled(!self.session.canSave)
                if !self.session.isReady {
                    let remaining = max(0, CustomDictionaryTrainingMerge.readyCoveredCount - self.session.readinessProgress)
                    Text("\(remaining) correct \(remaining == 1 ? "try" : "tries") to unlock Add replacement.")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textTertiary)
                }
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var trainingStatus: some View {
        if self.session.capturePhase == .recording {
            HStack(spacing: FWMetric.space4) {
                RecordingPillPreview(state: .listen, size: .medium)
                Text("Listening. Say “\(self.session.candidate.correctedText)”.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textPrimary)
            }
        } else if self.session.isReady {
            Text("Heard right 3 times in a row.")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.stateDone)
        } else if self.session.hasError, !self.session.statusMessage.isEmpty {
            Text(self.session.statusMessage)
                .recordText(FWType.detailStrong)
                .foregroundStyle(FWColor.stateAttention)
                .fixedSize(horizontal: false, vertical: true)
        } else if !self.session.statusMessage.isEmpty {
            Text(self.session.statusMessage)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
        }
    }

    private var successContent: some View {
        VStack(alignment: .leading, spacing: FWMetric.space4) {
            Text(self.session.successTitle)
                .recordText(FWType.section)
                .foregroundStyle(FWColor.textPrimary)
            HStack(spacing: FWMetric.space3) {
                RecordMark(state: .done)
                Text("“\(self.session.candidate.heardText)” will become “\(self.session.candidate.correctedText)” from now on.")
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.opacity)
    }

    private func header(title: String, allowsBack: Bool) -> some View {
        HStack(spacing: FWMetric.space3) {
            if allowsBack {
                RecordIconButton(icon: .back, size: .s, action: self.session.returnToChoice)
                    .disabled(self.session.capturePhase != .idle)
            }
            Text(title)
                .recordText(FWType.section)
                .foregroundStyle(FWColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            RecordIconButton(icon: .close, size: .s, action: self.onDismiss)
        }
    }

    private var correctionPair: some View {
        HStack(alignment: .firstTextBaseline, spacing: FWMetric.space3) {
            Text(self.session.candidate.heardText)
                .recordText(FWType.transcript)
                .foregroundStyle(FWColor.textSecondary)
            Text("→")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textTertiary)
            Text(self.session.candidate.correctedText)
                .recordText(FWType.transcript)
                .foregroundStyle(FWColor.textPrimary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hairline: some View {
        Rectangle()
            .fill(FWColor.lineRule)
            .frame(height: FWMetric.lineHairline)
    }

    private func startProgressAnimation() {
        self.progress = 1
        guard !self.reduceMotion else { return }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: self.displayDuration)) {
                self.progress = 0
            }
        }
    }
}
