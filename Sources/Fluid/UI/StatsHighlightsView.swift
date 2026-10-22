import SwiftUI

/// Next milestones, How you use it and Personal bests, derived only from the cached Stats snapshot.
struct StatsHighlightsView: View {
    let snapshot: StatsSnapshot
    @State private var hoveredApp: String?
    @State private var pinnedApp: String?
    @State private var hoveredHour: Int?
    @State private var pinnedHour: Int?

    private var focusedApp: String? { self.hoveredApp ?? self.pinnedApp }
    private var focusedHour: Int? { self.hoveredHour ?? self.pinnedHour }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordSectionLine(
                heading: "Next milestones",
                detail: "\(self.snapshot.totalMilestonesAchieved) of \(self.snapshot.totalMilestonesPossible) reached"
            )
            self.milestoneLine(
                "Words spoken",
                value: "\(self.snapshot.totalWords.formatted()) words",
                current: self.snapshot.totalWords,
                milestones: self.snapshot.wordMilestones
            ) { "\($0.formatted()) to \($1.formatted()) words" }
            self.milestoneLine(
                "Dictations",
                value: "\(self.snapshot.totalTranscriptions.formatted()) dictations",
                current: self.snapshot.totalTranscriptions,
                milestones: self.snapshot.transcriptionMilestones
            ) { "\($0.formatted()) to \($1.formatted()) dictations" }
            self.milestoneLine(
                "Best streak",
                value: StatsView.days(self.snapshot.bestStreak),
                current: self.snapshot.bestStreak,
                milestones: self.snapshot.streakMilestones
            ) { "\($0.formatted()) to a \($1)-day streak" }

            RecordSectionLine(heading: "How you use it", detail: "Patterns across your saved history")
            self.appsLine
            self.hoursLine

