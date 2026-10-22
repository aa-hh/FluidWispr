import Combine
import SwiftUI

enum DictionaryWordWizardStep: Equatable {
    case spelling, recording, review, saved, manual

    var position: Int {
        switch self {
        case .spelling: 1
        case .recording, .manual: 2
        case .review, .saved: 3
        }
    }
}

/// One recorded take, in the order it was said. Display only; saving uses the variants.
struct DictionaryWordTake: Equatable {
    let heard: String
    let duration: TimeInterval?
    let heardRight: Bool
}

/// One task at a time. Recording and persistence remain with the existing dictionary services.
struct DictionaryWordWizard: View {
    @Binding var word: String
    let step: DictionaryWordWizardStep
    let count: Int
    let heard: String
    let variants: [String]
    let busy: Bool
    let recording: Bool
    let processing: Bool
    let starting: Bool
    let error: String?
    let voiceSupported: Bool
    let alreadyCorrect: Bool
    let savedWord: String
    let onContinue: () -> Void
    let onRecord: () -> Void
    let onSave: () -> Void
    let onBack: () -> Void
    let onNewWord: () -> Void
    let onManual: () -> Void
    let onPracticeMore: () -> Void
    var onRedo: () -> Void = {}
    var automaticCaptureActive = false
    var pronunciationNotice: String?
    var pronunciationIncomplete = false
    var takes: [DictionaryWordTake] = []
    /// How long the last attempt ran, for a take that ended in an issue.
    var attemptDuration: TimeInterval?
    var voiceSampleCount = 0
    /// Dictation is running into a text field (not a training capture).
    var fieldDictating = false
    var savedEntry: SettingsStore.CustomDictionaryEntry?
    var onDictionary: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var wordFocused: Bool
    @State private var showingRecordingTips = false
    @State private var playgroundBusy = false
    @State private var confirmingRedo = false
    @State private var confirmingWordChange = false
    @State private var pendingWord = ""

    var body: some View {
        Group {
            switch self.step {
            case .spelling: self.spellingPage
            case .recording, .review: self.capturePage
            case .saved: self.savedPage
            case .manual: EmptyView()
            }
        }
        .overlay(alignment: .top) { self.alertLayer }
        .task(id: self.step) { self.wordFocused = self.step == .spelling }
    }

    // MARK: - Step 1

    private var isDictatingIntoField: Bool {
        self.fieldDictating && self.wordFocused
    }

    private var canContinue: Bool {
        !self.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.isDictatingIntoField
    }

    private var spellingHint: String {
        let hint = SettingsStore.shared.dictationKeyHint
        if self.isDictatingIntoField {
            return hint.holds
                ? "Listening. Let go of \(hint.key) to put the words in this field."
                : "Listening. Press \(hint.key) again to put the words in this field."
        }
        return hint.holds ? "Type it, or hold \(hint.key) and say it." : "Type it, or press \(hint.key) and say it."
    }

