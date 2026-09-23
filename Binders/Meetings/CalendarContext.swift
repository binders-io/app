import BindersKit
import EventKit
import Foundation

/// The calendar: the event behind a meeting, so notes get a real title and attendees, and events added by voice.
@MainActor
enum CalendarContext {
    private static let store = EKEventStore()

    struct Event {
        let title: String
        let attendees: [String]
    }

    enum CalendarError: LocalizedError {
        case accessDenied
        case noCalendar

        var errorDescription: String? {
            switch self {
            case .accessDenied: "Calendar access is off. Allow it in System Settings → Privacy & Security → Calendars."
            case .noCalendar: "There is no calendar to add to. Open Calendar and add an account first."
            }
        }
    }

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The non-all-day event in progress (or starting within 10 minutes) at `date`.
    static func event(at date: Date) -> Event? {
        guard isAuthorized else { return nil }
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-6 * 3600), end: date.addingTimeInterval(3600), calendars: nil)
        let candidates = store.events(matching: predicate).filter { event in
            !event.isAllDay && event.startDate <= date.addingTimeInterval(600) && event.endDate >= date
        }
        guard let event = candidates.min(by: { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }) else {
            return nil
        }
        let attendees = (event.attendees ?? []).compactMap { participant -> String? in
            guard !participant.isCurrentUser else { return nil }
            if let name = participant.name, !name.isEmpty, !name.contains("@") { return name }
            return participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        return Event(title: event.title ?? "", attendees: attendees)
    }

    /// Adds the event to the default calendar, asking for access first if needed. Returns the calendar it went into.
    static func add(_ draft: DraftEvent) async throws -> String {
        if !isAuthorized, !(await requestAccess()) { throw CalendarError.accessDenied }
        guard let calendar = store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications }) else {
            throw CalendarError.noCalendar
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.isAllDay = draft.allDay
        event.startDate = draft.start
        event.endDate = draft.allDay ? draft.start : draft.end
        event.location = draft.location
        try store.save(event, span: .thisEvent, commit: true)
        return calendar.title
    }
}
