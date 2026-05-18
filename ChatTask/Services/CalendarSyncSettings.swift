import Foundation

/// User defaults for Apple Calendar (EventKit) integration — all off by default.
enum CalendarSyncSettings {
    enum AppStorageKeys {
        static let master = "calendarSyncMasterEnabled"
        static let timedTasks = "calendarSyncTimedTasksEnabled"
        static let importApple = "calendarImportAppleEventsEnabled"
        static let selectedCalendarID = "calendarSyncSelectedCalendarIdentifier"
    }

    private static let defaults = UserDefaults.standard

    static var masterEnabled: Bool {
        get { defaults.bool(forKey: AppStorageKeys.master) }
        set { defaults.set(newValue, forKey: AppStorageKeys.master) }
    }

    static var syncTimedTasksEnabled: Bool {
        get { defaults.bool(forKey: AppStorageKeys.timedTasks) }
        set { defaults.set(newValue, forKey: AppStorageKeys.timedTasks) }
    }

    static var importAppleEventsEnabled: Bool {
        get { defaults.bool(forKey: AppStorageKeys.importApple) }
        set { defaults.set(newValue, forKey: AppStorageKeys.importApple) }
    }

    static var selectedCalendarIdentifier: String? {
        get {
            let s = defaults.string(forKey: AppStorageKeys.selectedCalendarID) ?? ""
            return s.isEmpty ? nil : s
        }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: AppStorageKeys.selectedCalendarID)
            } else {
                defaults.removeObject(forKey: AppStorageKeys.selectedCalendarID)
            }
        }
    }

    /// Master + “sync timed tasks” — outbound writes allowed when permission and calendar exist.
    static var isOutboundEnabled: Bool {
        masterEnabled && syncTimedTasksEnabled
    }
}
