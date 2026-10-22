import Charts
import SwiftUI

/// The Activity, Words add up and Weekly rhythm lines. Charts consume at most 180
/// cached daily totals; changing the range never reads history.
struct StatsActivityView: View {
    let snapshot: StatsSnapshot
    @State private var days = 30
    @State private var selectedDate: Date?
    @State private var hoveredDate: Date?
    @State private var hoveredWeekday: Int?
    @State private var pinnedWeekday: Int?

    private var period: StatsActivityPeriod {
        StatsActivityPeriod(activity: self.snapshot.dailyWordCounts(days: self.days), calendar: .current)
    }

    private var focusedDate: Date? { self.hoveredDate ?? self.selectedDate }
    private var focusedWeekday: Int? { self.hoveredWeekday ?? self.pinnedWeekday }

    var body: some View {
        let period = self.period
        VStack(alignment: .leading, spacing: 0) {
            self.activityLine(period)
            self.growthLine(period)
            self.rhythmLine(period)
        }
        .onChange(of: self.days) { _, _ in
            self.selectedDate = nil
            self.hoveredDate = nil
            self.hoveredWeekday = nil
            self.pinnedWeekday = nil
        }
        .onExitCommand {
            self.selectedDate = nil
            self.pinnedWeekday = nil
            self.hoveredDate = nil
        }
    }

    // MARK: - Activity

