import AppKit
import Foundation

/// Where the dictation is going: the app, window and field the user started in, and the
/// field that gets the text when the recording stops.
extension DictationSession {
    func getCurrentAppInfo() -> (name: String, bundleId: String, windowTitle: String) {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let name = frontmostApp.localizedName ?? "Unknown"
            let bundleId = frontmostApp.bundleIdentifier ?? "unknown"
            let title = self.getFrontmostWindowTitle(ownerPid: frontmostApp.processIdentifier) ?? ""
            return (name: name, bundleId: bundleId, windowTitle: title)
        }
        return (name: "Unknown", bundleId: "unknown", windowTitle: "")
    }

    func isSpokenSendBlockedApp(
        _ appInfo: (name: String, bundleId: String, windowTitle: String)
    ) -> Bool {
        let identity = "\(appInfo.name) \(appInfo.bundleId)".lowercased()
        return identity.contains("terminal")
            || identity.contains("iterm")
            || identity.contains("warp")
            || identity.contains("ghostty")
            || identity.contains("kitty")
            || identity.contains("alacritty")
    }

    /// Best-effort frontmost window title lookup for the current app
    func getFrontmostWindowTitle(ownerPid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownerPid else { continue }
            if let name = info[kCGWindowName as String] as? String, name.isEmpty == false {
                return name
            }
        }
        return nil
    }

    func captureRecordingTargetContext() {
        // Capture the focused target PID BEFORE any overlay/UI changes.
        // Used to restore focus when the user interacts with overlay dropdowns.
        let targetContext = TypingService.captureRecordingTargetContext()
        if let targetContext, let element = targetContext.element {
            self.recordingFocusTarget = TypingService.CapturedFocusTarget(
                pid: targetContext.pid,
                window: targetContext.window,
                element: element
            )
        } else {
            self.recordingFocusTarget = TypingService.captureSystemFocusTarget()
        }
        NotchContentState.shared.recordingTargetContext = targetContext
        NotchContentState.shared.recordingTargetPID = targetContext?.pid
            ?? self.recordingFocusTarget?.pid
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier

        let info = self.getCurrentAppInfo()
        self.recordingAppInfo = info
        self.rewriteMode.setPromptAppBundleID(info.bundleId)
        DebugLogger.shared.debug(
            "Captured recording app context: app=\(info.name), bundleId=\(info.bundleId), title=\(info.windowTitle)",
            source: "DictationSession"
        )
    }

    func captureRecordingFormattingContextIfNeeded() {
        // Capture text before the caret only when formatting or cleanup context needs it.
        if self.needsDictationFocusedFieldContext() {
            self.recordingPrecedingText = TypingService.textBeforeCursorInFocusedField()
            DebugLogger.shared.debug(
                "Captured preceding text for continuous dictation (chars=\(self.recordingPrecedingText.count))",
                source: "DictationSession"
            )
        } else {
            self.recordingPrecedingText = ""
        }
    }

    /// Text before the cursor costs an Accessibility read, so read it only for
    /// formatting or for an AI cleanup that will actually run.
    func needsDictationFocusedFieldContext() -> Bool {
        if SettingsStore.shared.needsDictationFormattingContext { return true }
        guard SettingsStore.shared.dictationCleanupContextEnabled else { return false }
        return DictationAIPostProcessingGate.isConfigured(
            for: self.activeDictationShortcutSlot ?? .primary,
            appBundleID: self.recordingAppInfo?.bundleId
        )
    }

    func captureRecordingContext() {
        self.captureRecordingTargetContext()
        self.captureRecordingFormattingContextIfNeeded()
    }

    func captureDictationStopSnapshot(slot: SettingsStore.DictationShortcutSlot) -> DictationStopSnapshot {
        let current = TypingService.captureRecordingTargetContext()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let isOverlay = current?.pid == ownPID && (NSApp.keyWindow == nil || NSApp.keyWindow is NSPanel)
        let useOriginal = SettingsStore.shared.returnDictationToStartingField || isOverlay
        let target = DictationStopSnapshot.selectTarget(
            current: current,
            original: NotchContentState.shared.recordingTargetContext,
            returnToStartingField: SettingsStore.shared.returnDictationToStartingField,
            ownOverlayFocused: isOverlay
        )
        let app = target.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        // Window title and preceding text need WindowServer and Accessibility
        // round-trips; completeDictationStopSnapshot fills them after the
        // microphone has stopped.
        let info = (
            name: app?.localizedName ?? "Unknown",
            bundleId: target?.bundleIdentifier ?? "unknown",
            windowTitle: ""
        )
        if !useOriginal { DictationAppSession.shared.activate(target?.bundleIdentifier) }
        let label = SettingsStore.shared.dictationOverlayLabel(for: slot, appBundleID: info.bundleId)
        if NotchContentState.shared.stopSnapshotLabel != label {
            NotchContentState.shared.stopSnapshotLabel = label
        }
        return .capture(
            target: target,
            appInfo: info,
            slot: slot,
            precedingText: useOriginal ? self.recordingPrecedingText : "",
            readsContextFromFocusedField: !useOriginal
        )
    }

    func completeDictationStopSnapshot(_ stopSnapshot: inout DictationStopSnapshot?) {
        guard var snapshot = stopSnapshot else { return }
        let windowTitle = snapshot.target.flatMap { self.getFrontmostWindowTitle(ownerPid: $0.pid) }
        var precedingText: String?
        if snapshot.readsContextFromFocusedField,
           SettingsStore.shared.needsDictationFormattingContext || (SettingsStore.shared.dictationCleanupContextEnabled && snapshot.usesAI),
           let target = snapshot.target,
           TypingService.currentFocusedPID() == target.pid
        {
            precedingText = TypingService.textBeforeCursorInFocusedField()
        }
        snapshot.completeContext(windowTitle: windowTitle, precedingText: precedingText)
        stopSnapshot = snapshot
    }

    func resolveTypingTargetPID(returnToStartingField: Bool = true) -> (pid: pid_t?, shouldRestoreOriginalFocus: Bool) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let context = NotchContentState.shared.recordingTargetContext
        let focusedPID = TypingService.currentFocusedPID()
        let pidFinishedAt = ProcessInfo.processInfo.systemUptime
        let checksElement = returnToStartingField && context?.pid == focusedPID && context?.element != nil
        let elementIsFocused = !checksElement || context.map { TypingService.isCapturedFocusStillActive($0) } == true
        let target = DictationTargetPolicy.resolve(
            returnToStartingField: returnToStartingField,
            focusedPID: focusedPID,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            originalPID: context?.pid ?? NotchContentState.shared.recordingTargetPID,
            originalFieldIsFocused: context != nil && context?.pid == focusedPID && elementIsFocused
        )
        let finishedAt = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.benchmark(
            "APP_BENCH",
            message: "focus_target_check totalMs=\((finishedAt - startedAt) * 1000) pidMs=\((pidFinishedAt - startedAt) * 1000) " +
                "elementMs=\((finishedAt - pidFinishedAt) * 1000) elementChecked=\(checksElement) returnToStartingField=\(returnToStartingField)",
            source: "AppBenchmark"
        )
        return target
    }
}
