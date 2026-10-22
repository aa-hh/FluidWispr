import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Presentation only: preserve the user's selected model and the language catalog's order.
enum OnboardingModelRecommendation {
    static func defaultRoutes(forLanguageID languageID: String, from availableRoutes: [VoiceEngineLanguageRoute]) -> [VoiceEngineLanguageRoute] {
        guard let first = availableRoutes.first else { return [] }
        guard languageID == "en" else { return [first] }
        if let english = availableRoutes.first(where: { $0.model == .parakeetTDTv2 }),
           let mini = availableRoutes.first(where: { $0.model == .fluidParakeetMini })
        {
            return [english, mini]
        }
        // Mini has the same architecture gate and a newer OS gate. Keep the
        // established cards when either preferred model is unavailable.
        var routes = [first]
        if let builtIn = availableRoutes.first(where: { $0.model == .appleSpeech || $0.model == .appleSpeechAnalyzer }),
           builtIn.id != first.id
        {
            routes.append(builtIn)
        }
        return routes
    }
}

/// First-run setup, drawn as the Record window: a setup sidebar with six counted steps,
/// then a ruled sheet per step. The voice model keeps downloading while the person moves
/// on to the permission steps.
struct OnboardingFlowView: View {
    @EnvironmentObject var appServices: AppServices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var asr: ASRService {
        self.appServices.asr
    }

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var installations = SpeechModelInstallationSnapshot.shared

    @Binding var currentStep: Int
    let accessibilityEnabled: Bool
    let accessibilitySetupInProgress: Bool
    let markAISkipped: () -> Void
    let finishOnboarding: () -> Void
    let finishOnboardingAtGettingStarted: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let menuBarManager: MenuBarManager
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    let theme: AppTheme
    /// Shows Settings › General. Done's "Open Settings" finishes setup, then calls this.
    var openSettings: () -> Void = {}

    static let playgroundStepIndex = Step.playground.rawValue
    static let cleanupStepIndex = Step.cleanup.rawValue

    @State private var selectedLanguageID = SettingsStore.shared.onboardingSelectedLanguageID
    @State private var selectedModelRouteID: String?
    @State private var onboardingInputDevices: [AudioDevice.Device] = []
    @State private var hasLoadedOnboardingInputs = false
    @State private var selectedOnboardingInputUID = ""
    @State private var previewedOnboardingInputUID: String?
    @State private var microphonePreviewTask: Task<Void, Never>?
    @State private var microphonePreviewGeneration: UInt64 = 0
    @State private var onboardingMicrophoneRefreshGeneration: UInt64 = 0
    @State private var isOnboardingFlowVisible = false
    @State private var isRequestingMicrophone = false
    @State private var isShowingOtherModelRoutes = false
    @State private var preparingModelRouteID: String?
    @State private var modelPreparationTask: Task<Void, Never>?
    @State private var lastDownloadFraction: Double = 0
    @State private var modelDownloadFailedBytes: Int64?
    @State private var languageSearchText = ""
    @State private var accessibilitySettingsClosedEarly = false
    @State private var tryoutNothingHeard = false
    @State private var tryoutValidatedAt: Date?
    @State private var cerebrasKeyText = ""
    @State private var cerebrasKeyCheck: CerebrasKeyState = .idle
    @State private var ollamaRunning = false

    enum Step: Int, CaseIterable {
        case landing = 0
        case language = 1
        case voiceModel = 2
        case microphone = 3
        case accessibility = 4
        case playground = 5
        case cleanup = 6
        case done = 7

        static let counted: [Step] = [.language, .voiceModel, .microphone, .accessibility, .playground, .cleanup]

        var analyticsStep: AnalyticsOnboardingStep {
            switch self {
            case .landing: .welcome
            case .language: .language
            case .voiceModel: .voiceModel
            case .microphone: .microphone
            case .accessibility: .accessibility
            case .playground: .playground
            case .cleanup: .cleanup
            case .done: .done
            }
        }

        var sidebarLabel: String {
            switch self {
            case .landing, .done: ""
            case .language: "Language"
            case .voiceModel: "Voice model"
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            case .playground: "Try it"
            case .cleanup: "Cleanup"
            }
        }
    }

    /// The voice model step lets the person continue once the model is ready, and also
    /// while it downloads or after the download failed, so setup carries on meanwhile.
    static func voiceModelCanContinue(isReady: Bool, downloadStarted: Bool, downloadFailed: Bool) -> Bool {
        isReady || downloadStarted || downloadFailed
    }

    private enum VoiceModelState {
        case notDownloaded
        case downloading
        case failed
        case ready
    }

    private enum MicrophoneState {
        case notAsked
        case waiting
        case allowed
        case turnedOff
        case noMicrophone
    }

    private enum AccessibilityState {
        case notAsked
        case waiting
        case closedEarly
        case turnedOn
    }

    private enum CerebrasKeyState {
        case idle
        case checking
        case connected
        case rejected
        case unreachable
        case keychainFailed
    }

    private var step: Step {
        Step(rawValue: self.currentStep) ?? .voiceModel
    }

    private var popularOnboardingLanguages: [VoiceEngineLanguage] {
        VoiceEngineLanguageCatalog.popularLanguages()
    }

    private var selectedOnboardingLanguage: VoiceEngineLanguage {
        VoiceEngineLanguageCatalog.language(id: self.selectedLanguageID)
            ?? VoiceEngineLanguageCatalog.language(id: "en")
            ?? VoiceEngineLanguage(id: "en", displayName: "English", aliases: [], isPopular: true)
    }

    private var searchedOnboardingLanguages: [VoiceEngineLanguage] {
        VoiceEngineLanguageCatalog.searchableLanguages(query: self.languageSearchText)
    }

    private var selectedLanguageRoutes: [VoiceEngineLanguageRoute] {
        VoiceEngineLanguageCatalog.routes(for: self.selectedOnboardingLanguage)
    }

    private var selectedOnboardingRoute: VoiceEngineLanguageRoute? {
        if let selectedModelRouteID,
           let selectedRoute = self.selectedLanguageRoutes.first(where: { $0.id == selectedModelRouteID })
        {
            return selectedRoute
        }

        if let selectedRoute = self.selectedLanguageRoutes.first(where: { self.isRouteSelectedInSettings($0) }) {
            return selectedRoute
        }

        return self.selectedLanguageRoutes.first
    }

    private var otherModelRoutes: [VoiceEngineLanguageRoute] {
        self.selectedLanguageRoutes.filter { $0.id != self.selectedOnboardingRoute?.id }
    }

    private var recommendedOnboardingModel: SpeechModel {
        self.selectedOnboardingRoute?.model ?? SpeechModel.defaultModel
    }

    private var isVoiceModelReady: Bool {
        guard let route = self.selectedOnboardingRoute else {
            return false
        }
        return self.isRouteSelectedInSettings(route) && self.asr.isAsrReady
    }

