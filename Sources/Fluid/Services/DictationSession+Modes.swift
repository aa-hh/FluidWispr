import AppKit
import Foundation

/// Which mode is recording and how a live mode switch changes it, the voice Edit and
/// Command flows, and the usage record for a finished dictation.
extension DictationSession {
    func setActiveRecordingMode(_ mode: RecordingMode) {
        if mode != .dictate, mode != .promptMode {
            self.clearActiveDictationShortcutState()
        }
        self.activeRecordingMode = mode
        switch mode {
        case .none, .dictate, .promptMode:
            self.isRecordingForCommand = false
            self.isRecordingForRewrite = false
        case .edit:
            self.isRecordingForCommand = false
            self.isRecordingForRewrite = true
        case .command:
            self.isRecordingForCommand = true
            self.isRecordingForRewrite = false
        }
    }

    func clearActiveRecordingMode() {
        self.setActiveRecordingMode(.none)
    }

    func clearActiveDictationShortcutState() {
        self.activeDictationShortcutSlot = nil
        self.promptModeOverrideText = nil
        NotchContentState.shared.activeDictationShortcutSlot = nil
        NotchContentState.shared.promptModeOverrideProfileName = nil
        NotchContentState.shared.promptModeOverrideProfileID = nil
        NotchContentState.shared.isPromptModeActive = false
    }

    /// Cancel an in-flight prewarm. Called on abort / new recording start — NOT on
    /// a normal stop, because AI post-processing runs after stop and benefits from
    /// the warm prefix cache the prewarm prime.
    func cancelPrewarmDictationIfNeeded() {
        self.prewarmDictationTask?.cancel()
        self.prewarmDictationTask = nil
    }

    func handleLivePromptModeSwitch(_ mode: SettingsStore.PromptMode) {
        guard !NotchContentState.shared.isProcessing else { return }
        switch mode.normalized {
        case .dictate:
            guard self.activeRecordingMode != .dictate || NotchContentState.shared.mode != .dictation else { return }
            self.setActiveRecordingMode(.dictate)
            self.rewriteMode.clearState()
            self.menuBarManager?.setOverlayMode(.dictation)
        case .edit:
            guard self.activeRecordingMode != .edit || NotchContentState.shared.mode == .dictation else { return }
            self.setActiveRecordingMode(.edit)
            let hasOriginal = !self.rewriteMode.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasContext = !self.rewriteMode.selectedContextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasOriginal, !hasContext {
                let captured = self.rewriteMode.captureSelectedText()
                DebugLogger.shared.info("Live switch to Edit Text attempted context capture: \(captured)", source: "DictationSession")
                if !captured {
                    self.rewriteMode.startWithoutSelection()
                }
            }
            self.menuBarManager?.setOverlayMode(.edit)
        case .write, .rewrite:
            guard self.activeRecordingMode != .edit || NotchContentState.shared.mode == .dictation else { return }
            self.setActiveRecordingMode(.edit)
            let hasOriginal = !self.rewriteMode.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasContext = !self.rewriteMode.selectedContextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasOriginal, !hasContext {
                let captured = self.rewriteMode.captureSelectedText()
                DebugLogger.shared.info("Live switch to Edit Text attempted context capture: \(captured)", source: "DictationSession")
                if !captured {
                    self.rewriteMode.startWithoutSelection()
                }
            }
            self.menuBarManager?.setOverlayMode(.edit)
        }
    }

    func handleLiveOverlayModeSwitch(_ mode: OverlayMode) {
        guard !NotchContentState.shared.isProcessing else { return }
        switch mode {
        case .dictation:
            self.handleLivePromptModeSwitch(.dictate)
        case .edit, .write, .rewrite:
            self.handleLivePromptModeSwitch(.edit)
        case .command:
            guard self.activeRecordingMode != .command || NotchContentState.shared.mode != .command else { return }
            self.rewriteMode.clearState()
            self.setActiveRecordingMode(.command)
            self.menuBarManager?.setOverlayMode(.command)
        }
    }

    func processRewriteWithVoiceInstruction(
        _ instruction: String,
        appInfo: (name: String, bundleId: String, windowTitle: String),
        lifecycleID: UInt64
    ) async {
        let isOutputValid: @MainActor () -> Bool = { self.overlayLifecycleID == lifecycleID && self.cancelledOutputLifecycleID != lifecycleID }
        await self.voiceEditFlow.run(instruction, appBundleID: appInfo.bundleId, isOutputValid: isOutputValid)
    }

    func processCommandWithVoice(_ command: String, lifecycleID: UInt64) async {
        let isOutputValid: @MainActor () -> Bool = { self.overlayLifecycleID == lifecycleID && self.cancelledOutputLifecycleID != lifecycleID }
        let service = self.commandMode
        let flow = VoiceCommandFlow(
            setProcessing: { self.menuBarManager?.setProcessing($0) },
            process: { await service.processUserCommand($0, notifyInvalidRequest: true, isOutputValid: $1) },
            cancelInvalidPendingCommand: { service.cancelInvalidPendingCommand() },
            hasPendingCommand: { service.pendingCommand != nil },
            setPendingConfirmationOwner: { self.pendingVoiceCommandLifecycleID = $0 }
        )
        await flow.run(command, lifecycleID: lifecycleID, isOutputValid: isOutputValid)
    }

