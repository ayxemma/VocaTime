import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.openURL) private var openURL
    @Environment(PermissionService.self) private var permissionService
    @AppStorage(AppUILanguage.storageKey) private var languageRaw: String = AppUILanguage.defaultForDevice().rawValue
    @AppStorage(ReminderOffset.defaultsKey) private var reminderDefaultMinutes: Int = 0

    @State private var showPaywall = false

    private var strings: AppStrings { appUILanguage.strings }

    /// Rows shown in Settings (calendar is managed elsewhere).
    private let settingsPermissionKinds: [PermissionKind] = [.notifications, .microphone, .speech]

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

            Section {
                ForEach(settingsPermissionKinds) { kind in
                    permissionRow(kind: kind)
                }
            } header: {
                Text(s.settingsPermissionsSection)
            }

            // Developer preview — remove before shipping
            Section("Developer") {
                Button("Preview Paywall") {
                    showPaywall = true
                }
                .foregroundStyle(Color.accentColor)
            }
        }
        .navigationTitle(s.settingsNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .task {
            await permissionService.refreshAll()
        }
    }

    @ViewBuilder
    private func permissionRow(kind: PermissionKind) -> some View {
        let s = strings
        let status = permissionService.status(for: kind)
        let enabled = isPermissionEnabled(status)
        Button {
            handlePermissionTap(kind)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(localizedPermissionTitle(kind))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(enabled ? s.settingsPermissionEnabled : s.settingsPermissionDisabled)
                        .font(.subheadline)
                        .foregroundStyle(enabled ? Color.green : Color.secondary)
                }
                Text(localizedPermissionFooter(kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func localizedPermissionTitle(_ kind: PermissionKind) -> String {
        let s = strings
        switch kind {
        case .notifications: return s.settingsPermissionNotificationsTitle
        case .microphone: return s.settingsPermissionMicrophoneTitle
        case .speech: return s.settingsPermissionSpeechTitle
        case .calendar: return s.permissionCalendar
        }
    }

    private func localizedPermissionFooter(_ kind: PermissionKind) -> String {
        let s = strings
        switch kind {
        case .notifications: return s.settingsPermissionNotificationsFooter
        case .microphone: return s.settingsPermissionMicrophoneFooter
        case .speech: return s.settingsPermissionSpeechFooter
        case .calendar: return s.permissionCalendarExplanation
        }
    }

    private func isPermissionEnabled(_ status: PermissionStatus) -> Bool {
        switch status {
        case .granted, .provisional: return true
        case .notDetermined, .denied, .restricted, .unknown: return false
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func handlePermissionTap(_ kind: PermissionKind) {
        let status = permissionService.status(for: kind)
        switch status {
        case .granted, .provisional:
            openSystemSettings()
        case .notDetermined:
            Task { await permissionService.request(kind, language: appUILanguage) }
        case .denied, .restricted, .unknown:
            openSystemSettings()
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(\.appUILanguage, .en)
            .environment(PermissionService())
    }
}
