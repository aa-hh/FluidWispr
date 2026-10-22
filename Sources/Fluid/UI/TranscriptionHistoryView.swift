import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A hidden existing row can be selected from sidebar search even when the list is empty.
nonisolated enum HistorySelectionRevealPolicy {
    static func needsFilterReset(
        requestedID: UUID?,
        selectedID: UUID?,
        allEntries: [TranscriptionHistoryEntry],
        visibleEntries: [TranscriptionHistoryEntry]
    ) -> Bool {
        guard let selectedID, requestedID == selectedID else { return false }
        return !visibleEntries.contains { $0.id == selectedID }
            && allEntries.contains { $0.id == selectedID }
    }
}

/// One History page (Today, Yesterday or Earlier) as a ruled sheet, or every day's matches
/// while the header search holds text.
struct TranscriptionHistoryView: View {
    let day: HistoryDay
    /// Shared by the three pages; while it holds text the sidebar shows no selection.
    @Binding var searchQuery: String
    let accessibilityTrusted: Bool
    let microphoneDenied: Bool
    let openAccessibilitySettings: () -> Void
    let showAccessibilityGuide: () -> Void
    let openMicrophoneSettings: () -> Void

    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var pasteCenter = PasteOutcomeCenter.shared
    @ObservedObject private var practiceField = DictationPracticeField.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var audioEntryID: UUID?
    @State private var playToggleRequest = 0
    @State private var changesEntryID: UUID?
    @State private var expandedEntryIDs: Set<UUID> = []
    @State private var copiedEntryID: UUID?
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var availableAudioFiles: Set<String> = []
    @State private var audioAvailabilityRevision = UUID()
    @State private var exportFailure: (entry: TranscriptionHistoryEntry, message: String)?
    @FocusState private var listFocused: Bool

    private struct AudioAvailabilityRequest: Equatable {
        let fileNames: [String]
        let revision: UUID
    }

    private var audioAvailabilityRequest: AudioAvailabilityRequest {
        AudioAvailabilityRequest(
            fileNames: self.historyStore.entries.compactMap { $0.audio?.fileName },
            revision: self.audioAvailabilityRevision
        )
    }

    /// Lives in the store so the sidebar search can select a row before this view
    /// exists, and the store's delete and clear paths keep it valid.
    private var selectedEntryID: UUID? {
        get { self.historyStore.selectedEntryID }
        nonmutating set { self.historyStore.selectedEntryID = newValue }
    }

