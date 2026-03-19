import AVFoundation
import EventKit
import Foundation
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

    func request(_ kind: PermissionKind) async {
        lastErrorMessage = nil
        switch kind {
        case .microphone:
            await requestMicrophone()
        case .speech:
            await requestSpeech()
        case .notifications:
            await requestNotifications()
        case .calendar:
            await requestCalendar()
        }
    }

    // MARK: - Microphone

    private func refreshMicrophone() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneStatus = mapAVAudio(status)
    }

    private func requestMicrophone() async {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        if current == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            microphoneStatus = granted ? .granted : .denied
            if !granted {
                lastErrorMessage = "Microphone access was denied. You can enable it in Settings."
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

    private func requestSpeech() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
        await refreshSpeech()
        if speechStatus == .denied {
            lastErrorMessage = "Speech recognition was denied. You can enable it in Settings."
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

    private func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = mapNotification(settings.authorizationStatus)
    }

    private func requestNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshNotifications()
            if !granted {
                lastErrorMessage = "Notifications were not allowed. You can enable them in Settings."
            }
        } catch {
            lastErrorMessage = "Could not request notifications: \(error.localizedDescription)"
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

    private func requestCalendar() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            await refreshCalendar()
            if !granted {
                lastErrorMessage = "Calendar access was denied. You can enable it in Settings."
            }
        } catch {
            lastErrorMessage = "Calendar error: \(error.localizedDescription)"
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
