import SwiftUI

struct SettingsView: View {
    @Environment(\.appUILanguage) private var appUILanguage
    @AppStorage(AppUILanguage.storageKey) private var languageRaw: String = AppUILanguage.defaultForDevice().rawValue
    @AppStorage(ReminderOffset.defaultsKey) private var reminderDefaultMinutes: Int = 0

    private var strings: AppStrings { appUILanguage.strings }

    private var selectedReminderOffset: Binding<ReminderOffset> {
        Binding(
            get: { ReminderOffset.nearest(to: reminderDefaultMinutes) },
            set: { reminderDefaultMinutes = $0.rawValue }
        )
    }

    var body: some View {
        let s = strings
        List {
            Section(s.appLanguage) {
                Picker(s.appLanguage, selection: $languageRaw) {
                    ForEach(AppUILanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section(s.reminderDefaultLabel) {
                Picker(s.reminderLabel, selection: selectedReminderOffset) {
                    ForEach(ReminderOffset.allCases) { option in
                        Text(option.displayLabel).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle(s.settingsNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(\.appUILanguage, .en)
    }
}
