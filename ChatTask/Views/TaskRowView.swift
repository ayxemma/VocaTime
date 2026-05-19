import SwiftData
import SwiftUI

enum TaskScheduleFormatting {
    static func hasWallClockTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let h = calendar.component(.hour, from: date)
        let m = calendar.component(.minute, from: date)
        let s = calendar.component(.second, from: date)
        return !(h == 0 && m == 0 && s == 0)
    }
}

enum TaskRowScheduleContext {
    case overdue
    case today
    case upcoming
    case done
    case calendar
}

// MARK: - Completion toggle

struct TaskRowCompletionButton: View {
    @Bindable var task: TaskItem
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.themePalette) private var themePalette

    var body: some View {
        let s = appUILanguage.strings
        Button {
            let newValue = !task.isCompleted
            task.isCompleted = newValue
            task.completedAt = newValue ? Date() : nil
            task.updatedAt = Date()
        } label: {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(task.isCompleted ? themePalette.accentColor : Color(.tertiaryLabel))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.isCompleted ? s.markIncomplete : s.markComplete)
    }
}

// MARK: - Row content (title + metadata)

struct TaskRowMainContent: View {
    @Bindable var task: TaskItem
    var scheduleContext: TaskRowScheduleContext

    @Environment(\.locale) private var locale
    @Environment(\.appUILanguage) private var appUILanguage
    @AppStorage(AppTextSize.storageKey) private var textSizeRaw: String = AppTextSize.default.rawValue

