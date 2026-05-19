import SwiftData
import SwiftUI

struct TaskDetailView: View {
    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.appUILanguage) private var appUILanguage
    @FocusState private var titleFocused: Bool

    @State private var scheduleEnabled: Bool
    @State private var daySelection: Date
    @State private var specificTimeEnabled: Bool
    @State private var timeSelection: Date
    @State private var reminderOffset: ReminderOffset
    @State private var alertStyle: ReminderAlertStyle
    @State private var recurrenceEnabled: Bool
    @State private var selectedWeekdays: Set<Int>

    private var calendar: Calendar { .current }

    private var strings: AppStrings { appUILanguage.strings }

    init(task: TaskItem) {
        self.task = task
        let cal = Calendar.current
        if let s = task.scheduledDate {
            _scheduleEnabled = State(initialValue: true)
            _daySelection = State(initialValue: cal.startOfDay(for: s))
            _specificTimeEnabled = State(initialValue: TaskScheduleFormatting.hasWallClockTime(s, calendar: cal))
            _timeSelection = State(initialValue: s)
        } else {
            _scheduleEnabled = State(initialValue: false)
            _daySelection = State(initialValue: cal.startOfDay(for: Date()))
            _specificTimeEnabled = State(initialValue: false)
            _timeSelection = State(initialValue: Date())
        }
        let offsetMinutes = task.reminderOffsetMinutes ?? ReminderOffset.globalDefault.rawValue
        _reminderOffset = State(initialValue: ReminderOffset.nearest(to: offsetMinutes))
        _alertStyle = State(initialValue: task.alertStyle)
        _recurrenceEnabled = State(initialValue: task.isRecurring)
        _selectedWeekdays = State(initialValue: Set(task.recurrenceWeekdays))
    }

    var body: some View {
        let s = strings
        Form {
            Section(s.taskSection) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if alertStyle == .important {
                        ImportantPriorityMark(font: .body.weight(.semibold))
                    }
                    TextField(s.titlePlaceholder, text: titleBinding)
                        .focused($titleFocused)
                }

                TextField(s.notesPlaceholder, text: notesBinding, axis: .vertical)
                    .lineLimit(3...8)
            }

            Section(s.scheduleSection) {
                Toggle(s.scheduledToggle, isOn: $scheduleEnabled)
                    .onChange(of: scheduleEnabled) { _, new in
                        if new {
                            if task.scheduledDate == nil {
                                daySelection = calendar.startOfDay(for: Date())
                                specificTimeEnabled = false
                                timeSelection = Date()
                            }
                        }
                        flushScheduleToTask()
                    }

                if scheduleEnabled {
                    DatePicker(s.datePickerLabel, selection: $daySelection, displayedComponents: .date)
                        .environment(\.locale, locale)
                        .onChange(of: daySelection) { _, _ in
                            flushScheduleToTask()
                        }

                    Toggle(s.specificTime, isOn: $specificTimeEnabled)
                        .onChange(of: specificTimeEnabled) { _, _ in
                            if !specificTimeEnabled {
                                recurrenceEnabled = false
                                selectedWeekdays = []
                            }
                            flushScheduleToTask()
                        }

                    if specificTimeEnabled {
                        DatePicker(s.timePickerLabel, selection: $timeSelection, displayedComponents: .hourAndMinute)
                            .environment(\.locale, locale)
                            .onChange(of: timeSelection) { _, _ in
                                flushScheduleToTask()
                            }

                        Picker(s.reminderLabel, selection: $reminderOffset) {
                            ForEach(ReminderOffset.allCases) { option in
                                Text(option.displayLabel).tag(option)
                            }
                        }
                        .onChange(of: reminderOffset) { _, new in
                            task.reminderOffsetMinutes = new.rawValue
                            task.updatedAt = Date()
                            TaskReminderService.shared.schedule(for: task)
                        }

                        Toggle(isOn: importantReminderBinding) {
                            Text("Mark as Important")
                        }

                        if alertStyle == .important {
                            Text("Time Sensitive when allowed. Still respects Silent Mode and Focus.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle("Repeat weekly", isOn: $recurrenceEnabled)
                            .onChange(of: recurrenceEnabled) { _, new in
                                if new, selectedWeekdays.isEmpty {
                                    selectedWeekdays = [isoWeekday(for: daySelection)]
                                }
                                flushScheduleToTask()
                            }

                        if recurrenceEnabled {
                            weekdayEditor

                            if let label = TaskRecurrenceFormatting.label(for: task, locale: locale) {
                                Text(label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Text(s.scheduleHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(s.completed, isOn: completionBinding)
            }

            Section {
                Button(role: .destructive) {
                    CalendarSyncService.shared.removeCalendarEvent(for: task, modelContext: modelContext, logDeletion: true)
                    TaskReminderService.shared.cancel(taskID: task.id)
                    modelContext.delete(task)
                    try? modelContext.save()
                    dismiss()
                } label: {
                    Text(s.deleteTask)
                }
            }
        }
        .navigationTitle(s.taskSection)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            titleFocused = true
        }
    }

    private var importantReminderBinding: Binding<Bool> {
        Binding(
            get: { alertStyle == .important },
            set: { isImportant in
                let newStyle: ReminderAlertStyle = isImportant ? .important : .normal
                alertStyle = newStyle
                task.alertStyle = newStyle
                task.updatedAt = Date()
                print("[TaskDetail] alertStyleSelected task=\(task.id.uuidString) style=\(newStyle.rawValue)")
                TaskReminderService.shared.schedule(for: task)
                print("[TaskDetail] notificationRescheduledAfterAlertStyleChange")
            }
        )
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { task.title },
            set: { new in
                task.title = new
                task.updatedAt = Date()
                touchCalendarSync()
            }
        )
    }

    private var weekdayEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repeat on")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(1...7, id: \.self) { weekday in
                    Button {
                        toggleWeekday(weekday)
                    } label: {
                        Text(shortWeekdaySymbol(forISOWeekday: weekday))
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(selectedWeekdays.contains(weekday) ? Color.accentColor : Color(.secondarySystemBackground))
                            )
                            .foregroundStyle(selectedWeekdays.contains(weekday) ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(fullWeekdaySymbol(forISOWeekday: weekday))
                    .accessibilityAddTraits(selectedWeekdays.contains(weekday) ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { task.notes ?? "" },
            set: { new in
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                task.notes = trimmed.isEmpty ? nil : trimmed
                task.updatedAt = Date()
                touchCalendarSync()
            }
        )
    }

    private var completionBinding: Binding<Bool> {
        Binding(
            get: { task.isCompleted },
            set: { new in
                task.isCompleted = new
                task.completedAt = new ? Date() : nil
                task.updatedAt = Date()
                if new {
                    TaskReminderService.shared.cancel(taskID: task.id)
                } else {
                    TaskReminderService.shared.schedule(for: task)
                }
            }
        )
    }

    private func flushScheduleToTask() {
        guard scheduleEnabled else {
            task.scheduledDate = nil
            task.reminderOffsetMinutes = nil
            clearRecurrence()
            task.updatedAt = Date()
            TaskReminderService.shared.cancel(taskID: task.id)
            touchCalendarSync()
            return
        }
        if recurrenceEnabled && !specificTimeEnabled {
            recurrenceEnabled = false
        }
        task.scheduledDate = TaskScheduleHelpers.scheduledDate(
            calendar: calendar,
            hasDate: true,
            daySelection: daySelection,
            hasSpecificTime: specificTimeEnabled,
            timeSelection: timeSelection
        )
        task.reminderOffsetMinutes = specificTimeEnabled ? reminderOffset.rawValue : nil
        if recurrenceEnabled {
            let weekdays = sanitizedSelectedWeekdays
            if weekdays.isEmpty {
                clearRecurrence()
                recurrenceEnabled = false
            } else {
                task.recurrenceFrequencyRaw = RecurrenceFrequency.weekly.rawValue
                task.recurrenceWeekdaysRaw = weekdays.map(String.init).joined(separator: ",")
                task.recurrenceTimeMinutes = recurrenceTimeMinutes
                task.recurrenceTimeZoneIdentifier = TimeZone.current.identifier
                task.recurrenceStartDate = calendar.startOfDay(for: daySelection)
                task.recurrenceEndDate = nil
            }
        } else {
            clearRecurrence()
        }
        task.updatedAt = Date()
        TaskReminderService.shared.schedule(for: task)
        touchCalendarSync()
    }

    private func touchCalendarSync() {
        CalendarSyncService.shared.applyOutboundEligibility(for: task)
        CalendarSyncService.shared.syncOutbound(for: task, modelContext: modelContext)
        try? modelContext.save()
    }

    private var sanitizedSelectedWeekdays: [Int] {
        Array(selectedWeekdays.filter { (1...7).contains($0) }).sorted()
    }

    private var recurrenceTimeMinutes: Int {
        calendar.component(.hour, from: timeSelection) * 60 + calendar.component(.minute, from: timeSelection)
    }

    private func clearRecurrence() {
        task.recurrenceFrequencyRaw = nil
        task.recurrenceWeekdaysRaw = nil
        task.recurrenceTimeMinutes = nil
        task.recurrenceTimeZoneIdentifier = nil
        task.recurrenceStartDate = nil
        task.recurrenceEndDate = nil
    }

    private func toggleWeekday(_ weekday: Int) {
        if selectedWeekdays.contains(weekday) {
            if selectedWeekdays.count > 1 {
                selectedWeekdays.remove(weekday)
            }
        } else {
            selectedWeekdays.insert(weekday)
        }
        flushScheduleToTask()
    }

    private func isoWeekday(for date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 ? 7 : weekday - 1
    }

    private func shortWeekdaySymbol(forISOWeekday iso: Int) -> String {
        guard let index = Self.foundationWeekdayIndex(forISOWeekday: iso) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = formatter.veryShortWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        return symbols[index]
    }

    private func fullWeekdaySymbol(forISOWeekday iso: Int) -> String {
        guard let index = Self.foundationWeekdayIndex(forISOWeekday: iso) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = formatter.weekdaySymbols ?? ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return symbols[index]
    }

    private static func foundationWeekdayIndex(forISOWeekday iso: Int) -> Int? {
        guard (1...7).contains(iso) else { return nil }
        return iso == 7 ? 0 : iso
    }
}

private struct TaskDetailPreviewHost: View {
    private let container: ModelContainer
    private let task: TaskItem

    init() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let c = try! ModelContainer(for: TaskItem.self, configurations: config)
        let t = TaskItem(title: "Preview task", notes: "Note", scheduledDate: Date())
        c.mainContext.insert(t)
        container = c
        task = t
    }

    var body: some View {
        NavigationStack {
            TaskDetailView(task: task)
                .environment(\.appUILanguage, .en)
                .environment(\.locale, Locale(identifier: "en_US"))
        }
        .modelContainer(container)
    }
}

#Preview {
    TaskDetailPreviewHost()
}
