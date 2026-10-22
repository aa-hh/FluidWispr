import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The numbers available to the shareable stats image. Totals only: no transcript text,
/// app names or times of day ever leave the Mac through this card.
struct StatsShareContent {
    let totalWords: Int
    let timeSaved: String
    let currentStreak: Int
    let totalTranscriptions: Int
    let keystrokesSaved: Int
    let aiPolishRate: Int
    let talkingWordsPerMinute: Int?
    let biggestDayWords: Int
    let longestDictationWords: Int
    let activity: [Int]

    /// A paperback page holds roughly 275 words.
    var pagesEquivalent: Int { self.totalWords / 275 }

    var headline: String {
        if self.pagesEquivalent >= 300 {
            let novels = Double(self.pagesEquivalent) / 300
            return String(format: "About %.1f novels, spoken instead of typed.", novels)
        }
        if self.pagesEquivalent >= 2 {
            return "About \(self.pagesEquivalent) book pages, spoken instead of typed."
        }
        return "Spoken instead of typed."
    }
}

/// A stat the user can switch on or off for their card.
enum StatsShareStat: String, CaseIterable, Identifiable {
    case keystrokes, timeSaved, streak, dictations, aiPolish, talkingSpeed, biggestDay, longestDictation

    static let maxSelected = 4
    static let defaults: [StatsShareStat] = [.keystrokes, .timeSaved, .streak, .dictations]

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .keystrokes: return "Keystrokes saved"
        case .timeSaved: return "Time saved"
        case .streak: return "Streak"
        case .dictations: return "Dictations"
        case .aiPolish: return "AI cleanup"
        case .talkingSpeed: return "Talking speed"
        case .biggestDay: return "Biggest day"
        case .longestDictation: return "Longest dictation"
        }
    }

    /// Talking speed needs measured audio; everything else is always available.
    func isAvailable(in content: StatsShareContent) -> Bool {
        self != .talkingSpeed || content.talkingWordsPerMinute != nil
    }

    func value(in content: StatsShareContent) -> String {
        switch self {
        case .keystrokes: return Self.compact(content.keystrokesSaved)
        case .timeSaved:
            // Once it is hours, the minutes are noise on a share card.
            return content.timeSaved.split(separator: " ").first { $0.hasSuffix("h") }.map(String.init) ?? content.timeSaved
        case .streak: return "\(content.currentStreak)"
        case .dictations: return content.totalTranscriptions.formatted()
        case .aiPolish: return "\(content.aiPolishRate)%"
        case .talkingSpeed: return "\(content.talkingWordsPerMinute ?? 0)"
        case .biggestDay: return content.biggestDayWords.formatted()
        case .longestDictation: return content.longestDictationWords.formatted()
        }
    }

    var label: String {
        switch self {
        case .keystrokes: return "keys never pressed"
        case .timeSaved: return "time saved"
        case .streak: return "day streak"
        case .dictations: return "dictations"
        case .aiPolish: return "cleaned up by AI"
        case .talkingSpeed: return "words a minute"
        case .biggestDay: return "words in one day"
        case .longestDictation: return "words in one go"
        }
    }

    private static func compact(_ number: Int) -> String {
        number.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }
}

/// Fixed-size artwork rendered to an image at 2x. Near-black in both appearances.
struct StatsShareCard: View {
    static let size = CGSize(width: 600, height: 338)

    let content: StatsShareContent
    let stats: [StatsShareStat]
    let showsActivity: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: FWMetric.space3) {
                    Capsule()
                        .fill(FWColor.pillBody)
                        .overlay { Capsule().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline) }
                        .frame(width: 28, height: 10)
                    Text("FluidWispr")
                        .recordText(FWType.label)
                        .foregroundStyle(FWColor.textPrimary)
                }
                Spacer()
                Text(Date.now.formatted(.dateTime.month(.wide).year()))
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: FWMetric.space2) {
                Text(self.content.totalWords.formatted())
                    .font(.fluidSystem(size: 64, weight: .semibold))
                    .tracking(-1.28)
                    .monospacedDigit()
                    .frame(height: 72)
                    .foregroundStyle(FWColor.textPrimary)
                Text("words dictated")
                    .recordText(FWType.section)
                    .foregroundStyle(FWColor.textPrimary)
                Text(self.content.headline)
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textSecondary)
            }

            Spacer(minLength: 0)

            // Four long stats leave less room; the graph steps down to fewer days before it is dropped.
            ViewThatFits(in: .horizontal) {
                self.statsRow(activityDays: 30)
                self.statsRow(activityDays: 21)
                self.statsRow(activityDays: 14)
                self.statsRow(activityDays: 0)
            }
        }
        .padding(FWMetric.space8)
        .frame(width: Self.size.width, height: Self.size.height)
        .recordNearBlack()
        .clipShape(RoundedRectangle(cornerRadius: FWMetric.radiusContainer, style: .continuous))
    }

    private func statsRow(activityDays: Int) -> some View {
        HStack(alignment: .bottom, spacing: FWMetric.space7) {
            ForEach(self.stats) { stat in
                self.metric(stat)
            }
            Spacer(minLength: 0)
            if self.showsActivity, activityDays > 0 {
                self.sparkline(days: activityDays)
            }
        }
    }

    private func metric(_ stat: StatsShareStat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(stat.value(in: self.content))
                .recordText(FWType.title)
                .foregroundStyle(FWColor.textPrimary)
            Text(stat.label)
                .recordText(FWType.small)
                .foregroundStyle(FWColor.textSecondary)
        }
        .fixedSize()
    }

    private func sparkline(days: Int) -> some View {
        let activity = Array(self.content.activity.suffix(days))
        let peak = max(activity.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(activity.enumerated()), id: \.offset) { _, words in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(FWColor.textPrimary.opacity(words == 0 ? 0.2 : 0.9))
                    .frame(width: 3, height: words == 0 ? 3 : max(3, 40 * CGFloat(words) / CGFloat(peak)))
            }
        }
        .frame(height: 40, alignment: .bottom)
        .fixedSize()
    }
}

