import SwiftData
import SwiftUI

struct TaskComposerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.appUILanguage) private var appUILanguage

    // All @State properties start at their defaults.
    // onAppear resets them explicitly on every presentation so SwiftUI's state
    // preservation across sheet presentations never leaks old values into a new task.
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDate = false
    @State private var daySelection = Calendar.current.startOfDay(for: Date())
    @State private var showDatePicker = false
    @State private var hasSpecificTime = false
    @State private var timeSelection = Date()
    @State private var showTimePicker = false
    @State private var reminderOffset: ReminderOffset = .atTime

    @FocusState private var titleFocused: Bool

    private var calendar: Calendar { .current }
    private var strings: AppStrings { appUILanguage.strings }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty
    }

    var body: some View {
        let s = strings
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TextField(s.titlePlaceholder, text: $title, axis: .vertical)
                    .font(.title3.weight(.semibold))
                    .focused($titleFocused)

                TextField(s.notesPlaceholder, text: $notes, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3...10)

                VStack(alignment: .leading, spacing: 0) {
                    composeRow(
                        label: s.date,
                        value: dateSummary,
                        expanded: showDatePicker,
                        action: {
                            if !hasDate {
                                hasDate = true
                                daySelection = calendar.startOfDay(for: Date())
                            }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showDatePicker.toggle()
                            }
                        }
                    )

                    if showDatePicker && hasDate {
                        DatePicker(
                            "",
                            selection: $daySelection,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .environment(\.locale, locale)
                        .padding(.vertical, 8)

                        Button(s.removeDate) {
                            hasDate = false
                            hasSpecificTime = false
                            showDatePicker = false
                            showTimePicker = false
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    if hasDate {
                        Divider()
                            .padding(.vertical, 4)

                        composeRow(
                            label: s.time,
                            value: timeSummary,
                            expanded: showTimePicker,
                            action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showTimePicker.toggle()
                                }
                            }
                        )

                        if showTimePicker {
                            Toggle(s.specificTime, isOn: $hasSpecificTime)
                                .padding(.vertical, 6)

                            if hasSpecificTime {
                                DatePicker(
                                    "",
                                    selection: $timeSelection,
                                    displayedComponents: .hourAndMinute
                                )
                                .labelsHidden()
                                .environment(\.locale, locale)
                                .padding(.vertical, 4)

                                Divider()
                                    .padding(.vertical, 2)

                                Picker(s.reminderLabel, selection: $reminderOffset) {
                                    ForEach(ReminderOffset.allCases) { option in
                                        Text(option.displayLabel).tag(option)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(s.newTask)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(s.cancel) {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(s.add) {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
        }
        .onAppear {
            // FIX: Reset all local state on every appearance.
            // SwiftUI can preserve @State across sheet presentations (same view
            // identity in the hierarchy). Without this reset, values from a previous
            // task creation — especially hasSpecificTime and timeSelection — carry
            // into the new task and corrupt its scheduledDate and reminder.
            title = ""
            notes = ""
            hasDate = false
            hasSpecificTime = false
            daySelection = calendar.startOfDay(for: Date())
            timeSelection = Date()
            showDatePicker = false
            showTimePicker = false
            reminderOffset = ReminderOffset.globalDefault
            titleFocused = true

            print("""
            [TaskComposer] Opened — state reset to clean defaults.
              hasDate=\(hasDate)  hasSpecificTime=\(hasSpecificTime)
              daySelection=\(daySelection)  timeSelection=\(timeSelection)
              reminderOffset=\(reminderOffset.displayLabel)
            """)
        }
    }

    // MARK: - Summaries

    private var dateSummary: String {
        let s = strings
        guard hasDate else { return s.none }
        if calendar.isDateInToday(daySelection) { return s.todaySummary }
        if calendar.isDateInTomorrow(daySelection) { return s.tomorrowSummary }
        return daySelection.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    private var timeSummary: String {
        let s = strings
        guard hasDate else { return "—" }
        if !hasSpecificTime { return s.anytime }
        return timeSelection.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    // MARK: - Row builder

    private func composeRow(
        label: String,
        value: String,
        expanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save

    private func save() {
        print("""
        [TaskComposer] Saving task —
          title='\(trimmedTitle)'
          hasDate=\(hasDate)  daySelection=\(daySelection)
          hasSpecificTime=\(hasSpecificTime)  timeSelection=\(timeSelection)
          reminderOffset=\(reminderOffset.displayLabel) (\(reminderOffset.rawValue) min)
        """)

        let notesTrimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let scheduled = TaskScheduleHelpers.scheduledDate(
            calendar: calendar,
            hasDate: hasDate,
            daySelection: daySelection,
            hasSpecificTime: hasSpecificTime,
            timeSelection: timeSelection
        )
        let item = TaskItem(
            title: trimmedTitle,
            notes: notesTrimmed.isEmpty ? nil : notesTrimmed,
            scheduledDate: scheduled,
            endDate: nil,
            isCompleted: false,
            completedAt: nil,
            createdAt: now,
            updatedAt: now,
            source: .manual,
            kind: .task,
            reminderOffsetMinutes: hasSpecificTime ? reminderOffset.rawValue : nil
        )
        modelContext.insert(item)
        try? modelContext.save()

        print("""
        [TaskComposer] Task inserted —
          id=\(item.id)
          title='\(item.title)'
          scheduledDate=\(String(describing: item.scheduledDate))
          reminderOffsetMinutes=\(String(describing: item.reminderOffsetMinutes))
        """)

        TaskReminderService.shared.schedule(for: item)
        dismiss()
    }
}

#Preview {
    NavigationStack {
        TaskComposerView()
            .environment(\.appUILanguage, .en)
            .environment(\.locale, Locale(identifier: "en_US"))
    }
    .modelContainer(for: TaskItem.self, inMemory: true)
}