    func showPrivateAIEditModeUnavailableIfNeeded() -> Bool {
        let settings = SettingsStore.shared
        let providerID = settings.rewriteModeLinkedToGlobal
            ? settings.selectedProviderID
            : settings.rewriteModeSelectedProviderID
        guard PrivateFeatures.privateAIProvider,
              providerID.trimmingCharacters(in: .whitespacesAndNewlines) ==
              PrivateAIProviderFeature.shared.providerID
        else {
            return false
        }

        guard !self.asr.isRunningOrStarting,
              !NotchContentState.shared.isProcessing
        else {
            return true
        }

        self.menuBarManager?.setOverlayMode(.edit)
        self.advanceOverlayLifecycle()
        let expectedOverlayLifecycleID = self.overlayLifecycleID
        self.menuBarManager?.showRecordingOverlayImmediately()
        NotchContentState.shared.showAIProcessingFailure(
            message: "Edit Mode cannot be used with Fluid-1",
            canRetry: false
        )
        self.menuBarManager?.finishProcessingKeepingOverlayVisible()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard self.overlayLifecycleID == expectedOverlayLifecycleID else { return }
            NotchContentState.shared.clearAIProcessingFailure()
            await self.menuBarManager?.finishProcessingAndHideOverlay()
        }
        return true
    }

    func currentDictationAIModelInfo(
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil,
        appBundleID: String? = nil
    ) -> (provider: String?, model: String?) {
        let route = DictationProviderRoute.resolve(
            settings: SettingsStore.shared,
            dictationSlot: dictationSlot,
            appBundleID: appBundleID
        )
        let providerOut = route.providerKey.isEmpty ? nil : route.providerKey
        let modelOut = route.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : route.model
        return (provider: providerOut, model: modelOut)
    }

    func currentTranscriptionModelInfo() -> (provider: String, model: String) {
        let selectedModel = SettingsStore.shared.selectedSpeechModel
        return (
            provider: selectedModel.provider.rawValue.lowercased(),
            model: selectedModel.rawValue
        )
    }

    func recordDictationUsage(
        shouldUseAI: Bool,
        dictationSlot: SettingsStore.DictationShortcutSlot?,
        appBundleID: String,
        snapshot: DictationStopSnapshot? = nil
    ) -> (provider: String?, model: String?) {
        let postProcessing = snapshot.map { (provider: Optional($0.route.providerKey), model: Optional($0.route.model)) } ?? self.currentDictationAIModelInfo(
            dictationSlot: dictationSlot,
            appBundleID: appBundleID
        )
        AnalyticsService.shared.recordUsage(
            mode: .dictation,
            transcriptionModel: SettingsStore.shared.selectedSpeechModel.analyticsDescriptor,
            aiModel: shouldUseAI ? AnalyticsModelDescriptor(
                provider: postProcessing.provider ?? "unknown",
                model: postProcessing.model ?? "unknown"
            ) : nil
        )
        return postProcessing
    }

    func currentDictationOutputRouteForHotkeyStop() -> OutputRoute {
        let isDictationMode = self.activeRecordingMode == .dictate || self.activeRecordingMode == .promptMode

        if OnboardingDictationOutputPolicy.usesSandbox(
            onboardingPracticeActive: self.isOnboardingSandboxRouteActive,
            isDictation: isDictationMode,
            targetProcessID: NotchContentState.shared.recordingTargetPID,
            fluidVoiceProcessID: ProcessInfo.processInfo.processIdentifier
        ) {
            return .onboardingSandbox
        }
        return .normal
    }

    var voiceEditFlow: VoiceEditFlow {
        let rewrite = self.rewriteMode
        return VoiceEditFlow(
            setPromptAppBundleID: { rewrite.setPromptAppBundleID($0) },
            originalText: { rewrite.originalText },
            requestRewrite: { await rewrite.processRewriteRequest($0) },
            rewrittenText: { rewrite.rewrittenText },
            clearRewrite: { rewrite.clearState() },
            setProcessing: { self.menuBarManager?.setProcessing($0) },
            finishWithoutResult: { await self.menuBarManager?.finishProcessingAndHideOverlay() },
            typingTarget: { self.resolveTypingTargetPID() },
            restoreTarget: { text, isOutputValid in
                await self.prepareRecordingTargetForDelivery(
                    text,
                    keepBackup: SettingsStore.shared.copyTranscriptionToClipboard,
                    isOutputValid: isOutputValid
                )
            },
            deliver: { text, pid, isOutputValid in
                await self.asr.typeTextToActiveField(
                    text,
                    preferredTargetPID: pid,
                    preserveTranscriptOnClipboard: SettingsStore.shared.copyTranscriptionToClipboard,
                    isOutputValid: isOutputValid
                )
            },
            showDeliveryFailure: { self.showTextDeliveryFailure($0, transcript: $1) },
            hideOverlay: { self.hideOverlayAfterOutput() }
        )
    }

    var isOnboardingVoicePlaygroundStepActive: Bool {
        let onboardingPlaygroundStep = 4
        return !SettingsStore.shared.onboardingCompleted &&
            SettingsStore.shared.onboardingCurrentStep == onboardingPlaygroundStep
    }

    var isOnboardingSandboxRouteActive: Bool {
        let onboardingAIEnhancementStep = 5
        return self.isOnboardingVoicePlaygroundStepActive ||
            (!SettingsStore.shared.onboardingCompleted && SettingsStore.shared.onboardingCurrentStep == onboardingAIEnhancementStep)
    }
}
