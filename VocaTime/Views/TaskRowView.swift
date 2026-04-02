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
                .foregroundStyle(task.isCompleted ? Color.accentColor : Color(.tertiaryLabel))
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

    private var calendar: Calendar { .current }
    private var strings: AppStrings { appUILanguage.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title — most prominent element
            Text(task.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(titleForegroundColor)
                .strikethrough(task.isCompleted)
                .fixedSize(horizontal: false, vertical: true)

            // Time + notes on a single metadata line
            HStack(spacing: 5) {
                Text(timeText)
                    .font(.caption)
                    .fontWeight(timeFontWeight)
                    .foregroundStyle(timeForegroundStyle)
                    .strikethrough(task.isCompleted)
                    .monospacedDigit()

                if let notes = task.notes, !notes.isEmpty {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(Color(.tertiaryLabel))
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .strikethrough(task.isCompleted)
                        .lineLimit(1)
                }
            }

            // Day label for upcoming or off-today overdue
            if let day = daySubtitleText {
                Text(day)
                    .font(.caption2)
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

// MARK: - Card wrapper helpers

private struct TaskCardModifier: ViewModifier {
    var dimmed: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 0.5)
            )
            .opacity(dimmed ? 0.6 : 1)
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
        .modifier(TaskCardModifier(dimmed: emphasizeCompleted && task.isCompleted))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
    }

    private var accessibilityLabelText: String {
        let s = strings
        var parts: [String] = []
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
        .modifier(TaskCardModifier(dimmed: emphasizeCompleted && task.isCompleted))
        .accessibilityElement(children: .combine)
    }
}
