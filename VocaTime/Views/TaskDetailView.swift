import SwiftData
import SwiftUI

struct TaskDetailView: View {
    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @FocusState private var titleFocused: Bool

    @State private var scheduleEnabled: Bool
    @State private var daySelection: Date
    @State private var specificTimeEnabled: Bool
    @State private var timeSelection: Date

    private var calendar: Calendar { .current }

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
    }

    var body: some View {
        Form {
            Section("Task") {
                TextField("Title", text: titleBinding)
                    .focused($titleFocused)

                TextField("Notes", text: notesBinding, axis: .vertical)
                    .lineLimit(3...8)
            }

            Section("Schedule") {
                Toggle("Scheduled", isOn: $scheduleEnabled)
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
                    DatePicker("Date", selection: $daySelection, displayedComponents: .date)
                        .onChange(of: daySelection) { _, _ in
                            flushScheduleToTask()
                        }

                    Toggle("Specific time", isOn: $specificTimeEnabled)
                        .onChange(of: specificTimeEnabled) { _, _ in
                            flushScheduleToTask()
                        }

                    if specificTimeEnabled {
                        DatePicker("Time", selection: $timeSelection, displayedComponents: .hourAndMinute)
                            .onChange(of: timeSelection) { _, _ in
                                flushScheduleToTask()
                            }
                    }
                }

                Text("Leave “Specific time” off to treat the task as Anytime on that day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Completed", isOn: completionBinding)
            }

            Section {
                Button(role: .destructive) {
                    modelContext.delete(task)
                    try? modelContext.save()
                    dismiss()
                } label: {
                    Text("Delete Task")
                }
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            titleFocused = true
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { task.title },
            set: { new in
                task.title = new
                task.updatedAt = Date()
            }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { task.notes ?? "" },
            set: { new in
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                task.notes = trimmed.isEmpty ? nil : new
                task.updatedAt = Date()
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
            }
        )
    }

    private func flushScheduleToTask() {
        guard scheduleEnabled else {
            task.scheduledDate = nil
            task.updatedAt = Date()
            return
        }

        let day = calendar.startOfDay(for: daySelection)
        if specificTimeEnabled {
            let h = calendar.component(.hour, from: timeSelection)
            let m = calendar.component(.minute, from: timeSelection)
            var c = calendar.dateComponents([.year, .month, .day], from: day)
            c.hour = h
            c.minute = m
            c.second = 0
            task.scheduledDate = calendar.date(from: c) ?? day
        } else {
            task.scheduledDate = day
        }
        task.updatedAt = Date()
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
        }
        .modelContainer(container)
    }
}

#Preview {
    TaskDetailPreviewHost()
}
