import Foundation

/// One thing a message commits somebody to: a promise the writer made, or something the writer asked of the reader.
public struct DetectedCommitment: Codable, Equatable, Sendable {
    public var kind: String
    public var task: String
    public var to: String?
    public var due: String?
    public var quote: String?

    public init(kind: String = "promise", task: String, to: String? = nil, due: String? = nil, quote: String? = nil) {
        self.kind = kind
        self.task = task
        self.to = to
        self.due = due
        self.quote = quote
    }

    public var isPromise: Bool { kind != "ask" }
}

/// Finds the promises in something you wrote ("I'll send the deck by Friday") so they can become to-dos.
public enum CommitmentDetection {
    private struct Envelope: Decodable { var commitments: [DetectedCommitment] }

    /// A cheap first pass: only messages with first-person future intent or a direct request go to the model.
    public static func mayContainCommitment(_ text: String) -> Bool {
        let pattern = #"(?i)\b(i'?ll|i will|i'm going to|i am going to|i'm gonna|gonna|i can|let me|leave it with me|leave that with me|on it|i promise|"#
            + #"will (send|do|get|have|share|check|call|book|follow|set|fix|review|look|update|ping|circle|reach|schedule|draft|write|prepare|bring|drop|forward|confirm)|"#
            + #"i'?ll (send|do|get|have|share|check|call|book|follow|set|fix|review|look|update|ping|circle|reach|schedule|draft|write|prepare|bring|drop|forward|confirm)|"#
            + #"consider it done|count on me|expect it|you'll have|by (eod|cob|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|end of|next week|the end)|"#
            + #"can you|could you|would you|please (send|share|review|check|confirm|let me|get|book|update)|need you to|remind me)\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    public static func systemPrompt() -> String {
        """
        You read one message a person wrote and sent. Find the commitments in it.
        A promise is something the WRITER says they will do: send, deliver, call, check, fix, follow up, book, review, introduce, pay.
        An ask is something the writer explicitly asks the RECIPIENT to do that has a concrete deliverable.
        Skip pleasantries, hypotheticals, questions with no deliverable, things already done, and anything a third party will do.
        For each commitment give: kind ("promise" or "ask"); task, a short imperative phrase starting with a verb that names the deliverable and the person, reusing the message's own words; to, the person it is promised to or asked of, or null; due, the deadline exactly as the message says it ("Friday", "tomorrow morning", "EOD", "next week", "Sept 20"), or null; quote, the sentence it came from.
        Reply with compact single-line JSON only: {"commitments":[{"kind":"promise","task":"","to":null,"due":null,"quote":""}]}
        No commitments: {"commitments":[]}
        """
    }

    public static func userPrompt(text: String, app: String?, recipients: String?, subject: String?, date: Date) -> String {
        var header = "Written"
        if let app, !app.isEmpty { header += " in \(app)" }
        if let recipients, !recipients.isEmpty { header += " to \(recipients)" }
        if let subject, !subject.isEmpty { header += ", subject: \(subject)" }
        header += " on \(date.formatted(date: .complete, time: .shortened))."
        return header + "\n\n" + text
    }

    /// Tolerates code fences and prose around the JSON; salvages well-formed objects from a malformed reply.
    public static func parse(_ output: String) -> [DetectedCommitment] {
        if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
           let decoded = try? JSONDecoder().decode(Envelope.self, from: Data(output[start...end].utf8)) {
            return clean(decoded.commitments)
        }
        if let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]"), start < end,
           let decoded = try? JSONDecoder().decode([DetectedCommitment].self, from: Data(output[start...end].utf8)) {
            return clean(decoded)
        }
        guard let objects = try? NSRegularExpression(pattern: #"\{[^{}]*\}"#) else { return [] }
        let text = output as NSString
        var found: [DetectedCommitment] = []
        for match in objects.matches(in: output, range: NSRange(location: 0, length: text.length)) {
            let object = text.substring(with: match.range)
            guard let task = field("task", in: object) else { continue }
            found.append(DetectedCommitment(kind: field("kind", in: object) ?? "promise", task: task, to: field("to", in: object),
                                            due: field("due", in: object), quote: field("quote", in: object)))
        }
        return clean(found)
    }

