import Combine
import SwiftUI

enum CommandModeRecordingOwnershipPolicy {
    static func ownsRecording(after outcome: AudioCaptureStartOutcome, isRunning: Bool) -> Bool {
        outcome == .started && isRunning
    }

    static func shouldStopOnDeactivate(ownsRecording: Bool, isRunning: Bool) -> Bool {
        ownsRecording && isRunning
    }

    static func shouldStopAfterStart(ownsRecording: Bool, isPresentationActive: Bool) -> Bool {
        ownsRecording && !isPresentationActive
    }
}

struct CommandModeView: View {
    @ObservedObject var service: CommandModeService
    let isActive: Bool
    @EnvironmentObject var appServices: AppServices
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var chatStore = ChatHistoryStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onClose: (() -> Void)?

    @AppStorage("CommandHistoryInspectorVisible") private var prefersHistoryVisible = true
    @State private var compactHistoryPresented = false
    @State private var drafts = CommandSessionDrafts()
    @State private var showingArchiveLimit = false
    @State private var showModelPicker = false
    @State private var modelOptions: [CommandModelOption] = []
    @State private var selectedModelProviderID = ""
    @State private var selectedModelID = ""
    @State private var ownsASRRecording = false
    @State private var isASRStartPending = false
    @State private var isASRStopPending = false
    @State private var recordingSessionID: String?
    @State private var isSubmissionPending = false
    @State private var isPresentationActive = false
    @State private var followsLatestMessage = true
    @State private var isUserScrolling = false
    @State private var isThinkingExpanded = false

