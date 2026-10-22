import AppKit
import SwiftUI

struct RewriteModeView: View {
    @ObservedObject var service: RewriteModeService
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService {
        self.appServices.asr
    }

    @ObservedObject var settings = SettingsStore.shared
    @EnvironmentObject var menuBarManager: MenuBarManager
    var onClose: (() -> Void)?

    @State private var inputText: String = ""
    @State private var showOriginal: Bool = true
    @State private var isThinkingExpanded: Bool = false
    /// The words in the field arrived from the microphone.
    @State private var inputIsSpoken = false
    /// The last instruction sent, as the user gave it, with when and how.
    @State private var asked: (text: String, at: Date, spoken: Bool)?
    @State private var selectionTime = Date()
    /// The rewrite that was put back into the app, shown until the next instruction.
    @State private var replacedText: String?

    private static let writeExamples = [
        "Write a short thank-you to Priya for the review",
        "Reply to Sam that Friday at 10 works",
    ]
    private static let editExamples = [
        "Make this more formal",
        "Fix the grammar and spelling",
        "Summarise this in two lines",
    ]

    var body: some View {
        VStack(spacing: 0) {
            RecordHeader("Edit Mode", subtitle: "Select text in any app, then say how to change it.") {
                self.modelPopUp
            }
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 0) {
                        self.rows
                        self.fillerRow
                    }
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
            }
            self.composer
        }
        .padding(.top, FWMetric.space8)
        .background(FWColor.surfaceWindow)
        .onChange(of: self.asr.finalText) { _, newText in
            if !newText.isEmpty {
                self.inputText = newText
                self.inputIsSpoken = true
            }
        }
        .onChange(of: self.service.originalText) { _, _ in self.selectionTime = Date() }
        .onExitCommand {
            self.onClose?()
        }
    }

    // MARK: - State

    private var appName: String? {
        guard let bundleID = self.service.promptAppBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Text the user selected in another app; in write mode the service keeps the prompt there instead.
    private var selectedText: String? {
        let text = self.service.originalText
        return text.isEmpty || self.service.isWriteMode ? nil : text
    }

    /// The real error from the last answer, when the last request failed.
    private var failure: String? {
        guard !self.service.isProcessing, self.service.rewrittenText.isEmpty,
              let last = self.service.conversationHistory.last, last.role == .assistant else { return nil }
        let prefix = "Error: "
        return last.content.hasPrefix(prefix) ? String(last.content.dropFirst(prefix.count)) : last.content
    }

    private var isListening: Bool { self.asr.isRunning }
    private var hasResult: Bool { !self.service.rewrittenText.isEmpty && self.replacedText == nil }

    private var modelLabel: String {
        let providerID = self.settings.rewriteModeSelectedProviderID
        let model = self.settings.rewriteModeSelectedModel ?? ""
        guard let provider = self.providers.first(where: { $0.id == providerID }) else { return "Choose model" }
        return model.isEmpty ? provider.name : "\(provider.name)  ·  \(model)"
    }

    private static func wordCount(_ text: String) -> String {
        let count = text.split(whereSeparator: \.isWhitespace).count
        return count == 1 ? "1 word" : "\(count) words"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Header

    private var providers: [(id: String, name: String)] {
        ModelRepository.shared.builtInProvidersList() + self.settings.savedProviders.map { (id: $0.id, name: $0.name) }
    }

    private var modelPopUp: some View {
        RecordPopUp(self.modelLabel) {
            ForEach(self.providers, id: \.id) { provider in
                let models = self.settings.availableModels(for: provider.id, task: .edit)
                if !models.isEmpty {
                    Section(provider.name) {
                        ForEach(models, id: \.self) { model in
                            Button {
                                self.settings.rewriteModeSelectedProviderID = provider.id
                                self.settings.rewriteModeSelectedModel = model
                            } label: {
                                if provider.id == self.settings.rewriteModeSelectedProviderID, model == self.settings.rewriteModeSelectedModel {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Provider and model")
        .disabled(self.service.isProcessing)
    }

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        let nothingSelected = self.service.originalText.isEmpty && self.service.conversationHistory.isEmpty && !self.service.isProcessing
        if nothingSelected {
            self.nothingSelectedRows
        } else {
            if let selected = self.selectedText {
                if self.hasResult || self.replacedText != nil {
                    self.originalRow(selected)
                } else {
                    self.selectedRow(selected)
                }
            }
            if let asked = self.asked {
                self.askedRow(asked)
            }
            if self.service.isProcessing {
                self.rewritingRow
            } else if let replaced = self.replacedText {
                self.replacedRow(replaced)
            } else if self.hasResult {
                self.resultRow
            } else if let failure = self.failure {
                self.failureRow(failure)
            }
        }
    }

    private func marginTime(_ date: Date, mark: RecordMark.State? = nil) -> some View {
        HStack(spacing: FWMetric.space2) {
            Text(Self.time(date))
                .recordText(FWType.detailStrong)
                .foregroundStyle(FWColor.textSecondary)
            if let mark { RecordMark(state: mark) }
        }
    }

    private func marginLine(_ text: String, color: Color = FWColor.textSecondary) -> some View {
        Text(text)
            .recordText(FWType.detail)
            .foregroundStyle(color)
    }

    private func marginFact(_ text: String) -> some View {
        Text(text)
            .recordText(FWType.small)
            .foregroundStyle(FWColor.textTertiary)
    }

    @ViewBuilder
    private var nothingSelectedRows: some View {
        RecordLine {
            HStack(spacing: FWMetric.space2) {
                RecordMark(state: .waiting)
                self.marginLine("Nothing selected")
            }
        } content: {
            Text("Say what to write and it goes where your cursor is. To change existing text, select it first.")
                .recordText(FWType.body)
                .foregroundStyle(FWColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        self.exampleRows(Self.writeExamples, label: "To write")
        self.exampleRows(Self.editExamples, label: "With text selected")
    }

    private func exampleRows(_ examples: [String], label: String) -> some View {
        ForEach(examples, id: \.self) { example in
            RecordLine {
                if example == examples.first {
                    self.marginFact(label)
                }
            } content: {
                Button {
                    self.inputText = example
                    self.inputIsSpoken = false
                } label: {
                    Text(example)
                        .recordText(FWType.body)
                        .foregroundStyle(FWColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add this example to your message")
            }
        }
    }

    private func selectedRow(_ text: String) -> some View {
        RecordLine {
            self.marginTime(self.selectionTime)
            self.marginLine(self.appName.map { "Selected in \($0)" } ?? "Selected text")
            self.marginFact(Self.wordCount(text))
        } content: {
            Text(text)
                .recordText(FWType.transcript)
                .foregroundStyle(FWColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func originalRow(_ text: String) -> some View {
        RecordLine {
            self.marginLine("Original")
            self.marginFact(Self.wordCount(text))
        } content: {
            if self.showOriginal {
                Text(text)
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(self.showOriginal ? "Hide original" : "Show original") {
                self.showOriginal.toggle()
            }
            .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
        }
    }

    private func askedRow(_ asked: (text: String, at: Date, spoken: Bool)) -> some View {
        RecordLine {
            self.marginTime(asked.at)
            self.marginLine("You asked")
            if asked.spoken { self.marginFact("Spoken") }
        } content: {
            Text(asked.text)
                .recordText(FWType.transcript)
                .foregroundStyle(FWColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rewritingRow: some View {
        RecordLine {
            HStack(spacing: FWMetric.space2) {
                RecordMark(state: .working)
                self.marginLine("Rewriting")
            }
        } content: {
            Text("Rewriting with \(self.settings.rewriteModeSelectedModel ?? "the selected model")")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
            if self.settings.showThinkingTokens, !self.service.streamingThinkingText.isEmpty {
                Button(self.isThinkingExpanded ? "Hide thinking" : "Thinking") {
                    self.isThinkingExpanded.toggle()
                }
                .buttonStyle(RecordButtonStyle(kind: .quiet, size: FWMetric.sizeControlS))
                .accessibilityValue(self.isThinkingExpanded ? "Expanded" : "Collapsed")
                if self.isThinkingExpanded {
                    ScrollView {
                        Text(self.service.streamingThinkingText)
                            .recordText(FWType.detail)
                            .foregroundStyle(FWColor.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
    }

    private var resultRow: some View {
        let text = self.service.rewrittenText
        return RecordLine(fill: .hover) {
            self.marginLine("Rewrite")
            self.marginFact(Self.wordCount(text))
        } content: {
            Text(text)
                .recordText(FWType.transcript)
                .foregroundStyle(FWColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: FWMetric.space3) {
                Button(self.appName.map { "Replace in \($0)" } ?? "Replace original") {
                    Task { @MainActor in
                        await self.service.acceptRewrite(text)
                        self.replacedText = text
                    }
                }
                .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                Button("Try again", action: self.retryLastInstruction)
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                Button("Copy") { _ = ClipboardService.copyToClipboard(text) }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
            }
        }
    }

    private func replacedRow(_ text: String) -> some View {
        RecordLine(fill: .hover) {
            HStack(spacing: FWMetric.space2) {
                RecordMark(state: .done)
                self.marginLine(self.appName.map { "Replaced in \($0)" } ?? "Replaced")
            }
            self.marginFact(Self.wordCount(text))
        } content: {
            Text(text)
                .recordText(FWType.transcript)
                .foregroundStyle(FWColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(self.appName.map { "To undo, press ⌘Z in \($0)." } ?? "To undo, press ⌘Z.")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
        }
    }

    private func failureRow(_ error: String) -> some View {
        RecordLine(fill: .hover) {
            HStack(spacing: FWMetric.space2) {
                RecordMark(state: .needsYou)
                self.marginLine("Failed", color: FWColor.stateAttention)
            }
        } content: {
            Text("Couldn’t rewrite this")
                .recordText(FWType.detailStrong)
                .foregroundStyle(FWColor.stateAttention)
            Text(self.failureMessage(error))
                .recordText(FWType.body)
                .foregroundStyle(FWColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: self.retryLastInstruction)
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                .disabled(self.asked == nil)
        }
    }

    private func failureMessage(_ error: String) -> String {
        let sentence = error.hasSuffix(".") ? error : error + "."
        guard self.selectedText != nil else { return sentence }
        return sentence + (self.appName.map { " Your text in \($0) is unchanged." } ?? " Your text is unchanged.")
    }

    /// The rest of the sheet: the margin rule carries on and the hairline closes it above the composer.
    private var fillerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: FWMetric.sizeMargin)
            RecordMarginRule()
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
                }
        }
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    // MARK: - Composer

    private var composerMarginNote: String {
        if self.isListening { return "Listening" }
        if self.service.isProcessing { return "You can edit again when this finishes." }
        return "Return to send"
    }

    private var placeholder: String {
        if self.hasResult { return "Or say another change" }
        return self.selectedText == nil ? "Ask me to write something" : "How should I edit this?"
    }

    private var canSend: Bool {
        !self.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.service.isProcessing && !self.isListening
    }

    private var composer: some View {
        RecordLine(showsRule: false) {
            Text(self.composerMarginNote)
                .recordText(FWType.small)
                .foregroundStyle(FWColor.textTertiary)
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space4) {
                if self.isListening {
                    HStack(spacing: FWMetric.space4) {
                        RecordingPillPreview(state: .listen, size: .medium)
                        Text("Say how to change it.")
                            .recordText(FWType.detail)
                            .foregroundStyle(FWColor.textSecondary)
                    }
                }
                RecordField(placeholder: self.placeholder, text: self.$inputText, size: .multi)
                    .frame(height: self.fieldHeight)
                    .onKeyPress(.return, phases: .down) { press in
                        // Option-Return falls through to the editor as a new line.
                        guard !press.modifiers.contains(.option) else { return .ignored }
                        self.submitRequest()
                        return .handled
                    }
                    .accessibilityLabel(self.placeholder)
                HStack(spacing: FWMetric.space3) {
                    Spacer(minLength: 0)
                    if self.isListening {
                        Button("Stop", action: self.toggleRecording)
                            .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                    } else {
                        Button("Speak", action: self.toggleRecording)
                            .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                            .disabled(self.service.isProcessing)
                        Button("Send", action: self.submitRequest)
                            // One primary per view: the rewrite's Replace takes it.
                            .buttonStyle(RecordButtonStyle(kind: self.hasResult ? .secondary : .primary, size: FWMetric.sizeControlM))
                            .disabled(!self.canSend)
                    }
                }
                .frame(minHeight: FWMetric.sizeControlM)
            }
        }
    }

    /// 56 pt for one or two lines, growing with typed lines up to eight (Transcript is 24 pt a line).
    private var fieldHeight: CGFloat {
        let lines = self.inputText.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return max(56, CGFloat(min(lines, 8)) * 24 + 16)
    }

    // MARK: - Actions

    private func toggleRecording() {
        if self.asr.isRunning {
            Task {
                _ = await self.asr.stop()
                _ = self.asr.consumeLastCompletedAudioSnapshot()
            }
        } else {
            Task { await self.asr.start() }
        }
    }

    private func submitRequest() {
        guard self.canSend else { return }
        let prompt = self.inputText
        self.asked = (text: prompt, at: Date(), spoken: self.inputIsSpoken)
        self.inputText = ""
        self.inputIsSpoken = false
        self.replacedText = nil
        Task {
            await self.service.processRewriteRequest(prompt)
        }
    }

    /// Sends the last instruction again as if for the first time.
    private func retryLastInstruction() {
        guard let asked = self.asked, !self.service.isProcessing else { return }
        self.service.dropLastExchange()
        self.asked = (text: asked.text, at: Date(), spoken: asked.spoken)
        Task {
            await self.service.processRewriteRequest(asked.text)
        }
    }
}
