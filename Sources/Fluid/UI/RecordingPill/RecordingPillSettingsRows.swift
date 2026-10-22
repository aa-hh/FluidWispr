import SwiftUI

/// The recording pill settings, shown at the top of the overlay card.
struct RecordingPillSettingsRows: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.row(title: "Pill shows", detail: "Keep the pill on screen, or show it only while you dictate") {
                FluidDropdownPicker("Pill shows", selectedTitle: self.settings.recordingPillVisibility.displayName, selection: self.$settings.recordingPillVisibility) {
                    ForEach(RecordingPillVisibility.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
            self.row(title: "Live words", detail: "Show what you say as you speak. Off shows your voice as a waveform") {
                FluidDropdownPicker("Live words", selectedTitle: self.settings.recordingPillLiveWords.displayName, selection: self.$settings.recordingPillLiveWords) {
                    ForEach(RecordingPillLiveWords.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
            self.row(title: "Pill size", detail: "How large the dictation pill is") {
                FluidDropdownPicker("Pill size", selectedTitle: self.settings.recordingPillSize.displayName, selection: self.$settings.recordingPillSize) {
                    ForEach(RecordingPillSize.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
            self.row(title: "Pill position", detail: "Where the pill rests. You can also drag it") {
                FluidDropdownPicker("Pill position", selectedTitle: self.settings.recordingPillDock.displayName, selection: self.$settings.recordingPillDock) {
                    ForEach(RecordingPillDock.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
        }
    }

    private func row<Picker: View>(title: String, detail: String, @ViewBuilder picker: () -> Picker) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(Color(nsColor: .labelColor))
                Text(detail)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.90) : self.theme.palette.primaryText.opacity(0.82))
            }
            Spacer()
            picker()
                .fluidDropdownStyle()
                .frame(width: 170, alignment: .trailing)
        }
    }
}
