import AppKit
import SwiftUI

/// Record/Code well: a sunken well of SF Mono 12 on 18, for commands in Command Mode.
struct RecordCodeWell: View {
    let code: String

    private static let lineSpacing: CGFloat = max(0, 18 - NSLayoutManager().defaultLineHeight(for: NSFont.fluidMonospacedSystemFont(ofSize: 12, weight: .regular)))

    var body: some View {
        Text(self.code)
            .font(.fluidSystem(size: 12, design: .monospaced))
            .lineSpacing(Self.lineSpacing)
            .foregroundStyle(FWColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, FWMetric.space3)
            .padding(.horizontal, FWMetric.space4)
            .background(RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous).fill(FWColor.surfaceSunken))
    }
}