    private var isModelPreparationInProgress: Bool {
        self.preparingModelRouteID != nil
            || self.asr.hasActiveModelPreparation
            || self.asr.hasActiveModelDownload
            || self.asr.isCancellingModelPreparation
            || self.asr.isDownloadingModel
            || (self.asr.isLoadingModel && !self.asr.isAsrReady)
    }

    private var voiceModelState: VoiceModelState {
        if self.isVoiceModelReady { return .ready }
        if self.isModelPreparationInProgress { return .downloading }
        if self.modelDownloadFailedBytes != nil { return .failed }
        return .notDownloaded
    }

    private var isMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    private var microphoneState: MicrophoneState {
        switch self.asr.micStatus {
        case .authorized:
            let hasError = !(self.asr.microphonePreviewError ?? "").isEmpty
            let noDevices = self.hasLoadedOnboardingInputs && self.onboardingInputDevices.isEmpty
            return hasError || noDevices ? .noMicrophone : .allowed
        case .denied, .restricted:
            return .turnedOff
        default:
            return self.isRequestingMicrophone ? .waiting : .notAsked
        }
    }

    private var accessibilityState: AccessibilityState {
        if self.accessibilityEnabled { return .turnedOn }
        if self.accessibilitySetupInProgress { return .waiting }
        return self.accessibilitySettingsClosedEarly ? .closedEarly : .notAsked
    }

    private var isPlaygroundReady: Bool {
        self.settings.onboardingPlaygroundValidated || self.settings.onboardingPlaygroundSkipped
    }

    private var keyHint: (key: String, holds: Bool) {
        self.settings.dictationKeyHint
    }

    private var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    private var isRecordingPrimaryShortcut: Bool {
        self.activeShortcutRecordingTarget?.isPrimaryDictation == true
    }