    static func clean(_ items: [DetectedCommitment]) -> [DetectedCommitment] {
        var seen = Set<String>()
        var result: [DetectedCommitment] = []
        for var item in items {
            item.task = item.task.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            guard item.task.count >= 4, item.task.count <= 200 else { continue }
            item.task = item.task.prefix(1).uppercased() + item.task.dropFirst()
            item.kind = item.kind.lowercased() == "ask" ? "ask" : "promise"
            item.to = blankToNil(item.to)
            item.due = blankToNil(item.due)
            item.quote = blankToNil(item.quote)
            let key = item.task.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(item)
        }
        return result
    }

    /// "Send you the deck" reads badly on a to-do list; with the recipient known it becomes "Send Noah the deck".
    public static func personalize(_ item: DetectedCommitment, recipient: String?) -> DetectedCommitment {
        guard item.isPromise, let name = (item.to ?? recipient)?.split(separator: " ").first.map(String.init), !name.isEmpty else { return item }
        var copy = item
        copy.task = copy.task.replacingOccurrences(of: #"(?i)\byourself\b"#, with: name, options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\byour\b"#, with: name + "'s", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\byou\b"#, with: name, options: .regularExpression)
        return copy
    }

    private static func blankToNil(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !["null", "none", "n/a", "unknown", "-"].contains(value.lowercased()) else { return nil }
        return value
    }

    private static func field(_ name: String, in object: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"\(name)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""),
              let match = regex.firstMatch(in: object, range: NSRange(location: 0, length: (object as NSString).length)) else { return nil }
        let raw = (object as NSString).substring(with: match.range(at: 1))
        return raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: " ")
    }

    // MARK: Due dates

