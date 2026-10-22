import AppKit
import Foundation

/// The stop pipeline: what happens between the user releasing the shortcut and the
/// text landing, plus the prompt test route and the Spoken Send countdown.
extension DictationSession {
    func stopAndProcessTranscription(route: OutputRoute = .normal, toggleStopRequestedAt: TimeInterval? = nil) async {
        guard self.processingDictationLifecycleID == nil else { return }
        let outputLifecycleID = self.overlayLifecycleID
        self.processingDictationLifecycleID = outputLifecycleID
        defer {
            if self.processingDictationLifecycleID == outputLifecycleID {
                self.processingDictationLifecycleID = nil
            }
        }
        var closeTrace = OverlayCloseTrace("content.stopCallback")
        defer { closeTrace.finish() }
        let lifecycle = self.overlayLifecycleID
        defer {
            if self.overlayLifecycleID == lifecycle { NotchContentState.shared.stopSnapshotLabel = nil }
        }
        let pipelineID = UUID().uuidString
        await DebugLogger.$pipelineID.withValue(pipelineID) {
            await self.processStoppedTranscription(route: route, pipelineID: pipelineID, toggleStopRequestedAt: toggleStopRequestedAt)
        }
    }

    // Keep the ordered dictation delivery path intact during integration.
    // swiftlint:disable:next function_body_length
    func processStoppedTranscription(route: OutputRoute, pipelineID: String, toggleStopRequestedAt: TimeInterval?) async {
        guard let summaryActivity = MeetingSummaryActivityCoordinator.shared.beginProcessing() else {
            MeetingSummaryActivityCoordinator.presentBusyError()
            return
        }
        defer { MeetingSummaryActivityCoordinator.shared.endProcessing(summaryActivity) }

        let pipelineStartedAt = ProcessInfo.processInfo.systemUptime
        let expectedOverlayLifecycleID = self.overlayLifecycleID
        self.appBench("pipeline_begin id=\(pipelineID) route=\(route.rawValue) toggleStopRequestedAt=\(toggleStopRequestedAt.map { String($0) } ?? "nil") loadAvg1m=\(self.benchmarkLoadAverage())")
        defer {
            self.appBench("pipeline_handler_return id=\(pipelineID) elapsedMs=\((ProcessInfo.processInfo.systemUptime - pipelineStartedAt) * 1000) deliveryMayBePending=true")
        }
        DebugLogger.shared.info("Output route selected: \(route.rawValue)", source: "DictationSession")
        self.appBench("stop_path_enter route=\(route.rawValue)")
        let isOnboardingTryout = route == .onboardingSandbox && self.isOnboardingVoicePlaygroundStepActive

        // Check if we're in rewrite or command mode
        let modeAtStop = self.activeRecordingMode
        let wasRewriteMode = modeAtStop == .edit || self.isRecordingForRewrite
        let wasCommandMode = modeAtStop == .command || self.isRecordingForCommand
        let activeDictationSlot = self.currentDictationShortcutSlot(for: modeAtStop)
        let promptOverride = self.promptModeOverrideText
        let promptTest = DictationPromptTestCoordinator.shared
        let promptTestSessionID = promptTest.isActive ? promptTest.sessionID : nil
        var stopSnapshot = route.savesHistory && !wasRewriteMode && !wasCommandMode && !promptTest.isActive
            ? self.captureDictationStopSnapshot(slot: activeDictationSlot ?? .primary) : nil
        let shouldUseAIOnStop = stopSnapshot?.usesAI ?? activeDictationSlot.map {
            DictationAIPostProcessingGate.isConfigured(for: $0, appBundleID: self.recordingAppInfo?.bundleId)
        } ?? DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: self.recordingAppInfo?.bundleId)
        let shouldHideOverlayOnStop = route == .historyOnly || self.cancelledOutputLifecycleID == expectedOverlayLifecycleID || (route == .normal && !wasRewriteMode && !wasCommandMode
            && !promptTest.isActive && !shouldUseAIOnStop && !SettingsStore.shared.spokenSendEnabled)
        DebugLogger.shared.info(
            "Routing decision snapshot | activeMode=\(modeAtStop.rawValue) | rewrite=\(wasRewriteMode) | command=\(wasCommandMode) | overlay=\(NotchContentState.shared.mode.rawValue)",
            source: "DictationSession"
        )

        self.clearActiveRecordingMode()
        let stopOverlay = self.prepareOverlayForASRStop(shouldHideOverlayOnStop: shouldHideOverlayOnStop, lifecycleID: expectedOverlayLifecycleID)
        let stopUIInvalidationHold = self.holdStopUIInvalidation(whileProcessing: !stopOverlay.didRequestHide)
        defer { self.releaseStopUIInvalidation(stopUIInvalidationHold) }