    private var calendar: Calendar { .current }
    private var strings: AppStrings { appUILanguage.strings }
    private var typography: AppTypography { AppTypography(textSize: AppTextSize(storageRaw: textSizeRaw)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.title)
                    .font(typography.taskTitle)
                    .foregroundStyle(titleForegroundColor)
                    .strikethrough(task.isCompleted)
                    .fixedSize(horizontal: false, vertical: true)

                if task.hasImportantPriority {
                    ImportantPriorityBadge(size: .compact)
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }

            // Time + notes on a single metadata line
            HStack(spacing: 5) {
                Text(timeText)
                    .font(typography.taskMetadata)
                    .fontWeight(timeFontWeight)
                    .foregroundStyle(timeForegroundStyle)
                    .strikethrough(task.isCompleted)
                    .monospacedDigit()

                if let notes = task.notes, !notes.isEmpty {
                    Text("·")
                        .font(typography.taskMetadata)
                        .foregroundStyle(Color(.tertiaryLabel))
                    Text(notes)
                        .font(typography.taskMetadata)
                        .foregroundStyle(Color.secondary)
                        .strikethrough(task.isCompleted)
                        .lineLimit(1)
                }
            }

            // Day label for upcoming or off-today overdue
            if let day = daySubtitleText {
                Text(day)
                    .font(typography.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .strikethrough(task.isCompleted)
            }

            if let recurrence = TaskRecurrenceFormatting.label(for: task, locale: locale) {
                Text(recurrence)
                    .font(typography.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .strikethrough(task.isCompleted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Computed

    private var isTimedTask: Bool {
        guard let d = task.scheduledDate else { return false }
        return TaskScheduleFormatting.hasWallClockTime(d, calendar: calendar)
    }

    private var timeText: String {
        let s = strings
        if let recurringTime = TaskRecurrenceFormatting.timeText(for: task, locale: locale) {
            return recurringTime
        }
        guard let d = task.scheduledDate else { return s.anytime }
        guard TaskScheduleFormatting.hasWallClockTime(d, calendar: calendar) else { return s.anytime }
        return d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    private var daySubtitleText: String? {
        if scheduleContext == .upcoming, let d = task.scheduledDate {
            return d.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().locale(locale))
        }
        if scheduleContext == .overdue, let d = task.scheduledDate,
           !calendar.isDate(d, inSameDayAs: Date()) {
            return d.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().locale(locale))
        }
        return nil
    }

    private var treatAsOverdueInCalendar: Bool {
        scheduleContext == .calendar
            && !task.isCompleted
            && (task.scheduledDate.map { $0 < Date() } ?? false)
    }

    private var timeFontWeight: Font.Weight {
        if scheduleContext == .overdue, !task.isCompleted { return .medium }
        if treatAsOverdueInCalendar { return .medium }
        return .regular
    }

    private var timeForegroundStyle: AnyShapeStyle {
        if task.isCompleted { return AnyShapeStyle(Color(.tertiaryLabel)) }
        if scheduleContext == .overdue { return AnyShapeStyle(Color.orange) }
        if treatAsOverdueInCalendar { return AnyShapeStyle(Color.orange) }
        if isTimedTask { return AnyShapeStyle(Color.secondary) }
        return AnyShapeStyle(Color(.tertiaryLabel))
    }

    private var titleForegroundColor: Color {
        task.isCompleted ? Color.secondary : Color.primary
    }
}

enum TaskRecurrenceFormatting {
    static func label(for task: TaskItem, locale: Locale) -> String? {
        guard task.recurrenceFrequency == .weekly else { return nil }
        let weekdays = task.recurrenceWeekdays
        guard !weekdays.isEmpty else { return nil }
        let days = weekdayRangeText(weekdays: weekdays, locale: locale)
        if let time = timeText(for: task, locale: locale) {
            return "Repeats \(days) at \(time)"
        }
        return "Repeats \(days)"
    }

    static func timeText(for task: TaskItem, locale: Locale) -> String? {
        guard let minutes = task.recurrenceTimeMinutes,
              (0..<(24 * 60)).contains(minutes)
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        if let tz = task.recurrenceTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) {
            calendar.timeZone = tz
        }
        var comps = DateComponents()
        comps.year = 2000
        comps.month = 1
        comps.day = 3
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        guard let date = calendar.date(from: comps) else { return nil }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    private static func weekdayRangeText(weekdays: [Int], locale: Locale) -> String {
        let sanitized = Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
        guard !sanitized.isEmpty else { return "" }
        let ranges = contiguousRanges(sanitized)
        return ranges.map { range in
            if range.count >= 3, let first = range.first, let last = range.last {
                return "\(shortWeekdaySymbol(forISOWeekday: first, locale: locale))-\(shortWeekdaySymbol(forISOWeekday: last, locale: locale))"
            }
            return range.map { shortWeekdaySymbol(forISOWeekday: $0, locale: locale) }.joined(separator: ", ")
        }
        .joined(separator: ", ")
    }

    private static func contiguousRanges(_ weekdays: [Int]) -> [[Int]] {
        weekdays.reduce(into: [[Int]]()) { ranges, day in
            guard var last = ranges.popLast() else {
                ranges.append([day])
                return
            }
            if let previous = last.last, day == previous + 1 {
                last.append(day)
                ranges.append(last)
            } else {
                ranges.append(last)
                ranges.append([day])
            }
        }
    }

    private static func shortWeekdaySymbol(forISOWeekday iso: Int, locale: Locale) -> String {
        guard let index = foundationWeekdayIndex(forISOWeekday: iso) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = formatter.shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return symbols[index]
    }

    private static func foundationWeekdayIndex(forISOWeekday iso: Int) -> Int? {
        guard (1...7).contains(iso) else { return nil }
        return iso == 7 ? 0 : iso
    }
}

// MARK: - Card wrapper helpers

private struct TaskCardModifier: ViewModifier {
    @Environment(\.themePalette) private var themePalette
    var dimmed: Bool
    var isImportant: Bool = false

    func body(content: Content) -> some View {
        let shadowOpacity = themePalette.isMinimal ? 0.06 : 0.05
        return content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(themePalette.cardBackground)
            )
            .shadow(color: Color.black.opacity(shadowOpacity), radius: themePalette.isMinimal ? 2 : 4, x: 0, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        themePalette.isMinimal
                            ? Color.black.opacity(0.06)
                            : Color(.separator).opacity(0.25),
                        lineWidth: themePalette.isMinimal ? 0.75 : 0.5
                    )
            )
            .opacity(dimmed ? 0.6 : 1)
            .importantTaskCardAccent(isImportant)
    }
}

// MARK: - Standalone row (no navigation)

struct TaskRowView: View {
    @Bindable var task: TaskItem
    var emphasizeCompleted: Bool
    var scheduleContext: TaskRowScheduleContext

    @Environment(\.locale) private var locale
    @Environment(\.appUILanguage) private var appUILanguage

    private var calendar: Calendar { .current }
    private var strings: AppStrings { appUILanguage.strings }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TaskRowCompletionButton(task: task)
                .padding(.top, 2)
            TaskRowMainContent(task: task, scheduleContext: scheduleContext)
        }
        .modifier(TaskCardModifier(
            dimmed: emphasizeCompleted && task.isCompleted,
            isImportant: task.hasImportantPriority
        ))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
    }

    private var accessibilityLabelText: String {
        let s = strings
        var parts: [String] = []
        if task.hasImportantPriority {
            parts.append(ReminderAlertStyle.important.displayName)
        }
        if let d = task.scheduledDate, TaskScheduleFormatting.hasWallClockTime(d, calendar: calendar) {
            parts.append(d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))
        } else {
            parts.append(s.anytime)
        }
        parts.append(task.title)
        if let n = task.notes, !n.isEmpty { parts.append(n) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Navigable row (completion stays independent; content navigates)

struct TaskNavigableRow: View {
    @Bindable var task: TaskItem
    var emphasizeCompleted: Bool
    var scheduleContext: TaskRowScheduleContext

    @Environment(\.appUILanguage) private var appUILanguage
    private var strings: AppStrings { appUILanguage.strings }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TaskRowCompletionButton(task: task)
                .padding(.top, 2)
            NavigationLink {
                TaskDetailView(task: task)
            } label: {
                TaskRowMainContent(task: task, scheduleContext: scheduleContext)
            }
            .buttonStyle(.plain)
            .accessibilityHint(strings.editTaskDetails)
        }
        .modifier(TaskCardModifier(
            dimmed: emphasizeCompleted && task.isCompleted,
            isImportant: task.hasImportantPriority
        ))
        .accessibilityElement(children: .combine)
    }
}
