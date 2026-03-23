import Foundation

enum TaskScheduleHelpers {
    /// Builds `scheduledDate` for a calendar day, optionally with wall-clock time (otherwise start of day / “Anytime”).
    static func scheduledDate(
        calendar: Calendar,
        hasDate: Bool,
        daySelection: Date,
        hasSpecificTime: Bool,
        timeSelection: Date
    ) -> Date? {
        guard hasDate else { return nil }
        let day = calendar.startOfDay(for: daySelection)
        if hasSpecificTime {
            let h = calendar.component(.hour, from: timeSelection)
            let m = calendar.component(.minute, from: timeSelection)
            var c = calendar.dateComponents([.year, .month, .day], from: day)
            c.hour = h
            c.minute = m
            c.second = 0
            return calendar.date(from: c) ?? day
        }
        return day
    }
}
