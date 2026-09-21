import EventKit
import Foundation

/// Finds the calendar event for a meeting so notes get a real title and attendee names.
@MainActor
enum CalendarContext {
    private static let store = EKEventStore()

    struct Event {
        let title: String
        let attendees: [String]
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
}
