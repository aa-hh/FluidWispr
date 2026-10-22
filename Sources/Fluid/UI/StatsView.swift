import SwiftUI

/// Stats: one scrolling ruled sheet. Every number comes from the cached snapshot,
/// which counts only dictations since the last stats reset; history is never touched.
struct StatsView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var statsStore = StatsSnapshotStore.shared
    @State private var statsOwner = UUID()
    @ObservedObject private var settings = SettingsStore.shared

    @State private var showResetConfirmation: Bool = false
    @State private var showShareSheet = false
    @State private var showWPMEditor: Bool = false
    @State private var editingWPM: String = ""
    private var stats: StatsSnapshot {
        (self.statsStore.snapshot ?? StatsSnapshot()).usingWeekdays(self.settings.weekendsDontBreakStreak)
    }

    /// While the speed popover holds a valid number, Time saved previews it; Cancel restores.
    private var typingWPM: Int {
        if self.showWPMEditor, let wpm = Int(self.editingWPM), wpm > 0 { return wpm }
        return self.settings.userTypingWPM
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                RecordHeader("Stats", subtitle: "Counted from your saved history, on this Mac.") {
                    Button("Share my stats…") { self.showShareSheet = true }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                        .disabled(self.statsStore.snapshot == nil)
                        .help("Make an image of your stats to post or send")
                }

                if self.statsStore.snapshot == nil {
                    HStack(spacing: FWMetric.space3) {
                        ProgressView().controlSize(.small).tint(FWColor.textTertiary)
                        Text("Loading your stats…")
                            .recordText(FWType.body)
                            .foregroundStyle(FWColor.textSecondary)
                    }
                    .padding(.leading, FWMetric.sizeMargin + FWMetric.space7)
                    .padding(.top, FWMetric.space7)
                } else {
                    self.todayLine
                    StatsActivityView(snapshot: self.stats)
                    self.allTimeSection
                    StatsHighlightsView(snapshot: self.stats)
                    self.startOverLine
                }
            }
            .padding(.top, FWMetric.space8)
            .padding(.bottom, FWMetric.space9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(FWColor.surfaceWindow)
        .sheet(isPresented: self.$showShareSheet) {
            StatsShareSheet(content: self.shareContent) { self.showShareSheet = false }
        }
        .onAppear { self.statsStore.activate(self.statsOwner) }
        .onDisappear { self.statsStore.deactivate(self.statsOwner) }
    }

    private var shareContent: StatsShareContent {
        StatsShareContent(
            totalWords: self.stats.totalWords,
            timeSaved: self.stats.formattedTimeSaved(typingWPM: self.settings.userTypingWPM),
            currentStreak: self.stats.currentStreak,
            totalTranscriptions: self.stats.totalTranscriptions,
            keystrokesSaved: self.stats.totalCharacters,
            aiPolishRate: self.stats.aiEnhancementRate,
            talkingWordsPerMinute: self.stats.talkingWordsPerMinute,
            biggestDayWords: self.stats.mostWordsInDay,
            longestDictationWords: self.stats.longestTranscriptionWords,
            activity: self.stats.dailyWordCounts(days: 30).map(\.words)
        )
    }

    // MARK: - Today

    private var todayLine: some View {
        let words = self.todayWords
        let milestone = StatsDailyMilestone(words: words)
        return RecordLine {
            StatsMargin("Today", Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space4) {
                HStack(alignment: .firstTextBaseline, spacing: FWMetric.space4) {
                    Text(words == 0 ? "No words yet today" : "\(words.formatted()) words")
                        .recordText(FWType.title)
                        .foregroundStyle(FWColor.textPrimary)
                    Text(words == 0 ? "Press the dictation key, talk, then press it again." : self.todaySummary(words: words))
                        .recordText(FWType.body)
                        .foregroundStyle(FWColor.textSecondary)
                }
                VStack(alignment: .leading, spacing: FWMetric.space3) {
                    HStack {
                        Text(self.milestoneText(milestone))
                            .recordText(FWType.detail)
                            .foregroundStyle(FWColor.textSecondary)
                        Spacer(minLength: FWMetric.space4)
                        if milestone.nextTarget != nil {
                            Text("\(Int(milestone.progress * 100))%")
                                .recordText(FWType.detailStrong)
                                .foregroundStyle(FWColor.textPrimary)
                        }
                    }
                    RecordProgressLine(fraction: milestone.progress)
                }
            }
        }
    }

    /// Today's words come from the snapshot, so a stats reset clears them at once.
    private var todayWords: Int {
        guard let last = self.stats.activity.last, Calendar.current.isDateInToday(last.date) else { return 0 }
        return last.words
    }

    private func todaySummary(words: Int) -> String {
        let count = self.stats.todayTranscriptions
        var parts = [count == 1 ? "1 dictation" : "\(count.formatted()) dictations"]
        parts.append("about \(Self.duration(minutes: Self.savedMinutes(words: words, typingWPM: self.typingWPM))) saved")
        if self.stats.currentStreak > 0 {
            parts.append("\(self.stats.currentStreak)-day streak")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func milestoneText(_ milestone: StatsDailyMilestone) -> String {
        guard let target = milestone.nextTarget else { return "Every daily milestone reached today" }
        if milestone.words == 0 { return "\(target.formatted()) words to your first milestone" }
        return "\(milestone.remaining.formatted()) words to \(target.formatted()) today"
    }

    // MARK: - All time

    private var allTimeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordSectionLine(heading: "All time", detail: self.allTimeDetail)
            self.timeSavedLine
            self.valueLine("Words", value: self.stats.totalWords.formatted(), explanation: "Spoken instead of typed.")
            self.valueLine(
                "Dictations",
                value: self.stats.totalTranscriptions.formatted(),
                explanation: "\(self.stats.averageWordsPerTranscription.formatted()) words each on average."
            )
            self.valueLine(
                "Fixed by cleanup",
                value: "\(self.stats.fluidFixedWords.formatted()) words",
                explanation: "Spelling, punctuation and filler words tidied for you."
            )
            self.valueLine("Keystrokes saved", value: self.stats.totalCharacters.formatted(), explanation: "Keys you never had to press.")
            self.valueLine("Streak", value: Self.days(self.stats.currentStreak), explanation: self.streakExplanation)
        }
    }

    private var allTimeDetail: String? {
        if let reset = self.settings.statsResetDate {
            return "Since you reset on \(reset.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
        return self.stats.firstDictationDate.map { "Since your first dictation on \($0.formatted(.dateTime.day().month(.abbreviated).year()))" }
    }

    private var streakExplanation: String {
        let best = "Best \(Self.days(self.stats.bestStreak))."
        return self.settings.weekendsDontBreakStreak ? "\(best) Weekends do not break it." : best
    }

    private var timeSavedLine: some View {
        let minutes = Self.savedMinutes(words: self.stats.totalWords, typingWPM: self.typingWPM)
        return RecordLine {
            StatsMargin("Time saved")
        } content: {
            HStack(alignment: .center, spacing: FWMetric.space4) {
                Text(Self.duration(minutes: minutes, alwaysHours: true))
                    .recordText(FWType.section)
                    .foregroundStyle(FWColor.textPrimary)
                Text("Compared with typing at \(self.typingWPM) words a minute.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                Button("Change speed…") {
                    self.editingWPM = "\(self.settings.userTypingWPM)"
                    self.showWPMEditor = true
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                .popover(isPresented: self.$showWPMEditor, arrowEdge: .bottom) {
                    self.wpmEditorPopover
                }
            }
        }
    }

    private var wpmEditorPopover: some View {
        VStack(alignment: .leading, spacing: FWMetric.space4) {
            Text("Your typing speed")
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)

            HStack(spacing: FWMetric.space3) {
                RecordField(placeholder: "45", text: self.$editingWPM)
                    .multilineTextAlignment(.center)
                    .frame(width: 56)
                    .accessibilityLabel("Typing speed in words a minute")
                Text("words a minute")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }

            Text("Most people type about 40. Fast typists reach 65 to 75. Time saved updates as you type.")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: FWMetric.space3) {
                Spacer(minLength: 0)
                Button("Cancel") { self.showWPMEditor = false }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let wpm = Int(self.editingWPM), wpm > 0 {
                        self.settings.userTypingWPM = wpm
                    }
                    self.showWPMEditor = false
                }
                .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(FWMetric.space5)
        .frame(width: 260)
        .background(FWColor.surfaceRaised)
    }

    private func valueLine(_ name: String, value: String, explanation: String) -> some View {
        RecordLine {
            StatsMargin(name)
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: FWMetric.space4) {
                Text(value)
                    .recordText(FWType.section)
                    .foregroundStyle(FWColor.textPrimary)
                Text(explanation)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }
        }
    }

    // MARK: - Start over

    private var startOverLine: some View {
        RecordLine(showsRule: false) {
            StatsMargin("Start over")
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space2) {
                Text("Sets every number on this page back to zero. Your \(self.historyStore.entries.count.formatted()) dictations stay in History.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                Button("Reset stats…") { self.showResetConfirmation = true }
                    .buttonStyle(RecordButtonStyle(kind: .destructive, size: FWMetric.sizeControlM))
                    .disabled(self.stats.totalTranscriptions == 0)
            }
        }
        .alert("Reset your stats?", isPresented: self.$showResetConfirmation) {
            Button("Reset stats", role: .destructive) {
                self.settings.statsResetDate = Date()
                self.statsStore.resetDateChanged()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every number on this page goes back to zero. Your history, dictionary and settings stay. You cannot undo this.")
        }
    }

    // MARK: - Helpers

    static func savedMinutes(words: Int, typingWPM: Int) -> Double {
        typingWPM > 0 ? max(0, Double(words) / Double(typingWPM) - Double(words) / 150) : 0
    }

    /// "26 min", "1 h 5 min"; `alwaysHours` gives "0 h 0 min" for the All time row.
    static func duration(minutes: Double, alwaysHours: Bool = false) -> String {
        let total = Int(minutes)
        if total < 60, !alwaysHours { return "\(total) min" }
        return "\(total / 60) h \(total % 60) min"
    }

    static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count.formatted()) days"
    }
}

/// The margin of a Stats line: a Label name and an optional Detail line under it.
struct StatsMargin: View {
    let name: String
    let detail: String?

    init(_ name: String, _ detail: String? = nil) {
        self.name = name
        self.detail = detail
    }

    var body: some View {
        Text(self.name)
            .recordText(FWType.label)
            .foregroundStyle(FWColor.textPrimary)
        if let detail = self.detail {
            Text(detail)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    StatsView()
        .frame(width: 816, height: 800)
}
