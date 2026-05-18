import SwiftUI
import UIKit

enum CalendarDisplaySource: String, Equatable {
    case chatTask
    case appleCalendar
}

/// Lightweight model for the in-app calendar: ChatTask rows use `TaskItem`; Apple Calendar uses this.
struct CalendarDisplayItem: Identifiable {
    var id: String
    var source: CalendarDisplaySource
    var title: String
    var startDate: Date
    var endDate: Date
    var calendarName: String?
    var color: UIColor
    var externalID: String?
    var notes: String?

    var swiftUIColor: Color { Color(self.color) }
}