    /// Turns "Friday", "tomorrow morning", "EOD", "next week", "in 2 days", "Sept 20", "9/20", "3pm" into a moment.
    /// Day-level deadlines land at 5 pm. Returns nil when the phrase isn't a time at all.
    public static func dueDate(from phrase: String?, relativeTo now: Date, calendar: Calendar = .current) -> Date? {
        guard var text = phrase?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = normalizeSpokenTime(text)
        text = text.replacingOccurrences(of: #"^(by|on|before|until|till|for|due|around|at)\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b(the|this coming|coming)\s+"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,!"))
        let cal = calendar
        let today = cal.startOfDay(for: now)
        func at(_ day: Date, hour: Int = 17, minute: Int = 0) -> Date {
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today) ?? today }
        let time = timeOfDay(in: text)
        let hour = time?.hour
        let minute = time?.minute ?? 0

        func dayResult(_ base: Date, defaultHour: Int = 17) -> Date {
            at(base, hour: hour ?? defaultHour, minute: minute)
        }

        if text.range(of: #"\b(eod|cob|end of (the )?day|end of today|later today|today|this afternoon|this evening|tonight)\b"#, options: .regularExpression) != nil {
            let evening = text.contains("tonight") || text.contains("evening")
            let candidate = dayResult(today, defaultHour: evening ? 20 : 17)
            return candidate > now ? candidate : nil
        }
        if text.range(of: #"\btomorrow\b"#, options: .regularExpression) != nil {
            let defaultHour = text.contains("morning") ? 10 : (text.contains("afternoon") ? 15 : (text.contains("evening") || text.contains("night") ? 20 : 17))
            return dayResult(day(1), defaultHour: defaultHour)
        }
        if text.range(of: #"\b(end of (the )?week|eow|this week|end of this week)\b"#, options: .regularExpression) != nil {
            return dayResult(nextWeekday(6, from: today, includeToday: true, calendar: cal))
        }
        if text.range(of: #"\b(early|beginning of|start of) next week\b"#, options: .regularExpression) != nil {
            return dayResult(cal.date(byAdding: .day, value: 1, to: nextWeekday(2, from: today, includeToday: false, calendar: cal)) ?? today)
        }
        if text.range(of: #"\bnext week\b"#, options: .regularExpression) != nil {
            let monday = nextWeekday(2, from: today, includeToday: false, calendar: cal)
            return dayResult(cal.date(byAdding: .day, value: 4, to: monday) ?? monday)
        }
        if text.range(of: #"\b(end of (the )?month|eom)\b"#, options: .regularExpression) != nil,
           let range = cal.range(of: .day, in: .month, for: today),
           let last = cal.date(bySetting: .day, value: range.count, of: today) {
            return dayResult(cal.startOfDay(for: last))
        }
        if let match = text.range(of: #"\bin (\d+|a|an|one|two|three|four|five|six|seven|ten) (minute|hour|day|week|month)s?\b"#, options: .regularExpression) {
            let parts = text[match].split(separator: " ")
            let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "ten": 10]
            let amount = Int(parts[1]) ?? words[String(parts[1])] ?? 1
            let unit = String(parts[2]).hasPrefix("minute") ? Calendar.Component.minute
                : (String(parts[2]).hasPrefix("hour") ? .hour : (String(parts[2]).hasPrefix("day") ? .day : (String(parts[2]).hasPrefix("week") ? .weekOfYear : .month)))
            guard let date = cal.date(byAdding: unit, value: amount, to: now) else { return nil }
            return unit == .minute || unit == .hour ? date : dayResult(cal.startOfDay(for: date))
        }
        let weekdays = ["sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3, "wednesday": 4, "wed": 4,
                        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5, "friday": 6, "fri": 6, "saturday": 7, "sat": 7]
        if let match = text.range(of: #"\b(next\s+)?(sunday|sun|monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat)\b"#, options: .regularExpression) {
            let phrase = text[match].split(separator: " ")
            let isNext = phrase.first == "next"
            let name = String(phrase.last ?? "")
            if let weekday = weekdays[name] {
                var base = nextWeekday(weekday, from: today, includeToday: !isNext, calendar: cal)
                if isNext, cal.component(.weekday, from: today) == weekday { base = cal.date(byAdding: .day, value: 7, to: today) ?? base }
                return dayResult(base)
            }
        }
        if let date = explicitDate(in: text, today: today, calendar: cal) {
            return dayResult(date)
        }
        if let time, text.range(of: #"^\s*(\d{1,2}(:\d{2})?\s*(am|pm)?|noon|midday|midnight)\s*$"#, options: .regularExpression) != nil {
            let candidate = at(today, hour: time.hour, minute: time.minute)
            return candidate > now ? candidate : at(day(1), hour: time.hour, minute: time.minute)
        }
        return nil
    }

    /// Splits the time off the end of a to-do said aloud: "call Sam tomorrow at 3 pm" → ("call Sam", "tomorrow at 3 pm", the date).
    /// Only a suffix made entirely of time words counts, so "book the flight to Boston Friday" keeps its destination.
    public static func splitDue(_ text: String, relativeTo now: Date, calendar: Calendar = .current) -> (task: String, due: String?, dueAt: Date?) {
        let normalized = normalizeSpokenTime(text)
        let words = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return (text, nil, nil) }
        for count in stride(from: min(7, words.count - 1), through: 1, by: -1) {
            let suffix = Array(words.suffix(count))
            guard suffix.allSatisfy(isTimeWord) else { continue }
            let phrase = suffix.joined(separator: " ")
            guard let date = dueDate(from: phrase, relativeTo: now, calendar: calendar) else { continue }
            let task = words.dropLast(count).joined(separator: " ")
                .replacingOccurrences(of: #"(?i)[\s,]*\b(by|on|at|before|due|until|till|for|around|and)\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",;:")))
            guard !task.isEmpty else { continue }
            return (task, phrase, date)
        }
        return (text, nil, nil)
    }

