import SwiftData
import SwiftUI

struct CalendarView: View {
    @Query(sort: \TaskItem.updatedAt, order: .reverse) private var allTasks: [TaskItem]

    @State private var displayedMonth: Date
    @State private var selectedDate: Date

    private var calendar: Calendar { .current }

    init() {
        let cal = Calendar.current
        let today = Date()
        let monthStart = cal.dateInterval(of: .month, for: today)?.start ?? today
        _displayedMonth = State(initialValue: monthStart)
        _selectedDate = State(initialValue: cal.startOfDay(for: today))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                monthHeader

                weekdayHeaderRow

                LazyVGrid(columns: Self.gridColumns, spacing: 10) {
                    ForEach(monthGridCells) { cell in
                        if let date = cell.date {
                            dayCell(date: date)
                        } else {
                            Color.clear
                                .frame(height: Self.cellHeight)
                        }
                    }
                }

                selectedDaySection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.large)
    }

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Previous month")

            Spacer()

            Text(displayedMonth, format: .dateTime.month(.wide).year())
                .font(.title2.weight(.semibold))

            Spacer()

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Next month")
        }
    }

    private var weekdayHeaderRow: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[($0 + first) % 7] }
    }

    private func dayCell(date: Date) -> some View {
        let sod = calendar.startOfDay(for: date)
        let count = taskCount(on: sod)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)

        return Button {
            selectedDate = sod
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.body.weight(isToday ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)

                Group {
                    if count == 1 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                    } else if count > 1 {
                        Text("\(min(count, 99))")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    } else {
                        Color.clear.frame(height: 12)
                    }
                }
                .frame(height: 12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.cellHeight)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.55) : (isToday ? Color.accentColor.opacity(0.35) : Color.clear),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityDayLabel(date: date, count: count, isSelected: isSelected))
    }

    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedDate, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                .font(.headline)

            let items = tasks(on: selectedDate)
            if items.isEmpty {
                Text("No tasks on this day")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { task in
                        TaskNavigableRow(
                            task: task,
                            emphasizeCompleted: false,
                            scheduleContext: .calendar
                        )
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func shiftMonth(by delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth),
              let interval = calendar.dateInterval(of: .month, for: next)
        else { return }
        displayedMonth = interval.start
        if !calendar.isDate(selectedDate, equalTo: interval.start, toGranularity: .month) {
            selectedDate = interval.start
        }
    }

    private var monthGridCells: [MonthGridCell] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }

        var comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        guard let monthStart = calendar.date(from: comps) else { return [] }

        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [MonthGridCell] = (0..<leading).map { i in MonthGridCell(idOffset: i, date: nil) }

        var idBase = leading
        for day in dayRange {
            comps.day = day
            if let date = calendar.date(from: comps) {
                cells.append(MonthGridCell(idOffset: idBase, date: calendar.startOfDay(for: date)))
                idBase += 1
            }
        }

        while cells.count % 7 != 0 {
            cells.append(MonthGridCell(idOffset: idBase, date: nil))
            idBase += 1
        }

        return cells
    }

    private func anchorDayStart(for item: TaskItem) -> Date {
        let ref = item.scheduledDate ?? item.createdAt
        return calendar.startOfDay(for: ref)
    }

    private func taskCount(on dayStart: Date) -> Int {
        allTasks.reduce(into: 0) { count, item in
            if calendar.isDate(anchorDayStart(for: item), inSameDayAs: dayStart) {
                count += 1
            }
        }
    }

    private func tasks(on day: Date) -> [TaskItem] {
        let sod = calendar.startOfDay(for: day)
        let filtered = allTasks.filter { calendar.isDate(anchorDayStart(for: $0), inSameDayAs: sod) }
        return sortedDayList(filtered)
    }

    private func sortedDayList(_ items: [TaskItem]) -> [TaskItem] {
        items.sorted { lhs, rhs in
            let lhsAnytime = isAnytime(lhs)
            let rhsAnytime = isAnytime(rhs)
            if lhsAnytime != rhsAnytime {
                if lhsAnytime { return false }
                return true
            }
            if !lhsAnytime, !rhsAnytime {
                return (lhs.scheduledDate ?? .distantFuture) < (rhs.scheduledDate ?? .distantFuture)
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func isAnytime(_ item: TaskItem) -> Bool {
        guard let d = item.scheduledDate else { return true }
        return !TaskScheduleFormatting.hasWallClockTime(d, calendar: calendar)
    }

    private func accessibilityDayLabel(date: Date, count: Int, isSelected: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        var parts = [formatter.string(from: date)]
        if count == 1 {
            parts.append("1 task")
        } else if count > 1 {
            parts.append("\(count) tasks")
        }
        if isSelected {
            parts.append("selected")
        }
        return parts.joined(separator: ", ")
    }

    private struct MonthGridCell: Identifiable {
        let id: String
        let date: Date?

        init(idOffset: Int, date: Date?) {
            self.date = date
            self.id = date.map { "\($0.timeIntervalSince1970)" } ?? "pad-\(idOffset)"
        }
    }

    private static let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
    private static let cellHeight: CGFloat = 52
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TaskItem.self, configurations: config)
    NavigationStack {
        CalendarView()
    }
    .modelContainer(container)
}
