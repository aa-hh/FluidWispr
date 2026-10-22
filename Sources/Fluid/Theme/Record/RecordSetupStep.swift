import SwiftUI

/// Record/Setup step: one 168 by 28 capsule in onboarding's step list, with a
/// trailing mark for its state.
struct RecordSetupStep: View {
    enum State {
        case current
        case done
        case next
        case needsYou
        case currentNeedsYou
        case working
    }

    let label: String
    let state: State

    var body: some View {
        HStack(spacing: FWMetric.space3) {
            Text(self.label)
                .recordText(FWType.body)
                .foregroundStyle(self.state == .next ? FWColor.textSecondary : FWColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let mark = self.mark {
                RecordMark(state: mark)
            }
        }
        .padding(.horizontal, FWMetric.space4)
        .frame(width: FWMetric.sizeMargin, height: FWMetric.sizeControlM)
        .background(Capsule().fill(self.isCurrent ? FWColor.surfaceSelected : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(self.isCurrent ? .isSelected : [])
    }

    private var isCurrent: Bool {
        self.state == .current || self.state == .currentNeedsYou
    }

    private var mark: RecordMark.State? {
        switch self.state {
        case .current, .next: nil
        case .done: .done
        case .needsYou, .currentNeedsYou: .needsYou
        case .working: .waiting
        }
    }
}
