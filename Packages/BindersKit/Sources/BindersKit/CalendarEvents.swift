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
///
/// Dates are never left to the model: small models copy whatever "now" they are given and invent times. The phrase at
/// the end of the text is tried first; the model is only asked to quote the title and the day and time as said, and the
/// code works those out.
public enum CalendarEventExtraction {
    public static let defaultDuration: TimeInterval = 3_600

    public static func systemPrompt() -> String {
        """
        You turn a spoken or written note into one calendar event. Do not work out dates yourself: quote them.
        Give: title, a short name for the event (what, and with whom; no day or time in it); when, the day and time exactly as the note says them ("Monday, eleven a.m.", "tomorrow at noon", "next Tuesday"), and null if the note names none; duration_minutes, a number only if the note says how long, else null; location, a place if one is named, or null.
        Reply with compact single-line JSON only: {"title":"","when":"","duration_minutes":null,"location":null}
        Not an event: {"title":null}
        """
    }

    public static func userPrompt(text: String) -> String {
        text
    }

    /// The event in the model's reply, with the quoted day and time worked out by code. Nil when the phrase isn't a time,
    /// or lands on "now" or in the past, which is what a model does when the note names no time.
    public static func parse(_ output: String, now: Date, calendar: Calendar = .current) -> DraftEvent? {
        guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8)) as? [String: Any],
              let rawTitle = object["title"] as? String, let when = object["when"] as? String else { return nil }
        let minutes = (object["duration_minutes"] as? Int) ?? (object["duration_minutes"] as? Double).map(Int.init)
        let location = (object["location"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return resolve(title: rawTitle, when: when, durationMinutes: minutes, location: location, now: now, calendar: calendar)
    }

    /// Without a model: the time phrase at the end says when, the rest is the title.
    public static func deterministic(_ text: String, now: Date, calendar: Calendar = .current) -> DraftEvent? {
        let split = CommitmentDetection.splitDue(text.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: now, calendar: calendar)
        guard let phrase = split.due else { return nil }
        return resolve(title: split.task, when: phrase, durationMinutes: nil, location: nil, now: now, calendar: calendar)
    }

    /// "doctor 's appointment and" → "Doctor's appointment": speech spacing, a leading article and a dangling "and" go.
    public static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+'(s|t|re|ll|ve|d|m)\b"#, with: "'$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+n't\b"#, with: "n't", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^(a|an|the)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)[\s,]*\b(and|at|on|for)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",;:.")))
        title = title.prefix(1).uppercased() + title.dropFirst()
        return title
    }

    private static func resolve(title rawTitle: String, when: String, durationMinutes: Int?, location: String?,
                                now: Date, calendar: Calendar) -> DraftEvent? {
        let title = cleanTitle(rawTitle)
        guard !title.isEmpty, let start = CommitmentDetection.dueDate(from: when, relativeTo: now, calendar: calendar) else { return nil }
        // A model given no time answers with the present, or a date it made up that has passed.
        guard abs(start.timeIntervalSince(now)) > 120, start > now.addingTimeInterval(-60) else { return nil }
        if !CommitmentDetection.mentionsTimeOfDay(when) {
            let day = calendar.startOfDay(for: start)
            return DraftEvent(title: title, start: day, end: day, allDay: true, location: location)
        }
        let duration = durationMinutes.map { TimeInterval(max(5, min($0, 24 * 60)) * 60) } ?? defaultDuration
        return DraftEvent(title: title, start: start, end: start.addingTimeInterval(duration), allDay: false, location: location)
    }
}
