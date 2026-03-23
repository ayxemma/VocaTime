import SwiftData
import SwiftUI

struct TaskComposerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDate = false
    @State private var daySelection = Calendar.current.startOfDay(for: Date())
    @State private var showDatePicker = false
    @State private var hasSpecificTime = false
    @State private var timeSelection = Date()
    @State private var showTimePicker = false

    @FocusState private var titleFocused: Bool

    private var calendar: Calendar { .current }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TextField("Title", text: $title, axis: .vertical)
                    .font(.title3.weight(.semibold))
                    .focused($titleFocused)

                TextField("Notes", text: $notes, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3...10)

                VStack(alignment: .leading, spacing: 0) {
                    composeRow(
                        label: "Date",
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
                        .padding(.vertical, 8)

                        Button("Remove date") {
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
                            label: "Time",
                            value: timeSummary,
                            expanded: showTimePicker,
                            action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showTimePicker.toggle()
                                }
                            }
                        )

                        if showTimePicker {
                            Toggle("Specific time", isOn: $hasSpecificTime)
                                .padding(.vertical, 6)

                            if hasSpecificTime {
                                DatePicker(
                                    "",
                                    selection: $timeSelection,
                                    displayedComponents: .hourAndMinute
                                )
                                .labelsHidden()
                                .padding(.vertical, 4)
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
        .navigationTitle("New Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
        }
        .onAppear {
            titleFocused = true
        }
    }

    private var dateSummary: String {
        guard hasDate else { return "None" }
        if calendar.isDateInToday(daySelection) { return "Today" }
        if calendar.isDateInTomorrow(daySelection) { return "Tomorrow" }
        return Self.mediumDateFormatter.string(from: daySelection)
    }

    private var timeSummary: String {
        guard hasDate else { return "—" }
        if !hasSpecificTime { return "Anytime" }
        return Self.timeOnlyFormatter.string(from: timeSelection)
    }

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

    private func save() {
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
            kind: .task
        )
        modelContext.insert(item)
        try? modelContext.save()
        dismiss()
    }

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

#Preview {
    NavigationStack {
        TaskComposerView()
    }
    .modelContainer(for: TaskItem.self, inMemory: true)
}