    private func activityLine(_ period: StatsActivityPeriod) -> some View {
        RecordLine {
            StatsMargin("Activity", "Words each day")
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space5) {
                HStack(alignment: .center) {
                    HStack(alignment: .firstTextBaseline, spacing: FWMetric.space3) {
                        Text("\(period.totalWords.formatted()) words")
                            .recordText(FWType.section)
                            .foregroundStyle(FWColor.textPrimary)
                        Text("in \(self.periodName)  ·  \(period.activeDays) active days")
                            .recordText(FWType.detail)
                            .foregroundStyle(FWColor.textSecondary)
                    }
                    Spacer(minLength: FWMetric.space4)
                    RecordSegmentedChoice(
                        options: [(30, "30 days"), (60, "60 days"), (90, "3 months"), (180, "6 months")],
                        selection: self.$days
                    )
                    .accessibilityLabel("Activity period")
                }
                HStack(alignment: .top, spacing: FWMetric.space7) {
                    StatsHeatmapView(period: period).id(self.days)
                    if self.days <= 60 {
                        self.dailyBars(period)
                    } else {
                        self.periodHighlights(period)
                    }
                }
                HStack(alignment: .center) {
                    Text(self.keyText(period))
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                    Spacer(minLength: FWMetric.space4)
                    HStack(spacing: FWMetric.space2) {
                        Text("Less")
                        ForEach(0..<5) { level in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(StatsHeatmapView.cellColor(level))
                                .frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                        }
                        Text("More")
                    }
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.textSecondary)
                }
            }
            .padding(.bottom, FWMetric.space3)
        }
    }

    private var periodName: String {
        switch self.days {
        case 90: "3 months"
        case 180: "6 months"
        default: "\(self.days) days"
        }
    }

    private func keyText(_ period: StatsActivityPeriod) -> String {
        if period.totalWords == 0 { return "Your first dictation fills in a square." }
        if self.days > 60 {
            let first = period.calendar.weekdaySymbols[period.calendar.firstWeekday - 1]
            return "Hover a square for the day. Weeks start on \(first)."
        }
        let perDay = period.totalWords / max(1, period.activeDays)
        return "Best day \(period.peakWords.formatted())  ·  \(perDay.formatted()) per active day"
    }

    private func periodHighlights(_ period: StatsActivityPeriod) -> some View {
        VStack(alignment: .leading, spacing: FWMetric.space6) {
            self.periodMetric("Best day", words: period.peakWords)
            self.periodMetric("Per active day", words: period.totalWords / max(1, period.activeDays))
        }
    }

    private func periodMetric(_ title: String, words: Int) -> some View {
        VStack(alignment: .leading, spacing: FWMetric.space1) {
            Text(title)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
            Text("\(words.formatted()) words")
                .recordText(FWType.section)
                .foregroundStyle(FWColor.textPrimary)
        }
    }

    // MARK: - Day by day bars

    private func dailyBars(_ period: StatsActivityPeriod) -> some View {
        let plot: CGFloat = 112
        let peak = max(1, period.peakWords)
        return GeometryReader { geometry in
            // 10 wide, 4 apart; narrower when 60 days would not fit.
            let pitch = min(14, geometry.size.width / CGFloat(max(1, period.days.count)))
            let width = pitch * 10 / 14
            VStack(alignment: .leading, spacing: FWMetric.space2) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(period.days) { day in
                        let focused = self.focusedDate == day.date
                        let isToday = period.calendar.isDateInToday(day.date)
                        ZStack(alignment: .bottom) {
                            Color.clear
                            if day.words > 0 {
                                UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                                    .fill(focused || isToday ? FWColor.textPrimary : FWColor.textTertiary)
                                    .frame(width: width, height: max(2, CGFloat(day.words) / CGFloat(peak) * (plot - 8)))
                                    .opacity(self.focusedDate == nil || focused ? 1 : 0.35)
                            }
                        }
                        .frame(width: pitch, height: plot)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if focused {
                                RecordChartTooltip(date: Self.weekdayDate(day.date), value: "\(day.words.formatted()) words")
                                    .fixedSize()
                                    .offset(y: -(max(2, CGFloat(day.words) / CGFloat(peak) * (plot - 8)) + FWMetric.space3))
                                    .allowsHitTesting(false)
                            }
                        }
                        .zIndex(focused ? 1 : 0)
                        .onHover { hovering in
                            if hovering {
                                self.hoveredDate = day.date
                            } else if self.hoveredDate == day.date {
                                self.hoveredDate = nil
                            }
                        }
                        .onTapGesture { self.selectedDate = self.selectedDate == day.date ? nil : day.date }
                        .accessibilityElement()
                        .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                        .accessibilityValue("\(day.words) words")
                    }
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
                }
                self.dateLabels(period.days.map(\.date), pitch: pitch)
            }
        }
        .frame(height: plot + FWMetric.space2 + 14)
        .frame(minWidth: 180)
    }

    /// First, middle and last day: the first left-aligned, the middle centred, the last right-aligned.
    private func dateLabels(_ dates: [Date], pitch: CGFloat?) -> some View {
        let picks = dates.isEmpty ? [] : [dates[0], dates[dates.count / 2], dates[dates.count - 1]]
        return ZStack {
            ForEach(Array(picks.enumerated()), id: \.offset) { index, date in
                Text(Self.shortDate(date))
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : (index == 2 ? .trailing : .center))
            }
        }
        .recordText(FWType.small)
        .foregroundStyle(FWColor.textSecondary)
        .frame(width: pitch.map { $0 * CGFloat(dates.count) })
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Words add up

    private func growthLine(_ period: StatsActivityPeriod) -> some View {
        let focused = self.focusedDay(period)
        let step = Self.gridStep(for: period.totalWords)
        let gridLines = period.totalWords == 0 ? [0] : (0...3).map { $0 * step }
        return RecordLine {
            StatsMargin("Words add up", "Running total")
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space4) {
                Text(self.growthCaption(period, focused: focused))
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .lineLimit(1)
                Chart {
                    ForEach(gridLines, id: \.self) { value in
                        RuleMark(y: .value("Words", value))
                            .foregroundStyle(FWColor.lineRule)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                    if period.totalWords > 0 {
                        ForEach(period.days) { day in
                            AreaMark(x: .value("Date", day.date), y: .value("Words", day.cumulativeWords))
                                .foregroundStyle(FWColor.textPrimary.opacity(0.08))
                            LineMark(x: .value("Date", day.date), y: .value("Words", day.cumulativeWords))
                                .foregroundStyle(FWColor.textPrimary)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                        if let last = period.days.last {
                            PointMark(x: .value("Date", last.date), y: .value("Words", last.cumulativeWords))
                                .opacity(0)
                                .annotation(position: .top, alignment: .trailing, spacing: FWMetric.space6) {
                                    Text(last.cumulativeWords.formatted())
                                        .recordText(FWType.smallStrong)
                                        .foregroundStyle(FWColor.textPrimary)
                                }
                        }
                        if let focused {
                            RuleMark(x: .value("Date", focused.date))
                                .foregroundStyle(FWColor.textSecondary.opacity(0.4))
                                .lineStyle(StrokeStyle(lineWidth: 1))
                            PointMark(x: .value("Date", focused.date), y: .value("Words", focused.cumulativeWords))
                                .symbol {
                                    Circle()
                                        .fill(FWColor.textPrimary)
                                        .frame(width: 10, height: 10)
                                        .overlay { Circle().strokeBorder(FWColor.surfaceWindow, lineWidth: 2) }
                                }
                        }
                    }
                }
                .statsChartInteraction(onInspect: { x, proxy, pin in self.inspectDate(x, proxy: proxy, pin: pin) }, onExit: { self.hoveredDate = nil })
                .chartYScale(domain: 0...max(1, gridLines.last ?? 1))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: gridLines) { value in
                        AxisValueLabel {
                            if let words = value.as(Int.self) {
                                Text(words.formatted(.number.notation(.compactName)))
                                    .recordText(FWType.small)
                                    .foregroundStyle(FWColor.textSecondary)
                            }
                        }
                    }
                }
                .frame(height: 140)
                self.dateLabels(period.days.map(\.date), pitch: nil)
                    .padding(.leading, 44)
            }
            .padding(.bottom, FWMetric.space2)
        }
    }

    /// Three even steps to a rounded maximum: 25,340 gives steps of 10K, 71,850 of 30K.
    static func gridStep(for total: Int) -> Int {
        let raw = max(1, Double(total) / 3)
        let magnitude = pow(10, floor(log10(raw)))
        return Int(ceil(raw / magnitude) * magnitude)
    }

    private func inspectDate(_ x: CGFloat, proxy: ChartProxy, pin: Bool) {
        guard let date: Date = proxy.value(atX: x) else { return }
        let day = Calendar.current.startOfDay(for: date)
        if pin {
            self.selectedDate = self.selectedDate == day ? nil : day
        } else if self.hoveredDate != day {
            self.hoveredDate = day
        }
    }

    private func focusedDay(_ period: StatsActivityPeriod) -> StatsActivityPeriod.Day? {
        guard let date = self.focusedDate else { return nil }
        return period.days.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func growthCaption(_ period: StatsActivityPeriod, focused: StatsActivityPeriod.Day?) -> String {
        if period.totalWords == 0 { return "Your running total starts with your first dictation." }
        if let day = focused {
            return "\(Self.shortDate(day.date))  ·  \(day.cumulativeWords.formatted()) words so far. Click to pin this day."
        }
        return "Hover along the line to read any day. Click to pin it."
    }

    // MARK: - Weekly rhythm

    private func rhythmLine(_ period: StatsActivityPeriod) -> some View {
        let peak = period.peakWeekdayAverage
        return RecordLine {
            StatsMargin("Weekly rhythm", "Average per weekday")
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space4) {
                Text(self.rhythmCaption(period))
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .lineLimit(1)
                HStack(alignment: .bottom, spacing: 16) {
                    ForEach(period.weekdays) { day in
                        let isPeak = peak > 0 && day.averageWords == peak
                        let focused = self.focusedWeekday == day.id
                        VStack(spacing: FWMetric.space2) {
                            ZStack(alignment: .bottom) {
                                Color.clear
                                if day.averageWords > 0 {
                                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                                        .fill(isPeak || focused ? FWColor.textPrimary : FWColor.textTertiary)
                                        .frame(height: CGFloat(day.averageWords / max(1, peak)) * 76)
                                        .opacity(self.focusedWeekday == nil || focused ? 1 : 0.35)
                                        .overlay(alignment: .top) {
                                            if isPeak {
                                                Text(Int(day.averageWords.rounded()).formatted())
                                                    .recordText(FWType.smallStrong)
                                                    .foregroundStyle(FWColor.textPrimary)
                                                    .fixedSize()
                                                    .offset(y: -18)
                                            }
                                        }
                                }
                            }
                            .frame(width: 24, height: 96)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(FWColor.lineRule).frame(width: 40, height: FWMetric.lineHairline)
                            }
                            Text(day.label)
                                .recordText(FWType.small)
                                .foregroundStyle(FWColor.textSecondary)
                                .fixedSize()
                        }
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                self.hoveredWeekday = day.id
                            } else if self.hoveredWeekday == day.id {
                                self.hoveredWeekday = nil
                            }
                        }
                        .onTapGesture { self.pinnedWeekday = self.pinnedWeekday == day.id ? nil : day.id }
                        .accessibilityElement()
                        .accessibilityLabel(day.fullLabel)
                        .accessibilityValue("\(Int(day.averageWords.rounded())) words per day on average")
                    }
                }
            }
            .padding(.bottom, FWMetric.space2)
        }
    }

    private func rhythmCaption(_ period: StatsActivityPeriod) -> String {
        if let day = period.weekdays.first(where: { $0.id == self.focusedWeekday }) {
            return "\(day.fullLabel)  ·  \(Int(day.averageWords.rounded()).formatted()) words per day on average"
        }
        guard let strongest = period.strongestWeekday else { return "Quiet days count too." }
        return "\(strongest)s are your strongest, \(Int(period.peakWeekdayAverage.rounded()).formatted()) words on average. Quiet days count too."
    }

    // MARK: - Formatting

    /// "22 Sep".
    nonisolated static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "Mon 12 Oct".
    nonisolated static func weekdayDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