            RecordSectionLine(heading: "Personal bests")
            self.bestLine(
                "Longest dictation",
                value: "\(self.snapshot.longestTranscriptionWords.formatted()) words",
                explanation: ["in one go", self.snapshot.longestTranscriptionDate.map(StatsActivityView.shortDate)].compactMap { $0 }.joined(separator: ", ")
            )
            self.bestLine(
                "Biggest day",
                value: "\(self.snapshot.mostWordsInDay.formatted()) words",
                explanation: self.snapshot.mostWordsInDayDate.map { "on \(StatsActivityView.shortDate($0))" } ?? ""
            )
            self.bestLine(
                "Busiest day",
                value: "\(self.snapshot.mostTranscriptionsInDay.formatted()) dictations",
                explanation: self.snapshot.mostTranscriptionsInDayDate.map { "on \(StatsActivityView.shortDate($0))" } ?? ""
            )
        }
        .onExitCommand {
            self.pinnedApp = nil
            self.pinnedHour = nil
        }
    }

    // MARK: - Milestones

    private func milestoneLine(
        _ name: String,
        value: String,
        current: Int,
        milestones: [(target: Int, achieved: Bool, label: String)],
        remaining: (Int, Int) -> String
    ) -> some View {
        let next = milestones.first { !$0.achieved }
        return RecordLine {
            StatsMargin(name)
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space3) {
                HStack(alignment: .firstTextBaseline, spacing: FWMetric.space4) {
                    Text(value)
                        .recordText(FWType.section)
                        .foregroundStyle(FWColor.textPrimary)
                    Text(next.map { remaining($0.target - current, $0.target) } ?? "Every milestone reached")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                }
                HStack(spacing: FWMetric.space2) {
                    ForEach(milestones.indices, id: \.self) { index in
                        let milestone = milestones[index]
                        Rectangle()
                            .fill(milestone.achieved ? FWColor.textPrimary : FWColor.lineRule)
                            .frame(height: 2)
                            .help("\(milestone.label): \(milestone.achieved ? "reached" : "not reached yet")")
                            .accessibilityLabel("\(milestone.label), \(milestone.achieved ? "reached" : "not reached")")
                    }
                }
            }
        }
    }

    // MARK: - Where your words go

    private var appsLine: some View {
        RecordLine {
            StatsMargin("Where your words go", self.appCaption)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if self.snapshot.topAppUsage.isEmpty {
                    Text("Dictate into an app to see it here.")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                } else {
                    ForEach(self.snapshot.topAppUsage, id: \.name) { app in
                        self.appRow(name: app.name, sessions: app.sessions)
                    }
                }
            }
            .padding(.bottom, FWMetric.space2)
        }
    }

    private func appRow(name: String, sessions: Int) -> some View {
        let share = Double(sessions) / Double(max(1, self.snapshot.totalTranscriptions))
        let top = Double(max(1, self.snapshot.topAppUsage.first?.sessions ?? 1))
        return Button {
            self.pinnedApp = self.pinnedApp == name ? nil : name
        } label: {
            HStack(spacing: FWMetric.space5) {
                Text(name)
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .leading)
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(FWColor.textTertiary)
                        .frame(width: geometry.size.width * Double(sessions) / top, height: 4)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 4)
                .accessibilityHidden(true)
                Text("\(sessions.formatted())  ·  \(Int((share * 100).rounded()))%")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .frame(width: 88, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { active in
            if active {
                self.hoveredApp = name
            } else if self.hoveredApp == name {
                self.hoveredApp = nil
            }
        }
        .opacity(self.focusedApp == nil || name == self.focusedApp ? 1 : 0.35)
        .accessibilityElement(children: .combine)
    }

    private var appCaption: String {
        guard let app = self.snapshot.topAppUsage.first(where: { $0.name == self.focusedApp }) else {
            return "Click an app to pin it"
        }
        return "\(app.name)  ·  \(app.sessions.formatted()) of \(self.snapshot.totalTranscriptions.formatted()) dictations"
    }

    // MARK: - Time of day

    private var hoursLine: some View {
        let hours = self.snapshot.hourlySessions
        let peak = hours.max() ?? 0
        return RecordLine {
            StatsMargin("Time of day", "Dictations per hour")
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space4) {
                if let caption = self.hourCaption {
                    Text(caption)
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: FWMetric.space2) {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(hours.indices, id: \.self) { hour in
                            let count = hours[hour]
                            let isPeak = count > 0 && count == peak
                            let focused = self.focusedHour == hour
                            ZStack(alignment: .bottom) {
                                Color.clear
                                if count > 0 {
                                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                        .fill(isPeak || focused ? FWColor.textPrimary : FWColor.textTertiary)
                                        .frame(height: CGFloat(count) / CGFloat(max(1, peak)) * 80)
                                        .opacity(self.focusedHour == nil || focused ? 1 : 0.35)
                                }
                            }
                            .frame(width: 16, height: 88)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering {
                                    self.hoveredHour = hour
                                } else if self.hoveredHour == hour {
                                    self.hoveredHour = nil
                                }
                            }
                            .onTapGesture { self.pinnedHour = self.pinnedHour == hour ? nil : hour }
                            .accessibilityElement()
                            .accessibilityLabel(String(format: "%02d:00", hour))
                            .accessibilityValue("\(count) dictations")
                        }
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
                    }
                    HStack(spacing: 0) {
                        ForEach([0, 6, 12, 18], id: \.self) { hour in
                            Text(String(format: "%02d:00", hour))
                                .frame(width: 24 * 6, alignment: .leading)
                        }
                    }
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textSecondary)
                }
                HStack(spacing: FWMetric.space7) {
                    Text("\(self.snapshot.aiEnhancementRate)% cleaned up by AI")
                    Text("\(self.snapshot.averageWordsPerTranscription.formatted()) words per dictation")
                }
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
            }
            .padding(.bottom, FWMetric.space2)
        }
    }

    private var hourCaption: String? {
        let hours = self.snapshot.hourlySessions
        if let hour = self.focusedHour, hours.indices.contains(hour) {
            return String(format: "%02d:00–%02d:00", hour, hour + 1) + "  ·  \(hours[hour].formatted()) dictations"
        }
        guard let peak = hours.max(), peak > 0, let hour = hours.firstIndex(of: peak) else { return nil }
        return String(format: "Most dictations land between %02d:00 and %02d:00.", hour, hour + 1)
    }

    // MARK: - Personal bests

    private func bestLine(_ name: String, value: String, explanation: String) -> some View {
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
}
