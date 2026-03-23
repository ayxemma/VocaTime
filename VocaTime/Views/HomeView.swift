import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PermissionService.self) private var permissionService
    @Query(sort: \TaskItem.updatedAt, order: .reverse) private var allTasks: [TaskItem]

    @State private var viewModel = VoiceCommandViewModel()
    @State private var showChat = false

    private var calendar: Calendar { .current }

    private var overdueTaskItems: [TaskItem] {
        let now = Date()
        return allTasks.filter { item in
            guard !item.isCompleted, let d = item.scheduledDate else { return false }
            return d < now
        }
        .sorted {
            ($0.scheduledDate ?? .distantPast) < ($1.scheduledDate ?? .distantPast)
        }
    }

    private var todayTaskItems: [TaskItem] {
        let now = Date()
        let items = allTasks.filter { item in
            guard !item.isCompleted else { return false }
            if let d = item.scheduledDate {
                guard calendar.isDate(d, inSameDayAs: now) else { return false }
                return d >= now
            }
            return calendar.isDate(item.createdAt, inSameDayAs: now)
        }
        return sortedTodayItems(items)
    }

    private var upcomingTaskItems: [TaskItem] {
        let startToday = calendar.startOfDay(for: Date())
        return allTasks.filter { item in
            guard !item.isCompleted, let d = item.scheduledDate else { return false }
            return calendar.startOfDay(for: d) > startToday
        }
        .sorted {
            ($0.scheduledDate ?? .distantFuture) < ($1.scheduledDate ?? .distantFuture)
        }
    }

    private var doneTodayItems: [TaskItem] {
        let now = Date()
        return allTasks.filter { item in
            guard item.isCompleted, let c = item.completedAt else { return false }
            return calendar.isDate(c, inSameDayAs: now)
        }
        .sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("VocaTime")
                            .font(.largeTitle.weight(.semibold))
                        Text("Speak → Understand → Schedule → Remind")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    statusStrip

                    dashboardSection

                    NavigationLink {
                        PermissionsView()
                    } label: {
                        Label("Permission status", systemImage: "lock.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
            }

            Button {
                showChat = true
            } label: {
                Image(systemName: "message.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
            .accessibilityLabel("Open command chat")
            .padding(.trailing, 20)
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $showChat) {
            ChatSheetView(viewModel: viewModel)
                .presentationDragIndicator(.visible)
        }
        .task {
            await permissionService.refreshAll()
        }
    }

    private var dashboardSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Tasks")
                .font(.title2.weight(.semibold))
                .padding(.horizontal)

            taskColumn(title: "Overdue", items: overdueTaskItems)
            taskColumn(title: "Today", items: todayTaskItems)
            taskColumn(title: "Upcoming", items: upcomingTaskItems)
            taskColumn(title: "Done", items: doneTodayItems, doneStyle: true)
        }
    }

    private func taskColumn(title: String, items: [TaskItem], doneStyle: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if items.isEmpty {
                Text("Nothing here yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { task in
                    TaskRowView(
                        task: task,
                        emphasizeCompleted: doneStyle,
                        scheduleContext: scheduleContext(for: title)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func scheduleContext(for columnTitle: String) -> TaskRowScheduleContext {
        switch columnTitle {
        case "Overdue": return .overdue
        case "Today": return .today
        case "Upcoming": return .upcoming
        case "Done": return .done
        default: return .today
        }
    }

    /// Timed tasks first (by time ascending); unscheduled / date-only clock ("Anytime") last, newest first among those.
    private func sortedTodayItems(_ items: [TaskItem]) -> [TaskItem] {
        items.sorted { lhs, rhs in
            let lhsAnytime = isTodayAnytime(lhs)
            let rhsAnytime = isTodayAnytime(rhs)
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

    private func isTodayAnytime(_ item: TaskItem) -> Bool {
        guard let d = item.scheduledDate else { return true }
        return !TaskScheduleFormatting.hasWallClockTime(d, calendar: calendar)
    }

    @ViewBuilder
    private var statusStrip: some View {
        let denied = PermissionKind.allCases.filter {
            permissionService.status(for: $0) == .denied
        }
        if !denied.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Some permissions are denied: \(denied.map(\.title).joined(separator: ", "))")
                    .font(.footnote)
                Text("Open Permission status to request access or fix in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }
}

private enum TaskScheduleFormatting {
    static func hasWallClockTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let h = calendar.component(.hour, from: date)
        let m = calendar.component(.minute, from: date)
        let s = calendar.component(.second, from: date)
        return !(h == 0 && m == 0 && s == 0)
    }
}

private enum TaskRowScheduleContext {
    case overdue
    case today
    case upcoming
    case done
}

private struct TaskRowView: View {
    @Bindable var task: TaskItem
    var emphasizeCompleted: Bool
    var scheduleContext: TaskRowScheduleContext

    private var calendar: Calendar { .current }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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
                    Text(Self.upcomingDayFormatter.string(from: d))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .strikethrough(task.isCompleted)
                }

                if showOverdueDaySubtitle, let d = task.scheduledDate {
                    Text(Self.upcomingDayFormatter.string(from: d))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .strikethrough(task.isCompleted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .opacity(emphasizeCompleted && task.isCompleted ? 0.75 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
    }

    /// Time-first label for scanning: clock time when present, otherwise "Anytime".
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

    private var timeFontWeight: Font.Weight {
        if scheduleContext == .overdue, !task.isCompleted {
            return .semibold
        }
        return .regular
    }

    /// Overdue: warning tint on the time; completed Done rows use tertiary.
    private var timeForegroundStyle: AnyShapeStyle {
        if task.isCompleted { return AnyShapeStyle(.tertiary) }
        if scheduleContext == .overdue { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(.secondary)
    }

    private var titleForegroundColor: Color {
        task.isCompleted ? Color.secondary : Color.primary
    }

    private var accessibilityLabelText: String {
        var parts = [timePrefix, task.title]
        if let n = task.notes, !n.isEmpty { parts.append(n) }
        return parts.joined(separator: ", ")
    }

    private static let timeColumnWidth: CGFloat = 82

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let upcomingDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TaskItem.self, configurations: config)
    NavigationStack {
        HomeView()
            .environment(PermissionService())
    }
    .modelContainer(container)
}
