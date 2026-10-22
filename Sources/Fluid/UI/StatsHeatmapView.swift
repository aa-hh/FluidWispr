import SwiftUI

/// Owns its pointer state. Hover never invalidates the parent or any Swift Charts view.
struct StatsHeatmapView: View {
    let period: StatsActivityPeriod
    private let labels: [Date: DayLabels]

    private struct DayLabels {
        let shortDate: String
        let accessible: String
        let words: String
    }

    private static let cell: CGFloat = 16
    private static let gap: CGFloat = 4

    init(period: StatsActivityPeriod) {
        self.period = period
        // Format once when the data/range changes, never while moving between squares.
        self.labels = Dictionary(uniqueKeysWithValues: period.days.map { day in
            (day.date, DayLabels(
                shortDate: day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                accessible: "\(day.date.formatted(date: .complete, time: .omitted)), \(day.words) words",
                words: "\(day.words.formatted()) words"
            ))
        })
    }

    @State private var hoveredDate: Date?

    var body: some View {
        self.heatmap(self.period)
            .onDisappear { self.hoveredDate = nil }
    }

    /// Level 0 is the rule colour; levels 1 to 4 are ink at rising strength.
    static func cellColor(_ level: Int) -> Color {
        let opacity: [Double] = [0, 0.22, 0.42, 0.66, 1]
        return level == 0 ? FWColor.lineRule : FWColor.textPrimary.opacity(opacity[min(4, level)])
    }

    private func heatmap(_ period: StatsActivityPeriod) -> some View {
        let calendar = period.calendar
        let columns = period.weeks
        return HStack(alignment: .top, spacing: 0) {
            VStack(spacing: Self.gap) {
                Color.clear.frame(height: 20 - Self.gap)
                ForEach(0..<7) { row in
                    Text(row.isMultiple(of: 2) ? calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + row) % 7] : "")
                        .recordText(FWType.small)
                        .foregroundStyle(FWColor.textSecondary)
                        .frame(width: 30, height: Self.cell, alignment: .leading)
                }
            }
            .frame(width: 30)
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(columns.indices, id: \.self) { column in
                    VStack(spacing: Self.gap) {
                        Text(period.monthLabel(for: column))
                            .recordText(FWType.small)
                            .foregroundStyle(FWColor.textSecondary)
                            .fixedSize()
                            .frame(width: Self.cell, height: 20 - Self.gap, alignment: .topLeading)
                        ForEach(0..<7) { row in
                            self.dayCell(columns[column][row], maximum: period.peakWords)
                                .frame(width: Self.cell, height: Self.cell)
                        }
                    }
                    .zIndex(columns[column].contains { $0?.date == self.hoveredDate } ? 1 : 0)
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func dayCell(_ day: StatsActivityPeriod.Day?, maximum: Int) -> some View {
        if let day {
            let level = day.words == 0 ? 0 : max(1, min(4, Int(ceil(Double(day.words) / Double(max(1, maximum)) * 4))))
            let highlighted = self.hoveredDate == day.date
            RoundedRectangle(cornerRadius: 3)
                .fill(Self.cellColor(level))
                .overlay {
                    if highlighted {
                        // 1.5 pt ring, 3 pt outside the cell.
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(FWColor.textPrimary, lineWidth: 1.5)
                            .frame(width: Self.cell + 6, height: Self.cell + 6)
                    }
                }
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    if highlighted {
                        RecordChartTooltip(date: self.labels[day.date]?.shortDate ?? "", value: self.labels[day.date]?.words ?? "")
                            .fixedSize()
                            .offset(y: -(Self.cell + FWMetric.space3))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .zIndex(highlighted ? 1 : 0)
                .onHover { hovering in
                    if hovering {
                        self.hoveredDate = day.date
                    } else if self.hoveredDate == day.date {
                        self.hoveredDate = nil
                    }
                }
                .accessibilityLabel(self.labels[day.date]?.accessible ?? "")
                .accessibilityElement(children: .ignore)
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }
}
