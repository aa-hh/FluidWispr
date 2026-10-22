import AppKit
import SwiftUI

struct CommandSessionSidebar: View {
    @ObservedObject var history = ChatHistoryStore.shared
    let canChangeSession: Bool
    let blockingReason: String?
    let onNewSession: () -> Void
    let onSelect: (String) -> Void
    let onArchive: (String) -> Void
    let onRestore: (String) -> Void

    @State private var searchText = ""
    @State private var rows: [SessionRow] = []
    @State private var scope = SessionScope.active
    @State private var keyboardSessionID: String?
    @FocusState private var listFocused: Bool

    private struct SessionRow: Identifiable, Equatable {
        let id: String
        let title: String
        let preview: String
        let relativeTime: String
        let group: SessionGroup
        let isArchived: Bool
    }

    private enum SessionGroup: String, CaseIterable {
        case today = "Today"
        case yesterday = "Yesterday"
        case older = "Older"
    }

    private enum SessionScope: String, CaseIterable {
        case active = "Active"
        case archived = "Archived"

        var isArchived: Bool { self == .archived }
    }

    private struct SessionPresentation: Equatable {
        let row: SessionRow
        let selected: Bool
        let keyboardSelected: Bool
        let enabled: Bool
        let blockingReason: String?
    }

    /// A session keeps one identity across date groups. Every rendered value is part of the item.
    private enum SessionListItem: Identifiable, Equatable {
        case heading(SessionGroup)
        case session(SessionPresentation)

        var id: String {
            switch self {
            case let .heading(group): "heading:\(group.rawValue)"
            case let .session(presentation): presentation.row.id
            }
        }
    }