    private var tryoutPhase: OnboardingTryoutStepView.Phase {
        if self.isRecordingPrimaryShortcut {
            let message = (self.shortcutRecordingMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? .changingKey : .keyConflict(message)
        }
        if self.asr.isRunning { return .listening }
        if self.settings.onboardingPlaygroundValidated { return .worked(self.tryoutValidatedAt) }
        if !self.isVoiceModelReady, self.isModelPreparationInProgress { return .waitingForModel }
        if self.tryoutNothingHeard { return .nothingHeard }
        return .ready
    }

    private var canContinue: Bool {
        switch self.step {
        case .landing, .cleanup, .done:
            return true
        case .language:
            return !self.selectedLanguageRoutes.isEmpty
        case .voiceModel:
            return Self.voiceModelCanContinue(
                isReady: self.isVoiceModelReady,
                downloadStarted: self.isModelPreparationInProgress,
                downloadFailed: self.modelDownloadFailedBytes != nil
            )
        case .microphone:
            return self.isMicrophoneReady
        case .accessibility:
            return self.accessibilityEnabled
        case .playground:
            return self.isPlaygroundReady && !self.asr.isRunning && !self.isRecordingAnyShortcut
        }
    }

    private var currentStepNeedsYou: Bool {
        switch self.step {
        case .voiceModel:
            return self.voiceModelState == .failed
        case .microphone:
            return self.microphoneState == .turnedOff || self.microphoneState == .noMicrophone
        case .accessibility:
            return self.accessibilityState == .closedEarly
        case .playground:
            switch self.tryoutPhase {
            case .keyConflict, .nothingHeard: return true
            default: return false
            }
        case .cleanup:
            return self.cerebrasKeyCheck == .rejected
        case .landing, .language, .done:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            self.setupSidebar
            Rectangle()
                .fill(FWColor.lineRule)
                .frame(width: FWMetric.lineHairline)
            self.stepContent
                .id(self.step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: self.reduceMotion ? FWMotion.durationReduceCrossfade : FWMotion.durationEnter), value: self.currentStep)
        .background(FWColor.surfaceWindow)
        .onAppear {
            self.installations.refresh()
            Task {
                let catalog = CompactSpeechModelReleaseCatalog.shared
                let revision = catalog.revision
                await catalog.refreshIfNeeded()
                if catalog.revision != revision { self.installations.refresh() }
            }
            self.isOnboardingFlowVisible = true
            self.syncOnboardingSelectionFromSettings()
            self.refreshOnboardingMicrophoneAuthorization(checkModels: true)
            let origin = self.settings.analyticsOnboardingOrigin
            AnalyticsService.shared.recordOnboardingStarted(origin: origin)
            AnalyticsService.shared.recordOnboardingStepViewed(self.step.analyticsStep, origin: origin)
        }
        .onChange(of: self.currentStep) { _, _ in
            self.tryoutNothingHeard = false
            if self.step == .microphone, self.isMicrophoneReady {
                self.refreshOnboardingMicrophones(startPreview: true)
            } else {
                self.stopOnboardingMicrophonePreview()
            }
            if self.step == .cleanup {
                self.refreshOllamaStatus()
            }
            AnalyticsService.shared.recordOnboardingStepViewed(
                self.step.analyticsStep,
                origin: self.settings.analyticsOnboardingOrigin
            )
        }
        .onChange(of: self.isMicrophoneReady) { _, isReady in
            guard self.step == .microphone else { return }
            if isReady {
                self.refreshOnboardingMicrophones(startPreview: true)
            } else {
                self.stopOnboardingMicrophonePreview()
            }
        }
        .onChange(of: self.asr.micStatus) { _, status in
            if status != .notDetermined {
                self.isRequestingMicrophone = false
            }
        }
        .onChange(of: self.asr.isStarting) { _, isStarting in
            guard self.isOnboardingFlowVisible,
                  self.step == .microphone,
                  self.isMicrophoneReady
            else { return }
            if isStarting {
                self.suspendOnboardingMicrophonePreviewForDictation()
            }
        }
        .onChange(of: self.asr.isRunning) { wasRunning, isRunning in
            guard self.step == .playground else { return }
            if isRunning {
                self.tryoutNothingHeard = false
            } else if wasRunning, self.asr.lastStopOutcome != .success {
                self.tryoutNothingHeard = true
            }
        }
        .onChange(of: self.settings.onboardingPlaygroundValidated) { _, validated in
            self.tryoutValidatedAt = validated ? Date() : nil
            if validated { self.tryoutNothingHeard = false }
        }
        .onChange(of: self.asr.downloadProgress) { _, progress in
            if let progress { self.lastDownloadFraction = progress }
        }
        .onChange(of: self.accessibilitySetupInProgress) { wasInProgress, inProgress in
            if inProgress {
                self.accessibilitySettingsClosedEarly = false
            } else if wasInProgress, !self.accessibilityEnabled {
                self.accessibilitySettingsClosedEarly = true
            }
        }
        .onReceive(self.asr.audioCaptureStateDidSettle) {
            guard self.isOnboardingFlowVisible,
                  self.step == .microphone,
                  self.isMicrophoneReady
            else { return }
            if self.asr.isRunning || self.asr.isStarting {
                self.suspendOnboardingMicrophonePreviewForDictation()
            } else {
                self.refreshOnboardingMicrophones(startPreview: true)
            }
        }
        .onDisappear {
            self.isOnboardingFlowVisible = false
            self.onboardingMicrophoneRefreshGeneration &+= 1
            // Only an abandoned setup stops the download; after Done it carries on.
            if !self.settings.onboardingCompleted {
                self.cancelOnboardingModelPreparation()
            }
            self.stopOnboardingMicrophonePreview()
        }
        .onChange(of: self.appServices.audioObserver.changeTick) { _, _ in
            guard self.step == .microphone, self.isMicrophoneReady else { return }
            self.refreshOnboardingMicrophones(startPreview: true)
        }
        .onChange(of: self.appServices.audioObserver.inputAvailabilityTick) { _, _ in
            guard self.step == .microphone, self.isMicrophoneReady else { return }
            self.refreshOnboardingMicrophones(startPreview: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.syncOnboardingSelectionFromSettings()
            self.refreshOnboardingMicrophoneAuthorization()
        }
    }

    // MARK: - Sidebar

    private var setupSidebar: some View {
        RecordSidebar(groups: [RecordSidebarGroup<Int>](), onSelect: { _ in }) {
            // The real window buttons sit here.
            Color.clear
                .frame(height: 12)
                .padding(.bottom, FWMetric.space6)
            Text("Setup")
                .recordText(FWType.small)
                .foregroundStyle(FWColor.textSecondary)
                .padding(.leading, FWMetric.space4)
                .padding(.top, FWMetric.space3)
                .padding(.bottom, FWMetric.space1)
                .accessibilityAddTraits(.isHeader)
            ForEach(Step.counted, id: \.self) { step in
                RecordSetupStep(label: step.sidebarLabel, state: self.setupState(for: step))
            }
        } footer: {
            if self.step.rawValue > Step.voiceModel.rawValue {
                self.downloadBlock
            }
            Text(self.sidebarFooterText)
                .recordText(FWType.small)
                .foregroundStyle(FWColor.textSecondary)
                .padding(.leading, FWMetric.space4)
                .padding(.bottom, FWMetric.space2)
        }
    }

    @ViewBuilder
    private var downloadBlock: some View {
        let state = self.voiceModelState
        if state == .downloading || state == .failed {
            VStack(alignment: .leading, spacing: FWMetric.space2) {
                if state == .failed {
                    HStack(spacing: FWMetric.space2) {
                        RecordMark(state: .needsYou)
                        Text("Download stopped")
                            .recordText(FWType.smallStrong)
                            .foregroundStyle(FWColor.stateAttention)
                    }
                    Button("Try again") {
                        self.currentStep = Step.voiceModel.rawValue
                    }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                } else {
                    Text("Voice model downloading")
                        .recordText(FWType.smallStrong)
                        .foregroundStyle(FWColor.textSecondary)
                    RecordProgressLine(fraction: self.downloadFraction)
                        .frame(width: 152)
                    Text(self.downloadProgressText)
                        .recordText(FWType.small)
                        .foregroundStyle(FWColor.textSecondary)
                }
            }
            .padding(.top, FWMetric.space2)
            .padding([.leading, .trailing, .bottom], FWMetric.space4)
        }
    }

    private var sidebarFooterText: String {
        switch self.step {
        case .landing: "6 steps"
        case .done: "All 6 steps done"
        default: "Step \(self.step.rawValue) of 6"
        }
    }

    private func setupState(for step: Step) -> RecordSetupStep.State {
        if step == self.step {
            return self.currentStepNeedsYou ? .currentNeedsYou : .current
        }
        if step == .voiceModel, self.step.rawValue > Step.voiceModel.rawValue {
            switch self.voiceModelState {
            case .failed: return .needsYou
            case .downloading: return .working
            case .notDownloaded, .ready: break
            }
        }
        return step.rawValue < self.step.rawValue ? .done : .next
    }

    // MARK: - Sheet

    @ViewBuilder
    private var stepContent: some View {
        switch self.step {
        case .landing: self.landingStep
        case .language: self.languageStep
        case .voiceModel: self.voiceModelStep
        case .microphone: self.microphoneStep
        case .accessibility: self.accessibilityStep
        case .playground: self.playgroundStep
        case .cleanup: self.cleanupStep
        case .done: self.doneStep
        }
    }

    private func sheet(
        title: String,
        subtitle: String,
        hint: String,
        @ViewBuilder rows: () -> some View,
        @ViewBuilder buttons: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            RecordHeader(title, subtitle: subtitle)
            Rectangle()
                .fill(FWColor.lineRule)
                .frame(height: FWMetric.lineHairline)
            ScrollView {
                VStack(spacing: 0) {
                    rows()
                }
            }
            Rectangle()
                .fill(FWColor.lineRule)
                .frame(height: FWMetric.lineHairline)
            HStack(spacing: 0) {
                Text(hint)
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, FWMetric.space7)
                    .padding(.trailing, FWMetric.space5)
                    .padding(.vertical, FWMetric.space4)
                    .frame(width: FWMetric.sizeMargin, alignment: .leading)
                RecordMarginRule()
                HStack(spacing: FWMetric.space3) {
                    Spacer(minLength: 0)
                    buttons()
                }
                .padding(.leading, FWMetric.space7)
                .padding(.trailing, FWMetric.space8)
                .padding(.vertical, FWMetric.space4)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, FWMetric.space8)
    }

    private func row(
        _ name: String,
        help: String? = nil,
        attention: Bool = false,
        @ViewBuilder content: () -> some View
    ) -> some View {
        RecordLine {
            Text(name)
                .recordText(FWType.label)
                .foregroundStyle(attention ? FWColor.stateAttention : FWColor.textPrimary)
            if let help {
                Text(help)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            content()
        }
    }

    private func status(_ mark: RecordMark.State, _ text: String) -> some View {
        HStack(spacing: FWMetric.space2) {
            RecordMark(state: mark)
            Text(text)
                .recordText(FWType.label)
                .foregroundStyle(self.statusColor(mark))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusColor(_ mark: RecordMark.State) -> Color {
        switch mark {
        case .done: FWColor.stateDone
        case .needsYou: FWColor.stateAttention
        default: FWColor.textSecondary
        }
    }

    private func bodyText(_ text: String, secondary: Bool = false) -> some View {
        Text(text)
            .recordText(FWType.body)
            .foregroundStyle(secondary ? FWColor.textSecondary : FWColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func numberedSteps(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: FWMetric.space2) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .firstTextBaseline, spacing: FWMetric.space3) {
                    Text("\(index + 1)")
                        .recordText(FWType.body)
                        .foregroundStyle(FWColor.textTertiary)
                        .frame(width: 12, alignment: .leading)
                    self.bodyText(text)
                }
            }
        }
    }

    private var backButton: some View {
        Button("Back", action: self.goBack)
            .buttonStyle(RecordButtonStyle(kind: .secondary))
            .keyboardShortcut(.cancelAction)
            .disabled(self.asr.isRunning || self.isRecordingAnyShortcut)
    }

    /// The footer's Continue. It takes Return only when it is the step's primary button.
    private func continueButton(isPrimary: Bool) -> some View {
        Button("Continue", action: self.handlePrimaryAction)
            .buttonStyle(RecordButtonStyle(kind: isPrimary ? .primary : .secondary))
            .keyboardShortcut(isPrimary ? .defaultAction : nil)
            .disabled(!self.canContinue)
    }

    private func pill(_ state: RimState) -> some View {
        RecordingPillPreview(state: state, size: .medium)
    }

    // MARK: - Welcome

    private var landingStep: some View {
        self.sheet(
            title: "Dictate into any app",
            subtitle: self.keyHint.holds
                ? "Hold a key, talk, and let go. Your words appear where the cursor is."
                : "Press a key, talk, and press it again. Your words appear where the cursor is.",
            hint: "Return to start."
        ) {
            self.row("The pill", help: "Shown while you talk") {
                self.pill(.idle)
                self.bodyText("It sits at the bottom of your screen. Its rim follows your voice and turns green when the text lands.", secondary: true)
            }
            self.row("On this Mac") {
                self.bodyText("Speech becomes text here, on this Mac. Nothing you say is sent anywhere unless you add a cloud key for cleanup.")
            }
            self.row("Setup covers") {
                self.bodyText("Your language, the voice model, microphone and Accessibility access, a short test where you can change your dictation key, and optional cleanup.")
            }
        } buttons: {
            Button("Get started", action: self.handlePrimaryAction)
                .buttonStyle(RecordButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Language

    private var languageStep: some View {
        self.sheet(
            title: "Which language do you speak most?",
            subtitle: "This picks the voice model. You can change it later in Settings.",
            hint: "Return continues. Escape goes back."
        ) {
            self.row("Language", help: "Most used") {
                VStack(alignment: .leading, spacing: FWMetric.space3) {
                    ForEach(self.popularOnboardingLanguages) { language in
                        RecordRadio(label: language.displayName, isSelected: self.selectedLanguageID == language.id) {
                            self.selectOnboardingLanguage(language)
                        }
                    }
                }
            }
            self.row("Other languages") {
                RecordField(placeholder: "Search all languages", text: self.$languageSearchText)
                    .frame(width: 320)
                VStack(alignment: .leading, spacing: FWMetric.space3) {
                    ForEach(self.otherLanguageChoices) { language in
                        RecordRadio(label: language.displayName, isSelected: self.selectedLanguageID == language.id) {
                            self.selectOnboardingLanguage(language)
                        }
                    }
                }
            }
        } buttons: {
            self.backButton
            self.continueButton(isPrimary: true)
        }
    }

    /// Search results, or the chosen language when it is not one of the popular ones.
    private var otherLanguageChoices: [VoiceEngineLanguage] {
        if self.languageSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return self.selectedOnboardingLanguage.isPopular ? [] : [self.selectedOnboardingLanguage]
        }
        return self.searchedOnboardingLanguages
    }

    private func selectOnboardingLanguage(_ language: VoiceEngineLanguage) {
        guard self.selectedLanguageID != language.id else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedLanguageID = language.id
            self.settings.onboardingSelectedLanguageID = language.id
            self.selectedModelRouteID = VoiceEngineLanguageCatalog.routes(for: language).first?.id
            self.isShowingOtherModelRoutes = false
            if language.isPopular {
                self.languageSearchText = ""
            }
            self.resetTryoutValidationForSetupChange()
        }
    }

    private func syncOnboardingSelectionFromSettings() {
        let allRoutes = VoiceEngineLanguageCatalog.allLanguages()
            .flatMap { VoiceEngineLanguageCatalog.routes(for: $0) }

        let storedLanguageID = self.settings.onboardingSelectedLanguageID
        let storedLanguageRoutes = VoiceEngineLanguageCatalog.routes(forLanguageID: storedLanguageID)
        let route = storedLanguageRoutes.first { route in
            self.isRouteModelAndLanguageSettingsSelected(route)
        } ?? storedLanguageRoutes.first ?? allRoutes.first { route in
            self.isRouteModelAndLanguageSettingsSelected(route)
        }

        guard let route else {
            if self.selectedModelRouteID == nil {
                self.selectedModelRouteID = self.selectedLanguageRoutes.first?.id
            }
            return
        }

        guard self.selectedLanguageID != route.language.id || self.selectedModelRouteID != route.id else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedLanguageID = route.language.id
            self.selectedModelRouteID = route.id
            self.isShowingOtherModelRoutes = false
            self.languageSearchText = ""
        }
    }

    // MARK: - Voice model

    private var voiceModelStep: some View {
        let state = self.voiceModelState
        let route = self.selectedOnboardingRoute
        let hint: String = switch state {
        case .notDownloaded: "Return downloads."
        case .downloading: "Continue goes on while it downloads."
        case .failed: "Return tries again."
        case .ready: "Return continues. Escape goes back."
        }
        return self.sheet(
            title: "Download the voice model",
            subtitle: "Speech recognition runs on this Mac, so it needs a model first.",
            hint: hint
        ) {
            self.row("Model", help: route?.id == self.selectedLanguageRoutes.first?.id ? "Recommended for \(self.selectedOnboardingLanguage.displayName)" : nil) {
                Text(Self.modelName(self.recommendedOnboardingModel))
                    .recordText(FWType.label)
                    .foregroundStyle(FWColor.textPrimary)
                self.bodyText(Self.modelDescription(self.recommendedOnboardingModel), secondary: true)
            }
            if !self.otherModelRoutes.isEmpty {
                self.row("Other models") {
                    Button(self.isShowingOtherModelRoutes ? "Hide other models" : "Show other models") {
                        self.isShowingOtherModelRoutes.toggle()
                    }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                    if self.selectedOnboardingLanguage.id == "en" {
                        self.bodyText("Parakeet v2 for English only, Whisper, and more.", secondary: true)
                    }
                    if self.isShowingOtherModelRoutes {
                        VStack(alignment: .leading, spacing: FWMetric.space3) {
                            ForEach(self.otherModelRoutes) { other in
                                RecordRadio(label: Self.modelName(other.model), isSelected: false) {
                                    self.selectOnboardingRoute(other)
                                }
                                .disabled(self.isModelPreparationInProgress || self.asr.isRunning)
                            }
                        }
                    }
                }
            }
            self.row("Download") {
                switch state {
                case .notDownloaded:
                    self.bodyText("\(self.totalDownloadText), stored on this Mac. You can remove it later in Settings.")
                    Button("Download") {
                        if let route { self.prepareOnboardingRoute(route) }
                    }
                    .buttonStyle(RecordButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(route == nil || !self.installations.canUseModelActions || self.asr.isRunning)
                case .downloading:
                    RecordProgressLine(fraction: self.downloadFraction)
                        .frame(width: 400)
                    Text(self.downloadProgressText)
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                    Button("Cancel", action: self.cancelOnboardingModelPreparation)
                        .buttonStyle(RecordButtonStyle(kind: .secondary))
                        .disabled(self.asr.isCancellingModelPreparation || self.asr.isCancellingModelDownload)
                case .failed:
                    self.status(.needsYou, "Download stopped at \(Self.megabytes(self.modelDownloadFailedBytes ?? 0))")
                    self.bodyText("The connection dropped. Check that you are online, then try again.")
                    Button("Try again") {
                        if let route { self.prepareOnboardingRoute(route) }
                    }
                    .buttonStyle(RecordButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(route == nil || self.asr.isRunning)
                case .ready:
                    self.status(.done, "Downloaded and ready")
                    self.bodyText("\(self.totalDownloadText) on this Mac.")
                }
            }
        } buttons: {
            self.backButton
            self.continueButton(isPrimary: state == .downloading || state == .ready)
        }
    }

    static func modelName(_ model: SpeechModel) -> String {
        switch model {
        case .parakeetTDT: "Parakeet TDT v3"
        case .parakeetTDTv2: "Parakeet TDT v2"
        default: model.humanReadableName
        }
    }

    private static func modelDescription(_ model: SpeechModel) -> String {
        model == .parakeetTDT
            ? "Fast and accurate, and works offline. It also understands 24 other European languages."
            : model.cardDescription
    }

    private static let megabyteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting = false
        formatter.isAdaptive = false
        return formatter
    }()

    private static func megabytes(_ bytes: Int64) -> String {
        self.megabyteFormatter.string(fromByteCount: bytes)
    }

    private var totalDownloadBytes: Int64 {
        self.recommendedOnboardingModel.expectedDownloadBytes
    }

    private var totalDownloadText: String {
        self.totalDownloadBytes > 0 ? Self.megabytes(self.totalDownloadBytes) : self.recommendedOnboardingModel.downloadSize
    }

    private var downloadFraction: Double {
        self.asr.downloadProgress ?? self.lastDownloadFraction
    }

    /// "212 MB of 483 MB", or the preparation phase once the bytes are in.
    private var downloadProgressText: String {
        guard self.totalDownloadBytes > 0, self.asr.downloadProgress != nil || self.lastDownloadFraction > 0 else {
            return self.asr.modelPreparationStatusText
        }
        let done = Int64(Double(self.totalDownloadBytes) * min(max(self.downloadFraction, 0), 1))
        return "\(Self.megabytes(done)) of \(Self.megabytes(self.totalDownloadBytes))"
    }

    private func prepareOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        guard self.installations.canUseModelActions, !self.asr.isRunning, !self.isModelPreparationInProgress else { return }

        self.modelPreparationTask?.cancel()
        self.modelDownloadFailedBytes = nil
        self.lastDownloadFraction = 0
        self.preparingModelRouteID = route.id
        self.selectOnboardingRoute(route)

        self.modelPreparationTask = Task { @MainActor in
            defer {
                self.preparingModelRouteID = nil
                self.modelPreparationTask = nil
            }

            do {
                try await self.asr.ensureAsrReady(source: .onboarding)
            } catch is CancellationError {
                DebugLogger.shared.info("Cancelled onboarding voice model setup for \(route.model.displayName)", source: "OnboardingFlowView")
            } catch {
                DebugLogger.shared.error("Failed to prepare onboarding voice model \(route.model.displayName): \(error)", source: "OnboardingFlowView")
                // The voice model step and the setup sidebar show the failure with Try again.
                self.modelDownloadFailedBytes = Int64(Double(route.model.expectedDownloadBytes) * self.lastDownloadFraction)
            }
            guard !Task.isCancelled else { return }
            await self.asr.checkIfModelsExistAsync()
        }
    }

    private func cancelOnboardingModelPreparation() {
        self.modelPreparationTask?.cancel()
        if self.asr.hasActiveModelDownload {
            self.asr.cancelModelDownload()
        } else {
            self.asr.cancelModelPreparation()
        }
    }

    private func isRouteModelAndLanguageSettingsSelected(_ route: VoiceEngineLanguageRoute) -> Bool {
        guard route.model == self.settings.selectedSpeechModel else {
            return false
        }

        switch route.binding {
        case .automatic, .whisper:
            return true
        case let .appleSpeech(localeIdentifier):
            return self.settings.selectedAppleSpeechLocaleIdentifier == localeIdentifier
        case let .cohere(language):
            return self.settings.selectedCohereLanguage == language
        case let .nemotron(language):
            return self.settings.selectedNemotronLanguage == language
        }
    }

    private func selectOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        let oldModel = self.settings.selectedSpeechModel
        let oldAppleSpeechLocaleIdentifier = self.settings.selectedAppleSpeechLocaleIdentifier
        let oldCohereLanguage = self.settings.selectedCohereLanguage
        let oldNemotronLanguage = self.settings.selectedNemotronLanguage

        self.selectedModelRouteID = route.id
        VoiceEngineLanguageCatalog.apply(route, to: self.settings)

        let languageChanged: Bool
        switch route.binding {
        case .automatic, .whisper:
            languageChanged = false
        case .appleSpeech:
            languageChanged = oldAppleSpeechLocaleIdentifier != self.settings.selectedAppleSpeechLocaleIdentifier
        case .cohere:
            languageChanged = oldCohereLanguage != self.settings.selectedCohereLanguage
        case .nemotron:
            languageChanged = oldNemotronLanguage != self.settings.selectedNemotronLanguage
        }

        if oldModel != self.settings.selectedSpeechModel || languageChanged {
            self.resetTryoutValidationForSetupChange()
            self.asr.resetTranscriptionProvider()
        }
    }

    // MARK: - Microphone

    private var microphoneStep: some View {
        let state = self.microphoneState
        let subtitle: String = switch state {
        case .notAsked, .waiting: "macOS asks once. Choose Allow in its dialog."
        case .allowed: "Pick the microphone you talk into. Speak to check it hears you."
        case .turnedOff: "FluidWispr can’t hear you until the microphone is turned on for it."
        case .noMicrophone: "Access is allowed, but macOS doesn’t see a microphone right now."
        }
        let hint: String = switch state {
        case .notAsked: "Return asks macOS."
        case .waiting: "The dialog has keyboard focus."
        case .turnedOff: "Return opens System Settings."
        case .allowed, .noMicrophone: "Return continues. Escape goes back."
        }
        return self.sheet(title: "Let FluidWispr hear you", subtitle: subtitle, hint: hint) {
            switch state {
            case .notAsked, .waiting:
                self.row("Microphone") {
                    self.status(.waiting, state == .waiting ? "Waiting for your answer in the macOS dialog" : "Not allowed yet")
                    Button("Allow microphone") {
                        self.isRequestingMicrophone = true
                        self.asr.requestMicAccess()
                    }
                    .buttonStyle(RecordButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(state == .waiting)
                }
                self.row("What it hears") {
                    self.bodyText("FluidWispr listens only while dictation is on. Speech is turned into text on this Mac.")
                }
            case .allowed:
                self.row("Microphone") {
                    self.status(.done, "Allowed")
                }
                self.row("Input", help: "Used for dictation") {
                    self.inputPopUp
                }
                self.row("Level", help: "Live") {
                    HStack(spacing: FWMetric.space3) {
                        self.pill(.listen)
                        self.bodyText("Speak. The rim follows your voice.")
                    }
                }
            case .turnedOff:
                self.row("Microphone") {
                    self.status(.needsYou, "Microphone access is off for FluidWispr")
                }
                self.row("How to fix") {
                    self.numberedSteps([
                        "Open Microphone settings.",
                        "Turn on FluidWispr in the list.",
                        "Come back to this window. It checks again when you return.",
                    ])
                    Button("Open Microphone settings") { self.asr.openSystemSettingsForMic() }
                        .buttonStyle(RecordButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            case .noMicrophone:
                self.row("Microphone") {
                    self.status(.done, "Allowed")
                }
                if self.onboardingInputDevices.isEmpty {
                    self.row("Input") {
                        self.status(.needsYou, "No microphone found")
                        self.bodyText("Plug in a microphone or headset. It appears here as soon as macOS sees it.")
                    }
                } else {
                    self.row("Input", help: "Used for dictation") {
                        self.status(.needsYou, self.asr.microphonePreviewError ?? "No microphone found")
                        self.inputPopUp
                    }
                }
            }
        } buttons: {
            self.backButton
                .disabled(state == .waiting)
            self.continueButton(isPrimary: state == .allowed || state == .noMicrophone)
        }
    }

    private var inputPopUp: some View {
        RecordPopUp(self.orderedOnboardingInputDevices.first { $0.uid == self.selectedOnboardingInputUID }?.name ?? "Choose microphone") {
            ForEach(self.orderedOnboardingInputDevices) { device in
                Button(device.name) { self.selectOnboardingMicrophone(uid: device.uid) }
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityStep: some View {
        let state = self.accessibilityState
        let hint: String = switch state {
        case .notAsked, .closedEarly: "Return opens System Settings."
        case .waiting: "The guide stays beside System Settings."
        case .turnedOn: "Return continues. Escape goes back."
        }
        return self.sheet(
            title: "Let FluidWispr type for you",
            subtitle: "Lets FluidWispr notice your dictation key in any app and put text where your cursor is.",
            hint: hint
        ) {
            switch state {
            case .notAsked:
                self.row("Accessibility") {
                    self.status(.waiting, "Not turned on yet")
                    self.openSystemSettingsButton
                }
            case .waiting:
                self.row("Accessibility", help: "In System Settings") {
                    self.status(.waiting, "Waiting for macOS to confirm")
                    self.bodyText("Already turned it on? This page updates within two seconds.")
                    Button("Show the guide again", action: self.openAccessibilitySettings)
                        .buttonStyle(RecordButtonStyle(kind: .secondary))
                }
            case .closedEarly:
                self.row("Accessibility") {
                    self.status(.needsYou, "System Settings closed before FluidWispr was turned on")
                    self.bodyText("Nothing is lost. Open it again and finish with the guide.")
                    self.openSystemSettingsButton
                }
            case .turnedOn:
                self.row("Accessibility") {
                    self.status(.done, "Turned on")
                    self.bodyText("FluidWispr can now hear your dictation key in any app and paste into it.")
                }
            }
            if state != .turnedOn {
                self.row("What happens") {
                    self.numberedSteps([
                        "System Settings opens, with this window beside it.",
                        "A small guide appears below Settings.",
                        "Drag FluidWispr from the guide into the list, then turn it on.",
                    ])
                }
            }
        } buttons: {
            self.backButton
            self.continueButton(isPrimary: state == .turnedOn)
        }
    }

    private var openSystemSettingsButton: some View {
        Button("Open System Settings", action: self.openAccessibilitySettings)
            .buttonStyle(RecordButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
    }

    // MARK: - Try it

    private var playgroundStep: some View {
        let phase = self.tryoutPhase
        let key = self.keyHint.key
        let isWorked: Bool = if case .worked = phase { true } else { false }
        let hint: String = switch phase {
        case .ready, .nothingHeard: "Tab reaches Skip."
        case .changingKey, .keyConflict: "Escape cancels."
        case .waitingForModel: "You can change the key while you wait."
        case .listening: "Escape stops without pasting."
        case .worked: "Return continues. Escape goes back."
        }
        return self.sheet(
            title: "Try it",
            subtitle: self.keyHint.holds
                ? "Click the box, hold \(key) and say something, then let go. Nothing is pasted into other apps."
                : "Click the box, press \(key) and say something. Nothing is pasted into other apps.",
            hint: hint
        ) {
            OnboardingTryoutStepView(
                finalText: Binding(
                    get: { self.asr.finalText },
                    set: { self.asr.finalText = $0 }
                ),
                language: self.selectedOnboardingLanguage,
                keyHint: self.keyHint,
                phase: phase,
                download: self.isModelPreparationInProgress ? (text: self.downloadProgressText, fraction: self.downloadFraction) : nil,
                onToggleShortcut: self.togglePrimaryShortcutRecording,
                onChangeMicrophone: { self.currentStep = Step.microphone.rawValue }
            )
        } buttons: {
            self.backButton
            if !isWorked {
                Button("Skip") {
                    let origin = self.settings.analyticsOnboardingOrigin
                    AnalyticsService.shared.skipOnboardingTryout(origin: origin)
                    self.settings.onboardingPlaygroundSkipped = true
                    self.goNext(outcome: .skipped)
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary))
                .disabled(self.asr.isRunning || self.isRecordingAnyShortcut)
            }
            self.continueButton(isPrimary: true)
        }
    }

    private func togglePrimaryShortcutRecording() {
        guard !self.asr.isRunning else { return }
        if self.isRecordingPrimaryShortcut {
            self.activeShortcutRecordingTarget = nil
            self.shortcutRecordingMessage = nil
        } else {
            self.shortcutRecordingMessage = nil
            self.activeShortcutRecordingTarget = .primaryDictation(.replace(0))
        }
    }

    private func resetTryoutValidationForSetupChange() {
        self.settings.onboardingPlaygroundValidated = false
        self.settings.onboardingPlaygroundSkipped = false
        self.settings.playgroundUsed = false
        self.asr.finalText = ""
    }

    // MARK: - Cleanup

    private var cleanupStep: some View {
        let check = self.cerebrasKeyCheck
        let hint: String = switch check {
        case .checking: "You can finish while it checks."
        case .rejected, .unreachable, .keychainFailed: "Finish now to use the fallbacks."
        case .idle, .connected: "Return finishes. You can add a key later in Settings."
        }
        return self.sheet(
            title: "Clean up your words",
            subtitle: "Optional. Removes filler words and fixes punctuation before the text is pasted.",
            hint: hint
        ) {
            self.row("Cloud cleanup", help: "Your own Cerebras key") {
                HStack(spacing: FWMetric.space3) {
                    if check == .checking || check == .connected {
                        RecordField(placeholder: "Paste a Cerebras API key", text: .constant(self.maskedCerebrasKey))
                            .frame(width: 360)
                    } else {
                        RecordField(placeholder: "Paste a Cerebras API key", text: self.$cerebrasKeyText, isError: check == .rejected)
                            .frame(width: 360)
                            .onSubmit(self.checkCerebrasKey)
                    }
                    switch check {
                    case .connected:
                        Button("Remove", action: self.removeCerebrasKey)
                            .buttonStyle(RecordButtonStyle(kind: .secondary))
                    case .rejected, .unreachable, .keychainFailed:
                        Button("Check again", action: self.checkCerebrasKey)
                            .buttonStyle(RecordButtonStyle(kind: .secondary))
                            .disabled(self.trimmedCerebrasKey.isEmpty)
                    case .idle, .checking:
                        Button("Check key", action: self.checkCerebrasKey)
                            .buttonStyle(RecordButtonStyle(kind: .secondary))
                            .disabled(check == .checking || self.trimmedCerebrasKey.isEmpty)
                    }
                }
                switch check {
                case .idle:
                    EmptyView()
                case .checking:
                    self.status(.waiting, "Checking the key with Cerebras…")
                case .connected:
                    self.status(.done, "Connected · Cerebras \(CerebrasKeyCheck.model)")
                    self.bodyText("Then Ollama when offline, then built-in rules.")
                case .rejected:
                    self.status(.needsYou, "Cerebras didn’t accept this key. Check that it was copied in full.")
                case .unreachable:
                    self.status(.needsYou, "Couldn’t reach Cerebras. Check that you are online, then check again.")
                case .keychainFailed:
                    self.status(.needsYou, "The key couldn’t be saved to your Keychain.")
                }
                if check != .connected {
                    self.bodyText("Get a key at cloud.cerebras.ai. It is stored in your Keychain, and only the dictated text is sent, never audio or what is on your screen.", secondary: true)
                }
            }
            if check != .connected {
                self.row("Without a key") {
                    self.bodyText("FluidWispr uses Ollama on this Mac when it is running, and built-in rules when it is not. Nothing leaves your Mac.")
                }
            }
            self.row("Ollama", help: "Optional") {
                if self.ollamaRunning {
                    self.status(.done, "Running · \(OllamaService.modelName)")
                } else {
                    self.status(.waiting, "Not running")
                    self.bodyText("Built-in rules will be used. You can add Ollama later for offline AI cleanup.")
                }
            }
            self.row("Short dictations") {
                self.bodyText("Three words or fewer are pasted as spoken, with no cleanup.")
            }
        } buttons: {
            self.backButton
            Button("Finish setup", action: self.handlePrimaryAction)
                .buttonStyle(RecordButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            if self.cerebrasKeyCheck == .idle, CerebrasKeyCheck.hasKey {
                self.cerebrasKeyCheck = .connected
            }
            self.refreshOllamaStatus()
        }
    }

    private var trimmedCerebrasKey: String {
        self.cerebrasKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "csk-" then bullets then the key's last four characters.
    private var maskedCerebrasKey: String {
        let key = self.trimmedCerebrasKey.isEmpty
            ? ((try? KeychainService.shared.fetchKey(for: CerebrasKeyCheck.providerID)) ?? "")
            : self.trimmedCerebrasKey
        return "csk-" + String(repeating: "•", count: 16) + String(key.suffix(4))
    }

    private func checkCerebrasKey() {
        let key = self.trimmedCerebrasKey
        guard !key.isEmpty, self.cerebrasKeyCheck != .checking else { return }
        self.cerebrasKeyCheck = .checking
        Task { @MainActor in
            let result = await CerebrasKeyCheck.verify(key: key)
            guard self.cerebrasKeyCheck == .checking, self.trimmedCerebrasKey == key else { return }
            self.cerebrasKeyCheck = switch result {
            case .accepted: .connected
            case .rejected: .rejected
            case .unreachable: .unreachable
            case .keychainFailed: .keychainFailed
            }
        }
    }

    private func removeCerebrasKey() {
        CerebrasKeyCheck.removeKey()
        self.cerebrasKeyText = ""
        self.cerebrasKeyCheck = .idle
    }

    private func refreshOllamaStatus() {
        Task { @MainActor in
            self.ollamaRunning = await OllamaService.shared.status() == .ready
        }
    }

    // MARK: - Done

    private var doneStep: some View {
        let key = self.keyHint.key
        return self.sheet(
            title: "You’re set",
            subtitle: self.keyHint.holds
                ? "Hold \(key) in any app, talk, then let go."
                : "Press \(key) in any app, talk, then press it again.",
            hint: "Return closes setup."
        ) {
            self.row("Dictation key") {
                RecordKeycap(key: key, size: .large)
                if !self.isVoiceModelReady, self.isModelPreparationInProgress {
                    self.bodyText("Dictation works as soon as the voice model finishes downloading.", secondary: true)
                }
            }
            self.row("The pill") {
                self.pill(.idle)
                self.bodyText("Shows at the bottom of your screen while you talk.")
            }
            self.row("Your record") {
                self.bodyText("Every dictation is kept in this window, numbered, so nothing you say is lost.")
            }
            self.row("Menu bar") {
                self.bodyText("FluidWispr keeps running in the menu bar. You can close this window.")
            }
        } buttons: {
            Button("Open Settings") {
                self.handlePrimaryAction()
                self.openSettings()
            }
            .buttonStyle(RecordButtonStyle(kind: .secondary))
            Button("Done", action: self.handlePrimaryAction)
                .buttonStyle(RecordButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Navigation

    private func goBack() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.currentStep = max(0, self.currentStep - 1)
    }

    private func goNext(outcome: AnalyticsOnboardingOutcome = .continued) {
        self.completeCurrentStep(outcome: outcome)
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.currentStep = min(Step.allCases.count - 1, self.currentStep + 1)
    }

    private func handlePrimaryAction() {
        if self.step == .language, let route = self.selectedOnboardingRoute {
            self.selectOnboardingRoute(route)
        }

        if self.step == .done {
            let origin = self.settings.analyticsOnboardingOrigin
            self.finishOnboarding()
            self.completeCurrentStep(
                outcome: .completed,
                origin: origin,
                completesFlow: self.settings.onboardingCompleted
            )
            return
        }
        guard self.canContinue else { return }
        self.goNext()
    }

    private func completeCurrentStep(
        outcome: AnalyticsOnboardingOutcome,
        origin: AnalyticsOnboardingOrigin? = nil,
        completesFlow: Bool = false
    ) {
        AnalyticsService.shared.recordOnboardingStepCompleted(
            self.step.analyticsStep,
            outcome: outcome,
            origin: origin ?? self.settings.analyticsOnboardingOrigin,
            completesFlow: completesFlow
        )
    }
}

private extension OnboardingFlowView {
    var orderedOnboardingInputDevices: [AudioDevice.Device] {
        let devicesByUID = Dictionary(
            self.onboardingInputDevices.map { ($0.uid, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var ordered = self.settings.microphonePriority.compactMap { devicesByUID[$0.uid] }
        let knownUIDs = Set(ordered.map(\.uid))
        ordered.append(contentsOf: self.onboardingInputDevices.filter { !knownUIDs.contains($0.uid) })
        return ordered
    }

    func isRouteSelectedInSettings(_ route: VoiceEngineLanguageRoute) -> Bool {
        guard route.model == self.settings.selectedSpeechModel else {
            return false
        }

        switch route.binding {
        case .automatic, .whisper:
            return self.settings.onboardingSelectedLanguageID == route.language.id
        case let .appleSpeech(localeIdentifier):
            return self.settings.selectedAppleSpeechLocaleIdentifier == localeIdentifier
        case let .cohere(language):
            return self.settings.selectedCohereLanguage == language
        case let .nemotron(language):
            return self.settings.selectedNemotronLanguage == language
        }
    }

    func refreshOnboardingMicrophoneAuthorization(checkModels: Bool = false) {
        Task { @MainActor in
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
            await AudioStartupGate.shared.waitUntilOpen()
            guard self.isOnboardingFlowVisible else { return }

            self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if self.step == .microphone, self.isMicrophoneReady {
                self.refreshOnboardingMicrophones(startPreview: true)
            }
            if checkModels {
                await self.asr.checkIfModelsExistAsync()
            }
        }
    }

    func refreshOnboardingMicrophones(startPreview: Bool) {
        guard self.isOnboardingFlowVisible else { return }
        self.onboardingMicrophoneRefreshGeneration &+= 1
        let generation = self.onboardingMicrophoneRefreshGeneration
        let suppressedUIDs = self.settings.suppressedMicrophoneUIDs

        Task { @MainActor in
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
            await AudioStartupGate.shared.waitUntilOpen()
            guard generation == self.onboardingMicrophoneRefreshGeneration,
                  self.isOnboardingFlowVisible,
                  self.step == .microphone,
                  self.isMicrophoneReady
            else { return }

            DispatchQueue.global(qos: .userInitiated).async {
                let inputs = AudioDevice.listInputDevicesRefreshingLiveness()
                let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
                let usableInputs = inputs.filter { device in
                    suppressedUIDs.contains(device.uid) == false && AudioDevice.isInputDeviceUsable(device)
                }

                DispatchQueue.main.async {
                    guard generation == self.onboardingMicrophoneRefreshGeneration,
                          self.isOnboardingFlowVisible,
                          self.step == .microphone,
                          self.isMicrophoneReady
                    else { return }

                    let selectedInput = self.appServices.microphonePreferenceCoordinator
                        .reconcileMicrophoneSelection(
                            availableInputs: inputs,
                            defaultInputUID: defaultInputUID
                        )
                    self.onboardingInputDevices = usableInputs
                    self.hasLoadedOnboardingInputs = true
                    self.selectedOnboardingInputUID = selectedInput?.uid ?? usableInputs.first?.uid ?? ""

                    if startPreview {
                        self.startOnboardingMicrophonePreviewIfNeeded()
                    }
                }
            }
        }
    }

    func selectOnboardingMicrophone(uid: String) {
        guard let device = self.onboardingInputDevices.first(where: { $0.uid == uid }) else {
            return
        }

        self.settings.recordInputDeviceSelection(device.uid, name: device.name)
        self.selectedOnboardingInputUID = device.uid
        self.startOnboardingMicrophonePreviewIfNeeded(forceRestart: true)
    }

    func startOnboardingMicrophonePreviewIfNeeded(forceRestart: Bool = false) {
        guard self.step == .microphone,
              self.isOnboardingFlowVisible,
              self.isMicrophoneReady,
              self.selectedOnboardingInputUID.isEmpty == false
        else { return }
        if forceRestart == false,
           self.previewedOnboardingInputUID == self.selectedOnboardingInputUID,
           self.asr.isMicrophonePreviewActive || self.microphonePreviewTask != nil
        {
            return
        }

        let selectedUID = self.selectedOnboardingInputUID
        self.microphonePreviewGeneration &+= 1
        let generation = self.microphonePreviewGeneration
        self.microphonePreviewTask?.cancel()
        self.previewedOnboardingInputUID = selectedUID
        self.microphonePreviewTask = Task { @MainActor in
            await self.asr.stopMicrophonePreview(retainPreparedCapture: false)
            guard generation == self.microphonePreviewGeneration,
                  Task.isCancelled == false,
                  self.step == .microphone,
                  self.isMicrophoneReady,
                  self.selectedOnboardingInputUID == selectedUID
            else {
                if generation == self.microphonePreviewGeneration {
                    self.microphonePreviewTask = nil
                }
                return
            }

            await self.asr.startMicrophonePreview()
            guard generation == self.microphonePreviewGeneration,
                  Task.isCancelled == false,
                  self.step == .microphone,
                  self.selectedOnboardingInputUID == selectedUID
            else {
                if generation == self.microphonePreviewGeneration {
                    await self.asr.stopMicrophonePreview()
                    self.microphonePreviewTask = nil
                }
                return
            }
            if self.asr.isMicrophonePreviewActive == false {
                self.previewedOnboardingInputUID = nil
            }
            self.microphonePreviewTask = nil
        }
    }

    func stopOnboardingMicrophonePreview() {
        self.microphonePreviewGeneration &+= 1
        let generation = self.microphonePreviewGeneration
        self.microphonePreviewTask?.cancel()
        self.microphonePreviewTask = Task { @MainActor in
            await self.asr.stopMicrophonePreview()
            guard generation == self.microphonePreviewGeneration else { return }
            self.previewedOnboardingInputUID = nil
            self.microphonePreviewTask = nil
        }
    }

    func suspendOnboardingMicrophonePreviewForDictation() {
        self.microphonePreviewGeneration &+= 1
        self.microphonePreviewTask?.cancel()
        self.microphonePreviewTask = nil
        self.previewedOnboardingInputUID = nil
    }
}
