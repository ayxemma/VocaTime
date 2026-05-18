import EventKit
import Foundation
import os.log
import SwiftData
import UIKit

/// EventKit-backed calendar sync: outbound ChatTask → Apple Calendar, read-only import for the calendar UI.
@MainActor
final class CalendarSyncService {
    static let shared = CalendarSyncService()

    private let store = EKEventStore()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChatTask", category: "CalendarSync")

    private init() {}

    // MARK: - Authorization

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var hasCalendarAccess: Bool {
        switch authorizationStatus() {
        case .fullAccess, .writeOnly: return true
        case .notDetermined, .restricted, .denied: return false
        @unknown default: return false
        }
    }

    /// Writable event calendars (local / iCloud / subscribed where allowed).
    func loadWritableCalendars() -> [EKCalendar] {
        let all = store.calendars(for: .event).filter(\.allowsContentModifications)
        log.info("calendarsLoaded count=\(all.count)")
        return all.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func resolveWritableCalendar() -> EKCalendar? {
        let writable = loadWritableCalendars()
        guard !writable.isEmpty else { return nil }
        if let id = CalendarSyncSettings.selectedCalendarIdentifier,
           let match = writable.first(where: { $0.calendarIdentifier == id }) {
            return match
        }
        if let first = writable.first {
            CalendarSyncSettings.selectedCalendarIdentifier = first.calendarIdentifier
            return first
        }
        return nil
    }

    func selectedOrFirstCalendarTitle() -> String? {
        resolveWritableCalendar()?.title
    }

    // MARK: - Outbound sync

    /// Call after creating a task or changing schedule: sets `calendarSyncEnabled` when settings allow.
    func applyOutboundEligibility(for task: TaskItem) {
        guard CalendarSyncSettings.isOutboundEnabled else {
            task.calendarSyncEnabled = false
            return
        }
        guard let scheduled = task.scheduledDate,
              TaskScheduleFormatting.hasWallClockTime(scheduled, calendar: .current)
        else {
            task.calendarSyncEnabled = false
            return
        }
        task.calendarSyncEnabled = true
    }

    /// Qualifying task: has specific time and per-task sync flag.
    private func taskQualifiesForPersistedCalendarEvent(_ task: TaskItem) -> Bool {
        guard let scheduled = task.scheduledDate,
              TaskScheduleFormatting.hasWallClockTime(scheduled, calendar: .current)
        else { return false }
        return task.calendarSyncEnabled
    }

    /// Writes/updates/deletes the Calendar event for this task.
    func syncOutbound(for task: TaskItem, modelContext: ModelContext) {
        let qualifies = taskQualifiesForPersistedCalendarEvent(task)

        if !qualifies {
            if task.calendarEventIdentifier != nil {
                removeCalendarEvent(for: task, modelContext: modelContext, logDeletion: true)
            }
            return
        }

        guard CalendarSyncSettings.isOutboundEnabled else { return }
        guard hasCalendarAccess else { return }

        guard let targetCalendar = resolveWritableCalendar() else {
            log.error("calendarSyncFailed reason=noWritableCalendar")
            return
        }

        let cal = Calendar.current
        let start = task.scheduledDate!
        let end = endDate(for: task, start: start, calendar: cal)

        if let existingID = task.calendarEventIdentifier,
           let existing = store.event(withIdentifier: existingID) {
            if existing.calendar.calendarIdentifier != targetCalendar.calendarIdentifier {
                existing.calendar = targetCalendar
                task.calendarIdentifier = targetCalendar.calendarIdentifier
            }
        configure(event: existing, task: task, start: start, end: end)
            do {
                try store.save(existing, span: task.isRecurring ? .futureEvents : .thisEvent)
                log.info("calendarEventUpdated task=\(task.id.uuidString, privacy: .public) eventId=\(existing.eventIdentifier ?? "", privacy: .public)")
            } catch {
                log.error("calendarEventSaveFailed error=\(String(describing: error), privacy: .public)")
                clearCalendarLink(for: task, modelContext: modelContext)
            }
            return
        }

        if let existingID = task.calendarEventIdentifier,
           store.event(withIdentifier: existingID) == nil {
            log.info("calendarEventMissing clearingIdentifier task=\(task.id.uuidString, privacy: .public)")
            task.calendarEventIdentifier = nil
            task.calendarIdentifier = nil
        }

        let event = EKEvent(eventStore: store)
        event.calendar = targetCalendar
        configure(event: event, task: task, start: start, end: end)

        do {
            try store.save(event, span: task.isRecurring ? .futureEvents : .thisEvent)
            if let ident = event.eventIdentifier {
                task.calendarEventIdentifier = ident
                task.calendarIdentifier = targetCalendar.calendarIdentifier
                task.externalCalendarSource = "apple"
                try? modelContext.save()
                log.info("calendarEventCreated task=\(task.id.uuidString, privacy: .public) eventId=\(ident, privacy: .public)")
            }
        } catch {
            log.error("calendarEventCreateFailed error=\(String(describing: error), privacy: .public)")
        }
    }

    private func configure(event: EKEvent, task: TaskItem, start: Date, end: Date) {
        event.title = task.title
        event.notes = task.notes
        event.startDate = start
        event.endDate = end
        event.isAllDay = false
        event.alarms = nil

        if task.isRecurring, task.recurrenceFrequency == .weekly {
            let days = ekWeekdays(from: task.recurrenceWeekdays)
            if days.isEmpty {
                event.recurrenceRules = nil
            } else {
                let endRule: EKRecurrenceEnd? = task.recurrenceEndDate.map { EKRecurrenceEnd(end: $0) }
                let rule = EKRecurrenceRule(
                    recurrenceWith: .weekly,
                    interval: 1,
                    daysOfTheWeek: days,
                    daysOfTheMonth: nil,
                    monthsOfTheYear: nil,
                    weeksOfTheYear: nil,
                    daysOfTheYear: nil,
                    setPositions: nil,
                    end: endRule
                )
                event.recurrenceRules = [rule]
            }
        } else {
            event.recurrenceRules = nil
        }
    }

    private func endDate(for task: TaskItem, start: Date, calendar: Calendar) -> Date {
        switch task.kind {
        case .event:
            if let taskEnd = task.endDate, taskEnd > start { return taskEnd }
            return calendar.date(byAdding: .minute, value: 30, to: start) ?? start.addingTimeInterval(1800)
        case .task, .reminder:
            return calendar.date(byAdding: .minute, value: 15, to: start) ?? start.addingTimeInterval(900)
        }
    }

    /// ISO weekday 1=Monday…7=Sunday → EventKit weekday (1=Sunday…).
    private func ekWeekdays(from isoWeekdays: [Int]) -> [EKRecurrenceDayOfWeek] {
        let unique = Array(Set(isoWeekdays.filter { (1...7).contains($0) })).sorted()
        return unique.compactMap { iso in
            let ekRaw = iso == 7 ? 1 : iso + 1
            guard let w = EKWeekday(rawValue: ekRaw) else { return nil }
            return EKRecurrenceDayOfWeek(w)
        }
    }

    func removeCalendarEvent(for task: TaskItem, modelContext: ModelContext, logDeletion: Bool) {
        guard let id = task.calendarEventIdentifier else { return }
        if let event = self.store.event(withIdentifier: id) {
            do {
                let isRecurring = !(event.recurrenceRules?.isEmpty ?? true)
                try store.remove(event, span: isRecurring ? .futureEvents : .thisEvent)
                if logDeletion {
                    log.info("calendarEventDeleted task=\(task.id.uuidString, privacy: .public) eventId=\(id, privacy: .public)")
                }
            } catch {
                log.error("calendarEventDeleteFailed error=\(String(describing: error), privacy: .public)")
            }
        } else if logDeletion {
            log.info("calendarEventMissing clearingIdentifier task=\(task.id.uuidString, privacy: .public)")
        }
        clearCalendarLink(for: task, modelContext: modelContext)
    }

    private func clearCalendarLink(for task: TaskItem, modelContext: ModelContext) {
        task.calendarEventIdentifier = nil
        task.calendarIdentifier = nil
        task.externalCalendarSource = nil
        try? modelContext.save()
    }

    // MARK: - Import (read-only display)

    func loadImportedDisplayItems(in interval: DateInterval, excludingChatTaskEventIDs: Set<String>) -> [CalendarDisplayItem] {
        guard CalendarSyncSettings.importAppleEventsEnabled else { return [] }
        guard hasCalendarAccess else { return [] }

        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        let events = store.events(matching: predicate)
        let filtered = events.filter { ev in
            guard let ident = ev.eventIdentifier else { return true }
            return !excludingChatTaskEventIDs.contains(ident)
        }

        let items = filtered.map { ev -> CalendarDisplayItem in
            let color = UIColor(cgColor: ev.calendar.cgColor)
            return CalendarDisplayItem(
                id: ev.eventIdentifier ?? UUID().uuidString,
                source: .appleCalendar,
                title: ev.title,
                startDate: ev.startDate,
                endDate: ev.endDate,
                calendarName: ev.calendar.title,
                color: color,
                externalID: ev.eventIdentifier,
                notes: ev.notes
            )
        }
        .sorted { $0.startDate < $1.startDate }

        log.info("importedCalendarEventsLoaded count=\(items.count)")
        return items
    }

    /// Month grid buffer: one month before/after visible month.
    static func fetchInterval(for monthStart: Date, calendar: Calendar) -> DateInterval? {
        guard let start = calendar.date(byAdding: .month, value: -1, to: monthStart),
              let intervalStart = calendar.dateInterval(of: .month, for: start)?.start,
              let end = calendar.date(byAdding: .month, value: 2, to: monthStart),
              let intervalEnd = calendar.dateInterval(of: .month, for: end)?.end
        else { return nil }
        return DateInterval(start: intervalStart, end: intervalEnd)
    }
}
