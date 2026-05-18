import SwiftData
import SwiftUI
import UIKit

struct CalendarView: View {
    @Environment(\.locale) private var locale
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.themePalette) private var themePalette
    @AppStorage(AppTextSize.storageKey) private var textSizeRaw: String = AppTextSize.default.rawValue
    @AppStorage(CalendarSyncSettings.AppStorageKeys.importApple) private var calendarImportAppleEvents = false
    @Query(sort: \TaskItem.updatedAt, order: .reverse) private var allTasks: [TaskItem]

    @State private var displayedMonth: Date
    @State private var selectedDate: Date
    @State private var composerSession: ComposerSession?
    @State private var importedCalendarItems: [CalendarDisplayItem] = []
    @State private var importedDetailItem: CalendarDisplayItem?

    private var calendar: Calendar {
        var cal = Calendar.current
        cal.locale = locale
        return cal
    }

    private var strings: AppStrings { appUILanguage.strings }
    private var typography: AppTypography { AppTypography(textSize: AppTextSize(storageRaw: textSizeRaw)) }

    init() {
        let cal = Calendar.current
        let today = Date()
        let monthStart = cal.dateInterval(of: .month, for: today)?.start ?? today
        _displayedMonth = State(initialValue: monthStart)
        _selectedDate = State(initialValue: cal.startOfDay(for: today))
    }

    var body: some View {
        let s = strings
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
        .background(themePalette.backgroundColor)
        .animation(.easeInOut(duration: 0.35), value: themePalette.theme)
        .navigationTitle(s.calendarTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    composerSession = ComposerSession()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(s.newTaskA11y)
            }
        }
        .sheet(item: $composerSession) { session in
            NavigationStack {
                TaskComposerView(sessionID: session.id)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $importedDetailItem) { item in
            ImportedAppleCalendarEventSheet(item: item)
                .environment(\.appUILanguage, appUILanguage)
                .environment(\.locale, locale)
                .presentationDragIndicator(.visible)
        }
        .task(id: displayedMonth) {
            reloadImportedCalendarEvents()
        }
        .onAppear {
            reloadImportedCalendarEvents()
        }
        .onChange(of: calendarImportAppleEvents) { _, _ in
            reloadImportedCalendarEvents()
        }
    }

    private var monthHeader: some View {
        let s = strings
        return HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(s.previousMonth)

            Spacer()

            Text(displayedMonth, format: Date.FormatStyle().month(.wide).year().locale(locale))
                .font(typography.pageTitle)

            Spacer()

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(s.nextMonth)
        }
    }

    private var weekdayHeaderRow: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(typography.sectionHeader)
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
        let count = dayItemCount(on: sod)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)

        return Button {
            selectedDate = sod
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(typography.font(size: 17, weight: isToday ? .semibold : .regular))
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
        let s = strings
        return VStack(alignment: .leading, spacing: 12) {
            Text(selectedDate, format: Date.FormatStyle().weekday(.wide).month(.abbreviated).day().locale(locale))
                .font(typography.sectionHeader)

            let items = combinedDayItems(for: selectedDate)
            if items.isEmpty {
                Text(s.noTasksThisDay)
                    .font(typography.body)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { row in
                        switch row {
                        case .task(let task):
                            TaskNavigableRow(
                                task: task,
                                emphasizeCompleted: false,
                                scheduleContext: .calendar
                            )
                        case .imported(let item):
                            ImportedCalendarEventRow(item: item, typography: typography) {
                                importedDetailItem = item
                            }
                        }
                    }
                }
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

    private func importedCount(on dayStart: Date) -> Int {
        guard calendarImportAppleEvents else { return 0 }
        return importedCalendarItems.filter { calendar.isDate(calendar.startOfDay(for: $0.startDate), inSameDayAs: dayStart) }.count
    }

    private func dayItemCount(on dayStart: Date) -> Int {
        taskCount(on: dayStart) + importedCount(on: dayStart)
    }

    private func reloadImportedCalendarEvents() {
        guard calendarImportAppleEvents,
              let interval = CalendarSyncService.fetchInterval(for: displayedMonth, calendar: calendar)
        else {
            importedCalendarItems = []
            return
        }
        importedCalendarItems = CalendarSyncService.shared.loadImportedDisplayItems(
            in: interval,
            excludingChatTaskEventIDs: Set(allTasks.compactMap(\.calendarEventIdentifier))
        )
    }

    private enum CalendarDayRow: Identifiable {
        case task(TaskItem)
        case imported(CalendarDisplayItem)

        var id: String {
            switch self {
            case .task(let t): return "t-\(t.id.uuidString)"
            case .imported(let i): return "i-\(i.id)"
            }
        }
    }

    private func tasks(on day: Date) -> [TaskItem] {
        let sod = calendar.startOfDay(for: day)
        let filtered = allTasks.filter { calendar.isDate(anchorDayStart(for: $0), inSameDayAs: sod) }
        return sortedDayList(filtered)
    }

    private func combinedDayItems(for day: Date) -> [CalendarDayRow] {
        var rows: [CalendarDayRow] = tasks(on: day).map { .task($0) }
        if calendarImportAppleEvents {
            let sod = calendar.startOfDay(for: day)
            let imported = importedCalendarItems
                .filter { calendar.isDate(calendar.startOfDay(for: $0.startDate), inSameDayAs: sod) }
                .sorted { $0.startDate < $1.startDate }
            rows.append(contentsOf: imported.map { .imported($0) })
        }
        return rows
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
        let s = strings
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        var parts = [formatter.string(from: date)]
        if count == 1 {
            parts.append(s.taskCountOne)
        } else if count > 1 {
            parts.append(String(format: s.taskCountMany, count))
        }
        if isSelected {
            parts.append(s.selected)
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

// MARK: - Imported Apple Calendar (read-only)

private struct ImportedCalendarEventRow: View {
    let item: CalendarDisplayItem
    let typography: AppTypography
    var onTap: () -> Void

    @Environment(\.appUILanguage) private var appUILanguage

    var body: some View {
        let s = appUILanguage.strings
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(item.swiftUIColor.opacity(0.55))
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(typography.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        Text(timeLabel)
                            .font(typography.caption)
                            .foregroundStyle(.secondary)
                        Text(s.calendarAppleEventBadge)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground).opacity(0.45))
            }
        }
        .buttonStyle(.plain)
    }

    private var timeLabel: String {
        let fmt = Date.FormatStyle(date: .omitted, time: .shortened)
        if item.endDate.timeIntervalSince(item.startDate) > 60 {
            return "\(item.startDate.formatted(fmt))–\(item.endDate.formatted(fmt))"
        }
        return item.startDate.formatted(fmt)
    }
}

private struct ImportedAppleCalendarEventSheet: View {
    let item: CalendarDisplayItem
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = appUILanguage.strings
        NavigationStack {
            Form {
                Section {
                    LabeledContent(s.calendarImportedEventDetailTitle) {
                        Text(item.title)
                    }
                    if let calName = item.calendarName {
                        LabeledContent(s.settingsCalendarPickerLabel) {
                            Text(calName)
                        }
                    }
                    LabeledContent(s.timePickerLabel) {
                        Text(timeRangeText)
                    }
                    if let notes = item.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.body)
                    }
                } footer: {
                    Text(s.calendarImportedEventReadOnlyHint)
                        .font(.footnote)
                }
            }
            .navigationTitle(s.calendarImportedEventDetailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(s.dismissDone) { dismiss() }
                }
            }
        }
    }

    private var timeRangeText: String {
        let df = DateIntervalFormatter()
        df.locale = locale
        df.dateStyle = .none
        df.timeStyle = .short
        return df.string(from: item.startDate, to: item.endDate) ?? ""
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TaskItem.self, configurations: config)
    NavigationStack {
        CalendarView()
            .environment(\.appUILanguage, .en)
    }
    .environment(\.locale, Locale(identifier: "en_US"))
    .modelContainer(container)
}