    private var spellingPage: some View {
        DictionaryPage(back: self.onDictionary) {
            RecordHeader("Add a word", subtitle: "Step 1 of 3 · Which word does FluidWispr get wrong?")
            RecordLine {
                self.marginLabel("Word", detail: "The spelling you want.")
            } content: {
                RecordField(placeholder: "For example, Anthropic", text: Binding(get: { self.word }, set: { value in
                    if self.count >= 1, value != self.word {
                        self.pendingWord = value
                        self.confirmingWordChange = true
                    } else { self.word = value }
                }))
                .frame(width: 320)
                .focused(self.$wordFocused)
                .dictionaryDictationInput(focused: self.wordFocused)
                .accessibilityLabel("Word to learn")
                .onSubmit { if self.canContinue { self.onContinue() } }
                Text(self.spellingHint)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textTertiary)
            }
            RecordLine {
                EmptyView()
            } content: {
                Button("Continue", action: self.onContinue)
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                    .disabled(!self.canContinue)
            }
        }
    }

    // MARK: - Steps 2 and 3

    private enum ReviewState {
        case ready, alreadyRight, saving, failed(String), voiceUnfinished
    }

    private var reviewState: ReviewState {
        if self.alreadyCorrect { return .alreadyRight }
        if self.busy { return .saving }
        if let error { return .failed(error) }
        if self.pronunciationIncomplete { return .voiceUnfinished }
        return .ready
    }

    private var captureSubtitle: String {
        guard self.step == .review else {
            let thirdTakeLive = self.count == 2 && self.recording && !self.starting && !self.processing
            return thirdTakeLive ? "Step 2 of 3 · One more" : "Step 2 of 3 · Say it three times"
        }
        switch self.reviewState {
        case .ready: return "Step 3 of 3 · Ready to save"
        case .alreadyRight: return "Step 3 of 3 · It already sounds right"
        case .saving: return "Step 3 of 3 · Saving"
        case .failed: return "Step 3 of 3 · Not saved"
        case .voiceUnfinished: return "Step 3 of 3 · Spellings ready"
        }
    }

    private var capturePage: some View {
        DictionaryPage(back: self.onDictionary) {
            RecordHeader("Add a word", subtitle: self.captureSubtitle) {
                HStack(spacing: FWMetric.space3) {
                    Button(self.showingRecordingTips ? "Hide tips" : "Tips") {
                        withAnimation(FWMotion.motion(reduced: self.reduceMotion)) { self.showingRecordingTips.toggle() }
                    }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                    Button("Change word", action: self.onBack)
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                        .disabled(self.busy)
                }
            }
            RecordLine {
                self.marginLabel("Word")
            } content: {
                Text(self.word)
                    .recordText(FWType.title)
                    .foregroundStyle(FWColor.textPrimary)
                Text(self.step == .review ? "Three takes recorded." : "Say only the word in your normal voice, then wait. Recording stops on its own.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.showingRecordingTips {
                self.tipsLine
            }
            ForEach(0..<self.takeRowCount, id: \.self) { index in
                self.takeLine(index)
            }
            if self.step == .review {
                self.reviewLine
            }
            RecordLine {
                EmptyView()
            } content: {
                HStack(spacing: FWMetric.space3) {
                    if self.step == .review {
                        self.reviewButtons
                    } else {
                        self.recordButtons
                    }
                }
                if let note = self.actionsNote {
                    Text(note)
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textTertiary)
                }
            }
            if self.step == .recording {
                RecordLine(showsRule: false) {
                    Text("Prefer typing?")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                } content: {
                    Button("Add manually", action: self.onManual)
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                        .disabled(self.busy)
                }
            }
        }
    }

    private var tipsLine: some View {
        RecordLine {
            self.marginLabel("Tips")
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space2) {
                Group {
                    Text("1   Say only the word. No sentence needed.")
                    Text("2   Wait when you finish. Recording stops on its own.")
                    Text("3   Speak again when the next take says Listening.")
                }
                .recordText(FWType.body)
                .foregroundStyle(FWColor.textPrimary)
                Text("A quiet room and your usual distance from the microphone work best.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }
        }
    }

    // MARK: - Take rows

    private enum TakeRow {
        case waiting, gettingReady, live, checking
        case heard(DictionaryWordTake)
        case issue(String)
    }

    /// Takes in order. Callers that only pass counts get rows rebuilt from the variants.
    private var shownTakes: [DictionaryWordTake] {
        // `count` is the number of takes, not a collection.
        // swiftlint:disable:next empty_count
        guard self.takes.isEmpty, self.count > 0 else { return self.takes }
        return (0..<self.count).map { index in
            let heard = index < self.variants.count ? self.variants[index] : self.word
            return DictionaryWordTake(heard: heard, duration: nil, heardRight: heard.caseInsensitiveCompare(self.word) == .orderedSame)
        }
    }

    private var currentAttempt: TakeRow? {
        guard self.step == .recording else { return nil }
        if self.starting { return .gettingReady }
        if self.processing { return .checking }
        if self.recording { return .live }
        if let error { return .issue(error) }
        return nil
    }

    private var takeRowCount: Int {
        max(3, self.shownTakes.count + (self.currentAttempt == nil ? 0 : 1))
    }

    private func takeRow(_ index: Int) -> TakeRow {
        let takes = self.shownTakes
        if index < takes.count { return .heard(takes[index]) }
        if index == takes.count, let current = self.currentAttempt { return current }
        return .waiting
    }

    private func takeLine(_ index: Int) -> some View {
        let row = self.takeRow(index)
        return RecordLine {
            Text("Take \(index + 1)")
                .recordText(FWType.detailStrong)
                .foregroundStyle(self.labelColor(row))
            if let mark = self.mark(row) {
                RecordMark(state: mark)
            }
            if let time = self.time(row) {
                Text(time)
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textTertiary)
            }
        } content: {
            switch row {
            case .waiting:
                Text("Waiting")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textTertiary)
            case .gettingReady:
                Text("Getting ready…")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            case .live:
                HStack(spacing: FWMetric.space4) {
                    RecordingPillPreview(state: .listen, size: .medium)
                    Text("Listening. Say “\(self.word)”.")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textPrimary)
                }
            case .checking:
                Text("Checking what was heard…")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            case let .heard(take):
                Text(take.heardRight ? self.word : take.heard)
                    .recordText(FWType.transcript)
                    .foregroundStyle(FWColor.textPrimary)
                Text(take.heardRight ? "Heard right." : "Heard differently. Saved as a spelling to fix.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            case let .issue(message):
                Text(message)
                    .recordText(FWType.detailStrong)
                    .foregroundStyle(FWColor.stateAttention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityLabel(row, number: index + 1))
    }

    private func labelColor(_ row: TakeRow) -> Color {
        switch row {
        case .waiting: FWColor.textTertiary
        case .issue: FWColor.stateAttention
        default: FWColor.textSecondary
        }
    }

    private func mark(_ row: TakeRow) -> RecordMark.State? {
        switch row {
        case .waiting, .gettingReady, .checking: .waiting
        case .live: nil
        case let .heard(take): take.heardRight ? .done : .captured
        case .issue: .needsYou
        }
    }

    private func time(_ row: TakeRow) -> String? {
        let seconds: TimeInterval? = switch row {
        case let .heard(take): take.duration
        case .issue: self.attemptDuration
        default: nil
        }
        guard let seconds else { return nil }
        let whole = max(1, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func accessibilityLabel(_ row: TakeRow, number: Int) -> String {
        switch row {
        case .waiting: "Take \(number), waiting"
        case .gettingReady: "Take \(number), getting ready"
        case .live: "Take \(number), listening"
        case .checking: "Take \(number), checking what was heard"
        case let .heard(take):
            take.heardRight ? "Take \(number), heard right" : "Take \(number), heard \(take.heard), saved as a spelling to fix"
        case let .issue(message): "Take \(number), \(message)"
        }
    }

    // MARK: - Step 3 outcome and actions

    @ViewBuilder
    private var reviewLine: some View {
        switch self.reviewState {
        case .ready, .saving:
            if !self.variants.isEmpty {
                RecordLine {
                    self.marginLabel("Will fix")
                } content: {
                    Text("\(Self.quotedList(self.variants)) will become “\(self.word)” in every dictation.")
                        .recordText(FWType.body)
                        .foregroundStyle(FWColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .alreadyRight:
            RecordLine {
                HStack(spacing: FWMetric.space2) {
                    RecordMark(state: .done)
                    Text("No fix needed")
                        .recordText(FWType.detailStrong)
                        .foregroundStyle(FWColor.stateDone)
                }
            } content: {
                Text("FluidWispr heard “\(self.word)” correctly in all three takes. Nothing needs saving.")
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .failed(message):
            RecordLine {
                HStack(spacing: FWMetric.space2) {
                    RecordMark(state: .needsYou)
                    Text("Not saved")
                        .recordText(FWType.detailStrong)
                        .foregroundStyle(FWColor.stateAttention)
                }
            } content: {
                Text(message)
                    .recordText(FWType.detailStrong)
                    .foregroundStyle(FWColor.stateAttention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .voiceUnfinished:
            RecordLine {
                self.marginLabel("Voice")
                Text("\(self.voiceSampleCount) of 3 samples")
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textTertiary)
            } content: {
                Text(self.pronunciationNotice ?? "")
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var captureActive: Bool {
        self.automaticCaptureActive || self.recording || self.processing || self.starting
    }

    private var canRecordMore: Bool {
        self.count < CustomDictionaryTrainingMerge.maxSamples
    }

    @ViewBuilder
    private var recordButtons: some View {
        let title = DictionaryCaptureAction.title(active: self.captureActive, failed: self.error != nil, count: self.count)
        if self.captureActive {
            Button(title, action: self.onRecord)
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                .disabled(self.processing || self.starting)
        } else {
            self.primaryButton(title, action: self.onRecord)
            if self.count >= 1 {
                self.redoButton
            }
        }
    }

    @ViewBuilder
    private var reviewButtons: some View {
        switch self.reviewState {
        case .ready, .saving:
            self.primaryButton(self.busy ? "Saving…" : "Add “\(self.word)” to dictionary", action: self.onSave)
                .disabled(self.busy)
            self.recordMoreButton
            self.redoButton
        case .alreadyRight:
            self.primaryButton("Test it in a sentence", action: self.onSave)
            self.recordMoreButton
        case .failed:
            self.primaryButton("Add manually", action: self.onManual)
            Button("Try saving again", action: self.onSave)
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
            self.redoButton
        case .voiceUnfinished:
            self.primaryButton("Save spelling corrections", action: self.onSave)
                .disabled(self.busy)
            self.recordMoreButton
            self.redoButton
        }
    }

    private var actionsNote: String? {
        guard self.step == .review, self.canRecordMore else { return nil }
        switch self.reviewState {
        case .ready, .saving: return "Record more is optional. It helps with tricky words."
        case .voiceUnfinished: return "Record more is needed to finish voice learning."
        case .alreadyRight, .failed: return nil
        }
    }

    @ViewBuilder
    private var recordMoreButton: some View {
        if self.canRecordMore {
            Button("Record more", action: self.onRecord)
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                .disabled(self.busy)
        }
    }

    private var redoButton: some View {
        Button("Redo takes") { self.confirmingRedo = true }
            .buttonStyle(RecordButtonStyle(kind: .destructive, size: FWMetric.sizeControlM))
            .disabled(self.busy)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
            .keyboardShortcut(.defaultAction)
    }

    // MARK: - Word saved

    private var savedSentence: String {
        let triggers = (self.savedEntry?.triggers ?? []).filter { $0.caseInsensitiveCompare(self.savedWord) != .orderedSame }
        guard !triggers.isEmpty else { return "“\(self.savedWord)” is in your dictionary." }
        return "\(Self.quotedList(triggers)) now become\(triggers.count == 1 ? "s" : "") “\(self.savedWord)”."
    }

    private var savedPage: some View {
        DictionaryPage(back: self.onDictionary) {
            RecordHeader("Test “\(self.savedWord)”", subtitle: self.savedEntry.map { "Saved to your dictionary as No. \($0.number)" })
            RecordLine {
                HStack(spacing: FWMetric.space2) {
                    RecordMark(state: .done)
                    Text("Saved")
                        .recordText(FWType.detailStrong)
                        .foregroundStyle(FWColor.stateDone)
                }
            } content: {
                Text(self.savedSentence)
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
            }
            DictionaryWordPlayground(word: self.savedWord, onPracticeMore: self.onPracticeMore, busy: self.$playgroundBusy, onNewWord: self.onNewWord)
        }
    }

    // MARK: - Parts

    private func marginLabel(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: FWMetric.space1) {
            Text(title)
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
            if let detail {
                Text(detail)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// “a”, “b” and “c”
    static func quotedList(_ items: [String]) -> String {
        let quoted = items.map { "“\($0)”" }
        guard quoted.count > 1 else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + quoted[quoted.count - 1]
    }

    @ViewBuilder
    private var alertLayer: some View {
        if self.confirmingWordChange {
            self.modal {
                RecordAlert(
                    title: "Change the word?",
                    message: "The \(self.count) \(self.count == 1 ? "take" : "takes") you recorded for “\(self.word)” will be discarded.",
                    layout: .sideBySide,
                    width: 300,
                    cancel: .init(label: "Cancel", kind: .secondary) { self.confirmingWordChange = false },
                    action: .init(label: "Change word", kind: .destructive) {
                        self.confirmingWordChange = false
                        self.word = self.pendingWord
                    }
                )
            }
        } else if self.confirmingRedo {
            self.modal {
                RecordAlert(
                    title: "Discard these takes and start again?",
                    message: "Your word stays the same. Words already in your dictionary are unchanged.",
                    layout: .sideBySide,
                    width: 300,
                    cancel: .init(label: "Cancel", kind: .secondary) { self.confirmingRedo = false },
                    action: .init(label: "Redo takes", kind: .destructive) {
                        self.confirmingRedo = false
                        self.onRedo()
                    }
                )
            }
        }
    }

    private func modal(@ViewBuilder _ alert: () -> some View) -> some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
            alert().padding(.top, FWMetric.space9)
        }
    }
}

enum DictionaryRingResponse {
    static func energy(for level: CGFloat) -> Double {
        guard level.isFinite else { return 0 }
        return sqrt(Double(min(1, max(0, level))))
    }
}

/// Three translucent sheets fan wide and pinch loosely; lines inside a sheet never cross, so the ring reads as silk, not rope.
private struct DictionaryRingArtwork: View, Animatable {
    let phase: Double
    var progress: Double
    var energy: Double
    var glow: Double
    let accent: Color
    let rest: Color
    let additive: Bool

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(self.progress, AnimatablePair(self.energy, self.glow)) }
        set {
            self.progress = newValue.first
            self.energy = newValue.second.first
            self.glow = newValue.second.second
        }
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let lit = min(1, max(0, self.glow) * 0.7 + self.energy * 0.5)
            let shading = GraphicsContext.Shading.conicGradient(
                Gradient(stops: self.stops),
                center: CGPoint(x: rect.midX, y: rect.midY),
                angle: .degrees(-90)
            )
            let paths = (0..<DictionaryRibbon.sheets).flatMap { sheet in
                (0..<7).map { line in
                    DictionaryRibbon(phase: self.phase, strand: Double(line - 3) * 4 / 3, energy: self.energy, sheet: sheet).path(in: rect)
                }
            }
            if self.additive { context.blendMode = .plusLighter }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 5 + lit * 5))
                layer.opacity = 0.3 + lit * 0.35
                for path in paths {
                    layer.stroke(path, with: shading, lineWidth: 1.6 + lit * 0.8)
                }
            }
            context.opacity = 0.5 + lit * 0.3
            for path in paths {
                context.stroke(path, with: shading, lineWidth: 0.7 + lit * 0.25)
            }
        }
    }

    /// The learned arc fades into the resting color instead of ending on a hard edge.
    private var stops: [Gradient.Stop] {
        let learned = self.accent
        let resting = self.rest.opacity(0.55)
        guard self.progress > 0.001 else { return [.init(color: resting, location: 0), .init(color: resting, location: 1)] }
        guard self.progress < 0.999 else { return [.init(color: learned, location: 0), .init(color: learned, location: 1)] }
        let fade = 0.1
        let start = max(0, self.progress - fade / 2)
        let end = min(1, max(start, self.progress + fade / 2))
        let seam = max(end, 1 - fade)
        return [
            .init(color: learned, location: 0),
            .init(color: learned, location: start),
            .init(color: resting, location: end),
            .init(color: resting, location: seam),
            .init(color: learned, location: 1),
        ]
    }
}

struct DictionaryRibbon: Shape {
    static let sheets = 3

    let phase: Double
    let strand: Double
    let energy: Double
    var sheet = 0

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) * 0.34
        let offset = Double(self.sheet) * 2.1
        let lobes = Double([3, 2, 4][self.sheet % 3])
        let drift = self.sheet.isMultiple(of: 2) ? self.phase : -self.phase
        let spread = self.strand / 4
        return Path { path in
            for sample in 0...180 {
                let angle = Double(sample) / 180 * .pi * 2
                let center = 1 + sin(angle * 3 + offset + self.phase) * 0.05 + sin(angle * 2 + offset * 0.6 - self.phase) * 0.03 + self.energy * 0.02
                // The sheet twists through a loose pinch, then opens into a wide veil; speech opens it further.
                let width = cos(angle * lobes + offset + drift) * (0.11 + self.energy * 0.05) + 0.018
                let distance = radius * (center + spread * width)
                let point = CGPoint(
                    x: rect.midX + CGFloat(cos(angle)) * distance,
                    y: rect.midY + CGFloat(sin(angle)) * distance
                )
                if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}

/// Uses normal shortcut dictation, accepting output only for a capture begun in this editor.
/// Draws the "Try it" line and, with `onNewWord`, the "Add another word" line.
struct DictionaryWordPlayground: View {
    let word: String
    let onPracticeMore: () -> Void
    @Binding var busy: Bool
    var onNewWord: (() -> Void)?
    @EnvironmentObject private var appServices: AppServices
    @FocusState private var editorFocused: Bool
    @State private var test = DictionaryShortcutTestState()

    private var placeholder: String {
        switch self.test.phase {
        case .recording: return "Listening…"
        case .processing: return "Checking…"
        case .idle:
            let hint = SettingsStore.shared.dictationKeyHint
            return "\(hint.holds ? "Hold" : "Press") \(hint.key) and say a sentence with “\(self.word)”."
        }
    }

    private var instruction: String {
        let hint = SettingsStore.shared.dictationKeyHint
        return hint.holds
            ? "Click the box, hold \(hint.key), say a sentence with the word, then let go."
            : "Click the box, press \(hint.key), say a sentence with the word, then press it again."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordLine {
                Text("Try it")
                    .recordText(FWType.label)
                    .foregroundStyle(FWColor.textPrimary)
                Text(self.instruction)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } content: {
                RecordField(placeholder: self.placeholder, text: Binding(get: { self.test.text }, set: { self.test.edit($0) }), size: .multi)
                    .frame(width: 420, height: 112)
                    .focused(self.$editorFocused)
                    .accessibilityLabel("Dictionary test text")
                self.result
            }
            if let onNewWord = self.onNewWord {
                RecordLine {
                    EmptyView()
                } content: {
                    Button("Add another word", action: onNewWord)
                        .buttonStyle(RecordButtonStyle(kind: self.test.result == .recognized ? .primary : .secondary, size: FWMetric.sizeControlM))
                        .disabled(self.busy)
                }
            }
        }
        .task(id: self.word) {
            self.test = DictionaryShortcutTestState()
            self.editorFocused = true
            self.busy = false
        }
        .onReceive(self.appServices.asr.$isRunning.dropFirst()) { running in
            if running {
                self.test.begin(editorFocused: self.editorFocused, appActive: NSApp.isActive, dictionaryCapture: self.appServices.asr.isDictionaryTrainingCaptureActive)
            } else {
                self.test.stopped()
            }
            self.busy = self.test.phase != .idle
        }
        .onReceive(self.appServices.asr.dictionaryTestAudioPublisher) { samples in
            self.test.receiveAudio(samples)
        }
        .onReceive(self.appServices.asr.$finalText.dropFirst()) { text in
            // Start clears shared output; only the final, nonempty value belongs to a test result.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.test.receive(text, word: self.word)
            self.busy = self.test.phase != .idle
        }
        .onReceive(self.appServices.asr.$showError.dropFirst()) { failed in
            if failed, let attempt = self.test.attemptID {
                self.test.expire(attempt)
                self.busy = false
            }
        }
        .task(id: self.test.phase == .processing ? self.test.attemptID : nil) {
            guard self.test.phase == .processing, let attempt = self.test.attemptID else { return }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self.test.expire(attempt)
            self.busy = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            self.test.cancel()
            self.busy = false
        }
        .onDisappear {
            self.test.cancel()
            self.busy = false
        }
    }

    @ViewBuilder
    private var result: some View {
        switch self.test.result {
        case .recognized:
            HStack(spacing: FWMetric.space2) {
                RecordMark(state: .done)
                Text("“\(self.word)” recognized" + (self.test.successes > 1 ? " · \(self.test.successes) times" : ""))
                    .recordText(FWType.detailStrong)
                    .foregroundStyle(FWColor.stateDone)
            }
        case .missed:
            HStack(spacing: FWMetric.space3) {
                Text("We didn’t catch “\(self.word)”. Try again, or record more examples.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                Button("Record more examples", action: self.onPracticeMore)
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                    .disabled(self.busy)
            }
        case .empty:
            Text("No words came through. Try \(SettingsStore.shared.dictationKeyHint.key) again.")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
        case .none:
            EmptyView()
        }
    }
}
