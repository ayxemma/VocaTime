import SwiftUI
import UIKit

/// Placeholder URLs — replace with your production legal pages before release.
private enum LegalURLs {
    static let privacyPolicy = URL(string: "https://www.apple.com/legal/privacy/en-ww/")!
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

struct SettingsView: View {
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.openURL) private var openURL
    @Environment(PermissionService.self) private var permissionService
    @Environment(SubscriptionManager.self) private var subscriptionManager

    @AppStorage(AppUILanguage.storageKey) private var languageRaw: String = AppUILanguage.defaultForDevice().rawValue
    @AppStorage(ReminderOffset.defaultsKey) private var reminderDefaultMinutes: Int = 0

    @State private var showPaywall = false
    @State private var showPurchaseErrorAlert = false
    @State private var purchaseErrorAlertText = ""

    private var strings: AppStrings { appUILanguage.strings }

    private var selectedReminderOffset: Binding<ReminderOffset> {
        Binding(
            get: { ReminderOffset.nearest(to: reminderDefaultMinutes) },
            set: { reminderDefaultMinutes = $0.rawValue }
        )
    }

    private var appDisplayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "ChatTask"
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        let s = strings
        Form {
            Section {
                Picker(selection: $languageRaw) {
                    ForEach(AppUILanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                } label: {
                    Text(s.appLanguage)
                }
                .pickerStyle(.menu)
            } header: {
                Text(s.settingsSectionGeneral)
            } footer: {
                Text(s.settingsUILanguageFooter)
            }

            Section {
                Picker(selection: selectedReminderOffset) {
                    ForEach(ReminderOffset.allCases) { option in
                        Text(option.displayLabel).tag(option)
                    }
                } label: {
                    Text(s.reminderDefaultLabel)
                }
                .pickerStyle(.menu)

                notificationPermissionRow
            } header: {
                Text(s.settingsSectionReminders)
            } footer: {
                Text(s.settingsReminderDefaultFooter)
            }

            Section {
                permissionRow(kind: .microphone)
                permissionRow(kind: .speech)
            } header: {
                Text(s.settingsSectionVoice)
            }

            Section {
                Button {
                    showPaywall = true
                } label: {
                    HStack {
                        Text(s.settingsSubscriptionTitle)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(
                            subscriptionManager.isProUnlocked
                                ? s.settingsSubscriptionStatusActive
                                : s.settingsSubscriptionStatusNotSubscribed
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
                .buttonStyle(.plain)

                Button {
                    Task { await restorePurchases() }
                } label: {
                    HStack {
                        if case .restoring = subscriptionManager.purchaseState {
                            ProgressView()
                                .padding(.trailing, 6)
                        }
                        Text(s.settingsRestorePurchases)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
                .disabled(isPurchaseBusy)
            } header: {
                Text(s.settingsSectionSubscription)
            }

            Section {
                Link(destination: LegalURLs.privacyPolicy) {
                    HStack {
                        Text(s.settingsPrivacyPolicy)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }

                Link(destination: LegalURLs.termsOfUse) {
                    HStack {
                        Text(s.settingsTermsOfUse)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }

                if let mailURL = contactSupportURL() {
                    Button {
                        openURL(mailURL)
                    } label: {
                        HStack {
                            Text(s.settingsContactSupport)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "envelope")
                                .font(.caption)
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                    }
                }
            } header: {
                Text(s.settingsSectionSupport)
            }

            Section {
                LabeledContent(s.settingsVersionLabel) {
                    Text(versionString)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(s.settingsAppRowLabel) {
                    Text(appDisplayName)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(s.settingsSectionAbout)
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
        .onChange(of: subscriptionManager.purchaseState) { _, newValue in
            if case .failed(let msg) = newValue {
                purchaseErrorAlertText = msg
                showPurchaseErrorAlert = true
            }
        }
        .alert(s.settingsAlertErrorTitle, isPresented: $showPurchaseErrorAlert) {
            Button("OK", role: .cancel) {
                subscriptionManager.clearPurchaseError()
            }
        } message: {
            Text(purchaseErrorAlertText)
        }
    }

    private var isPurchaseBusy: Bool {
        switch subscriptionManager.purchaseState {
        case .purchasing, .restoring: return true
        default: return false
        }
    }

    private func restorePurchases() async {
        subscriptionManager.clearPurchaseError()
        await subscriptionManager.restorePurchases()
    }

    private func contactSupportURL() -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = "support@chattask.app"
        c.queryItems = [
            URLQueryItem(name: "subject", value: "ChatTask support"),
            URLQueryItem(name: "body", value: "")
        ]
        return c.url
    }

    // MARK: - Notifications (Reminders section)

    private var notificationPermissionRow: some View {
        let s = strings
        let status = permissionService.status(for: .notifications)
        let enabled = isPermissionEnabled(status)
        return Button {
            handlePermissionTap(.notifications)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.settingsPermissionNotificationsTitle)
                        .foregroundStyle(.primary)
                    Text(s.settingsPermissionNotificationsFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Text(enabled ? s.settingsPermissionEnabled : s.settingsPermissionDisabled)
                    .font(.subheadline)
                    .foregroundStyle(enabled ? Color.green : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Voice rows

    @ViewBuilder
    private func permissionRow(kind: PermissionKind) -> some View {
        let s = strings
        let status = permissionService.status(for: kind)
        let enabled = isPermissionEnabled(status)
        Button {
            handlePermissionTap(kind)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedPermissionTitle(kind))
                        .foregroundStyle(.primary)
                    Text(localizedPermissionFooter(kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Text(enabled ? s.settingsPermissionEnabled : s.settingsPermissionDisabled)
                    .font(.subheadline)
                    .foregroundStyle(enabled ? Color.green : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func localizedPermissionTitle(_ kind: PermissionKind) -> String {
        let s = strings
        switch kind {
        case .microphone: return s.settingsPermissionMicrophoneTitle
        case .speech: return s.settingsPermissionSpeechTitle
        case .notifications: return s.settingsPermissionNotificationsTitle
        case .calendar: return s.permissionCalendar
        }
    }

    private func localizedPermissionFooter(_ kind: PermissionKind) -> String {
        let s = strings
        switch kind {
        case .microphone: return s.settingsPermissionMicrophoneFooter
        case .speech: return s.settingsPermissionSpeechFooter
        case .notifications: return s.settingsPermissionNotificationsFooter
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
            .environment(SubscriptionManager())
    }
}