        // Stop the ASR service and wait for transcription to complete
        // The processing indicator will stay visible during this phase
        let asrStopStartedAt = ProcessInfo.processInfo.systemUptime
        self.appBench("asr_stop_call")
        // Play the stop cue as soon as the audio engine has stopped, before the
        // (potentially slow) final transcription pass. Scoped to dictation only.
        // Command/Edit modes call asr.stop() without this callback.
        let transcribedText = await asr.stop(
            onCaptureStopped: {
                TranscriptionSoundPlayer.shared.playStopSound()
            },
            onFinalTranscriptionStarted: stopOverlay.onFinalTranscriptionStarted
        )
        self.appBench("asr_stop_return elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - asrStopStartedAt) * 1000).rounded()))")
        self.completeDictationStopSnapshot(&stopSnapshot)
        let audioSnapshot = self.asr.consumeLastCompletedAudioSnapshot()
        let dictionaryLearningRecording = self.asr.consumeDictionaryLearningRecording()
        let transcriptionDurationMilliseconds = self.asr.consumeLastFinalTranscriptionDurationMs()
        let parakeetProcessingDurationMilliseconds = self.asr.consumeLastFinalParakeetProcessingMs()
        DebugLogger.shared.info(
            "Stop transcription result | chars=\(transcribedText.count) | empty=\(transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
            source: "DictationSession"
        )

