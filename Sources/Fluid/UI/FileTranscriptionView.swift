import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum FileTranscriptionSearchReveal {
    static func transcriptID(_ target: AppSearchHit.Target?) -> UUID? {
        guard case let .transcript(id) = target else { return nil }
        return id
    }
}

struct FileTranscriptionView: View {
    @ObservedObject var asrService: ASRService
    @ObservedObject private var transcriptionService: FileTranscriptionService
    @ObservedObject private var fileHistoryStore = FileTranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Binding private var revealTarget: AppSearchHit.Target?
    @State private var selectedFileURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(asrService: ASRService, transcriptionService: FileTranscriptionService, revealTarget: Binding<AppSearchHit.Target?> = .constant(nil)) {
        self._revealTarget = revealTarget
        self.asrService = asrService
        _transcriptionService = ObservedObject(wrappedValue: transcriptionService)
    }

    @State private var showingFilePicker = false
    @State private var showingExportDialog = false
    @State private var exportResult: TranscriptionResult?
    @State private var exportFormat: ExportFormat = .text
    @State private var showingCopyConfirmation = false
    @State private var isDropTargeted = false
    @State private var droppedUnsupportedName: String?
    @State private var selectedFileDuration: TimeInterval?
    @State private var failure: FileTranscriptionService.TranscriptionError?
    @State private var searchQuery = ""
    @State private var transcriptListWidth: CGFloat = 248
    @State private var splitterDragStart: CGFloat?
    @State private var isSplitterHovered = false
    @State private var hoveredRowID: UUID?
    @State private var pendingDeleteEntry: FileTranscriptionEntry?
    @State private var showingClearConfirmation = false

    private struct RowMetadata {
        let preview: String
        let when: String
        let meta: String
    }

    @State private var rowMetadata: [UUID: RowMetadata] = [:]
    @State private var filteredEntries: [FileTranscriptionEntry] = []
    // Only an explicit global-search reveal may move the library viewport.
    @State private var pendingRevealID: UUID?

    private func updateSearchResults(entries: [FileTranscriptionEntry]) {
        let query = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filteredEntries = query.isEmpty ? entries : entries.filter {
            $0.displayTitle.localizedStandardContains(query) || $0.fileName.localizedStandardContains(query) || $0.text.localizedStandardContains(query)
        }
    }

    private var selectedEntry: FileTranscriptionEntry? {
        let entries = self.filteredEntries
        return entries.first { $0.id == self.fileHistoryStore.selectedEntryID } ?? entries.first
    }

    enum ExportFormat: String, CaseIterable {
        case text = "Text (.txt)"
        case json = "JSON (.json)"

        var fileExtension: String {
            switch self {
            case .text: return "txt"
            case .json: return "json"
            }
        }
    }

    private var chosenFileURL: URL? {
        self.selectedFileURL ?? self.transcriptionService.currentFileURL
    }

    private var selectedFileIsVideo: Bool {
        self.chosenFileURL.map { Self.isVideo(fileName: $0.lastPathComponent) } ?? false
    }

    private static func isVideo(fileName: String) -> Bool {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        return UTType(filenameExtension: fileExtension)?.conforms(to: .movie) ?? false
    }

