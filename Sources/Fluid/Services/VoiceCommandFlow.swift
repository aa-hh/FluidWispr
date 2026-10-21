import Foundation

/// Runs one spoken Command Mode request. If Escape or a newer recording cancels the output
/// while the agent works, a confirmation it left waiting is dropped and the processing
/// indicator is left to the cancel path.
@MainActor
struct VoiceCommandFlow {
    var setProcessing: @MainActor (Bool) -> Void
    var process: @MainActor (_ command: String, _ isOutputValid: @escaping @MainActor () -> Bool) async -> Void
    var cancelInvalidPendingCommand: @MainActor () -> Void
    var hasPendingCommand: @MainActor () -> Bool
    /// Records which recording owns the confirmation the agent is waiting on, or nil when none is.
    var setPendingConfirmationOwner: @MainActor (UInt64?) -> Void

    func run(_ command: String, lifecycleID: UInt64, isOutputValid: @escaping @MainActor () -> Bool) async {
        guard isOutputValid() else { return }
        DebugLogger.shared.info("Processing voice command (\(command.count) chars)", source: "ContentView")

        self.setProcessing(true)

        // CommandModeService stores the conversation and runs any terminal commands.
        await self.process(command, isOutputValid)
        guard isOutputValid() else {
            self.cancelInvalidPendingCommand()
            return
        }
        self.setPendingConfirmationOwner(self.hasPendingCommand() ? lifecycleID : nil)

        self.setProcessing(false)

        DebugLogger.shared.info("Command processed, conversation stored in Command Mode", source: "ContentView")
    }
}

/// The notch's follow-up field. The draft clears only when the command was accepted and
/// the user has not started typing a new draft while it was being sent.
@MainActor
enum FollowUpDraft {
    static func submit(
        _ text: String,
        send: (String) async -> Bool,
        currentText: () -> String,
        clear: () -> Void
    ) async {
        if await send(text), currentText() == text {
            clear()
        }
    }
}
