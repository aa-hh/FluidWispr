import SwiftUI

/// Record/Sidebar item: a 28 pt capsule row with the label at the left and an
/// optional count (tabular figures) or mark at the right.
struct RecordSidebarItem: View {
    let label: String
    var count: Int?
    var mark: RecordMark.State?
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: FWMetric.space3) {
                Text(self.label)
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count = self.count {
                    Text("\(count)")
                        .recordText(FWType.small)
                        .foregroundStyle(FWColor.textTertiary)
                }
                if let mark = self.mark {
                    RecordMark(state: mark)
                }
            }
        }
        .buttonStyle(RecordSidebarItemStyle(isSelected: self.isSelected))
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}

private struct RecordSidebarItemStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RecordSidebarItemBody(label: configuration.label, isSelected: self.isSelected)
    }
}

private struct RecordSidebarItemBody<Label: View>: View {
    let label: Label
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        self.label
            .padding(.horizontal, FWMetric.space4)
            .frame(maxWidth: .infinity, minHeight: FWMetric.sizeControlM, maxHeight: FWMetric.sizeControlM)
            .background(Capsule().fill(self.fill))
            .contentShape(Capsule())
            .recordFocusRing(self.isFocused, in: Capsule())
            .focusEffectDisabled()
            .onHover { self.isHovered = $0 }
            .animation(.easeInOut(duration: FWMotion.durationSnap), value: self.isHovered)
    }

    private var fill: Color {
        if self.isSelected { return FWColor.surfaceSelected }
        return self.isHovered ? FWColor.surfaceHover : .clear
    }
}
