import AppKit
import Combine
import Foundation

/// The overlay lifecycle, the Spoken Send voice check, and putting focus back in the
/// field the text goes to.
extension DictationSession {
    func advanceOverlayLifecycle() {
        self.spokenSendAutoStopTask?.cancel()
        self.spokenSendAutoStopTask = nil
        self.stopSpokenSendVoiceActivityMonitoring()
        self.spokenSendAutoStopTriggered = false
        self.spokenSendArming.reset()
        self.spokenSendCountdownStartedAt = nil
        self.spokenSendLastVoiceActivityAt = ProcessInfo.processInfo.systemUptime
        self.overlayLifecycleID &+= 1
        NotchContentState.shared.clearAIProcessingFailure()
        NotchContentState.shared.clearTextDeliveryFailure()
    }

    func handleSpokenSendAudioLevel(_ level: CGFloat) {
        guard SpokenSendParser.isMeaningfulVoiceActivity(level) else { return }

        let activityAt = ProcessInfo.processInfo.systemUptime
        self.spokenSendLastVoiceActivityAt = activityAt
        guard let countdownStartedAt = self.spokenSendCountdownStartedAt,
              SpokenSendParser.shouldCancelCountdownForVoiceActivity(
                  countdownStartedAt: countdownStartedAt,
                  voiceActivityAt: activityAt
              ),
              self.spokenSendAutoStopTask != nil
        else {
            return
        }

        self.spokenSendAutoStopTask?.cancel()
        self.spokenSendAutoStopTask = nil
        self.stopSpokenSendVoiceActivityMonitoring()
        self.spokenSendCountdownStartedAt = nil
        if NotchContentState.shared.spokenSendIndicatorState == .countingDown {
            NotchContentState.shared.setSpokenSendIndicatorState(.hidden)
        }
    }

    func startSpokenSendVoiceActivityMonitoring() {
        guard self.spokenSendVoiceActivityCancellable == nil else { return }
        self.spokenSendVoiceActivityCancellable = self.asr.audioLevelPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.handleSpokenSendAudioLevel(level)
            }
    }

    func stopSpokenSendVoiceActivityMonitoring() {
        self.spokenSendVoiceActivityCancellable?.cancel()
        self.spokenSendVoiceActivityCancellable = nil
    }

    func prepareStoppedDictationDelivery(_ text: String, keepBackup: Bool, snapshot: DictationStopSnapshot?, needsRestoration: Bool, isOutputValid: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        if let snapshot { return await snapshot.prepareDelivery(text, keepBackup: keepBackup, isOutputValid: isOutputValid) }
        return await self.prepareRecordingTargetForDelivery(text, keepBackup: keepBackup, needsRestoration: needsRestoration, isOutputValid: isOutputValid)
    }

    /// Restores only the window and element captured when recording started.
    func prepareRecordingTargetForDelivery(_ transcript: String, keepBackup: Bool, needsRestoration: Bool = true, isOutputValid: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        guard isOutputValid() else { return false }
        guard needsRestoration else { return true }
        return await PasteDeliveryCoordinator.shared.prepareForDelivery(transcript, preserveTranscriptOnClipboard: keepBackup, isOutputValid: isOutputValid) {
            await self.restoreFocusToRecordingTarget(isOutputValid: isOutputValid)
        }
    }

    func restoreFocusToRecordingTarget(isOutputValid: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        guard let context = NotchContentState.shared.recordingTargetContext else { return false }
        let pid = context.pid
        let startedAt = ProcessInfo.processInfo.systemUptime
        self.appBench("focus_restore_start targetPID=\(pid)")
        let result = await TypingService.prepareTargetForDelivery(context, isOutputValid: isOutputValid)
        self.appBench(
            "focus_restore_result result=\(result.rawValue) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))"
        )
        DebugLogger.shared.debug(
            "Restore focus result: \(result.rawValue), targetPID: \(pid)",
            source: "DictationSession"
        )
        self.appBench("focus_restore_settle_done delayMs=0")
        return result.isReady
    }

    func appBench(_ message: @autoclosure () -> String) {
        DebugLogger.shared.benchmark("APP_BENCH", message: message(), source: "AppBenchmark")
    }
}
