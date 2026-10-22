import AppKit
import AVFoundation
import Foundation

/// Starting a recording from a shortcut, and the History actions on the last dictation:
/// reprocess, copy, paste again, retry a failed paste, and undo the AI cleanup.
extension DictationSession {
    func reprocessLastDictation() {
        if let pendingText = self.pendingAIReprocessText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pendingText.isEmpty
        {
            DebugLogger.shared.info("Actions: Reprocessing pending failed dictation", source: "DictationSession")
            Task { @MainActor in
                await self.reprocessDictationText(pendingText)
            }
            return
        }

        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Reprocess requested but history is empty", source: "DictationSession")
            return
        }

        let rawText = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            DebugLogger.shared.info("Actions: Reprocess skipped because latest history raw text is empty", source: "DictationSession")
            return
        }

        DebugLogger.shared.info("Actions: Reprocessing latest dictation history entry", source: "DictationSession")
        Task { @MainActor in
            await self.reprocessDictationText(rawText)
        }
    }

    func copyLastDictationFromHistory() {
        guard let text = TranscriptionHistoryStore.shared.latestClipboardText else {
            DebugLogger.shared.info("Actions: Copy requested but no transcription is available", source: "DictationSession")
            return
        }

        _ = ClipboardService.copyToClipboard(text)
        DebugLogger.shared.info("Actions: Copied latest transcription to clipboard", source: "DictationSession")
    }

    /// Re-inserts the most recent transcription into the focused text field using the same
    /// clipboard-free insertion path as live dictation. Unlike copy, this never touches the
    /// system clipboard, and unlike reprocess, it pastes the existing text verbatim (no new
    /// history entry, no reformatting). Useful when the original auto-insert dropped the tail.
    /// Called only through PasteOutcomeCenter.pasteLastTranscript(), which lets one run at a
    /// time and reports the outcome. Returns nil when nothing was pasted.
    func pasteLastDictationFromHistory() async -> (transcript: String, result: TextDeliveryResult)? {
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Paste requested but history is empty", source: "DictationSession")
            return nil
        }

        // Prefer the processed text (what was actually delivered, possibly AI-enhanced),
        // falling back to raw for older entries or when enhancement was off.
        guard let text = last.clipboardText else {
            DebugLogger.shared.info("Actions: Paste skipped because latest history text is empty", source: "DictationSession")
            return nil
        }
        return await self.pasteHistoryText(text)
    }

    /// The paste half of "paste last transcript", also used by History's Paste on one entry.
    func pasteHistoryText(_ text: String) async -> (transcript: String, result: TextDeliveryResult)? {

        // The hotkey fires on key-down while its own modifier keys (e.g. ⌘⌃) are still
        // physically held. Synthesizing text in that state makes the target app treat the
        // characters as keyboard shortcuts and drop them, so the paste lands once the keys are
        // released, effectively "paste when you let go". The timeout is generous so a normal
        // hold (or a quick repeated press) still pastes on release; it only aborts if a modifier
        // is genuinely stuck, rather than typing a corrupted/destructive shortcut sequence.
        guard await Self.waitForHotkeyModifiersReleased(timeout: 5) else {
            DebugLogger.shared.info("Actions: Paste aborted - modifier keys still held after timeout", source: "DictationSession")
            return nil
        }

        // Re-check here rather than only at the hotkey trigger: the overlay menu entry point
        // has no pre-check, and the wait above may have elapsed since the trigger fired.
        guard !self.asr.isRunning else {
            DebugLogger.shared.info("Actions: Paste skipped - recording in progress", source: "DictationSession")
            return nil
        }

        // Paste Last is a new insertion at the current cursor, independent of
        // the previous recording's saved target. Never restore that older focus here.
        guard let targetPID = TypingService.currentFocusedPID(), targetPID != ProcessInfo.processInfo.processIdentifier else {
            DebugLogger.shared.info("Actions: Paste skipped - no external target field available", source: "DictationSession")
            return (text, .recoverableFailure(.noEditableTarget))
        }
        let appInfo = self.getCurrentAppInfo()
        let outputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: text,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let result = await self.asr.typeOutputPlanToActiveField(
            outputPlan,
            preferredTargetPID: targetPID
        )
        if case let .recoverableFailure(failure) = result {
            self.showTextDeliveryFailure(failure, transcript: text)
        } else {
            DebugLogger.shared.info("Actions: Pasted latest transcription into focused field", source: "DictationSession")
        }
        return (text, result)
    }

    func retryTextDelivery(_ transcript: String) async {
        guard !transcript.isEmpty else { return }

        self.menuBarManager?.setProcessing(true)
        NotchOverlayManager.shared.updateTranscriptionText("Inserting")
        let typingTarget = self.resolveTypingTargetPID()
        if typingTarget.shouldRestoreOriginalFocus,
           !(await self.prepareRecordingTargetForDelivery(transcript, keepBackup: SettingsStore.shared.copyTranscriptionToClipboard))
        {
            self.showTextDeliveryFailure(.targetRestoreFailed, transcript: transcript)
            return
        }

        let result = await self.asr.typeTextToActiveField(
            transcript,
            preferredTargetPID: typingTarget.pid,
            preserveTranscriptOnClipboard: SettingsStore.shared.copyTranscriptionToClipboard
        )
        if case let .recoverableFailure(failure) = result {
            self.showTextDeliveryFailure(failure, transcript: transcript)
        } else {
            self.hideOverlayAfterOutput()
        }
    }

    func undoLastAIProcessingFromHistory() {
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Undo AI requested but history is empty", source: "DictationSession")
            return
        }

        let rawText = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            DebugLogger.shared.info("Actions: Undo AI skipped because latest history raw text is empty", source: "DictationSession")
            return
        }

        guard last.wasAIProcessed else {
            DebugLogger.shared.info("Actions: Undo AI skipped because latest entry was not AI processed", source: "DictationSession")
            return
        }

        DebugLogger.shared.info("Actions: Restoring latest transcription raw text (undo AI)", source: "DictationSession")
        Task { @MainActor in
            await self.applyHistoryTextOutput(rawText, saveToHistory: true)
        }
    }

    func applyHistoryTextOutput(_ text: String, saveToHistory: Bool) async {
        // Keep hotkey/recording state deterministic before applying output text.
        if self.asr.isRunning {
            DebugLogger.shared.info("Actions: stopping active recording before history action output", source: "DictationSession")
            await self.asr.stopWithoutTranscription()
            self.cancelPrewarmDictationIfNeeded()
        }

        let appInfo = self.getCurrentAppInfo()
        let precedingText = SettingsStore.shared.needsDictationFormattingContext
            ? TypingService.textBeforeCursorInFocusedField()
            : ""
        let finalText = DictationTextFormatter.finalize(
            text,
            context: .init(appName: appInfo.name, bundleID: appInfo.bundleId, windowTitle: appInfo.windowTitle),
            precedingText: precedingText,
            settings: .currentForFinalize
        )
        let outputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )

        if saveToHistory, SettingsStore.shared.saveTranscriptionHistory {
            TranscriptionHistoryStore.shared.addEntry(
                rawText: text,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: false
            )
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isFluidFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        let targetContext = TypingService.captureRecordingTargetContext()
        NotchContentState.shared.recordingTargetContext = targetContext
        NotchContentState.shared.recordingTargetPID = targetContext?.pid

        let shouldTypeExternally = !isFluidFrontmost
        if shouldTypeExternally {
            let typingTarget = self.resolveTypingTargetPID()
            if typingTarget.shouldRestoreOriginalFocus {
                guard await self.prepareRecordingTargetForDelivery(finalText, keepBackup: SettingsStore.shared.copyTranscriptionToClipboard) else {
                    self.showTextDeliveryFailure(.targetRestoreFailed, transcript: finalText)
                    return
                }
            }
            let result = await self.asr.typeOutputPlanToActiveField(
                outputPlan,
                preferredTargetPID: typingTarget.pid,
                preserveTranscriptOnClipboard: SettingsStore.shared.copyTranscriptionToClipboard
            )
            if case let .recoverableFailure(failure) = result {
                self.showTextDeliveryFailure(failure, transcript: finalText)
            }
        } else {
            await PasteDeliveryCoordinator.shared.copyBackup(finalText, enabled: SettingsStore.shared.copyTranscriptionToClipboard)
        }
    }

    func reprocessDictationText(_ transcribedText: String) async {
        // If live recording is still active, stop it first so reprocess does not
        // leave ASR running in the background (which causes the next hotkey press
        // to behave like a stop instead of start).
        if self.asr.isRunning {
            DebugLogger.shared.info("Actions: stopping active recording before reprocess", source: "DictationSession")
            await self.asr.stopWithoutTranscription()
            self.cancelPrewarmDictationIfNeeded()
        }

        self.setActiveRecordingMode(.dictate)
        self.menuBarManager?.setProcessing(true)
        NotchOverlayManager.shared.updateTranscriptionText("Reprocessing...")

        var aiFallbackReason: String?
        var postProcessingModel: String?
        var aiProcessingDurationMilliseconds: Int?
        var aiTokensPerSecond: Double?
        var aiFallbackNotificationError: String?
        var aiFallbackProviderName = ""
        let appInfo = self.getCurrentAppInfo()
        let normalizedTranscribedText = ASRService.applySpokenPunctuationFormatting(
            transcribedText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        var finalText = normalizedTranscribedText
        let shouldUseAI = DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: appInfo.bundleId)
        if shouldUseAI {
            postProcessingModel = self.currentDictationAIModelInfo(
                dictationSlot: .primary,
                appBundleID: appInfo.bundleId
            ).model
            let postProcessingStart = ProcessInfo.processInfo.systemUptime
            do {
                let result = try await self.processTextWithAIMetrics(
                    normalizedTranscribedText,
                    dictationSlot: .primary
                )
                finalText = result.text
                aiTokensPerSecond = result.tokensPerSecond
            } catch {
                DebugLogger.shared.error(
                    "AI reprocess failed, falling back to raw transcription: \(error.localizedDescription)",
                    source: "DictationSession"
                )
                aiFallbackReason = error.localizedDescription
                aiFallbackNotificationError = DictationAIFailurePresentationPolicy.notificationMessage(for: error)
                aiFallbackProviderName = DictationProviderRoute.resolve(settings: SettingsStore.shared, dictationSlot: .primary, appBundleID: appInfo.bundleId)
                    .providerDisplayName
                finalText = normalizedTranscribedText
            }
            aiProcessingDurationMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - postProcessingStart) * 1000).rounded()
            )
        }

        let precedingText = SettingsStore.shared.needsDictationFormattingContext
            ? TypingService.textBeforeCursorInFocusedField()
            : ""
        finalText = DictationTextFormatter.finalize(
            finalText,
            context: .init(appName: appInfo.name, bundleID: appInfo.bundleId, windowTitle: appInfo.windowTitle),
            precedingText: precedingText,
            settings: .currentForFinalize
        )
        self.recordingPrecedingText = ""
        let outputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )

        if SettingsStore.shared.saveTranscriptionHistory {
            TranscriptionHistoryStore.shared.addEntry(
                rawText: transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: postProcessingModel != nil && aiFallbackReason == nil,
                processingModel: postProcessingModel,
                aiProcessingDurationMilliseconds: aiProcessingDurationMilliseconds,
                aiTokensPerSecond: aiTokensPerSecond,
                aiProcessingError: aiFallbackReason
            )
        }
        let shouldShowAIProcessingFailure = DictationAIFailurePresentationPolicy.shouldPresent(
            shouldPersistOutputs: true,
            fallbackReason: aiFallbackReason
        )
        if !shouldShowAIProcessingFailure {
            self.pendingAIReprocessText = nil
        }

        let targetContext = TypingService.captureRecordingTargetContext()
        NotchContentState.shared.recordingTargetContext = targetContext
        NotchContentState.shared.recordingTargetPID = targetContext?.pid

        let typingTarget = self.resolveTypingTargetPID()
        if typingTarget.shouldRestoreOriginalFocus {
            guard await self.prepareRecordingTargetForDelivery(finalText, keepBackup: SettingsStore.shared.copyTranscriptionToClipboard) else {
                self.showTextDeliveryFailure(.targetRestoreFailed, transcript: finalText)
                return
            }
        }
        let result = await self.asr.typeOutputPlanToActiveField(
            outputPlan,
            preferredTargetPID: typingTarget.pid,
            preserveTranscriptOnClipboard: SettingsStore.shared.copyTranscriptionToClipboard
        )
        if case let .recoverableFailure(failure) = result {
            self.showTextDeliveryFailure(failure, transcript: finalText)
            return
        }

        NotchOverlayManager.shared.updateTranscriptionText("")
        if shouldShowAIProcessingFailure {
            self.pendingAIReprocessText = transcribedText
            NotchContentState.shared.showAIProcessingFailure()
            self.menuBarManager?.finishProcessingKeepingOverlayVisible()
            if let aiFallbackNotificationError {
                // Reprocess runs without a time limit.
                NotificationService.showAIProcessingFallback(error: aiFallbackNotificationError, providerName: aiFallbackProviderName, budgetMilliseconds: nil)
            }
        } else {
            self.hideOverlayAfterOutput()
        }

        self.clearActiveRecordingMode()
    }

    /// Capture app context at start to avoid mismatches if the user switches apps mid-session
    func startRecording() -> Task<Void, Never>? {
        guard !self.isSavingCancelledRecording, self.processingDictationLifecycleID == nil else { return nil }
        // Browsing the demo must not send dictation to a previously focused app.
        guard !self.isFluidIntelligenceDemoShowing || (DictationPromptTestCoordinator.shared.isActive && !DictationPromptTestCoordinator.shared.isProcessing) else { return nil }
        guard !self.presentExclusiveActivityBlockIfNeeded() else { return nil }
        let model = SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info(
            "startRecording() for model=\(model.displayName), supportsStreaming=\(model.supportsStreaming)",
            source: "DictationSession"
        )
        guard !self.asr.isRunningOrStarting else {
            DebugLogger.shared.debug("start ignored because capture is already active", source: "DictationSession")
            return nil
        }
        self.advanceOverlayLifecycle()
        self.setActiveRecordingMode(.dictate)
        let shouldShowDictationOverlay = !self.isRecordingForCommand
            && !self.isRecordingForRewrite
            && self.asr.micStatus == .authorized
        let shouldPlayStartSound = !self.isRecordingForCommand
            && !self.isRecordingForRewrite
            && self.asr.micStatus == .authorized

        // Ensure normal dictation mode is set (command/rewrite modes set their own)
        if shouldShowDictationOverlay {
            self.menuBarManager?.setOverlayMode(.dictation)
            self.menuBarManager?.showRecordingOverlayImmediately()
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "overlay_phase phase=connecting",
                source: "AppBenchmark"
            )
        }

        let captureOverlayLifecycleID = self.overlayLifecycleID
        let captureTask = Task {
            guard !Task.isCancelled else {
                self.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: .dictate)
                return
            }
            let startOutcome = await self.asr.start(onCaptureStarted: {
                if shouldPlayStartSound {
                    TranscriptionSoundPlayer.shared.playStartSound()
                }
                self.captureRecordingContext()
                self.prewarmDictationCleanupIfNeeded(for: .primary)
                DebugLogger.shared.benchmark(
                    "APP_BENCH",
                    message: "overlay_phase phase=recording trigger=first_pcm",
                    source: "AppBenchmark"
                )
            })
            guard !Task.isCancelled else {
                self.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: .dictate)
                return
            }
            if startOutcome == .failed {
                self.menuBarManager?.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
        }

        // Pre-load model in background while recording (avoids 10s freeze on stop)
        let warmupGeneration = MeetingModelResidencyCoordinator.shared.warmupGeneration
        Task {
            guard MeetingModelResidencyCoordinator.shared.canRunWarmup(warmupGeneration) else { return }
            do {
                DebugLogger.shared.debug("pre-load model task started", source: "DictationSession")
                try await self.asr.ensureAsrReady()
                DebugLogger.shared.debug("Model pre-loaded during recording", source: "DictationSession")
            } catch {
                DebugLogger.shared.error("Failed to pre-load model: \(error)", source: "DictationSession")
            }
        }
        return captureTask
    }

    func awaitCaptureStart(_ captureTask: Task<Void, Never>?) async {
        guard let captureTask else { return }
        await withTaskCancellationHandler {
            await captureTask.value
        } onCancel: {
            captureTask.cancel()
        }
    }

    func clearCancelledCaptureStart(lifecycleID: UInt64, mode: RecordingMode) {
        guard self.overlayLifecycleID == lifecycleID,
              !self.asr.isRunningOrStarting,
              self.activeRecordingMode == mode || self.activeRecordingMode == .none
        else { return }
        self.cancelPrewarmDictationIfNeeded()
        self.clearActiveRecordingMode()
        self.menuBarManager?.hideRecordingOverlayImmediately(reason: "capture_start_cancelled")
    }

    func presentExclusiveActivityBlockIfNeeded() -> Bool {
        guard let activity = self.asr.activeExclusiveActivity else { return false }
        let message = "Wait for the active \(activity.displayName) to finish."
        self.asr.errorTitle = "Dictation Unavailable"
        self.asr.errorMessage = message
        self.asr.showError = true
        AccessibilityNotification.Announcement("Dictation unavailable. \(message)").post()
        DebugLogger.shared.info(
            "dictation start blocked by \(activity.rawValue)",
            source: "DictationSession"
        )
        return true
    }

    /// Warms whichever cleanup model this dictation will use while the user is
    /// still speaking: Fluid Intelligence on device, a fresh connection for
    /// cloud providers such as Cerebras, or a loaded model for Ollama.
    func prewarmDictationCleanupIfNeeded(for slot: SettingsStore.DictationShortcutSlot) {
        let appBundleID = self.asr.isRunningOrStarting ? self.recordingAppInfo?.bundleId : DictationAppSession.shared.appID
        guard DictationAIPostProcessingGate.isConfigured(for: slot, appBundleID: appBundleID) else { return }
        let route = DictationProviderRoute.resolve(
            settings: SettingsStore.shared,
            dictationSlot: slot,
            appBundleID: appBundleID
        )
        guard route.usesPrivateAI else {
            guard !route.baseURL.isEmpty, !route.model.isEmpty else { return }
            let baseURL = route.baseURL
            let ollamaModel = route.providerKey == DictationCleanupRouting.localFallbackProviderID ? route.model : nil
            Task.detached(priority: .utility) {
                await LLMClient.shared.warmUp(baseURL: baseURL, ollamaModel: ollamaModel)
            }
            return
        }

        // Cancel any prior prewarm so rapid start/stop doesn't queue duplicate
        // actor work on PrivateAIIntegrationService.
        self.prewarmDictationTask?.cancel()
        let warmupGeneration = MeetingModelResidencyCoordinator.shared.warmupGeneration
        self.prewarmDictationTask = Task {
            guard !Task.isCancelled, MeetingModelResidencyCoordinator.shared.canRunWarmup(warmupGeneration) else { return }
            DebugLogger.shared.debug(
                "AI dictation prewarm started slot=\(slot.rawValue)",
                source: "DictationSession"
            )
            await PrivateAIIntegrationService.shared.prewarmDictation()
            DebugLogger.shared.debug(
                "AI dictation prewarm complete slot=\(slot.rawValue)",
                source: "DictationSession"
            )
            if !Task.isCancelled {
                self.prewarmDictationTask = nil
            }
        }
    }

    func applyDictationShortcutSelectionContext(for slot: SettingsStore.DictationShortcutSlot) {
        let settings = SettingsStore.shared
        NotchContentState.shared.stopSnapshotLabel = nil
        self.activeDictationShortcutSlot = slot
        NotchContentState.shared.activeDictationShortcutSlot = slot
        NotchContentState.shared.isPromptModeActive = (slot == .secondary)

        switch settings.resolvedDictationPromptSelection(for: slot, appBundleID: DictationAppSession.shared.appID) {
        case .off, .default:
            self.promptModeOverrideText = nil
            NotchContentState.shared.promptModeOverrideProfileName = nil
            NotchContentState.shared.promptModeOverrideProfileID = nil
        case .privateAI:
            self.promptModeOverrideText = nil
            NotchContentState.shared.promptModeOverrideProfileName = PrivateAIProviderFeature.displayName
            NotchContentState.shared.promptModeOverrideProfileID = PrivateAIProviderPromptFormat.promptSelectionID
        case let .profile(profileID):
            guard let profile = settings.dictationPromptProfiles.first(where: {
                $0.id == profileID && $0.mode.normalized == .dictate
            }) else {
                self.promptModeOverrideText = nil
                NotchContentState.shared.promptModeOverrideProfileName = nil
                NotchContentState.shared.promptModeOverrideProfileID = nil
                return
            }

            self.promptModeOverrideText = settings.shortcutOverrideSystemPrompt(for: profile, mode: .dictate)
            NotchContentState.shared.promptModeOverrideProfileName = profile.name
            NotchContentState.shared.promptModeOverrideProfileID = profile.id
        }
    }

    func canBeginDictationRecording() -> Bool {
        guard !self.isSavingCancelledRecording, self.processingDictationLifecycleID == nil else { return false }
        if self.canSwitchActiveDictationCaptureMode { return true }
        guard !self.presentExclusiveActivityBlockIfNeeded() else { return false }
        return !self.asr.isRunningOrStarting && !self.asr.isDictionaryTrainingCaptureActive
    }

    func beginDictationRecording(
        for slot: SettingsStore.DictationShortcutSlot,
        mode: RecordingMode,
        startMethod: AnalyticsOnboardingTryoutStartMethod = .hotkey
    ) -> Task<Void, Never>? {
        guard self.canBeginDictationRecording() else { return nil }
        let switchesOwnedCapture = self.canSwitchActiveDictationCaptureMode
        let previousMode = self.activeRecordingMode
        DebugLogger.shared.debug("Begin dictation recording for slot \(slot.rawValue)", source: "DictationSession")
        DebugLogger.shared.debug("CLOSE_DETAIL nextStartRequested uptime=\(ProcessInfo.processInfo.systemUptime)", source: "StopTiming")
        self.appBench("begin_recording slot=\(slot.rawValue) mode=\(mode.rawValue)")
        if !switchesOwnedCapture, self.isOnboardingVoicePlaygroundStepActive {
            self.asr.finalText = ""
            SettingsStore.shared.onboardingPlaygroundValidated = false
            SettingsStore.shared.onboardingPlaygroundSkipped = false
            SettingsStore.shared.playgroundUsed = false
        }
        self.applyDictationShortcutSelectionContext(for: slot)
        self.setActiveRecordingMode(mode)
        self.rewriteMode.clearState()

        if switchesOwnedCapture {
            if self.asr.showError, self.asr.errorTitle == "Dictation Unavailable",
               self.asr.errorMessage == "Wait for the active dictation to finish."
            { self.asr.showError = false }
            self.menuBarManager?.setOverlayMode(.dictation)
            DebugLogger.shared.info(
                "Dictation capture mode switched from=\(previousMode.rawValue) to=\(mode.rawValue) slot=\(slot.rawValue)",
                source: "DictationSession"
            )
            return nil
        }
        guard !self.asr.isRunningOrStarting else {
            self.appBench("asr_start_skipped reason=already_running_or_starting")
            return nil
        }
        let isOnboardingTryout = self.isOnboardingVoicePlaygroundStepActive && mode == .dictate
        if isOnboardingTryout {
            AnalyticsService.shared.recordOnboardingTryoutAttemptStarted(startMethod: startMethod)
        }
        self.advanceOverlayLifecycle()
        if self.asr.micStatus == .authorized {
            self.appBench("overlay_mode_request mode=Dictation")
            self.menuBarManager?.setOverlayMode(.dictation)
            self.menuBarManager?.showRecordingOverlayImmediately()
            self.appBench("overlay_mode_requested mode=Dictation")
            self.appBench("overlay_phase phase=connecting")
        }
        let captureOverlayLifecycleID = self.overlayLifecycleID
        return Task {
            guard !Task.isCancelled else {
                self.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: mode)
                return
            }
            let asrStartStartedAt = ProcessInfo.processInfo.systemUptime
            DebugLogger.shared.benchmark("APP_BENCH", message: "asr_start_call", source: "AppBenchmark")
            let startOutcome = await self.asr.start(onCaptureStarted: {
                if SettingsStore.shared.enableTranscriptionSounds {
                    TranscriptionSoundPlayer.shared.playStartSound()
                }
                self.captureRecordingContext()
                self.prewarmDictationCleanupIfNeeded(for: slot)
                self.appBench("overlay_phase phase=recording trigger=first_pcm")
            })
            guard !Task.isCancelled else {
                self.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: mode)
                return
            }
            if startOutcome == .failed {
                self.menuBarManager?.hideRecordingOverlayImmediately(reason: "asr_start_failed")
                if isOnboardingTryout {
                    AnalyticsService.shared.recordOnboardingTryoutAttemptResult(
                        outcome: .error,
                        failureStage: .audioStart
                    )
                }
            }
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "asr_start_return elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - asrStartStartedAt) * 1000).rounded()))",
                source: "AppBenchmark"
            )
        }
    }

    func beginDictationRecording(for selection: SettingsStore.DictationPromptSelection, mode: RecordingMode) -> Task<Void, Never>? {
        guard self.canBeginDictationRecording() else { return nil }
        let settings = SettingsStore.shared
        settings.setDictationPromptSelection(selection, for: .secondary)
        return self.beginDictationRecording(for: .secondary, mode: mode)
    }

    var canSwitchActiveDictationCaptureMode: Bool {
        self.activeRecordingMode != .none && self.asr.canSwitchOwnedDictationCaptureMode
    }

    /// Set while one Paste Raw Instead run waits for keys or types, so a second press
    /// cannot find its own replacement and report the paste as missing.
    private static var isPasteRawInProgress = false

    /// Swaps the last AI-cleaned paste for the original transcript. When the paste still
    /// sits just before the cursor it is selected and typed over. Otherwise the overlay
    /// shows the transcript with its copy button, so the words are never lost.
    func pasteRawInsteadOfLastDictation() async {
        guard !Self.isPasteRawInProgress else { return }
        Self.isPasteRawInProgress = true
        defer { Self.isPasteRawInProgress = false }
        guard let last = TranscriptionHistoryStore.shared.entries.first, last.wasAIProcessed else {
            DebugLogger.shared.info("Actions: Paste raw skipped - latest dictation was not AI-cleaned", source: "DictationSession")
            return
        }
        let raw = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let delivered = last.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != delivered else {
            DebugLogger.shared.info("Actions: Paste raw skipped - cleanup left the transcript unchanged", source: "DictationSession")
            return
        }
        // Same reason as Paste Last: typing while the chord's modifiers are held turns the text into shortcuts.
        guard await Self.waitForHotkeyModifiersReleased(timeout: 5) else {
            DebugLogger.shared.info("Actions: Paste raw aborted - modifier keys still held after timeout", source: "DictationSession")
            return
        }
        guard !self.asr.isRunning else {
            DebugLogger.shared.info("Actions: Paste raw skipped - recording in progress", source: "DictationSession")
            return
        }

        guard let precedingText = TypingService.selectDeliveredTextBeforeCursor(delivered),
              let targetPID = TypingService.currentFocusedPID()
        else {
            DebugLogger.shared.info("Actions: Paste raw not typed - last paste not found at cursor", source: "DictationSession")
            self.showTextDeliveryFailure(.targetUnavailable, transcript: raw)
            return
        }

        let appInfo = self.getCurrentAppInfo()
        let finalText = DictationTextFormatter.finalize(
            raw,
            context: .init(appName: appInfo.name, bundleID: appInfo.bundleId, windowTitle: appInfo.windowTitle),
            precedingText: precedingText,
            settings: .currentForFinalize
        )
        let outputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let result = await self.asr.typeOutputPlanToActiveField(outputPlan, preferredTargetPID: targetPID)
        if case let .recoverableFailure(failure) = result {
            self.showTextDeliveryFailure(failure, transcript: finalText)
        } else {
            DebugLogger.shared.info("Actions: Replaced the last AI-cleaned paste with the transcript", source: "DictationSession")
        }
    }

    /// Polls until the keyboard modifier keys are released, returning `true` once they are, or
    /// `false` if the timeout elapses with keys still held. Used before synthesizing a paste so the
    /// inserted characters aren't swallowed as modifier+key shortcuts.
    private static func waitForHotkeyModifiersReleased(timeout: TimeInterval) async -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.isDisjoint(with: relevant) {
                return true
            }
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms
        }
        return false
    }
}
