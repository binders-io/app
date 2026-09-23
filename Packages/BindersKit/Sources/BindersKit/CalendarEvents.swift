import Foundation

/// An event ready to go on the calendar.
public struct DraftEvent: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String?

    public init(title: String, start: Date, end: Date, allDay: Bool = false, location: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
    }
}

/// Turns "lunch with Sam tomorrow at noon", or a dictated paragraph, into one calendar event.
public enum CalendarEventExtraction {
    public static let defaultDuration: TimeInterval = 3_600

    public static func systemPrompt() -> String {
        """
        You turn a spoken or written note into one calendar event.
        Give: title, a short name for the event (what, and with whom; no date or time in it); start, the start as local time in the form YYYY-MM-DDTHH:MM; end, the end the same way, or null when none is said; all_day, true only when a day is named but no time; location, a place if one is named, or null.
        Work out relative days ("tomorrow", "next Tuesday") from the current date given. Never invent a time: when only a day is said, set all_day true.
        Reply with compact single-line JSON only: {"title":"","start":"","end":null,"all_day":false,"location":null}
        Not an event, or no day at all: {"title":null}
        """
    }

    public static func userPrompt(text: String, now: Date) -> String {
        "Now: \(now.formatted(date: .complete, time: .shortened)).\n\n" + text
    }

    /// Reads the model's reply; tolerates fences and prose around the JSON, and a time phrase where a date was asked for.
    public static func parse(_ output: String, now: Date, calendar: Calendar = .current) -> DraftEvent? {
        guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8)) as? [String: Any],
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let startText = object["start"] as? String, let start = date(from: startText, now: now, calendar: calendar) else { return nil }
        let allDay = object["all_day"] as? Bool ?? false
        var event = DraftEvent(title: title, start: start, end: start.addingTimeInterval(defaultDuration), allDay: allDay,
                               location: (object["location"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
        if let endText = object["end"] as? String, let end = date(from: endText, now: now, calendar: calendar), end > start {
            event.end = end
        }
        if allDay {
            event.start = calendar.startOfDay(for: start)
            event.end = event.start
        }
        return event
    }

    /// Without a model: the time phrase at the end says when, the rest is the title. A day with no time is an all-day event.
    public static func fallback(_ text: String, now: Date, calendar: Calendar = .current) -> DraftEvent? {
        let split = CommitmentDetection.splitDue(text.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: now, calendar: calendar)
        guard let start = split.dueAt, let phrase = split.due else { return nil }
        var title = split.task.replacingOccurrences(of: #"(?i)^(a|an|the)\s+"#, with: "", options: .regularExpression)
        guard !title.isEmpty else { return nil }
        title = title.prefix(1).uppercased() + title.dropFirst()
        if CommitmentDetection.mentionsTimeOfDay(phrase) {
            return DraftEvent(title: title, start: start, end: start.addingTimeInterval(defaultDuration))
        }
        let day = calendar.startOfDay(for: start)
        return DraftEvent(title: title, start: day, end: day, allDay: true)
    }

    private static func date(from text: String, now: Date, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
        return CommitmentDetection.dueDate(from: trimmed, relativeTo: now, calendar: calendar)
    }
}