    private var filteredRows: [SessionRow] {
        let scopedRows = self.rows.filter { $0.isArchived == self.scope.isArchived }
        let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scopedRows }
        return scopedRows.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            if self.filteredRows.isEmpty {
                self.emptyState
            } else {
                self.sessionList
            }
            if !self.canChangeSession, let blockingReason {
                Text(blockingReason)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FWMetric.space5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FWColor.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command sessions")
        .onChange(of: self.scope) { _, _ in self.keyboardSessionID = nil }
        .onChange(of: self.searchText) { _, _ in self.keyboardSessionID = nil }
        .onReceive(self.history.$sessions) { self.refreshRows(from: $0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.refreshRows(from: self.history.sessions)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FWMetric.space4) {
            HStack {
                Text("Sessions")
                    .recordText(FWType.section)
                    .foregroundStyle(FWColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: FWMetric.space3)
                Button("New session") {
                    guard self.canChangeSession else { return }
                    self.scope = .active
                    self.searchText = ""
                    self.onNewSession()
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                .disabled(!self.canChangeSession)
                .help(self.blockingReason ?? "Start a new session")
            }
            RecordPopUp(self.scopeTitle(self.scope)) {
                Picker("Session history view", selection: self.$scope) {
                    ForEach(SessionScope.allCases, id: \.self) { scope in
                        Text(self.scopeTitle(scope)).tag(scope)
                    }
                }
                .pickerStyle(.inline)
            }
            .accessibilityLabel("Session history view")
            RecordField(placeholder: "Search sessions", text: self.$searchText)
                .accessibilityLabel("Search session titles and previews")
        }
        .padding(EdgeInsets(top: FWMetric.space8, leading: FWMetric.space5, bottom: FWMetric.space4, trailing: FWMetric.space5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
        }
    }

    private func scopeTitle(_ scope: SessionScope) -> String {
        "\(scope.rawValue) (\(self.rows.filter { $0.isArchived == scope.isArchived }.count))"
    }

    private var sessionList: some View {
        let filtered = self.filteredRows
        let currentID = self.history.currentChatID
        let enabled = self.canChangeSession
        let blockingReason = self.blockingReason
        let items = SessionGroup.allCases.flatMap { group -> [SessionListItem] in
            let groupedRows = filtered.filter { $0.group == group }
            guard !groupedRows.isEmpty else { return [] }
            return [.heading(group)] + groupedRows.map {
                .session(SessionPresentation(
                    row: $0,
                    selected: $0.id == currentID,
                    keyboardSelected: $0.id == self.keyboardSessionID,
                    enabled: enabled,
                    blockingReason: blockingReason
                ))
            }
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case let .heading(group):
                            Text(group.rawValue)
                                .recordText(FWType.small)
                                .foregroundStyle(FWColor.textSecondary)
                                .padding(EdgeInsets(top: FWMetric.space4, leading: FWMetric.space3, bottom: FWMetric.space2, trailing: FWMetric.space3))
                                .accessibilityAddTraits(.isHeader)
                        case let .session(presentation):
                            SessionRowView(
                                row: presentation.row,
                                selected: presentation.selected,
                                keyboardSelected: presentation.keyboardSelected,
                                canChangeSession: presentation.enabled,
                                blockingReason: presentation.blockingReason,
                                onSelect: self.openSession,
                                onArchive: self.onArchive,
                                onRestore: self.onRestore
                            )
                        }
                    }
                }
                .padding(EdgeInsets(top: FWMetric.space2, leading: FWMetric.space3, bottom: FWMetric.space3, trailing: FWMetric.space3))
            }
            .focusable()
            .focusEffectDisabled()
            .focused(self.$listFocused)
            .onMoveCommand { direction in
                guard self.canChangeSession, direction == .up || direction == .down,
                      !filtered.isEmpty else { return }
                self.listFocused = true
                let focusedID = self.keyboardSessionID ?? self.history.currentChatID
                let currentIndex = filtered.firstIndex { $0.id == focusedID }
                let index: Int
                if let currentIndex {
                    index = min(filtered.count - 1, max(0, currentIndex + (direction == .down ? 1 : -1)))
                } else {
                    index = direction == .down ? 0 : filtered.count - 1
                }
                let row = filtered[index]
                self.keyboardSessionID = row.id
                // Browsing archived rows must not restore them. Return explicitly opens one.
                if !row.isArchived, row.id != self.history.currentChatID { self.onSelect(row.id) }
                proxy.scrollTo(row.id, anchor: .center)
            }
            .onKeyPress(.return) {
                guard self.listFocused, self.canChangeSession, let id = self.keyboardSessionID,
                      self.filteredRows.contains(where: { $0.id == id }) else { return .ignored }
                self.openSession(id)
                return .handled
            }
            .onChange(of: self.history.currentChatID) { _, id in
                guard let id, filtered.contains(where: { $0.id == id }) else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func openSession(_ id: String) {
        guard self.canChangeSession,
              let session = self.history.sessions.first(where: { $0.id == id }) else { return }
        self.keyboardSessionID = nil
        if session.isArchived {
            self.onRestore(id)
            guard self.history.sessions.first(where: { $0.id == id })?.isArchived == false else { return }
            self.scope = .active
        }
        self.onSelect(id)
    }

    private struct SessionRowView: View {
        let row: SessionRow
        let selected: Bool
        let keyboardSelected: Bool
        let canChangeSession: Bool
        let blockingReason: String?
        let onSelect: (String) -> Void
        let onArchive: (String) -> Void
        let onRestore: (String) -> Void

        @State private var hovered = false
        @FocusState private var focusedControl: RowControl?

        private enum RowControl: Hashable {
            case open
            case archive
        }

        private var showsActions: Bool { self.keyboardSelected || self.hovered || self.focusedControl != nil }
        private var actionTitle: String { self.row.isArchived ? "Restore session" : "Archive session" }
        private var openHint: String { self.row.isArchived ? "Restore and open this session" : "Open this session" }

        var body: some View {
            Button {
                guard self.canChangeSession else { return }
                self.onSelect(self.row.id)
            } label: {
                VStack(alignment: .leading, spacing: FWMetric.space1) {
                    HStack(spacing: FWMetric.space3) {
                        Text(self.row.title)
                            .recordText(self.selected ? FWType.label : FWType.body)
                            .foregroundStyle(FWColor.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(self.row.relativeTime)
                            .recordText(FWType.small)
                            .foregroundStyle(FWColor.textSecondary)
                            .fixedSize()
                            .opacity(self.showsActions ? 0 : 1)
                    }
                    Text(self.row.preview)
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .padding(FWMetric.space3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused(self.$focusedControl, equals: .open)
            .accessibilityAddTraits(self.selected ? .isSelected : [])
            .accessibilityHint(self.openHint)
            .help(self.blockingReason ?? self.openHint)
            .accessibilityAction(named: Text(self.actionTitle)) { self.performArchiveAction() }
            .editableTitle(self.row.title, id: self.row.id, enabled: self.canChangeSession) {
                ChatHistoryStore.shared.renameChat(id: self.row.id, to: $0)
            }
            .overlay(alignment: .trailing) {
                Button(action: self.performArchiveAction) {
                    Image(systemName: self.row.isArchived ? "arrow.uturn.backward" : "archivebox")
                        .font(FWType.body.font)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused(self.$focusedControl, equals: .archive)
                .foregroundStyle(FWColor.textSecondary)
                .opacity(self.showsActions ? 1 : 0)
                .allowsHitTesting(self.showsActions)
                .disabled(!self.showsActions)
                .accessibilityHidden(!self.showsActions)
                .accessibilityLabel("\(self.actionTitle): \(self.row.title)")
                .help(self.blockingReason ?? self.actionTitle)
                .padding(.trailing, FWMetric.space2)
            }
            .background(
                self.selected ? FWColor.surfaceSelected : (self.showsActions ? FWColor.surfaceHover : .clear),
                in: RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous)
            )
            .overlay(alignment: .bottom) {
                if !self.selected {
                    Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
                }
            }
            .contentShape(Rectangle())
            .onHover { self.hovered = $0 }
            .disabled(!self.canChangeSession)
        }

        private func performArchiveAction() {
            guard self.canChangeSession else { return }
            if self.row.isArchived { self.onRestore(self.row.id) } else { self.onArchive(self.row.id) }
        }
    }

    private var emptyState: some View {
        let isSearching = !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let title = isSearching ? "No matching \(self.scope.rawValue.lowercased()) sessions" : "No \(self.scope.rawValue.lowercased()) sessions"
        return VStack(alignment: .leading, spacing: FWMetric.space2) {
            Text(title)
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
            Text(isSearching ? "Try another title or phrase from the preview." : (self.scope.isArchived ? "Archived sessions stay here until you restore them." : "Start a new session to work with your Mac."))
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, FWMetric.space5)
        .padding(.horizontal, FWMetric.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Refresh a bounded presentation snapshot only when sessions change or the app becomes active.
    private func refreshRows(from sessions: [ChatSession]) {
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        self.rows = sessions.sorted { $0.updatedAt > $1.updatedAt }.map { session in
            let message = session.messages.last {
                ($0.role == .user || $0.role == .assistant) && $0.content.contains { !$0.isWhitespace }
            }
            let preview = message.map { String($0.content.prefix(180)).split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? ""
            let group: SessionGroup
            if calendar.isDate(session.updatedAt, inSameDayAs: now) {
                group = .today
            } else if let yesterday, calendar.isDate(session.updatedAt, inSameDayAs: yesterday) {
                group = .yesterday
            } else {
                group = .older
            }
            return SessionRow(
                id: session.id,
                title: session.title,
                preview: preview.isEmpty ? "No messages yet" : preview,
                relativeTime: formatter.localizedString(for: session.updatedAt, relativeTo: now),
                group: group,
                isArchived: session.isArchived
            )
        }
    }
}
