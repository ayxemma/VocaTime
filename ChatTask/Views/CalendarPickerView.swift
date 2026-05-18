import EventKit
import SwiftUI

struct CalendarPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appUILanguage) private var appUILanguage

    @AppStorage(CalendarSyncSettings.AppStorageKeys.selectedCalendarID) private var selectedRaw: String = ""

    @State private var calendars: [EKCalendar] = []

    private var strings: AppStrings { appUILanguage.strings }

    var body: some View {
        List(calendars, id: \.calendarIdentifier) { cal in
            Button {
                selectedRaw = cal.calendarIdentifier
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(UIColor(cgColor: cal.cgColor)))
                        .frame(width: 10, height: 10)
                    Text(cal.title)
                        .foregroundStyle(.primary)
                    Spacer()
                    if isSelected(cal) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                            .font(.body.weight(.semibold))
                    }
                }
            }
        }
        .navigationTitle(strings.settingsCalendarPickerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            calendars = CalendarSyncService.shared.loadWritableCalendars()
        }
    }

    private func isSelected(_ cal: EKCalendar) -> Bool {
        if !selectedRaw.isEmpty {
            return cal.calendarIdentifier == selectedRaw
        }
        return cal.calendarIdentifier == calendars.first?.calendarIdentifier
    }
}

#Preview {
    NavigationStack {
        CalendarPickerView()
            .environment(\.appUILanguage, .en)
    }
}
