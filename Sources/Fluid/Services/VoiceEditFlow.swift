import Foundation

/// Runs one spoken Edit Mode instruction: asks the rewrite service for new text, then puts it
/// where the user was working. Each step checks `isOutputValid`, so Escape or a newer
/// recording stops the run without restoring focus, pasting, or showing a failure.
@MainActor
struct VoiceEditFlow {
    var setPromptAppBundleID: @MainActor (String) -> Void
    var originalText: @MainActor () -> String
    var requestRewrite: @MainActor (String) async -> Void
    var rewrittenText: @MainActor () -> String
    var clearRewrite: @MainActor () -> Void
    var setProcessing: @MainActor (Bool) -> Void
    var finishWithoutResult: @MainActor () async -> Void
    var typingTarget: @MainActor () -> (pid: pid_t?, shouldRestoreOriginalFocus: Bool)
    /// Returns focus to the field the recording started in. False when that failed.
    var restoreTarget: @MainActor (_ text: String, _ isOutputValid: @escaping @MainActor () -> Bool) async -> Bool
    var deliver: @MainActor (_ text: String, _ pid: pid_t?, _ isOutputValid: @escaping @MainActor () -> Bool) async -> TextDeliveryResult
    var showDeliveryFailure: @MainActor (TextDeliveryFailure, _ text: String) -> Void
    var hideOverlay: @MainActor () -> Void

    func run(_ instruction: String, appBundleID: String, isOutputValid: @escaping @MainActor () -> Bool) async {
        guard isOutputValid() else { return }
        defer {
            if !isOutputValid() { self.clearRewrite() }
        }
        self.setPromptAppBundleID(appBundleID)
        let originalText = self.originalText()
        DebugLogger.shared.info(
            "Processing \(originalText.isEmpty ? "write/improve" : "rewrite") - instruction length: \(instruction.count), originalText length: \(originalText.count)",
            source: "ContentView"
        )

        self.setProcessing(true)

        // With original text the service rewrites it; without, it improves the spoken text.
        await self.requestRewrite(instruction)
        guard isOutputValid() else { return }

        let rewritten = self.rewrittenText()
        guard !rewritten.isEmpty else {
            await self.finishWithoutResult()
            DebugLogger.shared.error("Rewrite failed - no result", source: "ContentView")
            return
        }
        DebugLogger.shared.info("Rewrite successful, typing result (chars: \(rewritten.count))", source: "ContentView")

        let target = self.typingTarget()
        if target.shouldRestoreOriginalFocus {
            guard await self.restoreTarget(rewritten, isOutputValid) else {
                guard isOutputValid() else { return }
                self.showDeliveryFailure(.targetRestoreFailed, rewritten)
                return
            }
        }
        let result = await self.deliver(rewritten, target.pid, isOutputValid)
        guard isOutputValid() else { return }
        if case let .recoverableFailure(failure) = result {
            self.showDeliveryFailure(failure, rewritten)
            return
        }

        self.clearRewrite()
        self.hideOverlay()
    }
}
