import SwiftUI

/// Record/Progress line: a 2 pt track in the rule colour with the done part in ink.
/// The caller sets the width (320 in onboarding, 240 in Settings).
struct RecordProgressLine: View {
    /// 0 to 1.
    let fraction: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(FWColor.lineRule)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(FWColor.ink)
                        .frame(width: proxy.size.width * min(max(self.fraction, 0), 1))
                }
            }
            .frame(height: 2)
            .accessibilityElement()
            .accessibilityValue("\(Int((min(max(self.fraction, 0), 1) * 100).rounded())) percent")
    }
}
