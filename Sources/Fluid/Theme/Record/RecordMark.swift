import SwiftUI

/// Record/Mark: the 12 pt state glyph in the margin, drawn rather than taken from
/// SF Symbols so the strokes stay at 1.2 to 1.5 pt.
struct RecordMark: View {
    enum State {
        case done
        case waiting
        case needsYou
        case retryFailed
        case working
        case live
        case captured
    }

    let state: State

    var body: some View {
        self.glyph
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch self.state {
        case .done:
            Self.tick.stroke(FWColor.stateDone, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        case .captured:
            Self.tick.stroke(FWColor.textSecondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        case .waiting:
            Self.ring(FWColor.textSecondary)
        case .needsYou:
            Self.ring(FWColor.stateAttention)
        case .retryFailed:
            Self.ring(FWColor.stateRetry)
        case .working:
            Rectangle().fill(FWColor.textSecondary).frame(width: 10, height: 2)
        case .live:
            Circle().fill(FWColor.liveIvory).frame(width: 8, height: 8)
        }
    }

    /// A tick about 9 by 6, centred in the 12 pt frame.
    private static let tick = Path { path in
        path.move(to: CGPoint(x: 1.5, y: 6))
        path.addLine(to: CGPoint(x: 4.5, y: 9))
        path.addLine(to: CGPoint(x: 10.5, y: 3))
    }

    private static func ring(_ color: Color) -> some View {
        Circle().strokeBorder(color, lineWidth: 1.2).frame(width: 8, height: 8)
    }
}
