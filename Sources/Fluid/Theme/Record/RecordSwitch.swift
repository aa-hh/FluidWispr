import SwiftUI

/// Record/Switch: a 34 by 20 capsule with a 16 pt knob. Space toggles it when focused.
struct RecordSwitch: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        Button { self.isOn.toggle() } label: { EmptyView() }
            .buttonStyle(RecordSwitchStyle(isOn: self.isOn))
            .accessibilityRepresentation {
                Toggle(self.label, isOn: self.$isOn)
            }
    }
}

private struct RecordSwitchStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration _: Configuration) -> some View {
        RecordSwitchBody(isOn: self.isOn)
    }
}

private struct RecordSwitchBody: View {
    let isOn: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: self.isOn ? .trailing : .leading) {
            Capsule()
                .fill(self.isOn ? FWColor.actionPrimary : FWColor.surfaceSunken)
                .overlay {
                    if !self.isOn {
                        Capsule().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline)
                    }
                }
            if self.reduceMotion {
                // A new identity per side, so the knob fades across instead of travelling.
                self.knob.id(self.isOn).transition(.opacity)
            } else {
                self.knob
            }
        }
        .frame(width: 34, height: 20)
        .contentShape(Capsule())
        .recordFocusRing(self.isFocused && self.isEnabled, in: Capsule())
        .focusEffectDisabled()
        .opacity(self.isEnabled ? 1 : 0.4)
        .animation(FWMotion.motion(reduced: self.reduceMotion), value: self.isOn)
    }

    private var knob: some View {
        Circle()
            .fill(self.isOn ? FWColor.actionOnPrimary : FWColor.textTertiary)
            .frame(width: 16, height: 16)
            .padding(FWMetric.space1)
    }
}