    private var asr: ASRService { self.appServices.asr }
    private var inputText: Binding<String> {
        Binding(
            get: { self.drafts.text(for: self.service.currentChatID) },
            set: { self.drafts.set($0, for: self.service.currentChatID) }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width >= CommandWorkspaceLayout.dockedHistoryMinimumWidth
            let dockedHistory = CommandWorkspaceLayout.showsDockedHistory(width: geometry.size.width, preferred: self.prefersHistoryVisible)
            let overlayHistory = !isWide && self.compactHistoryPresented
            ZStack(alignment: .trailing) {
                self.sheet(historyVisible: dockedHistory || overlayHistory, isWide: isWide)
                    .padding(.trailing, dockedHistory ? CommandWorkspaceLayout.sidebarWidth : 0)
                    .allowsHitTesting(!overlayHistory)
                    .disabled(overlayHistory)
                    .accessibilityHidden(overlayHistory)
                if overlayHistory {
                    Button { self.compactHistoryPresented = false } label: {
                        FWColor.surfaceWindow.opacity(0.65)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close session history")
                }
                if dockedHistory || overlayHistory {
                    CommandSessionSidebar(
                        canChangeSession: self.canChangeSession,
                        blockingReason: self.sessionBlockingReason,
                        onNewSession: self.newSession,
                        onSelect: { id in
                            guard self.canChangeSession, self.service.switchToChat(id: id) else { return }
                            self.compactHistoryPresented = false
                        },
                        onArchive: self.archiveSession,
                        onRestore: { id in
                            guard self.canChangeSession else { return }
                            self.service.restoreChat(id: id)
                        }
                    )
                    .frame(width: min(CommandWorkspaceLayout.sidebarWidth, geometry.size.width))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(FWColor.lineRule)
                            .frame(width: FWMetric.lineHairline)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    // The docked panel is part of the window; only the overlay floats.
                    .shadow(color: .black.opacity(overlayHistory ? 0.16 : 0), radius: 12, x: 0, y: 8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onChange(of: isWide) { _, _ in self.compactHistoryPresented = false }
        }
        .background(FWColor.surfaceWindow)
        .clipped()
        .overlay {
            if self.showingArchiveLimit {
                RecordAlert(
                    title: "Archive is full",
                    message: "Restore a session from Archived before archiving another.",
                    layout: .sideBySide,
                    cancel: .init(label: "OK", kind: .secondary) { self.showingArchiveLimit = false },
                    action: .init(label: "Show sessions", kind: .primary) {
                        self.showingArchiveLimit = false
                        self.compactHistoryPresented = true
                        self.prefersHistoryVisible = true
                    }
                )
            }
        }
        .onAppear {
            self.updatePresentationActivity(self.isActive)
        }
        .onDisappear { self.updatePresentationActivity(false) }
        .onChange(of: self.isActive) { _, active in self.updatePresentationActivity(active) }
        .onChange(of: self.asr.isRunning) { _, running in
            if !running { self.ownsASRRecording = false }
        }
        .onChange(of: self.service.currentChatID) { _, _ in
            self.followsLatestMessage = true
            self.isThinkingExpanded = false
        }
        .onChange(of: self.chatStore.sessions.map(\.id)) { _, ids in self.drafts.retain(sessionIDs: ids) }
        .onReceive(self.settings.objectWillChange.debounce(for: .milliseconds(80), scheduler: RunLoop.main)) { _ in
            if self.isPresentationActive { self.refreshModelCatalog() }
        }
        .onChange(of: self.canChangeSession) { _, canChange in
            if !canChange { self.showModelPicker = false }
        }
    }

    // MARK: - Sheet

    private var isNewSession: Bool {
        self.service.conversationHistory.isEmpty && !self.service.isProcessing
    }

    private func sheet(historyVisible: Bool, isWide: Bool) -> some View {
        VStack(spacing: 0) {
            self.header(historyVisible: historyVisible, isWide: isWide)
            self.chatArea
            self.composer
        }
        .padding(.top, FWMetric.space8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func header(historyVisible: Bool, isWide: Bool) -> some View {
        if !self.isNewSession, let session = self.chatStore.currentSession {
            RecordHeader(session.title, subtitle: self.sessionSubtitle(session)) {
                self.headerActions(historyVisible: historyVisible, isWide: isWide)
            }
            .editableTitle(session.title, id: session.id, enabled: self.canChangeSession, editorFont: FWType.title.font) {
                self.chatStore.renameChat(id: session.id, to: $0)
            }
        } else {
            RecordHeader("New session", subtitle: "Ask a question, work with files, or run a command on your Mac.") {
                self.headerActions(historyVisible: historyVisible, isWide: isWide)
            }
        }
    }

    private func headerActions(historyVisible: Bool, isWide: Bool) -> some View {
        HStack(spacing: FWMetric.space3) {
            if !self.isNewSession {
                Button("New session", action: self.newSession)
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                    .disabled(!self.canChangeSession)
                    .help(self.sessionBlockingReason ?? "New session")
            }
            Button("Sessions") { self.toggleHistory(isWide: isWide) }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                .help(historyVisible ? "Hide sessions" : "Show sessions")
                .accessibilityLabel(historyVisible ? "Hide sessions" : "Show sessions")
        }
    }

    private func sessionSubtitle(_ session: ChatSession) -> String {
        let calendar = Calendar.current
        let time = session.createdAt.formatted(date: .omitted, time: .shortened)
        let day = calendar.isDateInToday(session.createdAt) ? "Today"
            : calendar.isDateInYesterday(session.createdAt) ? "Yesterday"
            : session.createdAt.formatted(date: .abbreviated, time: .omitted)
        let started = "\(day) at \(time)"
        return self.selectedModelID.isEmpty ? started : "\(started)  ·  \(ModelDisplayName.forID(self.selectedModelID))"
    }

    /// A step row and the result or cancellation that followed it.
    private struct CommandRow: Identifiable {
        let message: CommandModeService.Message
        var result: CommandModeService.Message?
        var isRunning = false
        var id: UUID { self.message.id }
    }

    private var rows: [CommandRow] {
        let history = self.service.conversationHistory
        var rows: [CommandRow] = []
        var index = 0
        while index < history.count {
            let message = history[index]
            let next = index + 1 < history.count ? history[index + 1] : nil
            if let tool = message.toolCall {
                if let next, next.role == .tool || next.stepType == .cancelled {
                    rows.append(CommandRow(message: message, result: next))
                    index += 2
                    continue
                }
                // The waiting command has its own row with Run and Cancel.
                if self.service.pendingCommand?.id != tool.id {
                    rows.append(CommandRow(message: message, isRunning: self.service.isProcessing && next == nil))
                }
            } else {
                rows.append(CommandRow(message: message))
            }
            index += 1
        }
        return rows
    }

    private var chatArea: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if self.isNewSession {
                            self.examples
                        } else {
                            let rows = self.rows
                            ForEach(rows) { row in
                                CommandMessageView(message: row.message, result: row.result, isRunning: row.isRunning, onExpand: { self.followsLatestMessage = false })
                                    .id(row.id)
                            }
                            if self.service.isProcessing, rows.last?.isRunning != true {
                                self.processingRow
                            }
                            if let pending = self.service.pendingCommand {
                                self.pendingCommandRow(pending)
                            }
                        }
                        self.fillerRow
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
                .scrollIndicators(.automatic)
                .onScrollPhaseChange { _, phase in
                    self.isUserScrolling = phase == .interacting || phase == .decelerating
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 80
                } action: { _, nearBottom in
                    if self.isUserScrolling { self.followsLatestMessage = nearBottom }
                }
                .onChange(of: self.service.conversationHistory.count) { _, _ in
                    if self.followsLatestMessage { self.scrollToBottom(proxy) }
                }
                .onChange(of: self.service.currentChatID) { _, _ in self.scrollToBottom(proxy) }
                .onChange(of: self.service.isProcessing) { _, processing in
                    if processing { self.isThinkingExpanded = false }
                    if self.followsLatestMessage { self.scrollToBottom(proxy) }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height
                } action: { _, _ in
                    // Follow rendered block heights, including deferred Markdown, not individual tokens.
                    if self.followsLatestMessage { self.scrollToBottom(proxy) }
                }
                .onAppear { self.scrollToBottom(proxy) }
                .overlay(alignment: .bottom) {
                    if !self.followsLatestMessage {
                        Button("Latest") {
                            self.followsLatestMessage = true
                            self.scrollToBottom(proxy)
                        }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                        .padding(.bottom, FWMetric.space3)
                    }
                }
            }
        }
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

    private static let exampleRequests = [
        "List the files in my Downloads folder",
        "Show how much storage my Mac is using",
        "Explain how to check a Git repository’s status",
    ]

    private var examples: some View {
        ForEach(Self.exampleRequests, id: \.self) { example in
            RecordLine {
                if example == Self.exampleRequests.first {
                    Text("Examples")
                        .recordText(FWType.small)
                        .foregroundStyle(FWColor.textTertiary)
                }
            } content: {
                Button {
                    self.inputText.wrappedValue = example
                } label: {
                    Text(example)
                        .recordText(FWType.body)
                        .foregroundStyle(FWColor.textSecondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add this example to your message")
            }
        }
    }

    private var processingRow: some View {
        RecordLine {
            HStack(spacing: FWMetric.space2) {
                Text(Date.now.formatted(date: .omitted, time: .shortened))
                    .recordText(FWType.detailStrong)
                    .foregroundStyle(FWColor.textSecondary)
                RecordMark(state: .working)
            }
            Text("Working")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
        } content: {
            Text(self.currentStepLabel)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
                .lineLimit(2)
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
            if !self.service.streamingText.isEmpty {
                CommandMarkdownContent(text: self.service.streamingText)
            }
        }
    }

    private var currentStepLabel: String {
        guard let step = self.service.currentStep else { return "Working…" }
        switch step {
        case .thinking: return self.service.streamingText.isEmpty ? "Thinking…" : "Writing…"
        case let .checking(command): return "Checking · \(command.prefix(90))"
        case let .executing(command): return "Running · \(command.prefix(90))"
        case .verifying: return "Verifying…"
        case let .completed(success): return success ? "Done" : "Stopped"
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard self.followsLatestMessage else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: - Approval

    private func pendingCommandRow(_ pending: CommandModeService.PendingCommand) -> some View {
        RecordLine(fill: .hover) {
            HStack(spacing: FWMetric.space2) {
                Text(Date.now.formatted(date: .omitted, time: .shortened))
                    .recordText(FWType.detailStrong)
                    .foregroundStyle(FWColor.textSecondary)
                RecordMark(state: .needsYou)
            }
            Text("Needs you")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.stateAttention)
        } content: {
            Text("Review this command before it runs.")
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
            if let purpose = pending.purpose {
                Text(purpose)
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                RecordCodeWell(code: pending.command)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 88)
            .fixedSize(horizontal: false, vertical: true)
            if let directory = pending.workingDirectory {
                Text("Runs in \(directory)")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textTertiary)
                    .lineLimit(1)
            }
            HStack(spacing: FWMetric.space3) {
                Button("Run command") {
                    Task {
                        guard self.service.pendingCommand?.id == pending.id, !self.service.isProcessing else { return }
                        await self.service.confirmAndExecute()
                    }
                }
                .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                Button("Cancel") {
                    guard self.service.pendingCommand?.id == pending.id, !self.service.isProcessing else { return }
                    self.service.cancelPendingCommand()
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
            }
        }
    }

    // MARK: - Composer

    private var composerMarginNote: String? {
        if self.ownsASRRecording { return "Listening" }
        if self.settings.commandModeReadinessIssue != nil { return nil }
        if self.service.pendingCommand != nil { return "Run or cancel the command first." }
        if self.service.isProcessing { return "You can send when this step finishes." }
        return "Return to send"
    }

    private var composer: some View {
        RecordLine(showsRule: false) {
            if let note = self.composerMarginNote {
                Text(note)
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textTertiary)
            }
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space4) {
                if self.ownsASRRecording {
                    HStack(spacing: FWMetric.space4) {
                        RecordingPillPreview(state: .listen, size: .medium)
                        Text("Speak your command. It sends when you stop.")
                            .recordText(FWType.detail)
                            .foregroundStyle(FWColor.textSecondary)
                    }
                } else if let issue = self.settings.commandModeReadinessIssue {
                    HStack(spacing: FWMetric.space4) {
                        Text(issue)
                            .recordText(FWType.body)
                            .foregroundStyle(FWColor.stateAttention)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open AI Providers") {
                            AppNavigationRouter.shared.request(.aiEnhancements)
                        }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                    }
                }
                RecordField(placeholder: "Ask anything", text: self.inputText, size: .multi)
                    .frame(height: self.composerFieldHeight)
                    .onKeyPress(.return, phases: .down) { press in
                        // Option-Return falls through to the editor as a new line.
                        guard !press.modifiers.contains(.option) else { return .ignored }
                        self.submitCommand()
                        return .handled
                    }
                    .accessibilityLabel("Message")
                HStack(spacing: FWMetric.space3) {
                    self.modelSelector
                    self.approvalMenu
                    Spacer(minLength: FWMetric.space3)
                    self.composerActions
                }
                .frame(minHeight: FWMetric.sizeControlM)
            }
        }
    }

    /// 56 pt for one or two lines, growing with typed lines up to eight (Transcript is 24 pt a line).
    private var composerFieldHeight: CGFloat {
        let lines = self.inputText.wrappedValue.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return max(56, CGFloat(min(lines, 8)) * 24 + 16)
    }

    private var approvalMenu: some View {
        RecordPopUp(self.settings.commandModeConfirmBeforeExecute ? "Ask before risky commands" : "Run without asking") {
            Picker("Command approval", selection: self.$settings.commandModeConfirmBeforeExecute) {
                Text("Ask before risky commands").tag(true)
                Text("Run without asking").tag(false)
            }
            .pickerStyle(.inline)
        }
        .accessibilityLabel("Command approval")
        .help("Choose whether potentially destructive commands require your approval")
    }

    private var speakDisabled: Bool {
        self.isSubmissionPending || self.service.isProcessing || self.service.pendingCommand != nil || self.isASRStartPending
            || self.isASRStopPending || (self.asr.isRunning && !self.ownsASRRecording) || self.settings.commandModeReadinessIssue != nil
    }

    @ViewBuilder
    private var composerActions: some View {
        if self.ownsASRRecording {
            Button("Stop and send", action: self.toggleRecording)
                .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                .disabled(self.isASRStopPending)
        } else {
            HStack(spacing: FWMetric.space3) {
                Button("Speak", action: self.toggleRecording)
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                    .disabled(self.speakDisabled)
                    .help(self.sessionBlockingReason ?? "Speak a command")
                Button("Send", action: self.submitCommand)
                    // One primary per view: the waiting command's Run takes it.
                    .buttonStyle(RecordButtonStyle(kind: self.service.pendingCommand == nil ? .primary : .secondary, size: FWMetric.sizeControlM))
                    .disabled(!self.canSubmitCommand)
                    .help(self.sessionBlockingReason ?? "Send message")
            }
        }
    }

    private var modelSelector: some View {
        Button {
            self.refreshModelCatalog()
            self.showModelPicker.toggle()
        } label: {
            Text(self.selectedModelID.isEmpty ? "Choose model" : ModelDisplayName.forID(self.selectedModelID))
                .truncationMode(.middle)
        }
        .buttonStyle(RecordPopUpStyle())
        .fixedSize()
        .disabled(!self.canChangeSession)
        .help(self.sessionBlockingReason ?? "Search models across verified providers")
        .accessibilityLabel("Choose model")
        .popover(isPresented: self.$showModelPicker, arrowEdge: .top) {
            CommandModelPicker(
                options: self.modelOptions,
                selectedProviderID: self.selectedModelProviderID,
                selectedModelID: self.selectedModelID,
                onSelect: self.selectModel,
                onDismiss: { self.showModelPicker = false }
            )
        }
    }

    // MARK: - Actions

    private var sessionBlockingReason: String? {
        if self.service.pendingCommand != nil { return "Run or cancel the pending command before switching sessions." }
        if self.service.isProcessing { return "You can switch sessions when this command finishes." }
        if self.isSubmissionPending { return "Sending your message…" }
        if self.asr.isRunning || self.isASRStartPending || self.isASRStopPending { return "Finish recording before switching sessions." }
        return nil
    }

    private var canChangeSession: Bool { self.sessionBlockingReason == nil }
    private var canSubmitCommand: Bool {
        !self.inputText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !self.compactHistoryPresented && self.canChangeSession && self.settings.commandModeReadinessIssue == nil
    }

    private func toggleHistory(isWide: Bool) {
        withAnimation(self.reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            if isWide { self.prefersHistoryVisible.toggle() } else { self.compactHistoryPresented.toggle() }
        }
    }

    private func newSession() {
        guard self.canChangeSession else { return }
        self.service.createNewChat()
        self.compactHistoryPresented = false
    }

    private func archiveSession(_ id: String) {
        guard self.canChangeSession,
              self.chatStore.sessions.contains(where: { $0.id == id && !$0.isArchived }) else { return }
        if !self.service.archiveChat(id: id) { self.showingArchiveLimit = true }
    }

    private func updatePresentationActivity(_ active: Bool) {
        self.isPresentationActive = active
        self.service.enableNotchOutput = !active
        if active { self.refreshModelCatalog() }
        guard !active, CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(ownsRecording: self.ownsASRRecording, isRunning: self.asr.isRunning) else { return }
        self.ownsASRRecording = false
        Task { await self.asr.stopWithoutTranscription() }
    }

    private func toggleRecording() {
        if self.asr.isRunning {
            guard self.ownsASRRecording, !self.isASRStopPending else { return }
            self.ownsASRRecording = false
            self.isASRStopPending = true
            let sessionID = self.recordingSessionID
            self.recordingSessionID = nil
            Task {
                defer { self.isASRStopPending = false }
                let command = await self.asr.stop().trimmingCharacters(in: .whitespacesAndNewlines)
                _ = self.asr.consumeLastCompletedAudioSnapshot()
                guard !command.isEmpty, let sessionID, self.chatStore.sessions.contains(where: { $0.id == sessionID }) else { return }
                self.drafts.set(command, for: sessionID)
                guard self.isPresentationActive, self.service.currentChatID == sessionID,
                      !self.service.isProcessing, self.service.pendingCommand == nil,
                      self.settings.commandModeReadinessIssue == nil else { return }
                self.drafts.set("", for: sessionID)
                self.followsLatestMessage = true
                await self.service.processUserCommand(command)
            }
        } else {
            guard !self.isSubmissionPending, !self.isASRStartPending, !self.isASRStopPending, !self.service.isProcessing,
                  self.service.pendingCommand == nil else { return }
            self.isASRStartPending = true
            self.recordingSessionID = self.service.currentChatID
            Task {
                defer { self.isASRStartPending = false }
                let outcome = await self.asr.start()
                self.ownsASRRecording = CommandModeRecordingOwnershipPolicy.ownsRecording(after: outcome, isRunning: self.asr.isRunning)
                if !self.ownsASRRecording { self.recordingSessionID = nil }
                if CommandModeRecordingOwnershipPolicy.shouldStopAfterStart(ownsRecording: self.ownsASRRecording, isPresentationActive: self.isPresentationActive) {
                    self.updatePresentationActivity(false)
                }
            }
        }
    }

    private func submitCommand() {
        guard self.canSubmitCommand else { return }
        let sessionID = self.service.currentChatID
        let draft = self.inputText.wrappedValue
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isSubmissionPending = true
        Task {
            defer { self.isSubmissionPending = false }
            guard self.isPresentationActive, self.service.currentChatID == sessionID,
                  !self.service.isProcessing, self.service.pendingCommand == nil,
                  self.settings.commandModeReadinessIssue == nil else { return }
            if self.drafts.text(for: sessionID) == draft { self.drafts.set("", for: sessionID) }
            self.followsLatestMessage = true
            await self.service.processUserCommand(text)
        }
    }

    private func refreshModelCatalog() {
        let options = self.settings.commandModeModelCatalog()
        let providerKey = ModelRepository.shared.providerKey(for: self.settings.effectiveCommandModeProviderID)
        let modelID = self.settings.effectiveCommandModeSelectedModel
        let selected = options.first {
            ModelRepository.shared.providerKey(for: $0.providerID) == providerKey && $0.modelID == modelID
        }
        self.modelOptions = options
        self.selectedModelProviderID = selected?.providerID ?? ""
        self.selectedModelID = selected?.modelID ?? ""
    }

    private func selectModel(_ option: CommandModelOption) {
        guard self.canChangeSession else { return }
        let didSelect = self.settings.selectCommandModeModel(option)
        self.refreshModelCatalog()
        if didSelect { self.showModelPicker = false }
    }
}