    private var isSearching: Bool {
        !self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredEntries: [TranscriptionHistoryEntry] {
        self.isSearching ? self.historyStore.search(query: self.searchQuery) : self.historyStore.entries(in: self.day)
    }

    private var selectedEntry: TranscriptionHistoryEntry? {
        guard let id = self.selectedEntryID else { return nil }
        return self.filteredEntries.first(where: { $0.id == id })
    }

    var body: some View {
        self.entryListView
            .background(FWColor.surfaceWindow)
            .onChange(of: self.historyStore.searchSelectionRequest) { _, _ in
                self.revealExternalSelection()
            }
            .onChange(of: self.selectedEntryID) { _, _ in
                self.audioEntryID = nil
                self.changesEntryID = nil
            }
            .onDisappear {
                self.availableAudioFiles = []
                self.audioEntryID = nil
                self.copyFeedbackTask?.cancel()
                self.copiedEntryID = nil
                self.practiceField.isActive = false
                self.practiceField.text = ""
            }
            .onAppear {
                self.audioAvailabilityRevision = UUID()
                self.revealExternalSelection()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                self.audioAvailabilityRevision = UUID()
            }
            .task(id: self.audioAvailabilityRequest) {
                let request = self.audioAvailabilityRequest
                let available = await HistoryAudioAvailability.scan(fileNames: request.fileNames) {
                    DictationAudioHistoryStore.shared.audioFileExists(fileName: $0)
                }
                guard !Task.isCancelled, request == self.audioAvailabilityRequest else { return }
                self.availableAudioFiles = available
                if let entry = self.selectedEntry, !self.hasAudio(entry) {
                    self.audioEntryID = nil
                }
            }
            .overlay {
                if let failure = self.exportFailure {
                    RecordAlert(
                        title: "Pair export failed",
                        message: failure.message,
                        layout: .sideBySide,
                        cancel: .init(label: "OK", kind: .primary) { self.exportFailure = nil },
                        action: .init(label: "Try again", kind: .secondary) {
                            self.exportFailure = nil
                            self.exportPair(failure.entry)
                        }
                    )
                }
            }
    }

    // MARK: - Sheet

    private var entryListView: some View {
        let entries = self.filteredEntries
        let longest = entries.compactMap(Self.spokenMilliseconds).max() ?? 0
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        self.header(entries)
                        self.topLines
                        ForEach(self.sections(entries)) { section in
                            if let heading = section.heading {
                                self.dayHeadingLine(heading, totals: section.totals)
                            }
                            ForEach(section.items) { item in
                                switch item {
                                case let .entry(entry):
                                    self.line(entry, longest: longest)
                                        .id(entry.id)
                                case let .deleted(entry):
                                    self.undoLine(entry)
                                }
                            }
                        }
                        if entries.isEmpty {
                            self.emptyLine
                        }
                        self.sheetFiller
                    }
                    .padding(.top, FWMetric.space8)
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
                .focusable()
                .focusEffectDisabled()
                .focused(self.$listFocused)
                .onMoveCommand { direction in
                    self.moveSelection(direction, in: entries, proxy: proxy)
                }
                .onCopyCommand {
                    self.copyCommandProviders()
                }
                .onDeleteCommand {
                    if let entry = self.selectedEntry { self.delete(entry) }
                }
                .onKeyPress(.space) {
                    guard let entry = self.selectedEntry, self.hasAudio(entry) else { return .ignored }
                    if self.audioEntryID == entry.id {
                        self.playToggleRequest += 1
                    } else {
                        self.audioEntryID = entry.id
                    }
                    return .handled
                }
                .onAppear { self.reveal(self.selectedEntryID, with: proxy) }
                .onChange(of: self.historyStore.selectedEntryID) { _, id in self.reveal(id, with: proxy) }
            }
        }
    }

    private func header(_ entries: [TranscriptionHistoryEntry]) -> some View {
        RecordHeader(self.title, subtitle: self.summary(entries)) {
            RecordSearch(
                placeholder: "Search your words",
                text: self.$searchQuery,
                focusRequest: .pageSearchFocusRequested
            )
            .frame(width: 220)
        }
    }

    private var title: String {
        if self.isSearching { return "Search" }
        switch self.day {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .earlier: return "Earlier"
        }
    }

    private func summary(_ entries: [TranscriptionHistoryEntry]) -> String {
        if self.isSearching {
            let query = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entries.isEmpty else { return "No dictations match “\(query)”" }
            let days = Set(entries.map { Calendar.current.startOfDay(for: $0.timestamp) }).count
            let matches = entries.count == 1 ? "1 dictation matches" : "\(entries.count) dictations match"
            return "\(matches) “\(query)”  ·  \(days == 1 ? "1 day" : "\(days) days")"
        }
        guard !entries.isEmpty else {
            return self.day == .today ? "No dictations yet" : "No dictations"
        }
        var parts = Self.totals(entries)
        if self.day == .earlier, let newest = entries.first, let oldest = entries.last {
            parts.append(Self.dayRange(from: oldest.timestamp, to: newest.timestamp))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Sections

    private enum SheetItem: Identifiable {
        case entry(TranscriptionHistoryEntry)
        /// The entry waiting for Undo, drawn in its old place.
        case deleted(TranscriptionHistoryEntry)

        var id: String {
            switch self {
            case let .entry(entry): entry.id.uuidString
            case let .deleted(entry): "deleted-\(entry.id.uuidString)"
            }
        }

        var timestamp: Date {
            switch self {
            case let .entry(entry), let .deleted(entry): entry.timestamp
            }
        }
    }

    private struct SheetSection: Identifiable {
        let id: Date
        let heading: String?
        let totals: String?
        let items: [SheetItem]
    }

    /// Today and Yesterday are one list; Earlier and search results are grouped by day.
    private func sections(_ entries: [TranscriptionHistoryEntry]) -> [SheetSection] {
        var items = entries.map(SheetItem.entry)
        if !self.isSearching, let pending = self.historyStore.pendingUndo?.entry,
           self.historyStore.day(of: pending) == self.day
        {
            let index = items.firstIndex { $0.timestamp < pending.timestamp } ?? items.count
            items.insert(.deleted(pending), at: index)
        }
        guard self.isSearching || self.day == .earlier else {
            return items.isEmpty ? [] : [SheetSection(id: .distantFuture, heading: nil, totals: nil, items: items)]
        }
        let calendar = Calendar.current
        var sections: [SheetSection] = []
        var current: [SheetItem] = []
        var currentDay: Date?
        func close() {
            guard let currentDay else { return }
            let dayEntries: [TranscriptionHistoryEntry] = current.compactMap {
                if case let .entry(entry) = $0 { return entry }
                return nil
            }
            let totals = self.isSearching
                ? (dayEntries.count == 1 ? "1 match" : "\(dayEntries.count) matches")
                : Self.totals(dayEntries).joined(separator: "  ·  ")
            sections.append(SheetSection(id: currentDay, heading: Self.dayHeading(currentDay), totals: totals, items: current))
        }
        for item in items {
            let itemDay = calendar.startOfDay(for: item.timestamp)
            if itemDay != currentDay {
                close()
                current = []
                currentDay = itemDay
            }
            current.append(item)
        }
        close()
        return sections
    }

    // MARK: - Lines

    private func line(_ entry: TranscriptionHistoryEntry, longest: Int) -> some View {
        let isSelected = self.selectedEntryID == entry.id
        return HistoryEntryLine(
            entry: entry,
            state: self.lineState(entry),
            isSelected: isSelected,
            spokenFraction: Self.spokenMilliseconds(entry).map { longest > 0 ? Double($0) / Double(longest) : 1 },
            searchQuery: self.isSearching ? self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            hasAudio: self.hasAudio(entry),
            isPlaying: self.audioEntryID == entry.id,
            playToggleRequest: self.playToggleRequest,
            isCopied: self.copiedEntryID == entry.id,
            showsChanges: isSelected && self.changesEntryID == entry.id,
            isExpanded: self.expandedEntryIDs.contains(entry.id),
            cleanupDetail: self.cleanupDetail(entry),
            actions: HistoryEntryActions(
                select: {
                    self.selectedEntryID = entry.id
                    self.listFocused = true
                },
                copy: { self.copyFinalText(entry) },
                copyRaw: { self.copyToClipboard(entry.rawText) },
                paste: { Task { await PasteOutcomeCenter.shared.paste(entry: entry) } },
                togglePlayback: {
                    self.audioEntryID = self.audioEntryID == entry.id ? nil : entry.id
                },
                toggleChanges: {
                    self.changesEntryID = self.changesEntryID == entry.id ? nil : entry.id
                },
                expand: { self.expandedEntryIDs.insert(entry.id) },
                delete: { self.delete(entry) }
            )
        )
        .contextMenu { self.entryActions(entry) }
    }

    private func lineState(_ entry: TranscriptionHistoryEntry) -> HistoryLineState {
        if let outcome = self.pasteCenter.pasteOutcomes[entry.id], !outcome.didPaste, outcome != .cancelled {
            if self.pasteCenter.retriedEntryIDs.contains(entry.id) {
                return .retryFailed(canPaste: self.accessibilityTrusted)
            }
            if !self.accessibilityTrusted || outcome == .failed(.accessibilityNotTrusted) {
                return .waiting(note: "Not pasted yet. Accessibility is off.", canPaste: false)
            }
            return .waiting(note: Self.waitingNote(outcome, appName: entry.appName), canPaste: true)
        }
        if let error = entry.aiProcessingError {
            return .rawText(reason: Self.sentence(error))
        }
        return .pasted
    }

    private static func waitingNote(_ outcome: PasteOutcome, appName: String) -> String {
        switch outcome {
        case .failed(.pasteNotLanded):
            "Not pasted. The text did not appear in \(appName.isEmpty ? "the app" : appName)."
        case let .failed(failure):
            "Not pasted. " + Self.sentence(failure.userFacingMessage ?? "The text wasn't inserted")
        default:
            "Not pasted. No text field was focused."
        }
    }

    /// Lower-cases nothing, trims, and ends the text with a full stop.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    private func cleanupDetail(_ entry: TranscriptionHistoryEntry) -> String? {
        guard entry.aiProcessingError == nil, let model = self.recordedModel(entry) else { return nil }
        var detail = "Cleaned by \(model)"
        if let cleanup = entry.aiProcessingDurationMilliseconds {
            detail += " in \(cleanup) ms"
        }
        detail += "."
        if self.settings.showHistoryPerformanceMetrics,
           let heard = entry.parakeetProcessingDurationMilliseconds ?? entry.transcriptionDurationMilliseconds,
           let cleanup = entry.aiProcessingDurationMilliseconds
        {
            detail += " Heard in \(heard) ms, cleaned in \(cleanup) ms."
        }
        return detail
    }

    private func recordedModel(_ entry: TranscriptionHistoryEntry) -> String? {
        guard let model = entry.processingModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        return ModelDisplayName.forID(model)
    }

    private func dayHeadingLine(_ heading: String, totals: String?) -> some View {
        RecordLine {
            EmptyView()
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: FWMetric.space4) {
                Text(heading)
                    .recordText(FWType.section)
                    .foregroundStyle(FWColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let totals {
                    Text(totals)
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textTertiary)
                }
            }
            .padding(.top, FWMetric.space2)
        }
    }

    private func undoLine(_ entry: TranscriptionHistoryEntry) -> some View {
        RecordLine(fill: .sunken) {
            Text("Deleted")
                .recordText(FWType.detailStrong)
                .foregroundStyle(FWColor.textSecondary)
            Text([Self.clockTime(entry.timestamp), entry.appName].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textTertiary)
        } content: {
            HStack(spacing: FWMetric.space3) {
                Text(entry.audio == nil ? "No. \(entry.number) was deleted." : "No. \(entry.number) was deleted, with its recording.")
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textSecondary)
                Button("Undo") { self.historyStore.undoDelete() }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                    .keyboardShortcut("z", modifiers: .command)
                Text("or press ⌘Z")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textTertiary)
            }
        }
        .transition(self.reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }

    /// Notices that sit above the records: saving failed, loading, and a permission turned off.
    @ViewBuilder
    private var topLines: some View {
        if let error = self.historyStore.persistenceError {
            RecordLine {
                Text("Not saved")
                    .recordText(FWType.detailStrong)
                    .foregroundStyle(FWColor.stateAttention)
            } content: {
                VStack(alignment: .leading, spacing: FWMetric.space3) {
                    Text(error)
                        .recordText(FWType.body)
                        .foregroundStyle(FWColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("New dictations stay in this window until saving works again. Nothing is lost while FluidWispr is open.")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560, alignment: .leading)
                    Button("Try again") { self.historyStore.retryPersistence() }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                }
            }
        }
        if self.historyStore.isLoading {
            RecordLine {
                EmptyView()
            } content: {
                Text("Loading history…")
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textSecondary)
            }
        }
        if self.day == .today, !self.isSearching {
            if !self.accessibilityTrusted {
                self.permissionLine(
                    status: "Accessibility was turned off, so FluidWispr can’t paste",
                    detail: "Your words are still kept below. Turn it back on, then paste them from here."
                ) {
                    Button("Open System Settings", action: self.openAccessibilitySettings)
                        .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                    Button("Show the guide", action: self.showAccessibilityGuide)
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                }
            }
            if self.microphoneDenied {
                self.permissionLine(
                    status: "Microphone access was turned off",
                    detail: "FluidWispr can’t hear you until it is back on. Everything you dictated before is safe."
                ) {
                    Button("Open Microphone settings", action: self.openMicrophoneSettings)
                        .buttonStyle(RecordButtonStyle(kind: self.accessibilityTrusted ? .primary : .secondary, size: FWMetric.sizeControlM))
                }
            }
        }
    }

    private func permissionLine<Buttons: View>(
        status: String,
        detail: String,
        @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        RecordLine {
            Text("Needs you")
                .recordText(FWType.detailStrong)
                .foregroundStyle(FWColor.stateAttention)
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space3) {
                HStack(spacing: 6) {
                    RecordMark(state: .needsYou)
                    Text(status)
                        .recordText(FWType.body)
                        .foregroundStyle(FWColor.textPrimary)
                }
                Text(detail)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: FWMetric.space3) {
                    buttons()
                }
            }
        }
    }

    /// First launch, an empty day, or a search with no matches.
    @ViewBuilder
    private var emptyLine: some View {
        if self.isSearching {
            let query = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            RecordLine {
                EmptyView()
            } content: {
                VStack(alignment: .leading, spacing: FWMetric.space4) {
                    Text("Nothing matches “\(query)”.")
                        .recordText(FWType.section)
                        .foregroundStyle(FWColor.textPrimary)
                    Text("Search looks through what you said and the cleaned text, on every day. Try fewer words or another spelling.")
                        .recordText(FWType.body)
                        .foregroundStyle(FWColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)
                    Button("Clear search") { self.searchQuery = "" }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                }
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
        } else if self.day == .today, self.historyStore.entries.isEmpty, !self.historyStore.isLoading,
                  self.historyStore.pendingUndo == nil
        {
            self.firstLaunchLine
        }
    }

    private var firstLaunchLine: some View {
        let hint = self.settings.dictationKeyHint
        let instruction = hint.holds
            ? "Hold \(hint.key), say something, then let go."
            : "Press \(hint.key), say something, then press it again."
        return RecordLine {
            Text("No. 1")
                .recordText(FWType.small)
                .foregroundStyle(FWColor.textTertiary)
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space4) {
                Text("Your first dictation lands here.")
                    .recordText(FWType.section)
                    .foregroundStyle(FWColor.textPrimary)
                Text("\(instruction) The words go wherever your cursor is, and a numbered copy is kept here, so nothing you say is lost.")
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
                Button("Try a dictation") { self.practiceField.isActive = true }
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                    .padding(.top, FWMetric.space2)
                if self.practiceField.isActive {
                    RecordField(placeholder: "Your words", text: self.$practiceField.text, size: .multi)
                        .frame(width: 320, height: 120)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }

    /// The double rule carried on to the bottom of the window.
    private var sheetFiller: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: FWMetric.sizeMargin)
            RecordMarginRule()
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .frame(minHeight: FWMetric.sizeRowMin)
    }

    // MARK: - Actions

    @ViewBuilder
    private func entryActions(_ entry: TranscriptionHistoryEntry) -> some View {
        Button("Copy") { self.copyFinalText(entry) }

        if entry.wasAIProcessed {
            Button("Copy what you said") { self.copyToClipboard(entry.rawText) }
            Button("Copy both") { self.copyToClipboard(self.combinedText(for: entry)) }
        }

        if self.hasAudio(entry) {
            Divider()
            Button("Export pair…") { self.exportPair(entry) }
            Button("Show recording in Finder") { self.revealAudio(entry) }
        }

        Divider()

        Button("Delete", role: .destructive) { self.delete(entry) }
    }

    private func delete(_ entry: TranscriptionHistoryEntry) {
        if self.audioEntryID == entry.id { self.audioEntryID = nil }
        withAnimation(self.reduceMotion ? .easeInOut(duration: FWMotion.durationReduceCrossfade) : .easeOut(duration: FWMotion.durationEnter)) {
            self.historyStore.deleteEntry(id: entry.id)
        }
        if self.selectedEntryID != nil, !self.filteredEntries.contains(where: { $0.id == self.selectedEntryID }) {
            self.selectedEntryID = nil
        }
    }

    /// Parent-level handling also runs when no list exists to observe the selection.
    private func revealExternalSelection() {
        guard let request = self.historyStore.searchSelectionRequest else { return }
        defer { self.historyStore.consumeSearchSelectionRequest(request) }
        guard HistorySelectionRevealPolicy.needsFilterReset(
            requestedID: request.entryID,
            selectedID: self.selectedEntryID,
            allEntries: self.historyStore.entries,
            visibleEntries: self.filteredEntries
        ) else { return }
        self.searchQuery = ""
    }

    /// The parent clears a hidden selection's search; scroll after that view update.
    private func reveal(_ id: UUID?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        if !self.filteredEntries.contains(where: { $0.id == id }) {
            DispatchQueue.main.async { proxy.scrollTo(id) }
        } else {
            proxy.scrollTo(id)
        }
    }

    private func copyFinalText(_ entry: TranscriptionHistoryEntry) {
        guard let text = entry.clipboardText else { return }
        self.copyToClipboard(text)
        self.showCopiedFeedback(for: entry)
    }

    private func showCopiedFeedback(for entry: TranscriptionHistoryEntry) {
        self.copyFeedbackTask?.cancel()
        self.copiedEntryID = entry.id
        self.copyFeedbackTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self.copiedEntryID = nil
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection, in entries: [TranscriptionHistoryEntry], proxy: ScrollViewProxy) {
        guard !entries.isEmpty else { return }
        let current = self.selectedEntryID.flatMap { id in entries.firstIndex(where: { $0.id == id }) }
        let next: Int
        switch direction {
        case .up: next = max((current ?? 0) - 1, 0)
        case .down: next = current.map { min($0 + 1, entries.count - 1) } ?? 0
        default: return
        }
        let id = entries[next].id
        self.selectedEntryID = id
        proxy.scrollTo(id)
    }

    private func copyCommandProviders() -> [NSItemProvider] {
        guard let entry = self.selectedEntry, let text = entry.clipboardText else { return [] }
        ClipboardAudit.record("ui_copy_command")
        self.showCopiedFeedback(for: entry)
        return [NSItemProvider(object: text as NSString)]
    }

    private func copyToClipboard(_ text: String) {
        ClipboardAudit.record("ui_copy_begin")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ClipboardAudit.record("ui_copy_end")
    }

    private func combinedText(for entry: TranscriptionHistoryEntry) -> String {
        "\(entry.rawText)\n\n\(entry.processedText)"
    }

    private func hasAudio(_ entry: TranscriptionHistoryEntry) -> Bool {
        guard let audio = entry.audio else { return false }
        return self.availableAudioFiles.contains(audio.fileName)
    }

    private func revealAudio(_ entry: TranscriptionHistoryEntry) {
        guard let url = DictationAudioHistoryStore.shared.audioFileURL(for: entry),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportPair(_ entry: TranscriptionHistoryEntry) {
        do {
            guard self.hasAudio(entry) else { throw DictationAudioHistoryError.audioMissing }
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = DictationAudioHistoryStore.shared.suggestedPairExportFilename(for: entry)

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try DictationAudioHistoryStore.shared.exportPair(entry: entry, to: url)
        } catch {
            self.exportFailure = (entry, error.localizedDescription)
        }
    }

    // MARK: - Formatting

    /// How long the person spoke; nil when neither the entry nor its audio recorded it.
    nonisolated static func spokenMilliseconds(_ entry: TranscriptionHistoryEntry) -> Int? {
        entry.spokenDurationMilliseconds ?? entry.audio?.durationMilliseconds
    }

    /// "9 dictations", "4 min spoken" (when any length is known) and "610 words".
    private static func totals(_ entries: [TranscriptionHistoryEntry]) -> [String] {
        var parts = [entries.count == 1 ? "1 dictation" : "\(entries.count) dictations"]
        let spoken = entries.compactMap(Self.spokenMilliseconds).reduce(0, +)
        if spoken > 0 {
            parts.append("\(max(1, Int((Double(spoken) / 60_000).rounded()))) min spoken")
        }
        let words = entries.reduce(0) { $0 + Self.wordCount($1.processedText) }
        parts.append(words == 1 ? "1 word" : "\(words.formatted()) words")
        return parts
    }

    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func clockTime(_ date: Date) -> String {
        Self.clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// "Today", "Yesterday", or "Monday 19 October" (with the year when it is not this year).
    private static func dayHeading(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return Self.dayFormatter(calendar.isDate(day, equalTo: Date(), toGranularity: .year) ? "EEEE d MMMM" : "EEEE d MMMM yyyy")
            .string(from: day)
    }

    /// "14 to 19 October", "28 September to 3 October", or one day's date.
    private static func dayRange(from oldest: Date, to newest: Date) -> String {
        let calendar = Calendar.current
        let thisYear = calendar.isDate(oldest, equalTo: Date(), toGranularity: .year)
        let full = Self.dayFormatter(thisYear ? "d MMMM" : "d MMMM yyyy")
        if calendar.isDate(oldest, inSameDayAs: newest) { return full.string(from: newest) }
        let sameMonth = calendar.isDate(oldest, equalTo: newest, toGranularity: .month)
        let start = sameMonth ? Self.dayFormatter("d").string(from: oldest) : full.string(from: oldest)
        return "\(start) to \(full.string(from: newest))"
    }

    private static func dayFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - One record

enum HistoryLineState: Equatable {
    case pasted
    case waiting(note: String, canPaste: Bool)
    case rawText(reason: String)
    case retryFailed(canPaste: Bool)

    var mark: RecordMark.State {
        switch self {
        case .pasted: .done
        case .waiting: .waiting
        case .rawText: .needsYou
        case .retryFailed: .retryFailed
        }
    }
}

struct HistoryEntryActions {
    let select: () -> Void
    let copy: () -> Void
    let copyRaw: () -> Void
    let paste: () -> Void
    let togglePlayback: () -> Void
    let toggleChanges: () -> Void
    let expand: () -> Void
    let delete: () -> Void
}

/// One record as a ruled line: time, state, app and number in the margin; the words, any note,
/// the spoken length and, when selected, its details and actions in the text column.
private struct HistoryEntryLine: View {
    let entry: TranscriptionHistoryEntry
    let state: HistoryLineState
    let isSelected: Bool
    /// Length relative to the longest record in view; nil hides the spoken-length row.
    let spokenFraction: Double?
    let searchQuery: String
    let hasAudio: Bool
    let isPlaying: Bool
    let playToggleRequest: Int
    let isCopied: Bool
    let showsChanges: Bool
    let isExpanded: Bool
    let cleanupDetail: String?
    let actions: HistoryEntryActions

    @State private var isHovered = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0
    @State private var comparison: HistoryTextDiff?
    @State private var comparisonTooLong = false

    var body: some View {
        VStack(spacing: 0) {
            RecordLine(fill: self.isSelected ? .selected : (self.showsHoverFill ? .hover : .none)) {
                self.margin
            } content: {
                VStack(alignment: .leading, spacing: FWMetric.space3) {
                    self.transcript
                    self.noteRow
                    if self.isPlaying {
                        HistoryInlineAudioView(entry: self.entry, toggleRequest: self.playToggleRequest)
                            .id(self.entry.id)
                    } else {
                        self.spokenRow
                    }
                    if self.clamps, self.fullHeight > self.shownHeight + 1 {
                        Button("Show all \(TranscriptionHistoryView.wordCount(self.entry.processedText)) words", action: self.actions.expand)
                            .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                    }
                    if self.isSelected {
                        self.selectedRows
                    }
                }
            }
            if self.showsChanges, !self.comparisonTooLong {
                HistoryTextComparisonView(entry: self.entry, comparison: self.comparison, cleanupDetail: self.cleanupDetail) {
                    self.actionsRow
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { self.isHovered = $0 }
        .animation(.easeInOut(duration: FWMotion.durationSnap), value: self.isHovered)
        .onTapGesture(count: 2) {
            self.actions.select()
            self.actions.copy()
        }
        .simultaneousGesture(TapGesture().onEnded { self.actions.select() })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Copy")) { self.actions.copy() }
        .task(id: self.showsChanges) {
            guard self.showsChanges, self.comparison == nil, !self.comparisonTooLong else { return }
            let result = await HistoryTextComparisonView<EmptyView>.compare(self.entry)
            guard !Task.isCancelled else { return }
            self.comparison = result
            self.comparisonTooLong = result == nil
        }
    }

    /// Waiting and retry-failed lines keep the hover fill.
    private var showsHoverFill: Bool {
        switch self.state {
        case .waiting, .retryFailed: true
        case .pasted, .rawText: self.isHovered
        }
    }

    private var clamps: Bool {
        !self.isSelected && !self.isExpanded
    }

    @ViewBuilder
    private var margin: some View {
        HStack(spacing: FWMetric.space2) {
            Text(TranscriptionHistoryView.clockTime(self.entry.timestamp))
                .recordText(FWType.detailStrong)
                .foregroundStyle(FWColor.textSecondary)
            RecordMark(state: self.state.mark)
        }
        if !self.entry.appName.isEmpty {
            Text(self.entry.appName)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textTertiary)
                .lineLimit(1)
        }
        Text("No. \(self.entry.number)")
            .recordText(FWType.small)
            .foregroundStyle(FWColor.textTertiary)
    }

    private var transcriptText: AttributedString {
        var text = self.showsChanges
            ? HistoryTextComparisonView<EmptyView>.finalText(self.entry, comparison: self.comparison)
            : AttributedString(self.entry.clipboardText ?? "")
        guard !self.searchQuery.isEmpty else { return text }
        // Matched words are set in semibold, with no colour or fill.
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text[searchStart...].range(of: self.searchQuery, options: [.caseInsensitive, .diacriticInsensitive])
        {
            text[range].font = .fluidSystem(size: FWType.transcript.size, weight: .semibold)
            searchStart = range.upperBound
        }
        return text
    }

    private var transcript: some View {
        Text(self.transcriptText)
            .recordText(FWType.transcript)
            .foregroundStyle(FWColor.textPrimary)
            .lineLimit(self.clamps ? 6 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 600, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.shownHeight = $0 }
            .background(alignment: .topLeading) {
                if self.clamps {
                    // The unclamped height, to tell whether "Show all" is needed.
                    Text(self.transcriptText)
                        .recordText(FWType.transcript)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.fullHeight = $0 }
                }
            }
    }

    @ViewBuilder
    private var noteRow: some View {
        switch self.state {
        case .pasted:
            EmptyView()
        case let .waiting(note, canPaste):
            HStack(spacing: FWMetric.space3) {
                self.note(note, color: FWColor.textSecondary)
                Button("Paste", action: self.actions.paste)
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlS))
                    .disabled(!canPaste)
                self.copyButton
            }
        case let .rawText(reason):
            self.note(
                "Raw text: \(reason)" + (self.isSelected ? " These are your words as heard, pasted as they were." : ""),
                color: FWColor.stateAttention
            )
        case let .retryFailed(canPaste):
            HStack(spacing: FWMetric.space3) {
                self.note("Pasting again did not work. The words are kept here.", color: FWColor.stateRetry)
                Button("Paste again", action: self.actions.paste)
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlS))
                    .disabled(!canPaste)
                self.copyButton
            }
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .recordText(FWType.detail)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var copyButton: some View {
        Button(self.isCopied ? "Copied" : "Copy", action: self.actions.copy)
            .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
    }

    /// The hover Copy shows on lines that are not selected and carry no note buttons.
    private var showsHoverCopy: Bool {
        guard self.isHovered, !self.isSelected else { return false }
        switch self.state {
        case .pasted, .rawText: return true
        case .waiting, .retryFailed: return false
        }
    }

    @ViewBuilder
    private var spokenRow: some View {
        if let fraction = self.spokenFraction, let milliseconds = TranscriptionHistoryView.spokenMilliseconds(self.entry) {
            GeometryReader { geometry in
                HStack(spacing: FWMetric.space3) {
                    Rectangle()
                        .fill(FWColor.lineSpoken)
                        .frame(width: max(2, (geometry.size.width - 50) * min(max(fraction, 0), 1)), height: FWMetric.lineHairline)
                    Text(Self.runningTime(milliseconds))
                        .recordText(FWType.small)
                        .foregroundStyle(FWColor.textTertiary)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            .overlay(alignment: .trailing) {
                if self.showsHoverCopy { self.copyButton }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Spoken for \(Self.runningTime(milliseconds))")
        } else if self.showsHoverCopy {
            HStack {
                Spacer(minLength: 0)
                self.copyButton
            }
        }
    }

    @ViewBuilder
    private var selectedRows: some View {
        if self.entry.audio != nil, !self.hasAudio, !self.isPlaying {
            self.note(HistoryInlineAudioView.goneMessage, color: FWColor.textSecondary)
        }
        if self.isShortSkip {
            self.note("Three words or fewer skip cleanup, so this went in as heard.", color: FWColor.textTertiary)
        }
        if self.showsChanges {
            HStack(spacing: FWMetric.space3) {
                RecordSwitch("Show changes", isOn: Binding(get: { true }, set: { isOn in
                    if !isOn { self.actions.toggleChanges() }
                }))
                Text("Show changes")
                    .recordText(FWType.detailStrong)
                    .foregroundStyle(FWColor.textPrimary)
                Text(self.comparisonTooLong
                    ? HistoryTextComparisonView<EmptyView>.tooLongMessage
                    : "Underlined words were added by cleanup. Struck words were removed.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !self.showsChanges || self.comparisonTooLong {
            if let cleanupDetail {
                self.note(cleanupDetail, color: FWColor.textTertiary)
            }
            self.actionsRow
        }
    }

    /// Three words or fewer go in as heard, with no cleanup.
    private var isShortSkip: Bool {
        self.entry.processingModel == nil && self.entry.aiProcessingError == nil
            && TranscriptionHistoryView.wordCount(self.entry.rawText) <= 3
    }

    private var canShowChanges: Bool {
        self.entry.wasAIProcessed && self.entry.aiProcessingError == nil && self.entry.rawText != self.entry.processedText
    }

    private var actionsRow: some View {
        HStack(spacing: FWMetric.space3) {
            self.copyButton
            if self.showsChanges {
                Button("Copy what you said", action: self.actions.copyRaw)
            }
            if self.entry.audio != nil {
                Button(self.isPlaying ? "Close recording" : "Play recording", action: self.actions.togglePlayback)
                    .disabled(!self.hasAudio)
            }
            if self.canShowChanges, !self.showsChanges {
                Button("Show changes", action: self.actions.toggleChanges)
            }
            Spacer(minLength: 0)
            Button("Delete", action: self.actions.delete)
                .buttonStyle(RecordButtonStyle(kind: .destructive, size: FWMetric.sizeControlS))
        }
        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
        .padding(.top, FWMetric.space1)
    }

    private static func runningTime(_ milliseconds: Int) -> String {
        let seconds = max(0, Int((Double(milliseconds) / 1000).rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
