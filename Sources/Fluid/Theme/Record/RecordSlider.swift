import SwiftUI

/// Slider (Settings, sound volume): 160 pt wide, a 4 pt strong-line track filled
/// with ink up to a 16 pt raised knob. Left and right arrows step it when focused.
struct RecordSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    private static let width: CGFloat = 160
    private static let knob: CGFloat = 16

    var body: some View {
        let span = self.range.upperBound - self.range.lowerBound
        let fraction = span > 0 ? min(max((self.value - self.range.lowerBound) / span, 0), 1) : 0
        let travel = Self.width - Self.knob
        ZStack(alignment: .leading) {
            Capsule().fill(FWColor.lineStrong).frame(height: 4)
            Capsule().fill(FWColor.actionPrimary).frame(width: Self.knob / 2 + travel * fraction, height: 4)
            Circle()
                .fill(FWColor.surfaceRaised)
                .overlay { Circle().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline) }
                .frame(width: Self.knob, height: Self.knob)
                .recordFocusRing(self.isFocused && self.isEnabled, in: Circle())
                .offset(x: travel * fraction)
        }
        .frame(width: Self.width, height: Self.knob)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { drag in
                let position = min(max((drag.location.x - Self.knob / 2) / travel, 0), 1)
                self.value = self.range.lowerBound + span * position
            }
        )
        .focusable()
        .focused(self.$isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { self.step(-span / 20) }
        .onKeyPress(.rightArrow) { self.step(span / 20) }
        .opacity(self.isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Slider(value: self.$value, in: self.range) { Text(self.label) }
        }
    }

    private func step(_ delta: Double) -> KeyPress.Result {
        self.value = min(max(self.value + delta, self.range.lowerBound), self.range.upperBound)
        return .handled
    }
}
