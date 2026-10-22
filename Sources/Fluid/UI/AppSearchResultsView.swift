import SwiftUI

/// Grouped search results shown in place of the sidebar sections while the search
/// box has text. Each category independently toggles between a preview and all hits.
struct AppSearchResultsView: View {
    static let rowsPerGroup = 5

    @ObservedObject var service: AppSearchService
    @Binding var cursor: AppSearchHit.Target?
    @Binding var expanded: Set<AppSearchKind>
    let open: (AppSearchHit) -> Void

    /// The rows on screen, in order, for keyboard movement.
    static func visibleHits(_ groups: [AppSearchGroup], expanded: Set<AppSearchKind>) -> [AppSearchHit] {
        groups.flatMap { group in
            expanded.contains(group.kind) ? group.hits : Array(group.hits.prefix(self.rowsPerGroup))
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: FWMetric.space1) {
                    if self.service.isSearching {
                        self.note("Searching…")
                    } else if let error = self.service.searchError {
                        VStack(alignment: .leading, spacing: FWMetric.space2) {
                            Text(error)
                                .recordText(FWType.detail)
                                .foregroundStyle(FWColor.textSecondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Retry") { self.service.retry() }
                                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FWMetric.space4)
                        .padding(.vertical, FWMetric.space2)
                    } else if self.service.groups.isEmpty {
                        self.note("No results")
                    }
                    ForEach(self.service.groups) { group in
                        self.groupHeader(group)
                            .id(group.kind)
                        let shown = self.expanded.contains(group.kind) ? group.hits : Array(group.hits.prefix(Self.rowsPerGroup))
                        ForEach(shown) { hit in
                            self.row(hit)
                        }
                        if group.hits.count > Self.rowsPerGroup {
                            RecordSidebarItem(
                                label: self.expanded.contains(group.kind) ? "Show less" : "Show more (\(group.hits.count - Self.rowsPerGroup))"
                            ) {
                                let wasExpanded = self.expanded.contains(group.kind)
                                self.toggle(group)
                                if wasExpanded { proxy.scrollTo(group.kind, anchor: .top) }
                            }
                            .accessibilityLabel("\(self.expanded.contains(group.kind) ? "Show fewer" : "Show all") \(group.kind.title) results")
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: self.cursor) { _, target in
                target.map { proxy.scrollTo($0) }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .recordText(FWType.detail)
            .foregroundStyle(FWColor.textSecondary)
            .padding(.horizontal, FWMetric.space4)
            .padding(.vertical, FWMetric.space2)
    }

    @ViewBuilder
    private func groupHeader(_ group: AppSearchGroup) -> some View {
        let heading = Text(group.kind.title)
            .recordText(FWType.smallStrong)
            .foregroundStyle(FWColor.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, FWMetric.space4)
            .padding(.top, FWMetric.space4)
            .padding(.bottom, FWMetric.space2)
        if group.hits.count > Self.rowsPerGroup {
            Button { self.toggle(group) } label: {
                heading.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.kind.title) results")
            .accessibilityValue(self.expanded.contains(group.kind) ? "Expanded, \(group.hits.count) results" : "Showing \(Self.rowsPerGroup) of \(group.hits.count) results")
            .accessibilityHint(self.expanded.contains(group.kind) ? "Show fewer results" : "Show all results")
        } else {
            heading.accessibilityAddTraits(.isHeader)
        }
    }

    private func toggle(_ group: AppSearchGroup) {
        guard group.hits.count > Self.rowsPerGroup else { return }
        if self.expanded.remove(group.kind) == nil {
            self.expanded.insert(group.kind)
        } else if let cursor = self.cursor,
                  group.hits.dropFirst(Self.rowsPerGroup).contains(where: { $0.target == cursor })
        {
            self.cursor = nil
        }
    }

    private func row(_ hit: AppSearchHit) -> some View {
        RecordSidebarItem(label: hit.title, isSelected: self.cursor == hit.target) {
            self.open(hit)
        }
        .help(String(hit.snippet.characters))
        .accessibilityHint(String(hit.snippet.characters))
        .onHover {
            if $0 {
                self.cursor = hit.target
            }
        }
        .id(hit.id)
    }
}