    /// Whether a time phrase names a moment in the day ("3 pm", "noon", "tomorrow morning") rather than just a day.
    public static func mentionsTimeOfDay(_ phrase: String) -> Bool {
        let text = normalizeSpokenTime(phrase.lowercased())
        return timeOfDay(in: text) != nil
            || text.range(of: #"\b(morning|afternoon|evening|tonight|night|eod|cob|end of (the )?day)\b"#, options: .regularExpression) != nil
    }

    /// Speech writes times as words. "eleven a.m." → "11 am", "half past ten" → "10:30", "quarter to eleven" → "10:45",
    /// "ten o'clock" → "10:00", "at three" → "at 3". Case is kept; only the time words change.
    public static func normalizeSpokenTime(_ input: String) -> String {
        let hour = "(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\\d{1,2})"
        var text = input.replacingOccurrences(of: #"(?i)\b([ap])\.\s?m\.?(?=\s|$|[,;:!?])"#, with: "$1m", options: .regularExpression)
        text = replacing(#"(?i)\b(?:a\s+)?quarter\s+past\s+"# + hour + #"\b"#, in: text) { "\(hourNumber($0[1])):15" }
        text = replacing(#"(?i)\bhalf\s+past\s+"# + hour + #"\b"#, in: text) { "\(hourNumber($0[1])):30" }
        text = replacing(#"(?i)\b(?:a\s+)?quarter\s+to\s+"# + hour + #"\b"#, in: text) { "\(hourNumber($0[1]) == 1 ? 12 : hourNumber($0[1]) - 1):45" }
        text = replacing(#"(?i)\b"# + hour + #"\s+(fifteen|thirty|forty[-\s]?five)\b"#, in: text) { groups in
            let minutes = groups[2].lowercased().hasPrefix("fif") ? 15 : (groups[2].lowercased().hasPrefix("thirty") ? 30 : 45)
            return "\(hourNumber(groups[1])):\(minutes)"
        }
        text = replacing(#"(?i)\b"# + hour + #"\s*o'?clock\b"#, in: text) { "\(hourNumber($0[1])):00" }
        text = replacing(#"(?i)\b"# + hour + #"(\s*)(am|pm)\b"#, in: text) { "\(hourNumber($0[1]))\($0[2])\($0[3])" }
        text = replacing(#"(?i)\b(at\s+)"# + hour + #"\b"#, in: text) { "\($0[1])\(hourNumber($0[2]))" }
        return text
    }

    private static let hourWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                                    "ten": 10, "eleven": 11, "twelve": 12]

    private static func hourNumber(_ word: String) -> Int {
        Int(word) ?? hourWords[word.lowercased()] ?? 0
    }

    /// Replaces each match with what the closure makes of its groups (group 0 is the whole match).
    private static func replacing(_ pattern: String, in text: String, with replacement: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement(groups))
        }
        return result
    }

    private static let timeWords: Set<String> = [
        "by", "on", "at", "before", "due", "until", "till", "for", "around", "the", "this", "next", "coming", "in", "a", "an", "of",
        "end", "early", "beginning", "start", "later", "today", "tomorrow", "tonight", "eod", "cob", "eow", "eom", "noon", "midday",
        "midnight", "morning", "afternoon", "evening", "night", "week", "weeks", "day", "days", "month", "months", "hour", "hours",
        "minute", "minutes", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "fifteen", "thirty", "forty", "forty-five", "half", "quarter", "past", "o'clock", "oclock", "am", "pm", "a.m", "p.m",
        "sunday", "sun", "monday", "mon", "tuesday", "tue", "tues", "wednesday", "wed", "thursday", "thu", "thur", "thurs", "friday",
        "fri", "saturday", "sat", "january", "jan", "february", "feb", "march", "mar", "april", "apr", "may", "june", "jun", "july",
        "jul", "august", "aug", "september", "sep", "sept", "october", "oct", "november", "nov", "december", "dec",
    ]

    private static func isTimeWord(_ raw: String) -> Bool {
        let word = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        if word.isEmpty || timeWords.contains(word) { return true }
        return word.range(of: #"^(\d{1,2}(:\d{2})?(am|pm)?|\d{1,2}(st|nd|rd|th)|\d{1,2}/\d{1,2}(/\d{2,4})?|\d{4})$"#, options: .regularExpression) != nil
    }

    private static func timeOfDay(in text: String) -> (hour: Int, minute: Int)? {
        if text.range(of: #"\b(noon|midday)\b"#, options: .regularExpression) != nil { return (12, 0) }
        if text.range(of: #"\bmidnight\b"#, options: .regularExpression) != nil { return (23, 59) }
        guard let regex = try? NSRegularExpression(pattern: #"\b(at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?\b"#) else { return nil }
        let ns = text as NSString
        // The first number that is a time, not the first number: "September 15 at 10:00 am" is 10 o'clock, not 15.
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard var hour = Int(ns.substring(with: match.range(at: 2))) else { continue }
            let minute = match.range(at: 3).location != NSNotFound ? Int(ns.substring(with: match.range(at: 3))) ?? 0 : 0
            let suffix = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)) : ""
            let hasColon = match.range(at: 3).location != NSNotFound
            let afterAt = match.range(at: 1).location != NSNotFound
            // A bare number is a time only with am/pm, minutes or "at"; "Sept 20" or "9/20" must not become 9 o'clock.
            guard !suffix.isEmpty || hasColon || afterAt else { continue }
            if suffix.isEmpty, (1...6).contains(hour) { hour += 12 }   // Without am/pm, "3" and "three thirty" mean the afternoon; "10" the morning.
            if suffix.hasPrefix("p"), hour < 12 { hour += 12 }
            if suffix.hasPrefix("a"), hour == 12 { hour = 0 }
            guard (0...23).contains(hour), (0...59).contains(minute) else { continue }
            return (hour, minute)
        }
        return nil
    }

    private static func explicitDate(in text: String, today: Date, calendar cal: Calendar) -> Date? {
        let year = cal.component(.year, from: today)
        func build(month: Int, day: Int, year explicitYear: Int?) -> Date? {
            var components = DateComponents()
            components.month = month
            components.day = day
            components.year = explicitYear ?? year
            guard var date = cal.date(from: components) else { return nil }
            if explicitYear == nil, date < today, let next = cal.date(byAdding: .year, value: 1, to: date) { date = next }
            return cal.startOfDay(for: date)
        }
        if let match = text.range(of: #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#, options: .regularExpression) {
            let parts = text[match].split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 { return build(month: parts[1], day: parts[2], year: parts[0]) }
        }
        if let match = text.range(of: #"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#, options: .regularExpression) {
            let parts = text[match].split(separator: "/").compactMap { Int($0) }
            if parts.count >= 2, (1...12).contains(parts[0]), (1...31).contains(parts[1]) {
                let explicitYear = parts.count == 3 ? (parts[2] < 100 ? 2000 + parts[2] : parts[2]) : nil
                return build(month: parts[0], day: parts[1], year: explicitYear)
            }
        }
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12]
        let monthPattern = #"(jan|feb|mar|apr|may|jun|jul|aug|sept|sep|oct|nov|dec)[a-z]*\.?"#
        if let match = text.range(of: #"\b"# + monthPattern + #"\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s*(\d{4}))?"#, options: .regularExpression)
            ?? text.range(of: #"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + monthPattern + #"\b(?:,?\s*(\d{4}))?"#, options: .regularExpression) {
            let phrase = String(text[match])
            let monthKey = months.keys.sorted { $0.count > $1.count }.first { phrase.range(of: #"\b"# + $0, options: .regularExpression) != nil }
            let numbers = phrase.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            if let monthKey, let month = months[monthKey], let day = numbers.first(where: { (1...31).contains($0) }) {
                let explicitYear = numbers.first { $0 >= 2000 }
                return build(month: month, day: day, year: explicitYear)
            }
        }
        if let match = text.range(of: #"\b(?:the\s+)?(\d{1,2})(st|nd|rd|th)\b"#, options: .regularExpression) {
            let numbers = text[match].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            if let day = numbers.first, (1...31).contains(day) {
                let month = cal.component(.month, from: today)
                if let date = build(month: month, day: day, year: nil) { return date }
            }
        }
        return nil
    }

    private static func nextWeekday(_ weekday: Int, from today: Date, includeToday: Bool, calendar cal: Calendar) -> Date {
        let current = cal.component(.weekday, from: today)
        var delta = (weekday - current + 7) % 7
        if delta == 0, !includeToday { delta = 7 }
        return cal.date(byAdding: .day, value: delta, to: today) ?? today
    }
}
