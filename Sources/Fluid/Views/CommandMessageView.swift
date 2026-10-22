import Foundation
import SwiftUI

/// One ruled row of the Command Mode sheet. A step row also carries the message that
/// followed it: the terminal result, or the cancellation that stopped it running.
struct CommandMessageView: View {
    let message: CommandModeService.Message
    var result: CommandModeService.Message?
    var isRunning = false
    var onExpand: () -> Void = {}
    @ObservedObject private var settings = SettingsStore.shared
    @State private var thinkingExpanded = false
    @State private var outputExpanded = false
    @State private var toolOutput: CommandToolOutput?

    private var outputMessage: CommandModeService.Message? {
        if self.message.role == .tool { return self.message }
        return self.result?.role == .tool ? self.result : nil
    }

    private var isCancelled: Bool {
        self.message.stepType == .cancelled || self.result?.stepType == .cancelled
    }

    var body: some View {
        RecordLine {
            self.margin
        } content: {
            self.content
        }
        .task(id: self.outputMessage?.content) {
            guard let content = self.outputMessage?.content else { return }
            let parsed = await Task.detached(priority: .userInitiated) { CommandToolOutput.parse(content) }.value
            guard !Task.isCancelled else { return }
            self.toolOutput = parsed
        }
    }

    // MARK: - Margin

    private var margin: some View {
        Group {
            HStack(spacing: FWMetric.space2) {
                Text(self.message.timestamp.formatted(date: .omitted, time: .shortened))
                    .recordText(FWType.detailStrong)
                    .foregroundStyle(FWColor.textSecondary)
                if let mark = self.mark { RecordMark(state: mark) }
            }
            Text(self.role)
                .recordText(FWType.detail)
                .foregroundStyle(self.roleIsAttention ? FWColor.stateAttention : FWColor.textSecondary)
            if let duration = self.duration {
                Text(duration)
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textTertiary)
            }
        }
    }

    private var isStep: Bool { self.message.toolCall != nil || self.message.role == .tool }
    private var stepFailed: Bool { self.toolOutput?.success == false || self.outputMessage?.stepType == .failure }

    private var role: String {
        if self.message.role == .user { return "You" }
        if self.isCancelled { return "Cancelled" }
        if self.isStep {
            if self.isRunning { return "Running" }
            return self.stepFailed ? "Failed" : "Ran"
        }
        return self.message.stepType == .failure ? "Stopped" : "Answer"
    }

    private var roleIsAttention: Bool {
        !self.isCancelled && self.message.role != .user && (self.isStep ? self.stepFailed : self.message.stepType == .failure)
    }

    private var mark: RecordMark.State? {
        if self.message.role == .user { return nil }
        if self.isCancelled { return .waiting }
        if self.isStep {
            if self.isRunning { return .working }
            if self.stepFailed { return .needsYou }
            return self.outputMessage == nil ? nil : .done
        }
        switch self.message.stepType {
        case .failure: return .needsYou
        case .success: return .done
        default: return nil
        }
    }

    private var duration: String? {
        guard let ms = self.toolOutput?.executionTime, ms > 0, !self.isRunning else { return nil }
        return String(format: "%.1f s", Double(ms) / 1000)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if self.message.role == .user {
            Text(verbatim: self.message.content)
                .recordText(FWType.transcript)
                .foregroundStyle(FWColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if self.isStep {
            self.step
        } else if self.message.stepType == .cancelled {
            self.cancelledNote
        } else {
            self.answer
        }
        if self.settings.showThinkingTokens, let thinking = self.message.thinking, !thinking.isEmpty {
            self.thinking(thinking)
        }
    }

    @ViewBuilder
    private var step: some View {
        let tool = self.message.toolCall
        if let purpose = tool?.purpose ?? self.toolOutput?.title, !purpose.isEmpty {
            Text(purpose)
                .recordText(FWType.body)
                .foregroundStyle(self.isCancelled ? FWColor.textSecondary : FWColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let tool {
            RecordCodeWell(code: tool.command)
                .textSelection(.enabled)
        }
        if self.isCancelled {
            self.cancelledNote
        } else if self.stepFailed, let error = self.toolOutput?.error, !error.isEmpty {
            Text(verbatim: error)
                .recordText(FWType.body)
                .foregroundStyle(FWColor.stateAttention)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let parsed = self.toolOutput, !self.isCancelled {
            Button(self.outputExpanded ? "Hide output" : "Show output") {
                if !self.outputExpanded { self.onExpand() }
                self.outputExpanded.toggle()
            }
            .buttonStyle(RecordButtonStyle(kind: .quiet, size: FWMetric.sizeControlS))
            .accessibilityValue(self.outputExpanded ? "Expanded" : "Collapsed")
            if self.outputExpanded {
                if parsed.output.isEmpty {
                    Text("No output")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                } else {
                    CommandCodeBlock(code: parsed.output)
                }
            }
        }
    }

    private var cancelledNote: some View {
        Text("Cancelled. Nothing ran.")
            .recordText(FWType.detail)
            .foregroundStyle(FWColor.textSecondary)
    }

    @ViewBuilder
    private var answer: some View {
        if self.message.stepType == .failure {
            Text("Couldn’t complete this step")
                .recordText(FWType.detailStrong)
                .foregroundStyle(FWColor.stateAttention)
        }
        if !self.message.content.isEmpty {
            CommandMarkdownContent(text: self.message.content)
            CommandCopyButton(text: self.message.content, label: "Copy answer")
        }
    }

    private func thinking(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: FWMetric.space2) {
            Button(self.thinkingExpanded ? "Hide thinking" : "Thinking") {
                self.thinkingExpanded.toggle()
            }
            .buttonStyle(RecordButtonStyle(kind: .quiet, size: FWMetric.sizeControlS))
            .accessibilityValue(self.thinkingExpanded ? "Expanded" : "Collapsed")
            if self.thinkingExpanded {
                ScrollView {
                    Text(verbatim: text)
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
    }
}

/// Accept both the saved terminal result schema and unfamiliar results without losing their text.
struct CommandToolOutput: Sendable, Equatable {
    let success: Bool?
    let title: String
    let output: String
    let error: String?
    let executionTime: Int
    let language: String

    static func parse(_ text: String) -> CommandToolOutput {
        guard let data = text.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CommandToolOutput(success: nil, title: "Command output", output: text, error: nil, executionTime: 0, language: "Output")
        }
        let success = result["success"] as? Bool
        let error = result["error"] as? String
        let purpose = result["purpose"] as? String
        let output = result["output"] as? String
        // Unknown structured formats stay inspectable instead of disappearing as empty output.
        let display = output ?? (result["content"] as? String) ?? text
        return CommandToolOutput(
            success: success,
            title: purpose?.isEmpty == false ? purpose ?? "Command result" : (success == false ? "Command failed" : "Command result"),
            output: display,
            error: error,
            executionTime: result["executionTimeMs"] as? Int ?? 0,
            language: "Output"
        )
    }
}
