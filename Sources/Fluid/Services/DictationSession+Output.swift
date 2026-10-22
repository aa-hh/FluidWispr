import AppKit
import Foundation

/// What the overlay shows while a stopped dictation is processed, how the result is
/// delivered (paste, Spoken Send, or a failure the user can retry), and the timing log.
extension DictationSession {
    private static let aiProcessingStatusDelayNanoseconds: UInt64 = 500_000_000

    func deliverSpokenSend(
        _ outputPlan: DictationLiteralOutputPlan,
        targetPID: pid_t?,
        textReadyAt: TimeInterval,
        toggleStopRequestedAt: TimeInterval?,
        preserveTranscriptOnClipboard: Bool,
        stopSnapshot: DictationStopSnapshot? = nil,
        isOutputValid: @escaping @MainActor () -> Bool = { true }
    ) async -> TypingService.DeliveryOutcome {
        let sendsExistingDraft = outputPlan.plainText.isEmpty
        let outcome = await self.asr.typeOutputPlanToActiveFieldAndWait(
            outputPlan,
            preferredTargetPID: targetPID,
            textReadyAt: textReadyAt,
            toggleStopRequestedAt: toggleStopRequestedAt,
            postInsertionKey: SettingsStore.shared.spokenSendKey,
            requiredFocusTarget: stopSnapshot == nil ? self.recordingFocusTarget : stopSnapshot?.focusTarget,
            preserveTranscriptOnClipboard: preserveTranscriptOnClipboard,
            isOutputValid: isOutputValid
        )
        guard isOutputValid() else { return outcome }
        if outcome.didDispatchAction {
            NotchContentState.shared.setSpokenSendIndicatorState(.sent)
            try? await Task.sleep(nanoseconds: 350_000_000)
            return outcome
        }

        NotchContentState.shared.setSpokenSendIndicatorState(.failed)
        DebugLogger.shared.warning(
            "Spoken Send skipped because delivery safety checks did not pass",
            source: "DictationSession"
        )
        let message = outcome.didInsert
            ? "Text inserted — send skipped"
            : sendsExistingDraft ? "Couldn't send" : "Couldn't insert or send"
        NotchOverlayManager.shared.updateTranscriptionText(message)
        try? await Task.sleep(nanoseconds: 650_000_000)
        return outcome
    }

    func showStoppedDictationDeliveryFailure(_ failure: TextDeliveryFailure, transcript: String, snapshot: DictationStopSnapshot?) {
        if let snapshot {
            // Retry retains its captured-target behavior, now for the field selected at stop.
            NotchContentState.shared.recordingTargetContext = snapshot.target
            NotchContentState.shared.recordingTargetPID = snapshot.target?.pid
        }
        self.showTextDeliveryFailure(failure, transcript: transcript)
    }

    func makeAIProcessingFeedback(
        lifecycleID: UInt64
    ) -> (statusTask: Task<Void, Never>, streamPreview: DictationAIStreamPreviewBuffer) {
        // Fast local cleanup should finish before transient SwiftUI work can queue
        // ahead of its result. Slow providers still receive visible status feedback.
        let statusTask = scheduleDeferredMainActorOperation(
            afterNanoseconds: Self.aiProcessingStatusDelayNanoseconds
        ) {
            guard self.overlayLifecycleID == lifecycleID, self.cancelledOutputLifecycleID != lifecycleID else {
                self.appBench("processing_ui_skipped status=Refining reason=stale_lifecycle")
                return
            }
            self.menuBarManager?.flushDeferredStoppedRecordingState()
            self.menuBarManager?.setProcessing(true)
            self.appBench("processing_ui_request status=Refining trigger=delayed_status")
            NotchOverlayManager.shared.updateTranscriptionText("Refining")
            self.appBench("processing_ui_requested status=Refining trigger=delayed_status")
        }
        let streamPreview = DictationAIStreamPreviewBuffer { text in
            guard self.overlayLifecycleID == lifecycleID, self.cancelledOutputLifecycleID != lifecycleID else { return }
            NotchOverlayManager.shared.updateTranscriptionText(text)
        }
        return (statusTask, streamPreview)
    }

