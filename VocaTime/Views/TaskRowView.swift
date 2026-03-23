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

struct TaskRowCompletionButton: View {
    @Bindable var task: TaskItem

    var body: some View {
        Button {
            let newValue = !task.isCompleted
            task.isCompleted = newValue
            task.completedAt = newValue ? Date() : nil
            task.updatedAt = Date()
        } label: {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.isCompleted ? "Mark incomplete" : "Mark complete")
    }
}

struct TaskRowMainContent: View {
    @Bindable var task: TaskItem
    var scheduleContext: TaskRowScheduleContext

    private var calendar: Calendar { .current }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timePrefix)
                .font(.subheadline)
                .fontWeight(timeFontWeight)
                .monospacedDigit()
                .foregroundStyle(timeForegroundStyle)
                .frame(width: Self.timeColumnWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                    .foregroundStyle(titleForegroundColor)
                    .strikethrough(task.isCompleted)

                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough(task.isCompleted)
                }

                if showUpcomingDaySubtitle, let d = task.scheduledDate {
                    Text(Self.daySubtitleFormatter.string(from: d))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .strikethrough(task.isCompleted)
                }

                if showOverdueDaySubtitle, let d = task.scheduledDate {
                    Text(Self.daySubtitleFormatter.string(from: d))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .strikethrough(task.isCompleted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timePrefix: String {
        guard let d = task.scheduledDate else { return "Anytime" }
        guard TaskScheduleFormatting.hasWallClockTime(d, calendar: calendar) else { return "Anytime" }
        return Self.timeOnlyFormatter.string(from: d)
    }

    private var showUpcomingDaySubtitle: Bool {
        scheduleContext == .upcoming && task.scheduledDate != nil
    }

    private var showOverdueDaySubtitle: Bool {
        guard scheduleContext == .overdue, let d = task.scheduledDate else { return false }
        return !calendar.isDate(d, inSameDayAs: Date())
    }

    private var treatAsOverdueInCalendar: Bool {
        scheduleContext == .calendar
            && !task.isCompleted
            && (task.scheduledDate.map { $0 < Date() } ?? false)
    }

    private var timeFontWeight: Font.Weight {
        if scheduleContext == .overdue, !task.isCompleted {
            return .semibold
        }
        if treatAsOverdueInCalendar {
            return .semibold
        }
        return .regular
    }

    private var timeForegroundStyle: AnyShapeStyle {
        if task.isCompleted { return AnyShapeStyle(.tertiary) }
        if scheduleContext == .overdue { return AnyShapeStyle(Color.orange) }
        if treatAsOverdueInCalendar { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(.secondary)
    }

    private var titleForegroundColor: Color {
        task.isCompleted ? Color.secondary : Color.primary
    }

    private static let timeColumnWidth: CGFloat = 82

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let daySubtitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()
}

struct TaskRowView: View {
    @Bindable var task: TaskItem
    var emphasizeCompleted: Bool
    var scheduleContext: TaskRowScheduleContext

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TaskRowCompletionButton(task: task)
            TaskRowMainContent(task: task, scheduleContext: scheduleContext)
        }
        .padding(.vertical, 4)
        .opacity(emphasizeCompleted && task.isCompleted ? 0.75 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
    }

    private var calendar: Calendar { .current }

    private var accessibilityLabelText: String {
        var parts: [String] = []
        if let d = task.scheduledDate, TaskScheduleFormatting.hasWallClockTime(d, calendar: calendar) {
            parts.append(Self.timeOnlyFormatter.string(from: d))
        } else {
            parts.append("Anytime")
        }
        parts.append(task.title)
        if let n = task.notes, !n.isEmpty { parts.append(n) }
        return parts.joined(separator: ", ")
    }

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

/// Completion control stays independent; main content navigates to detail.
struct TaskNavigableRow: View {
    @Bindable var task: TaskItem
    var emphasizeCompleted: Bool
    var scheduleContext: TaskRowScheduleContext

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TaskRowCompletionButton(task: task)
            NavigationLink {
                TaskDetailView(task: task)
            } label: {
                TaskRowMainContent(task: task, scheduleContext: scheduleContext)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit task details")
        }
        .padding(.vertical, 4)
        .opacity(emphasizeCompleted && task.isCompleted ? 0.75 : 1)
        .accessibilityElement(children: .combine)
    }
}