/// Live preview, the on/off chips that shape it, and the three ways out: share, copy, save.
struct StatsShareSheet: View {
    let content: StatsShareContent
    let close: () -> Void
    @AppStorage("StatsShareSelectedStats") private var storedSelection = ""
    @AppStorage("StatsShareShowsActivity") private var showsActivity = true
    @State private var copied = false

    /// Kept in the enum's order so the card layout is stable however chips were tapped.
    private var selection: [StatsShareStat] {
        let stored = self.storedSelection.split(separator: ",").compactMap { StatsShareStat(rawValue: String($0)) }
        let chosen = self.storedSelection.isEmpty ? StatsShareStat.defaults : stored
        return StatsShareStat.allCases.filter { chosen.contains($0) && $0.isAvailable(in: self.content) }
    }

    private var card: StatsShareCard {
        StatsShareCard(content: self.content, stats: self.selection, showsActivity: self.showsActivity)
    }

    private var image: NSImage? {
        let renderer = ImageRenderer(content: self.card)
        renderer.scale = 2
        // The card's colours follow the drawing appearance, so render it as Dark.
        var image: NSImage?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { image = renderer.nsImage }
        return image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FWMetric.space5) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: FWMetric.space1) {
                    Text("Share your stats")
                        .recordText(FWType.section)
                        .foregroundStyle(FWColor.textPrimary)
                    Text("An image of your totals. No words, app names or times leave your Mac.")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                }
                Spacer()
                Button("Done", action: self.close)
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                    .keyboardShortcut(.cancelAction)
            }

            self.card
                .overlay {
                    RoundedRectangle(cornerRadius: FWMetric.radiusContainer, style: .continuous)
                        .strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline)
                        .environment(\.colorScheme, .dark)
                }

            VStack(alignment: .leading, spacing: FWMetric.space3) {
                Text("Show on the card, up to \(StatsShareStat.maxSelected)")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                FlowChips(spacing: FWMetric.space3) {
                    ForEach(StatsShareStat.allCases.filter { $0.isAvailable(in: self.content) }) { stat in
                        let isOn = self.selection.contains(stat)
                        self.chip(stat.title, isOn: isOn, isEnabled: isOn || self.selection.count < StatsShareStat.maxSelected) {
                            self.toggle(stat)
                        }
                    }
                    self.chip("Activity graph", isOn: self.showsActivity, isEnabled: true) {
                        self.showsActivity.toggle()
                    }
                }
            }

            HStack(spacing: FWMetric.space3) {
                if let image {
                    ShareLink(
                        item: Image(nsImage: image),
                        preview: SharePreview("My FluidWispr stats", image: Image(nsImage: image))
                    ) {
                        Text("Share…")
                    }
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                }
                Button(self.copied ? "Copied" : "Copy image", action: self.copy)
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                Button("Save as PNG…", action: self.save)
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                if self.copied {
                    Text("Image copied. Paste it anywhere.")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.stateDone)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(FWMetric.space6)
        .frame(width: 640)
        .background(FWColor.surfaceWindow)
        .onChange(of: self.storedSelection) { _, _ in self.copied = false }
        .onChange(of: self.showsActivity) { _, _ in self.copied = false }
    }

    private func chip(_ title: String, isOn: Bool, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .recordText(FWType.detailStrong)
                .foregroundStyle(isEnabled ? FWColor.textPrimary : FWColor.textTertiary)
                .padding(.horizontal, FWMetric.space4)
                .frame(height: FWMetric.sizeControlM)
                .background { if isOn { Capsule().fill(FWColor.surfaceSelected) } }
                .overlay { if !isOn { Capsule().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func toggle(_ stat: StatsShareStat) {
        var chosen = self.selection
        if let index = chosen.firstIndex(of: stat) {
            chosen.remove(at: index)
        } else if chosen.count < StatsShareStat.maxSelected {
            chosen.append(stat)
        }
        // An empty string means "defaults", so keep an explicit marker when everything is off.
        self.storedSelection = chosen.isEmpty ? "none" : chosen.map(\.rawValue).joined(separator: ",")
    }

    private func copy() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        self.copied = true
    }

    private func save() {
        guard let image,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "FluidWispr stats.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}

/// Wrapping row for the option chips.
private struct FlowChips: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = self.rows(in: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * self.spacing
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in self.rows(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + self.spacing
            }
            y += row.height + self.spacing
        }
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if var last = rows.last, last.width + self.spacing + size.width <= width {
                last.indices.append(index)
                last.width += self.spacing + size.width
                last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
