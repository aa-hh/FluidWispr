import SwiftUI

/// One entry in a `RecordSidebar` group.
struct RecordSidebarEntry<ID: Hashable>: Identifiable {
    let id: ID
    let label: String
    var count: Int?
    var mark: RecordMark.State?
    var isSelected = false
}

/// One headed group in a `RecordSidebar`.
struct RecordSidebarGroup<ID: Hashable>: Identifiable {
    let heading: String
    let items: [RecordSidebarEntry<ID>]

    var id: String { self.heading }
}

/// Record/Sidebar: the 184 pt source list. It draws nothing for the window
/// buttons; its content starts below the title bar area.
struct RecordSidebar<ID: Hashable, Header: View, Footer: View>: View {
    let groups: [RecordSidebarGroup<ID>]
    let onSelect: (ID) -> Void
    let header: Header
    let footer: Footer

    init(
        groups: [RecordSidebarGroup<ID>],
        onSelect: @escaping (ID) -> Void,
        @ViewBuilder header: () -> Header = { EmptyView() },
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.groups = groups
        self.onSelect = onSelect
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FWMetric.space1) {
            self.header
            ForEach(self.groups) { group in
                Text(group.heading)
                    .recordText(FWType.smallStrong)
                    .foregroundStyle(FWColor.textTertiary)
                    .padding(.leading, FWMetric.space4)
                    .padding(.top, FWMetric.space4)
                    .padding(.bottom, FWMetric.space2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.items) { item in
                    RecordSidebarItem(label: item.label, count: item.count, mark: item.mark, isSelected: item.isSelected) {
                        self.onSelect(item.id)
                    }
                }
            }
            Spacer(minLength: 0)
            self.footer
        }
        .padding(.top, FWMetric.space5)
        .padding(.horizontal, FWMetric.space3)
        .frame(width: FWMetric.sizeSidebar)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(FWColor.surfaceSidebar)
    }
}
