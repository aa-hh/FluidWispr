import AppKit
import ApplicationServices
import Foundation

/// The global shortcuts and the overlay's buttons: the session creates the one hotkey manager,
/// wires the notch callbacks, and handles Escape.
extension DictationSession {
    func initializeHotkeyManagerIfNeeded() {
        NotchContentState.shared.onPromptModeSwitchRequested = { mode in
            self.handleLivePromptModeSwitch(mode)
        }
        NotchContentState.shared.onOverlayModeSwitchRequested = { mode in
            self.handleLiveOverlayModeSwitch(mode)
        }
        NotchContentState.shared.onReprocessLastRequested = {
            self.reprocessLastDictation()
        }
        NotchContentState.shared.onCopyLastRequested = {
            self.copyLastDictationFromHistory()
        }
        PasteOutcomeCenter.shared.pasteLastHandler = {
            await self.pasteLastDictationFromHistory()
        }
        NotchContentState.shared.onPasteLastRequested = {
            Task { @MainActor in _ = await PasteOutcomeCenter.shared.pasteLastTranscript() }
        }
        NotchContentState.shared.onRetryTextDeliveryRequested = { transcript in
            Task { @MainActor in
                await self.retryTextDelivery(transcript)
            }
        }
        NotchContentState.shared.onUndoLastAIRequested = {
            self.undoLastAIProcessingFromHistory()
        }
        NotchContentState.shared.onOpenPreferencesRequested = {
            self.menuBarManager?.openPreferencesFromUI()
        }
        NotchContentState.shared.onCancelRequested = {
            _ = self.handleCancelShortcut()
        }
        NotchContentState.shared.onDictationPromptSelectionRequested = { selection in
            guard selection != .privateAI || PrivateAIProviderPromptFormat.isAvailable() else { return }
            let slot = self.activeDictationShortcutSlot ?? .primary
            DictationAppSession.shared.select(selection, slot: slot, appID: DictationAppSession.shared.appID)
            self.applyDictationShortcutSelectionContext(for: slot)
            self.prewarmDictationCleanupIfNeeded(for: slot)
        }

        guard self.hotkeyManager == nil else {
            // A reopened window starts out showing "initializing"; tell it the shared manager's health.
            self.checkHotkeyHealth()
            return
        }

        self.hotkeyManager = GlobalHotkeyManager(
            asrService: self.asr,
            primaryShortcuts: SettingsStore.shared.primaryDictationShortcuts,
            promptModeShortcut: SettingsStore.shared.promptModeHotkeyShortcut,
            commandModeShortcut: SettingsStore.shared.commandModeHotkeyShortcut,
            rewriteModeShortcut: SettingsStore.shared.rewriteModeHotkeyShortcut,
            promptShortcutAssignments: SettingsStore.shared.dictationPromptShortcutAssignments(),
            promptModeShortcutEnabled: SettingsStore.shared.promptModeShortcutEnabled,
            commandModeShortcutEnabled: FluidWisprBuild.includesCommandMode && SettingsStore.shared.commandModeShortcutEnabled,
            rewriteModeShortcutEnabled: SettingsStore.shared.rewriteModeShortcutEnabled,
            startRecordingCallback: {
                DebugLogger.shared.debug("startRecordingCallback invoked by hotkey", source: "DictationSession")
                await self.awaitCaptureStart(self.startRecording())
            },
            dictationModeCallback: {
                DebugLogger.shared.info("Dictate mode triggered", source: "DictationSession")
                DebugLogger.shared.debug(
                    "selected model for dictate hotkey=\(SettingsStore.shared.selectedSpeechModel.displayName)",
                    source: "DictationSession"
                )
                await self.awaitCaptureStart(self.beginDictationRecording(for: .primary, mode: .dictate))
            },
            stopAndProcessCallback: { toggleStopRequestedAt in
                let route = self.currentDictationOutputRouteForHotkeyStop()
                DebugLogger.shared.info("Hotkey stop callback using route: \(route.rawValue)", source: "DictationSession")
                await self.stopAndProcessTranscription(
                    route: route,
                    toggleStopRequestedAt: toggleStopRequestedAt
                )
            },
            promptModeCallback: {
                DebugLogger.shared.info("Prompt mode triggered", source: "DictationSession")
                await self.awaitCaptureStart(self.beginDictationRecording(for: .secondary, mode: .promptMode))
            },
            promptSelectionCallback: { selection in
                DebugLogger.shared.info("Prompt selection shortcut triggered", source: "DictationSession")
                await self.awaitCaptureStart(self.beginDictationRecording(for: selection, mode: .promptMode))
            },
            commandModeCallback: {
                guard !self.presentExclusiveActivityBlockIfNeeded() else { return }
                DebugLogger.shared.info("Command mode triggered", source: "DictationSession")
                self.captureRecordingContext()

                // Set flag so stopAndProcessTranscription knows to process as command
                self.setActiveRecordingMode(.command)

                // Set overlay mode to command
                self.menuBarManager?.setOverlayMode(.command)

                guard !self.asr.isRunningOrStarting else { return }

                self.advanceOverlayLifecycle()

                // Start recording immediately for the command
                DebugLogger.shared.info(
                    "Starting voice recording for command",
                    source: "DictationSession"
                )
                let captureOverlayLifecycleID = self.overlayLifecycleID
                let captureTask = Task {
                    guard !Task.isCancelled else {
                        self.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: .command)
                        return
                    }
                    let startOutcome = await self.asr.start(onCaptureStarted: {
                        TranscriptionSoundPlayer.shared.playStartSound()
                        self.appBench("overlay_phase phase=recording trigger=first_pcm mode=command")
                    })
                    guard !Task.isCancelled else {
                        self.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: .command)
                        return
                    }
                    if startOutcome == .failed {
                        self.menuBarManager?.hideRecordingOverlayImmediately(
                            reason: "command_asr_start_failed"
                        )
                    }
                }
                await self.awaitCaptureStart(captureTask)
            },
            rewriteModeCallback: {
                guard !self.presentExclusiveActivityBlockIfNeeded() else { return }

                self.captureRecordingContext()

                // Try to capture text first while still in the other app
                let captured = self.rewriteMode.captureSelectedText()
                DebugLogger.shared.info("Rewrite mode triggered, text captured: \(captured)", source: "DictationSession")

                if !captured {
                    // No text selected - start in "write mode" where user speaks
                    // what to write
                    DebugLogger.shared
                        .info(
                            "No text selected - starting in write/improve mode",
                            source: "DictationSession"
                        )
                    self.rewriteMode.startWithoutSelection()
                    // Set overlay mode to edit
                    self.menuBarManager?.setOverlayMode(.edit)
                } else {
                    // Text was selected - edit mode (with selected context)
                    self.menuBarManager?.setOverlayMode(.edit)
                }

                // Set flag so stopAndProcessTranscription knows to process as rewrite
                self.setActiveRecordingMode(.edit)

                guard !self.asr.isRunningOrStarting else { return }

                self.advanceOverlayLifecycle()

                // Start recording immediately for the edit instruction
                DebugLogger.shared.info("Starting voice recording for edit mode", source: "DictationSession")
                let captureOverlayLifecycleID = self.overlayLifecycleID
                let captureTask = Task {
                    guard !Task.isCancelled else {
                        self.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: .edit)
                        return
                    }
                    let startOutcome = await self.asr.start(onCaptureStarted: {
                        TranscriptionSoundPlayer.shared.playStartSound()
                        self.appBench("overlay_phase phase=recording trigger=first_pcm mode=edit")
                    })
                    guard !Task.isCancelled else {
                        self.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: .edit)
                        return
                    }
                    if startOutcome == .failed {
                        self.menuBarManager?.hideRecordingOverlayImmediately(
                            reason: "edit_asr_start_failed"
                        )
                    }
                }
                await self.awaitCaptureStart(captureTask)
            },
            isDictateRecordingProvider: {
                self.activeRecordingMode == .dictate
            },
            isPromptModeRecordingProvider: {
                self.activeRecordingMode == .promptMode
            },
            isCommandRecordingProvider: {
                self.activeRecordingMode == .command
            },
            isRewriteRecordingProvider: {
                self.activeRecordingMode == .edit
            },
            isShortcutCaptureActiveProvider: {
                self.isShortcutCaptureActive()
            },
            shortcutCaptureHandler: {
                self.shortcutCaptureHandler($0)
            }
        )
        if let hotkeyManager = self.hotkeyManager {
            HotkeyManagerOwner.shared.install(hotkeyManager)
        }
        self.hotkeyManager?.registerDebugToggleTriggerIfEnabled()

        self.checkHotkeyHealth()

        self.hotkeyManager?.setHotkeyMode(SettingsStore.shared.hotkeyMode)

        // Set cancel callback for Escape key handling (closes transient UI, resets recording state)
        // Distinguishes suggestion dismissal from recording cancellation.
        self.hotkeyManager?.setCancelCallback {
            self.handleCancelShortcutResult()
        }

        // Re-insert the most recent transcription on demand (no clipboard involved).
        self.hotkeyManager?.setPasteLastTranscriptionCallback {
            Task { @MainActor in _ = await PasteOutcomeCenter.shared.pasteLastTranscript() }
        }

        // Monitor initialization status
        Task {
            // Give some time for initialization
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

            await MainActor.run {
                var isHealthy = self.checkHotkeyHealth()
                DebugLogger.shared.debug("Initial hotkey manager health check: \(isHealthy)", source: "DictationSession")

                // If still not initialized and accessibility is enabled, try reinitializing
                if !isHealthy && AXIsProcessTrusted() {
                    isHealthy = self.checkHotkeyHealth()
                    DebugLogger.shared.debug("Initial hotkey manager health check: \(isHealthy)", source: "DictationSession")

                    // If still not initialized and accessibility is enabled, try reinitializing
                    if !isHealthy && AXIsProcessTrusted() {
                        DebugLogger.shared.debug("Hotkey manager not healthy, attempting reinitalization", source: "DictationSession")
                        self.hotkeyManager?.reinitialize()
                    }
                }
            }
        }
    }

    func configureNotchCallbacks() {
        NotchOverlayManager.shared.onNotchClicked = {
            guard NotchOverlayManager.shared.canHandleNotchCommandTap else { return }
            if NotchOverlayManager.shared.canShowExpandedCommandOutput,
               !NotchContentState.shared.commandConversationHistory.isEmpty
            {
                NotchOverlayManager.shared.showExpandedCommandOutput()
            }
        }

        NotchOverlayManager.shared.onCommandFollowUp = { [weak commandModeService = self.commandMode] text in
            guard NotchOverlayManager.shared.allowsCommandNotchActions, let commandModeService else { return false }
            let accepted = await commandModeService.processFollowUpCommand(text)
            if !accepted, commandModeService.pendingCommand != nil {
                self.asr.errorTitle = "Command Awaiting Approval"
                self.asr.errorMessage = "Approve or cancel the pending command before sending a follow-up. Your text has been kept."
                self.asr.showError = true
            }
            return accepted
        }

        NotchOverlayManager.shared.onNewChat = { [weak commandModeService = self.commandMode] in
            guard NotchOverlayManager.shared.allowsCommandNotchActions else { return }
            commandModeService?.createNewChat()
        }

        NotchOverlayManager.shared.onSwitchChat = { [weak commandModeService = self.commandMode] chatID in
            guard NotchOverlayManager.shared.allowsCommandNotchActions else { return }
            commandModeService?.switchToChat(id: chatID)
        }

        NotchOverlayManager.shared.onClearChat = { [weak commandModeService = self.commandMode] in
            guard NotchOverlayManager.shared.allowsCommandNotchActions else { return }
            commandModeService?.deleteCurrentChat()
        }
    }

    @discardableResult
    func handleCancelShortcut() -> Bool {
        self.handleCancelShortcutResult() != .unhandled
    }

    func handleCancelShortcutResult() -> GlobalHotkeyManager.CancelHandlingResult {
        if self.isSavingCancelledRecording { return .cancelled }
        var handled = false

        if DictionaryCorrectionOverlayController.shared.isPresented {
            DictionaryCorrectionOverlayController.shared.dismiss()
            return .dismissedOverlay
        }
        if NotchOverlayManager.shared.isCommandOutputExpanded {
            NotchOverlayManager.shared.hideExpandedCommandOutput()
            NotchOverlayManager.shared.onCommandOutputDismiss?()
            handled = true
        }

        if let lifecycleID = self.pendingVoiceCommandLifecycleID {
            self.cancelledOutputLifecycleID = lifecycleID
            self.pendingVoiceCommandLifecycleID = nil
            handled = self.commandMode.cancelInvalidPendingCommand() || handled
        }

        if let lifecycleID = self.processingDictationLifecycleID {
            // A stop already owns the audio; suppress its pending output without stopping again.
            self.cancelledOutputLifecycleID = lifecycleID
            handled = true
        } else if self.asr.isRunningOrStarting {
            let preservesHistory = SettingsStore.shared.saveTranscriptionHistory && self.asr.isRunning && !self.asr.isDictionaryTrainingCaptureActive
                && (self.activeRecordingMode == .dictate || self.activeRecordingMode == .promptMode)
                && !self.isRecordingForRewrite && !self.isRecordingForCommand
                && self.currentDictationOutputRouteForHotkeyStop() != .onboardingSandbox
                && !DictationPromptTestCoordinator.shared.isActive && !self.isFluidIntelligenceDemoShowing
            if preservesHistory {
                self.isSavingCancelledRecording = true
                self.cancelledOutputLifecycleID = self.overlayLifecycleID
                let manager = self.hotkeyManager
                let stopLockStartedAt = manager?.traceStopLocked()
                Task {
                    defer {
                        self.isSavingCancelledRecording = false
                        if let stopLockStartedAt { manager?.traceStopUnlocked(since: stopLockStartedAt) }
                    }
                    await self.stopAndProcessTranscription(route: .historyOnly)
                }
            } else {
                let isOnboardingTryout = self.isOnboardingVoicePlaygroundStepActive
                Task {
                    await self.asr.stopWithoutTranscription()
                    if isOnboardingTryout {
                        AnalyticsService.shared.recordOnboardingTryoutAttemptResult(outcome: .cancelled)
                    }
                }
                if self.activeRecordingMode == .edit || self.isRecordingForRewrite {
                    self.rewriteMode.clearState()
                }
                self.clearActiveRecordingMode()
            }
            self.cancelPrewarmDictationIfNeeded()
            handled = true
        } else if self.activeRecordingMode != .none {
            self.cancelPrewarmDictationIfNeeded()
            self.clearActiveRecordingMode()
            handled = true
        }

        if handled || NotchOverlayManager.shared.isBottomOverlayVisible || NotchOverlayManager.shared.isOverlayVisible {
            self.menuBarManager?.beginProcessingCompletionAndHideOverlay()
            handled = true
        }
        if self.cancelShortcutWindowHandler() {
            handled = true
        }
        if handled {
            self.spokenSendAutoStopTask?.cancel()
            self.spokenSendAutoStopTask = nil
            self.stopSpokenSendVoiceActivityMonitoring()
            self.spokenSendCountdownStartedAt = nil
            self.hotkeyManager?.resetModifierOnlyShortcutTracking(reason: .cancel)
        }
        return handled ? .cancelled : .unhandled
    }

    /// Checks the hotkey event tap and passes the answer to `onHotkeyHealthChecked`.
    @discardableResult
    func checkHotkeyHealth() -> Bool {
        let isHealthy = self.hotkeyManager?.validateEventTapHealth() ?? false
        self.onHotkeyHealthChecked?(isHealthy)
        return isHealthy
    }
}
