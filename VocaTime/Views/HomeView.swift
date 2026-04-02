import SwiftData
import SwiftUI

private enum DashboardColumn {
    case today
    case overdue
    case upcoming
    case done

    func title(_ strings: AppStrings) -> String {
        switch self {
        case .today: return strings.today
        case .overdue: return strings.overdue
        case .upcoming: return strings.upcoming
        case .done: return strings.doneColumn
        }
    }

    var scheduleContext: TaskRowScheduleContext {
        switch self {
        case .today: return .today
        case .overdue: return .overdue
        case .upcoming: return .upcoming
        case .done: return .done
        }
    }
}

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PermissionService.self) private var permissionService
    @Environment(\.appUILanguage) private var appUILanguage
    @AppStorage(AppUILanguage.storageKey) private var languageRaw: String = AppUILanguage.defaultForDevice().rawValue
    @Query(sort: \TaskItem.updatedAt, order: .reverse) private var allTasks: [TaskItem]

    @State private var viewModel = VoiceCommandViewModel()
    @State private var showChat = false
    @State private var showTaskComposer = false
    @State private var isTodayExpanded = true
    @State private var isOverdueExpanded = true
    @State private var isUpcomingExpanded = true
    @State private var isDoneExpanded = false

    private var calendar: Calendar { .current }

    private var strings: AppStrings { appUILanguage.strings }

    private var selectedUILanguage: AppUILanguage {
        AppUILanguage(storageRaw: languageRaw)
    }

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
        let s = strings
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: 28) {
                    statusStrip

                    dashboardSection

                    NavigationLink {
                        PermissionsView()
                    } label: {
                        Label(s.permissionStatus, systemImage: "lock.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
                .padding(.top, 12)
            }
            .background(Color(.systemGroupedBackground))

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
            .accessibilityLabel(s.openCommandChat)
            .padding(.trailing, 20)
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $showChat) {
            ChatSheetView(viewModel: viewModel)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTaskComposer) {
            NavigationStack {
                TaskComposerView()
            }
            .presentationDragIndicator(.visible)
        }
        .navigationTitle(strings.tasks)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Language", selection: $languageRaw) {
                        ForEach(AppUILanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedUILanguage.displayName)
                        Text("▾")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Language")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTaskComposer = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(s.newTaskA11y)
            }
        }
        .onAppear {
            viewModel.uiLanguage = selectedUILanguage
        }
        .onChange(of: languageRaw) { _, _ in
            viewModel.uiLanguage = selectedUILanguage
            Task {
                await viewModel.handleUILanguageChanged()
            }
        }
        .task {
            await permissionService.refreshAll()
        }
    }

    private var dashboardSection: some View {
        let s = strings
        return VStack(alignment: .leading, spacing: 20) {
            taskColumn(column: .today, items: todayTaskItems, isExpanded: $isTodayExpanded)
            taskColumn(column: .overdue, items: overdueTaskItems, isExpanded: $isOverdueExpanded)
            taskColumn(column: .upcoming, items: upcomingTaskItems, isExpanded: $isUpcomingExpanded)
            taskColumn(column: .done, items: doneTodayItems, isExpanded: $isDoneExpanded, doneStyle: true)
        }
    }

    private func taskColumn(column: DashboardColumn, items: [TaskItem], isExpanded: Binding<Bool>, doneStyle: Bool = false) -> some View {
        let s = strings
        let title = column.title(s)
        return VStack(alignment: .leading, spacing: 10) {
            // Section header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .kerning(0.4)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            // Task cards
            if isExpanded.wrappedValue {
                if items.isEmpty {
                    Text(s.nothingHereYet)
                        .font(.subheadline)
                        .foregroundStyle(Color(.tertiaryLabel))
                        .padding(.horizontal)
                        .padding(.top, 2)
                } else {
                    VStack(spacing: 8) {
                        ForEach(items) { task in
                            TaskNavigableRow(
                                task: task,
                                emphasizeCompleted: doneStyle,
                                scheduleContext: column.scheduleContext
                            )
                        }
                    }
                    .padding(.horizontal)
                }
            }
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
        let s = strings
        let denied = PermissionKind.allCases.filter {
            permissionService.status(for: $0) == .denied
        }
        if !denied.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(s.permissionsDeniedPrefix) \(denied.map { $0.localizedTitle(strings: s) }.joined(separator: ", "))")
                    .font(.footnote)
                Text(s.openPermissionHint)
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

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TaskItem.self, configurations: config)
    NavigationStack {
        HomeView()
            .environment(PermissionService())
            .environment(\.appUILanguage, .en)
    }
    .modelContainer(container)
}