    private var conflictingActivity: ASRExclusiveActivity? {
        guard let activity = self.asrService.activeExclusiveActivity,
              activity != .fileTranscription
        else {
            return nil
        }
        return activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordHeader("File transcription", subtitle: "Audio and video files, transcribed on this Mac.")
            self.addFileLine
            self.transcriptBrowser
                .overlay(alignment: .top) {
                    Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
                }
        }
        .padding(.top, FWMetric.space8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FWColor.surfaceWindow)
        .overlay(alignment: .topTrailing) {
            if self.showingCopyConfirmation {
                RecordToast(title: "Transcript copied", detail: "Paste it anywhere.")
                    .padding(.top, FWMetric.space7)
                    .padding(.trailing, FWMetric.space7)
                    .transition(self.reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) { self.confirmation }
        .fileExporter(
            isPresented: self.$showingExportDialog,
            document: TranscriptionDocument(
                result: self.exportResult ?? TranscriptionResult(text: "", confidence: 0, duration: 0, processingTime: 0, fileName: "transcript"),
                format: self.exportFormat,
                service: self.transcriptionService
            ),
            contentType: self.exportFormat == .text ? .plainText : .json,
            defaultFilename: "\((self.exportResult?.fileName).map { "\($0)_transcript" } ?? "transcript").\(self.exportFormat.fileExtension)"
        ) { exportCompletion in
            switch exportCompletion {
            case .success:
                DebugLogger.shared.info("File exported successfully", source: "FileTranscriptionView")
            case let .failure(error):
                DebugLogger.shared.error("Export failed: \(error)", source: "FileTranscriptionView")
            }
            self.exportResult = nil
        }
        .onReceive(self.fileHistoryStore.$entries) { entries in
            self.rowMetadata = Dictionary(entries.map { entry in
                (entry.id, Self.metadata(for: entry))
            }, uniquingKeysWith: { _, latest in latest })
            self.updateSearchResults(entries: entries)
        }
        .task(id: self.revealTarget) {
            guard let id = FileTranscriptionSearchReveal.transcriptID(self.revealTarget) else { return }
            self.searchQuery = ""
            self.updateSearchResults(entries: self.fileHistoryStore.entries)
            self.fileHistoryStore.selectedEntryID = id
            self.pendingRevealID = self.filteredEntries.contains(where: { $0.id == id }) ? id : nil
            self.revealTarget = nil
        }
        .task(id: self.chosenFileURL) {
            self.selectedFileDuration = nil
            guard let url = self.chosenFileURL else { return }
            let duration = try? await AVURLAsset(url: url).load(.duration)
            guard !Task.isCancelled, let seconds = duration?.seconds, seconds.isFinite, seconds > 0 else { return }
            self.selectedFileDuration = seconds
        }
        .onChange(of: self.searchQuery) { _, _ in
            self.updateSearchResults(entries: self.fileHistoryStore.entries)
        }
        .onChange(of: self.transcriptionService.isTranscribing) { _, isTranscribing in
            guard isTranscribing else { return }
            AccessibilityNotification.Announcement("File transcription started").post()
        }
        .onChange(of: self.transcriptionService.result?.id) { _, resultID in
            guard resultID != nil else { return }
            self.searchQuery = ""
            AccessibilityNotification.Announcement("File transcription complete").post()
        }
        .onChange(of: self.transcriptionService.error) { _, error in
            if error == nil { self.failure = nil }
            guard let error, !error.isEmpty else { return }
            AccessibilityNotification.Announcement("File transcription failed. \(error)").post()
        }
        .onAppear {
            if self.selectedFileURL == nil {
                self.selectedFileURL = self.transcriptionService.currentFileURL
            }
        }
    }

    // MARK: - Confirmations

    @ViewBuilder
    private var confirmation: some View {
        if let entry = self.pendingDeleteEntry {
            RecordAlert(
                title: "Delete “\(entry.displayTitle)”?",
                message: "This deletes the saved transcript. Your original \(Self.isVideo(fileName: entry.fileName) ? "video" : "audio") file stays where it is.",
                width: 300,
                cancel: .init(label: "Cancel", kind: .primary) { self.pendingDeleteEntry = nil },
                action: .init(label: "Delete transcript", kind: .destructive) {
                    self.fileHistoryStore.deleteEntry(id: entry.id)
                    self.pendingDeleteEntry = nil
                }
            )
            .padding(.top, 150)
        } else if self.showingClearConfirmation {
            RecordAlert(
                title: "Clear all transcripts?",
                message: "All saved file transcripts will be permanently deleted. Original files are kept.",
                width: 300,
                cancel: .init(label: "Cancel", kind: .primary) { self.showingClearConfirmation = false },
                action: .init(label: "Clear all", kind: .destructive) {
                    self.fileHistoryStore.clearAll()
                    self.showingClearConfirmation = false
                }
            )
            .padding(.top, 150)
        }
    }

    // MARK: - Add a file

    private var addFileLine: some View {
        RecordLine {
            StatsMargin("Add a file", "WAV, MP3, M4A, OGG, OPUS, MP4, MOV and more")
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space4) {
                if let activity = self.conflictingActivity {
                    Text(Self.pausedCopy(for: activity))
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                        .padding(.vertical, FWMetric.space3)
                        .padding(.horizontal, FWMetric.space4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous).fill(FWColor.surfaceSunken))
                }
                if let fileURL = self.chosenFileURL {
                    self.fileRow(fileURL)
                    if SpeakerDiarizationService.isSupported {
                        self.speakersRow
                    }
                    if self.transcriptionService.isTranscribing {
                        self.progressBlock
                    }
                    if self.transcriptionService.error != nil, let copy = self.failureCopy {
                        self.noteRow(copy) { self.transcriptionService.reset() }
                    }
                } else {
                    RecordDropWell(
                        heading: "Drop an audio or video file here",
                        help: "Or choose one from your Mac. It stays on this Mac.",
                        isTargeted: self.isDropTargeted
                    ) {
                        self.showingFilePicker = true
                    }
                    .help(FileTranscriptionService.supportedFormatsDescription)
                    .onDrop(of: [.fileURL], isTargeted: self.$isDropTargeted) { providers in
                        self.handleDrop(providers: providers)
                    }
                    if let name = self.droppedUnsupportedName {
                        self.noteRow("“\(name)” is not an audio or video file. Try WAV, MP3, M4A, OGG, OPUS, MP4 or MOV.") {
                            self.droppedUnsupportedName = nil
                        }
                    }
                }
            }
            .padding(.bottom, FWMetric.space3)
        }
        .fileImporter(
            isPresented: self.$showingFilePicker,
            allowedContentTypes: FileTranscriptionService.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    self.selectedFileURL = url
                    self.transcriptionService.reset()
                }
            case let .failure(error):
                DebugLogger.shared.error("File picker error: \(error)", source: "FileTranscriptionView")
            }
        }
    }

    static func pausedCopy(for activity: ASRExclusiveActivity) -> String {
        if activity == .dictation {
            return "File transcription waits while you dictate. Transcribe file comes back when you stop."
        }
        return "File transcription waits while \(activity.displayName) runs. Transcribe file comes back when it stops."
    }

    /// The failure note; an activity conflict is shown by the paused note instead.
    private var failureCopy: String? {
        switch self.failure {
        case .activityInProgress?: nil
        case .fileNotSupported?: "Transcription failed. This file has no audio track we can read. Nothing was saved."
        case .modelLoadFailed?: "Transcription failed. The voice model couldn’t be loaded. Nothing was saved."
        case .audioConversionFailed?: "Transcription failed. The audio couldn’t be read. Nothing was saved."
        case .transcriptionFailed?, nil: "Transcription failed. Nothing was saved."
        }
    }

    private func fileRow(_ fileURL: URL) -> some View {
        let isTranscribing = self.transcriptionService.isTranscribing
        let kind = self.selectedFileIsVideo ? "Video file" : "Audio file"
        return HStack(spacing: FWMetric.space4) {
            VStack(alignment: .leading, spacing: FWMetric.space1) {
                Text(fileURL.lastPathComponent)
                    .recordText(FWType.label)
                    .foregroundStyle(FWColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(self.selectedFileDuration.map { "\(kind)  ·  \(Self.clock($0))" } ?? kind)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove") {
                self.selectedFileURL = nil
                self.transcriptionService.reset()
            }
            .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
            .disabled(isTranscribing)
            .help(isTranscribing ? "Wait for transcription to finish" : "Remove file")
            Button(isTranscribing ? "Transcribing…" : "Transcribe file") {
                Task { await self.transcribeFile() }
            }
            .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
            .disabled(isTranscribing || self.conflictingActivity != nil)
            .help(self.conflictingActivity != nil ? "Wait for the active transcription to finish" : "Transcribe the selected file")
        }
    }

    private var speakersRow: some View {
        let isVideo = self.selectedFileIsVideo
        let isOn = self.settings.fileTranscriptionSpeakerLabelsEnabled && !isVideo
        let count = self.settings.fileTranscriptionExpectedSpeakerCount
        return HStack(spacing: FWMetric.space4) {
            RecordSwitch("Label speakers", isOn: isVideo ? .constant(false) : self.$settings.fileTranscriptionSpeakerLabelsEnabled)
            VStack(alignment: .leading, spacing: FWMetric.space1) {
                Text("Label speakers")
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
                Text(isVideo ? "Available for audio files only." : "Shows who said what. Downloads speaker models the first time.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isOn {
                RecordPopUp("Speakers: \(count == 0 ? "Auto" : String(count))") {
                    Button("Auto") { self.settings.fileTranscriptionExpectedSpeakerCount = 0 }
                    ForEach(2...8, id: \.self) { value in
                        Button("\(value)") { self.settings.fileTranscriptionExpectedSpeakerCount = value }
                    }
                }
                .accessibilityLabel("Number of speakers")
            }
        }
        .disabled(isVideo || self.transcriptionService.isTranscribing)
        .opacity(isVideo || self.transcriptionService.isTranscribing ? 0.5 : 1)
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: FWMetric.space3) {
            HStack(spacing: FWMetric.space3) {
                ProgressView().controlSize(.mini).tint(FWColor.textTertiary)
                Text("Transcribing  ·  \(Int((self.transcriptionService.progress * 100).rounded()))%")
                    .recordText(FWType.detailStrong)
                    .foregroundStyle(FWColor.textPrimary)
                Spacer(minLength: FWMetric.space4)
                Text("Runs on this Mac. The transcript appears below when it is done.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .lineLimit(1)
            }
            RecordProgressLine(fraction: self.transcriptionService.progress)
        }
    }

    /// An amber ring, the message and a Dismiss button. Never red.
    private func noteRow(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: FWMetric.space4) {
            Circle()
                .strokeBorder(FWColor.stateAttention, lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(message)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.stateAttention)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss", action: dismiss)
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
        }
    }

    // MARK: - Transcript library

    private var transcriptBrowser: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 1)
            let minimum = min(200, available / 2)
            let maximum = max(minimum, available - min(300, available / 2))
            let width = min(max(self.transcriptListWidth, minimum), maximum)
            HStack(spacing: 0) {
                self.transcriptList
                    .frame(width: width)
                self.transcriptDivider(width: width, minimum: minimum, maximum: maximum)
                Group {
                    if let entry = self.selectedEntry {
                        self.transcriptDetail(entry: entry)
                    } else {
                        self.emptyDetail
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func transcriptDivider(width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> some View {
        Rectangle()
            .fill(self.isSplitterHovered || self.splitterDragStart != nil ? FWColor.lineStrong : FWColor.lineRule)
            .frame(width: FWMetric.lineHairline)
            .frame(maxHeight: .infinity)
            .overlay {
                // A wider grab area than the 1 pt line it moves.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        self.isSplitterHovered = hovering
                        (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = self.splitterDragStart ?? width
                                self.splitterDragStart = start
                                self.transcriptListWidth = min(max(start + value.translation.width, minimum), maximum)
                            }
                            .onEnded { _ in self.splitterDragStart = nil }
                    )
                    .simultaneousGesture(TapGesture(count: 2).onEnded { self.transcriptListWidth = 248 })
                    .help("Drag to resize panes. Double-click to reset.")
            }
            .accessibilityElement()
            .accessibilityLabel("Resize transcript panes")
            .accessibilityValue("File list width \(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: self.transcriptListWidth = min(width + 40, maximum)
                case .decrement: self.transcriptListWidth = max(width - 40, minimum)
                @unknown default: break
                }
            }
            .onDisappear {
                if self.isSplitterHovered { NSCursor.arrow.set() }
                self.isSplitterHovered = false
                self.splitterDragStart = nil
            }
            .zIndex(1)
    }

    private var transcriptList: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transcripts")
                    .recordText(FWType.label)
                    .foregroundStyle(FWColor.textPrimary)
                Spacer()
                Text("\(self.filteredEntries.count)")
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textTertiary)
            }
            .padding(EdgeInsets(top: FWMetric.space5, leading: FWMetric.space5, bottom: FWMetric.space3, trailing: FWMetric.space5))

            RecordSearch(placeholder: "Search transcripts", text: self.$searchQuery)
                .accessibilityLabel("Search file names and transcript text")
                .padding(EdgeInsets(top: 0, leading: FWMetric.space5, bottom: FWMetric.space3, trailing: FWMetric.space5))

            if self.filteredEntries.isEmpty {
                VStack(spacing: FWMetric.space2) {
                    Text(self.searchQuery.isEmpty ? "No transcripts yet" : "No matching transcripts")
                        .recordText(FWType.label)
                        .foregroundStyle(FWColor.textPrimary)
                    Text(self.searchQuery.isEmpty ? "Transcribe a file to start your library." : "Try a file name or words from the transcript.")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                }
                .multilineTextAlignment(.center)
                .frame(width: 180)
                .padding(FWMetric.space5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: FWMetric.space1) {
                            ForEach(self.filteredEntries) { entry in
                                self.transcriptRow(entry: entry).id(entry.id)
                            }
                        }
                        .padding(EdgeInsets(top: FWMetric.space2, leading: FWMetric.space3, bottom: FWMetric.space2, trailing: FWMetric.space3))
                    }
                    .task(id: self.pendingRevealID) {
                        guard let id = self.pendingRevealID else { return }
                        await Task.yield()
                        guard !Task.isCancelled, self.pendingRevealID == id,
                              self.filteredEntries.contains(where: { $0.id == id }) else { return }
                        proxy.scrollTo(id)
                        self.pendingRevealID = nil
                    }
                }
            }
            HStack {
                Text("Saved on this Mac")
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textTertiary)
                Spacer()
                Button("Clear all…") { self.showingClearConfirmation = true }
                    .recordText(FWType.smallStrong)
                    .foregroundStyle(FWColor.textSecondary)
                    .buttonStyle(.plain)
                    .disabled(self.fileHistoryStore.entries.isEmpty)
                    .opacity(self.fileHistoryStore.entries.isEmpty ? 0.4 : 1)
            }
            .padding(EdgeInsets(top: FWMetric.space3, leading: FWMetric.space5, bottom: FWMetric.space3, trailing: FWMetric.space5))
            .overlay(alignment: .top) {
                Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
            }
        }
        .background(FWColor.surfaceWindow)
    }

    private func transcriptRow(entry: FileTranscriptionEntry) -> some View {
        let isSelected = self.selectedEntry?.id == entry.id
        return Button {
            self.pendingRevealID = nil
            self.fileHistoryStore.selectedEntryID = entry.id
        } label: {
            VStack(alignment: .leading, spacing: FWMetric.space1) {
                Text(entry.displayTitle)
                    .recordText(FWType.label)
                    .foregroundStyle(FWColor.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(self.rowMetadata[entry.id]?.when ?? "")
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textTertiary)
                Text(self.rowMetadata[entry.id]?.preview ?? "")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, FWMetric.space3)
            .padding(.horizontal, FWMetric.space4)
            .background(
                RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous)
                    .fill(isSelected ? FWColor.surfaceSelected : (self.hoveredRowID == entry.id ? FWColor.surfaceHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                self.hoveredRowID = entry.id
            } else if self.hoveredRowID == entry.id {
                self.hoveredRowID = nil
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .editableTitle(entry.displayTitle, id: entry.id.uuidString, doubleClickEnabled: false) {
            self.fileHistoryStore.renameEntry(id: entry.id, to: $0)
        }
    }

    private var emptyDetail: some View {
        let total = self.fileHistoryStore.entries.count
        let searching = !self.searchQuery.isEmpty && total > 0
        return VStack(spacing: FWMetric.space2) {
            Text(searching ? "No matching transcript" : "Your transcripts appear here")
                .recordText(FWType.section)
                .foregroundStyle(FWColor.textPrimary)
            Text(searching
                ? "Clear the search to see all \(total.formatted()) transcripts."
                : "Each file you transcribe is saved on this Mac, ready to read, copy or export.")
                .recordText(FWType.body)
                .foregroundStyle(FWColor.textSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(width: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcriptDetail(entry: FileTranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: FWMetric.space2) {
                Text(entry.displayTitle)
                    .recordText(FWType.section)
                    .foregroundStyle(FWColor.textPrimary)
                    .lineLimit(2)
                    .editableTitle(entry.displayTitle, id: entry.id.uuidString) {
                        self.fileHistoryStore.renameEntry(id: entry.id, to: $0)
                    }
                Text(self.rowMetadata[entry.id]?.meta ?? "")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                HStack(spacing: FWMetric.space3) {
                    Button("Copy") { self.copyToClipboard(entry.text) }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                    Menu {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Button(format.rawValue) {
                                self.exportFormat = format
                                self.exportResult = entry.toTranscriptionResult()
                                self.showingExportDialog = true
                            }
                        }
                    } label: {
                        Text("Export…")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                    .fixedSize()
                    Button("Delete") { self.pendingDeleteEntry = entry }
                        .buttonStyle(RecordButtonStyle(kind: .destructive, size: FWMetric.sizeControlM))
                        .help("Delete transcript")
                        .accessibilityLabel("Delete transcript")
                }
                .padding(.top, FWMetric.space2)
            }
            .padding(EdgeInsets(top: FWMetric.space5, leading: FWMetric.space7, bottom: FWMetric.space4, trailing: FWMetric.space8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
            }
            if entry.speakerSegments.isEmpty {
                if entry.speakerLabelingNotice != nil {
                    self.speakerNotice
                        .padding(EdgeInsets(top: FWMetric.space5, leading: FWMetric.space7, bottom: 0, trailing: FWMetric.space8))
                }
                FileTranscriptTextView(entryID: entry.id, text: entry.text)
                    .padding(.trailing, FWMetric.space3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if entry.speakerLabelingNotice != nil {
                            self.speakerNotice
                                .padding(EdgeInsets(top: FWMetric.space5, leading: FWMetric.space7, bottom: FWMetric.space3, trailing: FWMetric.space8))
                        }
                        ForEach(entry.speakerSegments) { segment in
                            RecordLine {
                                Text(segment.speaker)
                                    .recordText(FWType.detailStrong)
                                    .foregroundStyle(FWColor.textPrimary)
                                Text(segment.timestampText)
                                    .recordText(FWType.small)
                                    .foregroundStyle(FWColor.textTertiary)
                            } content: {
                                Text(segment.text)
                                    .recordText(FWType.transcript)
                                    .foregroundStyle(FWColor.textPrimary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .id(entry.id)
            }
        }
        .background(FWColor.surfaceWindow)
    }

    private var speakerNotice: some View {
        HStack(spacing: FWMetric.space3) {
            Circle()
                .strokeBorder(FWColor.stateAttention, lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("Speaker labels were not available for this file. The transcript is complete without them.")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.stateAttention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helper Functions

    private static let supportedFileExtensions = FileTranscriptionService.supportedFileExtensions

    /// "42:18", or "1:02:03" from an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private static func metadata(for entry: FileTranscriptionEntry) -> RowMetadata {
        let relative = DateFormatter()
        relative.doesRelativeDateFormatting = true
        relative.dateStyle = .medium
        relative.timeStyle = .short
        let speakers = Set(entry.speakerSegments.map(\.speaker)).count
        let words = entry.text.split(whereSeparator: \.isWhitespace).count
        let date = entry.timestamp.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
        return RowMetadata(
            preview: entry.previewText,
            when: "\(relative.string(from: entry.timestamp))  ·  \(Self.clock(entry.duration))",
            meta: "\(date)  ·  \(Self.clock(entry.duration))  ·  \(speakers > 0 ? "\(speakers) speakers" : "\(words.formatted()) words")"
        )
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            guard let url = url else { return }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedFileExtensions.contains(ext) else {
                DispatchQueue.main.async {
                    let name = url.lastPathComponent
                    self.droppedUnsupportedName = name
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.droppedUnsupportedName == name { self.droppedUnsupportedName = nil }
                    }
                }
                return
            }
            DispatchQueue.main.async {
                self.selectedFileURL = url
                self.transcriptionService.reset()
                self.droppedUnsupportedName = nil
            }
        }
        return true
    }

    private func transcribeFile() async {
        guard let fileURL = selectedFileURL else { return }
        self.failure = nil
        do {
            _ = try await self.transcriptionService.transcribeFile(fileURL)
        } catch {
            self.failure = error as? FileTranscriptionService.TranscriptionError
            DebugLogger.shared.error("Transcription error: \(error)", source: "FileTranscriptionView")
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation {
            self.showingCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                self.showingCopyConfirmation = false
            }
        }
    }
}

// MARK: - Document for Export

struct TranscriptionDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText, .json]
    }

    let result: TranscriptionResult
    let format: FileTranscriptionView.ExportFormat
    let service: FileTranscriptionService

    init(
        result: TranscriptionResult,
        format: FileTranscriptionView.ExportFormat,
        service: FileTranscriptionService
    ) {
        self.result = result
        self.format = format
        self.service = service
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp.\(self.format.fileExtension)")

        switch self.format {
        case .text:
            try self.service.exportToText(self.result, to: tempURL)
        case .json:
            try self.service.exportToJSON(self.result, to: tempURL)
        }

        let data = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)

        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Preview

#Preview {
    let asrService = ASRService()
    FileTranscriptionView(
        asrService: asrService,
        transcriptionService: FileTranscriptionService(asrService: asrService)
    )
    .frame(width: 700, height: 800)
}
