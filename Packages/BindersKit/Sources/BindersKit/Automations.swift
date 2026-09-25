import Foundation

/// A rule the user wrote: when a phrase is spoken in Command Mode, or something happens in Binders, run something.
public struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    public enum Trigger: Codable, Equatable, Sendable {
        /// Spoken in Command Mode; whatever follows the phrase is the payload's text.
        case phrase(text: String)
        case event(name: AutomationEvent)
    }

    public enum Action: Codable, Equatable, Sendable {
        /// The Shortcut receives the rendered `input` template as text.
        case shortcut(name: String, input: String)
        /// Placeholders are percent-encoded, so the template can carry them inside a query.
        case openURL(template: String)
        /// Run with zsh; the payload arrives as BINDERS_* environment variables, and the text on standard input.
        case script(command: String)
        /// POST as JSON: the rendered `body` template, or the whole payload when `body` is empty.
        case webhook(url: String, body: String)
    }

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: Trigger
    public var action: Action

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, trigger: Trigger, action: Action) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.action = action
    }
}

public enum AutomationEvent: String, Codable, CaseIterable, Identifiable, Sendable {
    case dictationInserted, todoAdded, promiseNoted, meetingReady, writingCaptured

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dictationInserted: "Dictation inserted"
        case .todoAdded: "To-do added"
        case .promiseNoted: "Promise noted"
        case .meetingReady: "Meeting notes ready"
        case .writingCaptured: "Writing captured"
        }
    }
}

/// What a trigger hands to its action. Every field is a placeholder: `{text}`, `{title}` and so on.
public struct AutomationPayload: Codable, Equatable, Sendable {
    public var event: String
    public var text: String
    public var title: String
    public var when: String
    public var date: String
    public var app: String
    public var binder: String
    public var summary: String
    public var link: String

    public init(event: String = "phrase", text: String = "", title: String = "", when: String = "", date: String = "",
                app: String = "", binder: String = "", summary: String = "", link: String = "") {
        self.event = event
        self.text = text
        self.title = title
        self.when = when
        self.date = date
        self.app = app
        self.binder = binder
        self.summary = summary
        self.link = link
    }

    /// "call Sam tomorrow at 3 pm": the text as said, title "call Sam", when "tomorrow at 3 pm", date in ISO 8601.
    public static func spoken(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> AutomationPayload {
        let split = CommitmentDetection.splitDue(text, relativeTo: now, calendar: calendar)
        return AutomationPayload(text: text, title: split.task, when: split.due ?? "", date: split.dueAt.map(iso) ?? "")
    }

    public var fields: [String: String] {
        ["event": event, "text": text, "title": title, "when": when, "date": date, "app": app, "binder": binder, "summary": summary, "link": link]
    }

    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

public enum AutomationTemplate {
    public static let placeholders = ["text", "title", "when", "date", "app", "binder", "summary", "link", "event"]

    /// Fills `{text}`, `{title}`… from the payload, passing each value through `encode` first.
    public static func render(_ template: String, payload: AutomationPayload, encode: (String) -> String = { $0 }) -> String {
        var result = template
        for (key, value) in payload.fields {
            result = result.replacingOccurrences(of: "{\(key)}", with: encode(value))
        }
        return result
    }

    /// Safe inside a URL query: everything but unreserved characters is percent-encoded.
    public static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Safe inside a JSON string literal (the quotes are the template's).
    public static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let quoted = String(data: data, encoding: .utf8), quoted.count >= 2 else { return value }
        return String(quoted.dropFirst().dropLast())
    }

    /// What follows the phrase when the instruction starts with it: "send to Things buy milk" → "buy milk", and "" when
    /// the phrase is the whole instruction. Nil when the instruction is about something else.
    public static func remainder(of instruction: String, afterPhrase phrase: String) -> String? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        let words = phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let pattern = "(?i)^(?:hey\\s+)?" + words.joined(separator: "\\s+") + "\\b[,:]?\\s*(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