    func prepareOverlayForASRStop(
        shouldHideOverlayOnStop: Bool, lifecycleID: UInt64
    ) -> (didRequestHide: Bool, onFinalTranscriptionStarted: (@MainActor () -> Void)?) {
        if shouldHideOverlayOnStop {
            DebugLogger.shared.debug("Hiding dictation overlay at stop path", source: "DictationSession")
            self.hideOverlayAsync(reason: "stop_path")
            return (true, nil)
        }

        guard self.asr.isFinalTranscriptionReady else {
            DebugLogger.shared.debug("Showing transcription processing state", source: "DictationSession")
            self.appBench("processing_ui_request status=Transcribing")
            self.menuBarManager?.setProcessing(true)
            NotchOverlayManager.shared.updateTranscriptionText("Transcribing")
            self.appBench("processing_ui_requested status=Transcribing")
            return (false, nil)
        }

        // Own the overlay before isRunning changes, but publish processing UI
        // only after final ASR has entered its executor.
        self.menuBarManager?.reserveProcessingOverlay()
        self.appBench("processing_ui_reserved trigger=warm_final_asr")
        let onFinalTranscriptionStarted: @MainActor () -> Void = {
            guard self.overlayLifecycleID == lifecycleID, self.cancelledOutputLifecycleID != lifecycleID else { return }
            self.menuBarManager?.flushDeferredStoppedRecordingState()
            self.appBench("processing_ui_request status=Transcribing trigger=final_executor")
            self.menuBarManager?.setProcessing(true)
            NotchOverlayManager.shared.updateTranscriptionText("Transcribing")
            self.appBench("processing_ui_requested status=Transcribing trigger=final_executor")
        }
        return (false, onFinalTranscriptionStarted)
    }

    func holdStopUIInvalidation(whileProcessing: Bool) -> UInt64? {
        whileProcessing ? self.asr.holdStopUIInvalidationForOutputPipeline() : nil
    }

    func releaseStopUIInvalidation(_ generation: UInt64?) {
        guard let generation else { return }
        self.asr.releaseStopUIInvalidationForOutputPipeline(generation)
    }

    func hideOverlayForDispatchedPaste(shouldHide: Bool, lifecycleID: UInt64) {
        guard shouldHide, self.overlayLifecycleID == lifecycleID else { return }
        self.appBench("overlay_hide_request reason=paste_dispatched")
        NotchOverlayManager.shared.markRecordingPasted()
        self.menuBarManager?.beginProcessingCompletionAndHideOverlay()
    }

    func handleTypingDelivery(
        _ outcome: TypingService.DeliveryOutcome,
        pipelineID: String,
        pipelineStartedAt: TimeInterval,
        textReadyAt: TimeInterval,
        shouldHideOverlay: Bool,
        expectedOverlayLifecycleID: UInt64
    ) {
        self.logPipelineCompletion(
            outcome: String(describing: outcome),
            pipelineID: pipelineID,
            pipelineStartedAt: pipelineStartedAt,
            textReadyAt: textReadyAt
        )
        guard shouldHideOverlay else { return }
        guard self.overlayLifecycleID == expectedOverlayLifecycleID else {
            self.appBench(
                "overlay_hide_skipped reason=delivery_complete staleLifecycle=\(expectedOverlayLifecycleID) currentLifecycle=\(self.overlayLifecycleID)"
            )
            return
        }
        // Preserve delivery-timed dismissal for the send-suppressed status path.
        // Ordinary dictation already hid in the dispatch turn and returns above.
        self.appBench("overlay_hide_request reason=delivery_complete outcome=\(outcome)")
        if outcome.didInsert { NotchOverlayManager.shared.markRecordingPasted() }
        self.menuBarManager?.beginProcessingCompletionAndHideOverlay()
    }

    func logPipelineCompletion(
        outcome: String,
        pipelineID: String,
        pipelineStartedAt: TimeInterval,
        textReadyAt: TimeInterval
    ) {
        let finishedAt = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.info(
            "PIPELINE_SUMMARY id=\(pipelineID) t=\(finishedAt) " +
                "stopToReadyMs=\((textReadyAt - pipelineStartedAt) * 1000) readyToDeliveryMs=\((finishedAt - textReadyAt) * 1000) " +
                "totalMs=\((finishedAt - pipelineStartedAt) * 1000) outcome=\(outcome)",
            source: "AppBenchmark"
        )
    }