        guard transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            // Empty results have no delivery callback, so clear their stale
            // preview before the existing empty-result dismissal path runs.
            NotchOverlayManager.shared.updateTranscriptionText("")
            DebugLogger.shared.debug("Transcription returned empty text", source: "DictationSession")
            if isOnboardingTryout {
                if self.asr.lastStopOutcome == .failed {
                    AnalyticsService.shared.recordOnboardingTryoutAttemptResult(
                        outcome: .error,
                        failureStage: .transcription
                    )
                } else {
                    AnalyticsService.shared.recordOnboardingTryoutAttemptResult(outcome: .empty)
                }
            }
            if route == .normal, !wasRewriteMode, !wasCommandMode, !promptTest.isActive {
                self.recordEmptyDictationPerformance(startedAt: pipelineStartedAt, asrMs: transcriptionDurationMilliseconds)
            }
            // Finish the same short exit transition even when no text is emitted.
            if !stopOverlay.didRequestHide {
                await self.menuBarManager?.finishProcessingAndHideOverlay()
            }
            return
        }

        let cancelledAtASRStop = route == .historyOnly || self.cancelledOutputLifecycleID == expectedOverlayLifecycleID
        if cancelledAtASRStop, promptTestSessionID != nil || route == .onboardingSandbox { return }

        // Prompt Test Mode: reroute dictation hotkey output into the prompt editor (no typing/clipboard/history).
        if !cancelledAtASRStop, await self.routePromptTestResult(transcribedText, sessionID: promptTestSessionID, lifecycleID: expectedOverlayLifecycleID) {
            return
        }

        if NotchOverlayManager.shared.isBottomOverlayVisible {
            BottomOverlayWindowController.shared.beginReleaseTransition()
        }

        // If this was a rewrite recording, process the rewrite instead of typing
        if wasRewriteMode {
            guard !cancelledAtASRStop else {
                self.rewriteMode.clearState()
                return
            }
            DebugLogger.shared.info("Processing rewrite instruction (\(transcribedText.count) chars)", source: "DictationSession")
            AnalyticsService.shared.recordModelUsage(
                role: .transcription,
                mode: .edit,
                descriptor: SettingsStore.shared.selectedSpeechModel.analyticsDescriptor
            )
            let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
            await self.processRewriteWithVoiceInstruction(transcribedText, appInfo: appInfo, lifecycleID: expectedOverlayLifecycleID)
            return
        }

        // If this was a command recording, process the command
        if wasCommandMode {
            guard !cancelledAtASRStop else { return }
            DebugLogger.shared.info("Processing command (\(transcribedText.count) chars)", source: "DictationSession")
            AnalyticsService.shared.recordModelUsage(
                role: .transcription,
                mode: .command,
                descriptor: SettingsStore.shared.selectedSpeechModel.analyticsDescriptor
            )
            await self.processCommandWithVoice(transcribedText, lifecycleID: expectedOverlayLifecycleID)
            return
        }

        var finalText: String
        var aiFallbackReason: String?
        var postProcessingModel: String?
        var aiProcessingDurationMilliseconds: Int?
        var aiTokensPerSecond: Double?
        var aiFallbackNotificationError: String?
        var aiFallbackIsQuiet = false
        var aiFallbackOutcome = "ai_fallback"
        let appInfo = stopSnapshot?.appInfo ?? self.recordingAppInfo ?? self.getCurrentAppInfo()
        let punctuationFormattedText = ASRService.applySpokenPunctuationFormatting(
            transcribedText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let spokenSendParse = SpokenSendParser.parseArmed(
            punctuationFormattedText,
            phrase: SettingsStore.shared.spokenSendPhrase,
            enabled: !cancelledAtASRStop && route.deliversText && SettingsStore.shared.spokenSendEnabled,
            wasArmed: self.spokenSendArming.wasArmed
        )
        self.updateSpokenSendIndicatorForFinalParse(shouldSend: spokenSendParse.shouldSend)
        let normalizedTranscribedText = spokenSendParse.text
        var sendsExistingDraft = spokenSendParse.shouldSend &&
            normalizedTranscribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let practiceModelID = route == .onboardingSandbox && SettingsStore.shared.onboardingCurrentStep == 5
            ? PrivateAIProviderPromptFormat.verifiedModelID(settings: SettingsStore.shared) : nil
        // A custom or one-off prompt may do more than clean up (translate, reformat),
        // so only the default cleanup is skipped for very short dictations.
        let skipsCleanupAsShort = practiceModelID == nil && promptOverride == nil &&
            stopSnapshot?.hasCustomPrompt == false && ShortDictation.skipsCleanup(normalizedTranscribedText)
        if skipsCleanupAsShort {
            self.appBench("ai_skipped_short words<=\(ShortDictation.maxWordsWithoutCleanup)")
        }
        // Only the default cleanup is held to the transcript's negations and numbers.
        let checksCleanupMeaning = practiceModelID == nil && promptOverride == nil && stopSnapshot?.hasCustomPrompt == false
        let shouldUseAI = !sendsExistingDraft && !skipsCleanupAsShort &&
            (practiceModelID != nil || (stopSnapshot?.usesAI ?? DictationAIPostProcessingGate.isConfigured(
                for: activeDictationSlot ?? .primary,
                appBundleID: appInfo.bundleId
            )))
        let transcriptionModelInfo = self.currentTranscriptionModelInfo()
        let postProcessingModelInfo = self.recordDictationUsage(
            shouldUseAI: shouldUseAI,
            dictationSlot: activeDictationSlot,
            appBundleID: appInfo.bundleId,
            snapshot: stopSnapshot
        )

        if shouldUseAI {
            DebugLogger.shared.debug("Routing transcription through AI post-processing", source: "DictationSession")
            postProcessingModel = postProcessingModelInfo.model
            let postProcessingInputChars = normalizedTranscribedText.count
            let postProcessingStart = ProcessInfo.processInfo.systemUptime
            let processingFeedback = self.makeAIProcessingFeedback(lifecycleID: expectedOverlayLifecycleID)
            let refiningStatusTask = processingFeedback.statusTask
            defer { refiningStatusTask.cancel() }

            let streamPreview = processingFeedback.streamPreview
            let streamHandler: PrivateAIStreamHandler = { chunk in
                streamPreview.append(chunk)
            }

            do {
                self.logAIProcessCall(pipelineID, postProcessingModelInfo, postProcessingInputChars)
                // The onboarding practice step keeps its own pacing; real dictation never waits past the budget.
                let result = try await self.cleanUpDictationWithinBudget(
                    route: stopSnapshot?.route ?? DictationProviderRoute.resolve(
                        settings: SettingsStore.shared,
                        dictationSlot: activeDictationSlot,
                        appBundleID: appInfo.bundleId
                    ),
                    enforcesBudget: practiceModelID == nil,
                    primary: { [stopSnapshot] in
                        try await self.processTextWithAIMetrics(
                            normalizedTranscribedText,
                            overrideSystemPrompt: promptOverride,
                            overrideProviderID: practiceModelID == nil ? nil : PrivateAIProviderFeature.shared.providerID,
                            overrideModel: practiceModelID,
                            dictationSlot: activeDictationSlot,
                            streamHandler: streamHandler,
                            benchmarkID: pipelineID,
                            stopSnapshot: stopSnapshot
                        )
                    },
                    localFallback: { [stopSnapshot] localModel in
                        // No stream preview: the failed cloud call may already have streamed into it.
                        try await self.processTextWithAIMetrics(
                            normalizedTranscribedText,
                            overrideSystemPrompt: stopSnapshot?.systemPrompt ?? promptOverride,
                            overrideProviderID: DictationCleanupRouting.localFallbackProviderID,
                            overrideModel: localModel,
                            dictationSlot: activeDictationSlot,
                            benchmarkID: pipelineID,
                            contextSnapshot: stopSnapshot
                        )
                    }
                )
                refiningStatusTask.cancel()
                finalText = result.text
                if checksCleanupMeaning,
                   let violation = CleanupMeaningGuard.check(transcript: normalizedTranscribedText, cleaned: result.text)
                {
                    self.appBench("cleanup_guard id=\(pipelineID) \(violation.logDescription)")
                    DebugLogger.shared.warning(
                        "AI cleanup changed a negation or number, pasting the transcript: \(violation.logDescription)",
                        source: "DictationSession"
                    )
                    aiFallbackReason = violation.historyReason
                    aiFallbackIsQuiet = true
                    aiFallbackOutcome = "ai_guard"
                    finalText = normalizedTranscribedText
                }
                self.appBench("ai_process_return id=\(pipelineID)")
                aiTokensPerSecond = result.tokensPerSecond
                streamPreview.flush()
                self.appBench("ai_preview_flushed id=\(pipelineID)")
            } catch {
                refiningStatusTask.cancel()
                self.appBench("ai_process_fail id=\(pipelineID)")
                // Fall back to the raw transcription so the user still gets
                // their words typed instead of an error string.
                DebugLogger.shared.error(
                    "AI post-processing failed, falling back to raw transcription: \(error.localizedDescription)",
                    source: "DictationSession"
                )
                aiFallbackReason = error.localizedDescription
                if error is LatencyBudget.Exceeded {
                    // A slow model is routine, not a failure: paste quietly and keep the reason in History.
                    aiFallbackIsQuiet = true
                    aiFallbackOutcome = "ai_timeout"
                } else {
                    aiFallbackNotificationError = DictationAIFailurePresentationPolicy.notificationMessage(for: error)
                }
                finalText = normalizedTranscribedText
            }
            let postProcessingLatencyMs = Int(
                ((ProcessInfo.processInfo.systemUptime - postProcessingStart) * 1000).rounded()
            )
            aiProcessingDurationMilliseconds = postProcessingLatencyMs
            let postProcessingProviderName = postProcessingModelInfo.provider ?? "unknown"
            let postProcessingModelName = postProcessingModelInfo.model ?? "unknown"
            DebugLogger.shared.info(
                "Dictation AI post-processing finished in \(postProcessingLatencyMs)ms "
                    + "provider=\(postProcessingProviderName) model=\(postProcessingModelName) "
                    + "inputChars=\(postProcessingInputChars) fallback=\(aiFallbackReason != nil)",
                source: "DictationSession"
            )
        } else {
            finalText = normalizedTranscribedText
        }

        // Runs after AI cleanup so the user's literal, GAAV and continuous dictation settings win.
        // Continuous dictation uses the field context captured at recording start.
        finalText = DictationTextFormatter.finalize(
            finalText,
            context: .init(appName: appInfo.name, bundleID: appInfo.bundleId, windowTitle: appInfo.windowTitle),
            precedingText: stopSnapshot?.precedingText ?? self.recordingPrecedingText,
            settings: .currentForFinalize
        )
        self.recordingPrecedingText = ""
        let outputRoute: OutputRoute = route == .normal && self.cancelledOutputLifecycleID == expectedOverlayLifecycleID ? .historyOnly : route
        if outputRoute == .historyOnly, sendsExistingDraft {
            // Keep the spoken words recoverable when Escape cancels a send-only draft.
            sendsExistingDraft = false
            finalText = ASRService.applyGAAVFormatting(punctuationFormattedText)
        }
        let publishesToPracticeField = route == .onboardingSandbox && DictationPracticeField.shared.isActive
        if outputRoute.publishesEditorResult, self.cancelledOutputLifecycleID != expectedOverlayLifecycleID,
           !publishesToPracticeField || self.isOnboardingPracticeStepActive
        { self.asr.finalText = finalText }
        if publishesToPracticeField, self.cancelledOutputLifecycleID != expectedOverlayLifecycleID {
            DictationPracticeField.shared.text = finalText
        }
        if route == .onboardingSandbox,
           self.cancelledOutputLifecycleID != expectedOverlayLifecycleID,
           self.isOnboardingVoicePlaygroundStepActive,
           !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            AnalyticsService.shared.finishOnboardingTryout(
                outcome: .success,
                failureStage: aiFallbackReason == nil ? nil : .postProcessing
            )
            SettingsStore.shared.onboardingPlaygroundValidated = true
            SettingsStore.shared.playgroundUsed = true
        }

        DebugLogger.shared.info("Transcription finalized (chars: \(finalText.count))", source: "DictationSession")
        let finalTextReadyAt = ProcessInfo.processInfo.systemUptime
        self.recordCompletedDictationPerformance(
            route: route,
            pipelineStartedAt: pipelineStartedAt,
            readyAt: finalTextReadyAt,
            transcriptionDurationMilliseconds: transcriptionDurationMilliseconds,
            aiProcessingDurationMilliseconds: aiProcessingDurationMilliseconds,
            fluidModel: AnalyticsFluidIntelligenceModel(modelID: postProcessingModel),
            tokensPerSecond: aiTokensPerSecond,
            outcome: aiFallbackReason == nil ? "success" : aiFallbackOutcome
        )
        let finalOutputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.appBench("transcription_finalized chars=\(finalText.count)")
        self.appBench("text_ready chars=\(finalText.count)")
        self.appBench("pipeline_text_ready id=\(pipelineID) stopToReadyMs=\((finalTextReadyAt - pipelineStartedAt) * 1000)")

        let shouldPersistOutputs = outputRoute.savesHistory
        let shouldDeliverOutputs = outputRoute.deliversText
        if shouldDeliverOutputs { FileLogger.shared.noteDictationUse() }
        if !shouldPersistOutputs {
            DebugLogger.shared.info(
                "Sandbox route active: suppressing clipboard/history/external typing side effects",
                source: "DictationSession"
            )
        }

        let shouldShowAIProcessingFailure = !aiFallbackIsQuiet && DictationAIFailurePresentationPolicy.shouldPresent(
            shouldPersistOutputs: shouldDeliverOutputs,
            fallbackReason: aiFallbackReason
        )
        if !shouldShowAIProcessingFailure {
            self.pendingAIReprocessText = nil
        }

        let isFluidFrontmost = stopSnapshot
            .map { $0.target?.pid == ProcessInfo.processInfo.processIdentifier } ?? (NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier)

        // Save to transcription history (transcription mode only, if enabled)
        if shouldPersistOutputs, !sendsExistingDraft, SettingsStore.shared.saveTranscriptionHistory {
            let historyEntryID = UUID()
            let historyTimestamp = Date()
            TranscriptionHistoryStore.shared.addEntry(
                id: historyEntryID,
                timestamp: historyTimestamp,
                rawText: outputRoute.deliversText && spokenSendParse.shouldSend ? normalizedTranscribedText : transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: postProcessingModel != nil && aiFallbackReason == nil,
                processingModel: postProcessingModel,
                transcriptionDurationMilliseconds: transcriptionDurationMilliseconds,
                parakeetProcessingDurationMilliseconds: parakeetProcessingDurationMilliseconds,
                aiProcessingDurationMilliseconds: aiProcessingDurationMilliseconds,
                aiTokensPerSecond: aiTokensPerSecond,
                aiProcessingError: aiFallbackReason,
                spokenDurationMilliseconds: audioSnapshot?.durationMilliseconds
            )
            self.persistDictationAudioIfNeeded(
                audioSnapshot,
                entryID: historyEntryID,
                timestamp: historyTimestamp,
                model: transcriptionModelInfo.model
            )
        }
        // When FluidVoice itself is frontmost, the bound editor already receives `finalText`.
        let shouldCopyToClipboard = shouldDeliverOutputs &&
            !sendsExistingDraft &&
            SettingsStore.shared.copyTranscriptionToClipboard
        let shouldTypeExternally = shouldDeliverOutputs && !isFluidFrontmost

        // Send-only stops normally have no History row. Recover their words if
        // Escape arrives after the output decision but before delivery completes.
        func saveCancelledSendOnlyHistory() {
            guard sendsExistingDraft, SettingsStore.shared.saveTranscriptionHistory else { return }
            let id = UUID()
            let timestamp = Date()
            TranscriptionHistoryStore.shared.addEntry(
                id: id,
                timestamp: timestamp,
                rawText: transcribedText,
                processedText: ASRService.applyGAAVFormatting(punctuationFormattedText),
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: false,
                processingModel: nil,
                transcriptionDurationMilliseconds: transcriptionDurationMilliseconds,
                spokenDurationMilliseconds: audioSnapshot?.durationMilliseconds
            )
            self.persistDictationAudioIfNeeded(audioSnapshot, entryID: id, timestamp: timestamp, model: transcriptionModelInfo.model)
        }

        var didTypeExternally = false
        var didFailTextDelivery = false

        self.appBench("typing_decision snapshotTarget=\(stopSnapshot != nil) external=\(shouldTypeExternally)")

        // A sidebar search field that was already focused when recording began gets
        // the text through its field editor, which also fires change notifications.
        // So does an in-app editor that opted in with `DictationTextTarget`.
        if isFluidFrontmost, shouldDeliverOutputs, !sendsExistingDraft,
           let focusTarget = self.recordingFocusTarget,
           focusTarget.pid == ProcessInfo.processInfo.processIdentifier,
           TypingService.isExactFocusTargetActive(focusTarget),
           let window = NSApp.keyWindow,
           let editor = window.firstResponder as? NSTextView,
           SidebarSearchField.owns(editor, in: window) || DictationTextTarget.accepts(editor)
        {
            editor.insertText(finalText, replacementRange: editor.selectedRange())
        }

        if shouldTypeExternally {
            let typingTarget = stopSnapshot.map { (pid: $0.target?.pid, shouldRestoreOriginalFocus: true) }
                ?? self.resolveTypingTargetPID(returnToStartingField: SettingsStore.shared.returnDictationToStartingField)
            let spokenSendRequested = spokenSendParse.shouldSend
            let sendFocus = stopSnapshot == nil ? self.recordingFocusTarget : stopSnapshot?.focusTarget
            let targetMatchesRecordingFocus = typingTarget.pid != nil
                && typingTarget.pid == sendFocus?.pid
            let spokenSendAllowed = spokenSendRequested
                && aiFallbackReason == nil
                && (sendsExistingDraft || !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && targetMatchesRecordingFocus
                && (typingTarget.shouldRestoreOriginalFocus || sendFocus.map { TypingService.isExactFocusTargetActive($0) } == true)
                && !self.isSpokenSendBlockedApp(appInfo)
            // Dispatch insertion as soon as the destination app is ready; the
            // overlay hides asynchronously after output so it cannot delay paste.
            let focusReady = await self.prepareStoppedDictationDelivery(
                finalText,
                keepBackup: shouldCopyToClipboard,
                snapshot: stopSnapshot,
                needsRestoration: typingTarget.shouldRestoreOriginalFocus,
                isOutputValid: { self.cancelledOutputLifecycleID != expectedOverlayLifecycleID }
            )
            // Escape can arrive while focus restoration is suspended; History is already saved.
            guard self.cancelledOutputLifecycleID != expectedOverlayLifecycleID else {
                saveCancelledSendOnlyHistory()
                return
            }

            if spokenSendAllowed {
                NotchContentState.shared.setSpokenSendIndicatorState(.sending)
                NotchOverlayManager.shared.updateTranscriptionText("Sending")
            }

            let deliveryResult: TextDeliveryResult
            if !focusReady {
                deliveryResult = .recoverableFailure(.targetRestoreFailed)
            } else if spokenSendAllowed {
                self.appBench(
                    "text_ready_to_type_request elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - finalTextReadyAt) * 1000).rounded()))"
                )
                let deliveryOutcome = await self.deliverSpokenSend(
                    finalOutputPlan,
                    targetPID: typingTarget.pid,
                    textReadyAt: finalTextReadyAt,
                    toggleStopRequestedAt: toggleStopRequestedAt,
                    preserveTranscriptOnClipboard: shouldCopyToClipboard,
                    stopSnapshot: stopSnapshot,
                    isOutputValid: { self.cancelledOutputLifecycleID != expectedOverlayLifecycleID }
                )
                self.logPipelineCompletion(
                    outcome: String(describing: deliveryOutcome),
                    pipelineID: pipelineID,
                    pipelineStartedAt: pipelineStartedAt,
                    textReadyAt: finalTextReadyAt
                )
                didTypeExternally = deliveryOutcome.didInsert
                deliveryResult = deliveryOutcome.didInsert || deliveryOutcome.didDispatchAction
                    ? .commandPosted
                    : .recoverableFailure(.pasteCommandFailed)
            } else {
                self.appBench(
                    "text_ready_to_type_request elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - finalTextReadyAt) * 1000).rounded()))"
                )
                deliveryResult = await self.asr.typeOutputPlanToActiveField(
                    finalOutputPlan,
                    preferredTargetPID: typingTarget.pid,
                    textReadyAt: finalTextReadyAt,
                    toggleStopRequestedAt: toggleStopRequestedAt,
                    tracksDictionaryCorrections: true,
                    preserveTranscriptOnClipboard: shouldCopyToClipboard,
                    isOutputValid: { self.cancelledOutputLifecycleID != expectedOverlayLifecycleID }
                )
                didTypeExternally = deliveryResult.wasDispatched
                self.handleTypingDelivery(
                    deliveryResult.wasDispatched ? .inserted : .insertionFailed,
                    pipelineID: pipelineID,
                    pipelineStartedAt: pipelineStartedAt,
                    textReadyAt: finalTextReadyAt,
                    shouldHideOverlay: deliveryResult.wasDispatched && !shouldShowAIProcessingFailure && !stopOverlay.didRequestHide && !spokenSendRequested,
                    expectedOverlayLifecycleID: expectedOverlayLifecycleID
                )
            }

            guard self.overlayLifecycleID == expectedOverlayLifecycleID, self.cancelledOutputLifecycleID != expectedOverlayLifecycleID else {
                if self.cancelledOutputLifecycleID == expectedOverlayLifecycleID { saveCancelledSendOnlyHistory() }
                self.appBench("delivery_ui_skipped reason=stale_recording")
                return
            }
            if spokenSendRequested, !spokenSendAllowed {
                NotchContentState.shared.setSpokenSendIndicatorState(.failed)
                DebugLogger.shared.warning(
                    "Spoken Send skipped because delivery safety checks did not pass",
                    source: "DictationSession"
                )
                if aiFallbackReason == nil {
                    NotchOverlayManager.shared.updateTranscriptionText("Text inserted — send skipped")
                    try? await Task.sleep(nanoseconds: 650_000_000)
                }
            }
            guard self.overlayLifecycleID == expectedOverlayLifecycleID else { return }
            NotchContentState.shared.setSpokenSendIndicatorState(.hidden)

            if case let .recoverableFailure(failure) = deliveryResult {
                didFailTextDelivery = true
                self.showStoppedDictationDeliveryFailure(failure, transcript: finalText, snapshot: stopSnapshot)
            } else if !shouldShowAIProcessingFailure, !stopOverlay.didRequestHide {
                self.hideOverlayAfterOutput()
            }
            // Delivery UI must complete before correction tracking queries Accessibility.
            if didTypeExternally, !spokenSendAllowed {
                AutomaticDictionaryCorrectionTracker.shared.beginObservingInsertion(
                    finalOutputPlan.plainText,
                    targetPID: typingTarget.pid,
                    learningRecording: dictionaryLearningRecording
                )
                self.appBench("dictionary_tracking_scheduled afterDeliveryUI=true")
            }
        }

        if !shouldTypeExternally {
            await PasteDeliveryCoordinator.shared.copyBackup(finalText, enabled: shouldCopyToClipboard, isOutputValid: { self.cancelledOutputLifecycleID != expectedOverlayLifecycleID })
        }

        guard self.cancelledOutputLifecycleID != expectedOverlayLifecycleID || outputRoute == .historyOnly else { return }

        // Submit raw fallback delivery before failure UI or notification work can
        // compete with it on the main actor. Sandbox runs never present either.
        if shouldShowAIProcessingFailure {
            self.pendingAIReprocessText = spokenSendParse.shouldSend ? normalizedTranscribedText : transcribedText
            NotchContentState.shared.showAIProcessingFailure()
            self.menuBarManager?.finishProcessingKeepingOverlayVisible()
            if let aiFallbackNotificationError {
                NotificationService.showAIProcessingFallback(error: aiFallbackNotificationError)
            }
        }

        if !didTypeExternally, !shouldShowAIProcessingFailure, !didFailTextDelivery, !stopOverlay.didRequestHide {
            self.hideOverlayAfterOutput()
        }
        if !shouldTypeExternally {
            self.logPipelineCompletion(
                outcome: outputRoute == .historyOnly ? "history_only" : (shouldPersistOutputs ? "internal_editor" : "sandbox"),
                pipelineID: pipelineID,
                pipelineStartedAt: pipelineStartedAt,
                textReadyAt: finalTextReadyAt
            )
        }
    }

    func processDictationPromptTest(_ transcribedText: String, lifecycleID: UInt64) async {
        let promptTest = DictationPromptTestCoordinator.shared
        let sessionID = promptTest.sessionID
        promptTest.lastTranscriptionText = transcribedText
        promptTest.lastOutputText = ""
        promptTest.lastError = ""
        guard DictationAIPostProcessingGate.isProviderConfigured(
            providerID: promptTest.draftProviderID,
            model: promptTest.draftModel
        ) else {
            promptTest.lastError = "AI post-processing is not configured. Configure a provider/model (and API key for non-local endpoints) to test prompts."
            if self.overlayLifecycleID == lifecycleID {
                self.menuBarManager?.setProcessing(false)
            }
            return
        }
        promptTest.isProcessing = true
        let refiningStatusTask = self.makeAIProcessingFeedback(lifecycleID: lifecycleID).statusTask
        defer {
            refiningStatusTask.cancel()
            if self.overlayLifecycleID == lifecycleID {
                self.menuBarManager?.setProcessing(false)
            }
            if promptTest.sessionID == sessionID { promptTest.isProcessing = false }
        }
        do {
            let result = try await self.processTextWithAI(
                transcribedText,
                overrideSystemPrompt: promptTest.usesBuiltInPrompt ? nil : promptTest.draftPromptText,
                overrideProviderID: promptTest.draftProviderID,
                overrideModel: promptTest.draftModel,
                dictationSlot: promptTest.usesBuiltInPrompt ? .primary : nil
            )
            let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
            let literalFormattedResult = ASRService.applyDictationLiteralFormatting(
                result,
                appName: appInfo.name,
                bundleID: appInfo.bundleId,
                windowTitle: appInfo.windowTitle
            )
            guard promptTest.acceptsResult(for: sessionID), self.cancelledOutputLifecycleID != lifecycleID else { return }
            promptTest.lastOutputText = ASRService.applyGAAVFormatting(literalFormattedResult)
        } catch {
            guard promptTest.acceptsResult(for: sessionID), self.cancelledOutputLifecycleID != lifecycleID else { return }
            DebugLogger.shared.error("Prompt test AI call failed: \(error.localizedDescription)", source: "DictationSession")
            promptTest.lastError = error.localizedDescription
        }
    }

    func routePromptTestResult(_ text: String, sessionID: UUID?, lifecycleID: UInt64) async -> Bool {
        guard let sessionID else { return false }
        // A closed/replaced practice session must never fall through to external typing.
        guard DictationPromptTestCoordinator.shared.acceptsResult(for: sessionID) else {
            if self.overlayLifecycleID == lifecycleID { self.menuBarManager?.setProcessing(false) }
            return true
        }
        await self.processDictationPromptTest(text, lifecycleID: lifecycleID)
        return true
    }

    func handleSpokenSendPartialTranscription(_ text: String) {
        guard SettingsStore.shared.spokenSendEnabled else { return }
        let isDictationMode = self.activeRecordingMode == .dictate || self.activeRecordingMode == .promptMode
        let isEligible = isDictationMode &&
            self.cancelledOutputLifecycleID != self.overlayLifecycleID &&
            self.currentDictationOutputRouteForHotkeyStop() == .normal &&
            self.asr.isRunning &&
            !self.spokenSendAutoStopTriggered
        let isArmed = self.spokenSendArming.update(
            partial: text,
            isEligible: isEligible,
            phrase: SettingsStore.shared.spokenSendPhrase
        )

        guard SettingsStore.shared.spokenSendImmediatelyEnabled else {
            if isEligible {
                NotchContentState.shared.setSpokenSendIndicatorState(isArmed ? .detected : .hidden)
            }
            return
        }

        guard isArmed else {
            self.spokenSendAutoStopTask?.cancel()
            self.spokenSendAutoStopTask = nil
            self.stopSpokenSendVoiceActivityMonitoring()
            self.spokenSendCountdownStartedAt = nil
            if !self.spokenSendAutoStopTriggered,
               NotchContentState.shared.spokenSendIndicatorState == .countingDown
            {
                NotchContentState.shared.setSpokenSendIndicatorState(.hidden)
            }
            return
        }

        guard self.spokenSendAutoStopTask == nil else {
            return
        }

        let expectedOverlayLifecycleID = self.overlayLifecycleID
        let countdownStartedAt = ProcessInfo.processInfo.systemUptime
        self.spokenSendCountdownStartedAt = countdownStartedAt
        self.spokenSendLastVoiceActivityAt = countdownStartedAt
        self.startSpokenSendVoiceActivityMonitoring()
        let expectedCountdownID = NotchContentState.shared.beginSpokenSendCountdown()
        self.spokenSendAutoStopTask = Task { @MainActor in
            // Keep one countdown across harmless streaming refinements such as punctuation or casing.
            try? await Task.sleep(nanoseconds: SpokenSendParser.immediateStopSettleNanoseconds)
            let quietDuration = ProcessInfo.processInfo.systemUptime - self.spokenSendLastVoiceActivityAt
            guard !Task.isCancelled,
                  self.overlayLifecycleID == expectedOverlayLifecycleID,
                  NotchContentState.shared.spokenSendCountdownID == expectedCountdownID,
                  self.asr.isRunning,
                  self.activeRecordingMode == .dictate || self.activeRecordingMode == .promptMode,
                  self.currentDictationOutputRouteForHotkeyStop() == .normal,
                  !self.spokenSendAutoStopTriggered,
                  SpokenSendParser.canCompleteImmediateStop(
                      self.asr.partialTranscription,
                      phrase: SettingsStore.shared.spokenSendPhrase,
                      spokenSendEnabled: SettingsStore.shared.spokenSendEnabled,
                      sendImmediatelyEnabled: SettingsStore.shared.spokenSendImmediatelyEnabled,
                      quietDuration: quietDuration,
                      armedText: self.spokenSendArming.armedText
                  )
            else {
                if self.overlayLifecycleID == expectedOverlayLifecycleID,
                   NotchContentState.shared.spokenSendCountdownID == expectedCountdownID
                {
                    self.spokenSendAutoStopTask = nil
                    self.stopSpokenSendVoiceActivityMonitoring()
                    self.spokenSendCountdownStartedAt = nil
                    if NotchContentState.shared.spokenSendIndicatorState == .countingDown {
                        NotchContentState.shared.setSpokenSendIndicatorState(.hidden)
                    }
                }
                return
            }

            self.spokenSendAutoStopTask = nil
            self.stopSpokenSendVoiceActivityMonitoring()
            self.spokenSendCountdownStartedAt = nil
            self.spokenSendAutoStopTriggered = true
            NotchContentState.shared.setSpokenSendIndicatorState(.sending)
            DebugLogger.shared.info("Spoken Send countdown completed; stopping dictation", source: "DictationSession")
            await self.stopAndProcessTranscription(route: .normal)
        }
    }
}
