import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Persistence helpers

private let homeSectionOrderKey    = "homeSectionOrder"
private let homeSectionOrderDefault = "today,upcoming,overdue,done"

// MARK: - DashboardColumn

private enum DashboardColumn: String, CaseIterable, Identifiable {
    case today
    case upcoming
    case overdue
    case done

    var id: String { rawValue }

    func title(_ strings: AppStrings) -> String {
        switch self {
        case .today:    return strings.today
        case .overdue:  return strings.overdue
        case .upcoming: return strings.upcoming
        case .done:     return strings.doneColumn
        }
    }

    var scheduleContext: TaskRowScheduleContext {
        switch self {
        case .today:    return .today
        case .overdue:  return .overdue
        case .upcoming: return .upcoming
        case .done:     return .done
        }
    }

    static let defaultOrder: [DashboardColumn] = [.today, .upcoming, .overdue, .done]

    static func from(storageString raw: String) -> [DashboardColumn] {
        let parts = raw.split(separator: ",").compactMap { DashboardColumn(rawValue: String($0)) }
        return Set(parts) == Set(DashboardColumn.allCases) ? parts : defaultOrder
    }

    static func storageString(for order: [DashboardColumn]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - Drop delegate

/// Handles live reordering as the user drags a section over another.
private struct SectionDropDelegate: DropDelegate {
    let targetSection: DashboardColumn
    @Binding var sectionOrder: [DashboardColumn]
    @Binding var dragging: DashboardColumn?
    let onCommit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let src = dragging, src != targetSection,
              let fromIdx = sectionOrder.firstIndex(of: src),
              let toIdx   = sectionOrder.firstIndex(of: targetSection) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            sectionOrder.move(
                fromOffsets: IndexSet(integer: fromIdx),
                toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onCommit()
        return true
    }
}

// MARK: - ComposerSession

/// A fresh token created each time the new-task composer is opened.
/// Giving the sheet a new `Identifiable` item on every presentation forces
/// SwiftUI to destroy and recreate `TaskComposerView` from scratch, guaranteeing
/// that no @State from a previous session survives into the new one.
struct ComposerSession: Identifiable {
    let id: UUID
    init() {
        id = UUID()
        print("[ComposerSession] New session created — id=\(id)")
    }
}

// MARK: - HomeView

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.themePalette) private var themePalette
    @AppStorage(AppUILanguage.storageKey) private var languageRaw: String = AppUILanguage.defaultForDevice().rawValue
    @AppStorage(homeSectionOrderKey) private var sectionOrderRaw: String = homeSectionOrderDefault
    @Query(sort: \TaskItem.updatedAt, order: .reverse) private var allTasks: [TaskItem]

    @State private var composerSession: ComposerSession?   // replaces showTaskComposer: Bool

    // Per-section expansion state
    @State private var isTodayExpanded    = true
    @State private var isOverdueExpanded  = true
    @State private var isUpcomingExpanded = true
    @State private var isDoneExpanded     = false

    // Section order — initialised from UserDefaults so the correct order
    // is used on the very first render (avoids a flash / layout shift).
    @State private var sectionOrder: [DashboardColumn]
    @State private var draggingSection: DashboardColumn?

    init() {
        let saved = UserDefaults.standard.string(forKey: homeSectionOrderKey) ?? homeSectionOrderDefault
        _sectionOrder = State(initialValue: DashboardColumn.from(storageString: saved))
    }

    // MARK: - Derived data

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
        .sorted { ($0.scheduledDate ?? .distantPast) < ($1.scheduledDate ?? .distantPast) }
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
        .sorted { ($0.scheduledDate ?? .distantFuture) < ($1.scheduledDate ?? .distantFuture) }
    }

    private var doneTodayItems: [TaskItem] {
        let now = Date()
        return allTasks.filter { item in
            guard item.isCompleted, let c = item.completedAt else { return false }
            return calendar.isDate(c, inSameDayAs: now)
        }
        .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    // MARK: - Body

    var body: some View {
        let s = strings
        ZStack {
            ScrollView {
                VStack(spacing: 28) {
                    dashboardSection
                }
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .background(themePalette.backgroundColor)
            .animation(.easeInOut(duration: 0.35), value: themePalette.theme)
        }
        .sheet(item: $composerSession) { session in
            NavigationStack {
                TaskComposerView(sessionID: session.id)
            }
            .presentationDragIndicator(.visible)
        }
        .navigationTitle(strings.tasks)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(strings.settingsNavigationTitle)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { composerSession = ComposerSession() } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(s.newTaskA11y)
            }
        }
    }

    // MARK: - Dashboard (ordered, draggable sections)

    private var dashboardSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(sectionOrder) { column in
                taskColumn(
                    column: column,
                    items: items(for: column),
                    isExpanded: expandedBinding(for: column),
                    doneStyle: column == .done
                )
                // Dim the section being dragged so other sections stand out as targets
                .opacity(draggingSection == column ? 0.45 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: draggingSection)
                // Accept drops from other section handles
                .onDrop(
                    of: [UTType.plainText],
                    delegate: SectionDropDelegate(
                        targetSection: column,
                        sectionOrder: $sectionOrder,
                        dragging: $draggingSection,
                        onCommit: saveSectionOrder
                    )
                )
            }
        }
    }

    // MARK: - Section column builder

    private func taskColumn(
        column: DashboardColumn,
        items: [TaskItem],
        isExpanded: Binding<Bool>,
        doneStyle: Bool = false
    ) -> some View {
        let s = strings
        return VStack(alignment: .leading, spacing: 10) {
            // Header row: expand/collapse button + drag handle on the right
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(column.title(s).uppercased())
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

                // Drag handle — the only draggable element; keeps task taps and scroll safe
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                    .onDrag {
                        draggingSection = column
                        return NSItemProvider(object: column.rawValue as NSString)
                    }
                    .accessibilityLabel("Drag to reorder \(column.title(s))")
            }
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

    // MARK: - Helpers

    private func items(for column: DashboardColumn) -> [TaskItem] {
        switch column {
        case .today:    return todayTaskItems
        case .overdue:  return overdueTaskItems
        case .upcoming: return upcomingTaskItems
        case .done:     return doneTodayItems
        }
    }

    private func expandedBinding(for column: DashboardColumn) -> Binding<Bool> {
        switch column {
        case .today:    return $isTodayExpanded
        case .overdue:  return $isOverdueExpanded
        case .upcoming: return $isUpcomingExpanded
        case .done:     return $isDoneExpanded
        }
    }

    private func saveSectionOrder() {
        sectionOrderRaw = DashboardColumn.storageString(for: sectionOrder)
    }

    private func sortedTodayItems(_ items: [TaskItem]) -> [TaskItem] {
        items.sorted { lhs, rhs in
            let lhsAnytime = isTodayAnytime(lhs)
            let rhsAnytime = isTodayAnytime(rhs)
            if lhsAnytime != rhsAnytime { return lhsAnytime ? false : true }
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

}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TaskItem.self, configurations: config)
    NavigationStack {
        HomeView()
            .environment(\.appUILanguage, .en)
    }
    .modelContainer(container)
}