    func recordCompletedDictationPerformance(
        route: OutputRoute,
        pipelineStartedAt: TimeInterval,
        readyAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        transcriptionDurationMilliseconds: Int?,
        aiProcessingDurationMilliseconds: Int?,
        fluidModel: AnalyticsFluidIntelligenceModel?,
        tokensPerSecond: Double?,
        outcome: String
    ) {
        guard route == .normal else { return }
        let readyMilliseconds = Int(((readyAt - pipelineStartedAt) * 1000).rounded())
        DebugLogger.shared.info(
            DictationPerformanceLogSummary.line(
                asrMilliseconds: transcriptionDurationMilliseconds,
                aiMilliseconds: aiProcessingDurationMilliseconds,
                readyMilliseconds: readyMilliseconds,
                outcome: outcome
            ),
            source: "AppBenchmark"
        )
        // Empty and failed dictations would drag the percentiles down.
        if outcome == "success" || outcome.hasPrefix("ai_"), let latencySummary = DictationLatencyRecorder.shared.record(.init(
            readyMilliseconds: readyMilliseconds,
            aiMilliseconds: aiProcessingDurationMilliseconds,
            cleanupTimedOut: outcome == "ai_timeout"
        )) {
            DebugLogger.shared.info(latencySummary.logLine, source: "AppBenchmark")
        }
        AnalyticsService.shared.recordBetaDictationPerformance(
            fluidModel: fluidModel,
            tokensPerSecond: tokensPerSecond
        )
    }

    func recordEmptyDictationPerformance(startedAt: TimeInterval, asrMs: Int?) {
        self.recordCompletedDictationPerformance(
            route: .normal,
            pipelineStartedAt: startedAt,
            transcriptionDurationMilliseconds: asrMs,
            aiProcessingDurationMilliseconds: nil,
            fluidModel: nil,
            tokensPerSecond: nil,
            outcome: self.asr.lastStopOutcome == .failed ? "asr_failed" : "empty"
        )
    }

    func hideOverlayAfterOutput() {
        self.hideOverlayAsync(reason: "after_output")
    }

    func updateSpokenSendIndicatorForFinalParse(shouldSend: Bool) {
        if shouldSend, NotchContentState.shared.spokenSendIndicatorState == .sending {
            return
        }
        NotchContentState.shared.setSpokenSendIndicatorState(shouldSend ? .detected : .hidden)
    }

    func showTextDeliveryFailure(_ failure: TextDeliveryFailure, transcript: String) {
        let failure = failure != .emptyText && !AXIsProcessTrusted() ? TextDeliveryFailure.accessibilityNotTrusted : failure
        DebugLogger.shared.warning("Text delivery failed: \(failure.rawValue)", source: "DictationSession")
        NotchContentState.shared.recordTextDeliveryFailure(failure, transcript: transcript)
        guard failure.userFacingMessage != nil else {
            self.hideOverlayAfterOutput()
            return
        }
        self.menuBarManager?.finishProcessingKeepingOverlayVisible()
    }

    func hideOverlayAsync(reason: String) {
        let expectedOverlayLifecycleID = self.overlayLifecycleID
        self.appBench("overlay_hide_request reason=\(reason) lifecycle=\(expectedOverlayLifecycleID)")
        Task { @MainActor in
            guard self.overlayLifecycleID == expectedOverlayLifecycleID else {
                self.appBench(
                    "overlay_hide_skipped reason=\(reason) staleLifecycle=\(expectedOverlayLifecycleID) currentLifecycle=\(self.overlayLifecycleID)"
                )
                return
            }

            let overlayHideStartedAt = ProcessInfo.processInfo.systemUptime
            await self.menuBarManager?.finishProcessingAndHideOverlay()
            self.appBench(
                "overlay_hidden reason=\(reason) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - overlayHideStartedAt) * 1000).rounded()))"
            )
        }
    }

    func persistDictationAudioIfNeeded(
        _ snapshot: DictationAudioSnapshot?,
        entryID: UUID,
        timestamp: Date,
        model: String
    ) {
        guard SettingsStore.shared.saveTranscriptionHistory,
              SettingsStore.shared.saveAudioWithTranscriptionHistory,
              let snapshot = snapshot
        else {
            return
        }
        let saveGeneration = TranscriptionHistoryStore.shared.audioSaveGeneration

        Task.detached(priority: .utility) {
            let result: (metadata: DictationAudioMetadata?, error: String?) = {
                do {
                    let metadata = try DictationAudioHistoryStore.shared.save(
                        snapshot: snapshot,
                        entryID: entryID,
                        timestamp: timestamp,
                        model: model
                    )
                    return (metadata, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }()

            await MainActor.run {
                if let metadata = result.metadata {
                    TranscriptionHistoryStore.shared.attachAudio(
                        metadata,
                        to: entryID,
                        expectedSaveGeneration: saveGeneration
                    )
                } else if let error = result.error {
                    DebugLogger.shared.error("Failed to save dictation audio: \(error)", source: "DictationSession")
                }
            }
            if let metadata = result.metadata {
                DictationAudioHistoryStore.shared.completePendingSave(fileName: metadata.fileName)
            }
        }
    }
}
