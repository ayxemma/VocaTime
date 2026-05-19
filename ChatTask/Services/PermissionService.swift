import AVFoundation
import EventKit
import Foundation
import os.log
import Speech
import UserNotifications

enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case speech
    case notifications
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        case .notifications: return "Notifications"
        case .calendar: return "Calendar"
        }
    }

    var usageExplanation: String {
        switch self {
        case .microphone:
            return "Needed to hear your voice commands."
        case .speech:
            return "Needed to turn speech into text."
        case .notifications:
            return "Needed to remind you at the right time."
        case .calendar:
            return "Needed to add events to your calendar."
        }
    }
}

enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
    case provisional
    case unknown

    var label: String {
        switch self {
        case .notDetermined: return "Not asked"
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .provisional: return "Provisional"
        case .unknown: return "Unknown"
        }
    }
}

@MainActor
@Observable
final class PermissionService {
    private let eventStore = EKEventStore()
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChatTask", category: "Permission")

    private(set) var microphoneStatus: PermissionStatus = .unknown
    private(set) var speechStatus: PermissionStatus = .unknown
    private(set) var notificationStatus: PermissionStatus = .unknown
    private(set) var calendarStatus: PermissionStatus = .unknown

    var lastErrorMessage: String?

    func refreshAll() async {
        await refreshMicrophone()
        await refreshSpeech()
        await refreshNotifications()
        await refreshCalendar()
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone: return microphoneStatus
        case .speech: return speechStatus
        case .notifications: return notificationStatus
        case .calendar: return calendarStatus
        }
    }

    func request(_ kind: PermissionKind, language: AppUILanguage) async {
        lastErrorMessage = nil
        let s = language.strings
        switch kind {
        case .microphone:
            await requestMicrophone(messageDenied: s.permissionMicDeniedAfterRequest)
        case .speech:
            await requestSpeech(messageDenied: s.permissionSpeechDeniedAfterRequest)
        case .notifications:
            await requestNotifications(strings: s)
        case .calendar:
            await requestCalendar(strings: s)
        }
    }

    // MARK: - Microphone

    private func refreshMicrophone() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneStatus = mapAVAudio(status)
    }

    private func requestMicrophone(messageDenied: String) async {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        if current == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            microphoneStatus = granted ? .granted : .denied
            if !granted {
                lastErrorMessage = messageDenied
            }
        } else {
            await refreshMicrophone()
        }
    }

    private func mapAVAudio(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .granted
        @unknown default: return .unknown
        }
    }

    // MARK: - Speech

    private func refreshSpeech() async {
        let status = SFSpeechRecognizer.authorizationStatus()
        speechStatus = mapSpeech(status)
    }

    private func requestSpeech(messageDenied: String) async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
        await refreshSpeech()
        if speechStatus == .denied {
            lastErrorMessage = messageDenied
        }
    }

    private func mapSpeech(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .granted
        @unknown default: return .unknown
        }
    }

    // MARK: - Notifications

    private static var notificationAuthorizationOptions: UNAuthorizationOptions {
        [.alert, .sound, .timeSensitive]
    }

    /// Silently requests notification permission on first app launch.
    /// Does nothing if the user has already made a decision.
    func requestNotificationsIfNeeded() async {
        await refreshNotifications()
        guard notificationStatus == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: Self.notificationAuthorizationOptions)
        await refreshNotifications()
    }

    private func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = mapNotification(settings.authorizationStatus)
    }

    private func requestNotifications(strings: AppStrings) async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: Self.notificationAuthorizationOptions.union([.badge]))
            await refreshNotifications()
            if !granted {
                lastErrorMessage = strings.permissionNotificationsDenied
            }
        } catch {
            lastErrorMessage = "\(strings.permissionNotificationsErrorPrefix) \(error.localizedDescription)"
            await refreshNotifications()
        }
    }

    private func mapNotification(_ status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .granted
        case .provisional: return .provisional
        case .ephemeral: return .granted
        @unknown default: return .unknown
        }
    }

    // MARK: - Calendar (iOS 17+ full access API)

    private func refreshCalendar() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        calendarStatus = mapEKStatus(status)
    }

    private func requestCalendar(strings: AppStrings) async {
        Self.log.info("calendarPermissionRequested")
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            await refreshCalendar()
            if granted {
                Self.log.info("calendarPermissionGranted")
            } else {
                Self.log.info("calendarPermissionDenied")
                lastErrorMessage = strings.permissionCalendarDenied
            }
        } catch {
            Self.log.info("calendarPermissionDenied")
            lastErrorMessage = "\(strings.permissionCalendarErrorPrefix) \(error.localizedDescription)"
            await refreshCalendar()
        }
    }

    private func mapEKStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess, .writeOnly: return .granted
        @unknown default: return .unknown
        }
    }
}
