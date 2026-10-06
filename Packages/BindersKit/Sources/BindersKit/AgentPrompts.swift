import Foundation

/// What you typed to an AI agent in the terminal, read from the agent's own history on this Mac: the words you sent,
/// never the screen or the command output around them.
public struct AgentPrompt: Equatable, Sendable {
    public let text: String
    /// The folder the agent was working in, when its history says.
    public let project: String?
    public let date: Date
    public let session: String?
    /// Which harness it was sent to, when the record says (hooks write many tools to one record).
    public var tool: String?

    public init(text: String, project: String?, date: Date, session: String?, tool: String? = nil) {
        self.text = text
        self.project = project
        self.date = date
        self.session = session
        self.tool = tool
    }

    /// "BindersPublic/app" for "/Users/someone/Documents/BindersPublic/app": enough to tell projects apart.
    public var projectName: String? {
        guard let project, !project.isEmpty else { return nil }
        let parts = project.split(separator: "/").suffix(2)
        return parts.joined(separator: "/")
    }
}

public enum AgentPrompts {
    /// A line of Claude Code's ~/.claude/history.jsonl: {"display", "pastedContents", "timestamp" (ms), "project", "sessionId"}.
    /// Pasted blocks stay as Claude Code shows them ("[Pasted text #1 +12 lines]"); their contents aren't kept.
    public static func claudeCode(_ line: String) -> AgentPrompt? {
        guard let json = object(line), let display = json["display"] as? String,
              let milliseconds = (json["timestamp"] as? NSNumber)?.doubleValue else { return nil }
        return worthKeeping(display).map {
            AgentPrompt(text: $0, project: json["project"] as? String, date: Date(timeIntervalSince1970: milliseconds / 1000),
                        session: json["sessionId"] as? String)
        }
    }

    /// A line of Codex's ~/.codex/history.jsonl: {"session_id", "ts" (seconds), "text"}.
    public static func codex(_ line: String) -> AgentPrompt? {
        guard let json = object(line), let text = json["text"] as? String, let seconds = (json["ts"] as? NSNumber)?.doubleValue else { return nil }
        return worthKeeping(text).map { AgentPrompt(text: $0, project: nil, date: Date(timeIntervalSince1970: seconds), session: json["session_id"] as? String) }
    }

    /// The prompt, trimmed, unless it isn't writing: a slash command on its own ("/clear", "/model opus"), a shell
    /// command run through the agent ("!git status"), or a reply too short to mean much on its own ("yes", "go ahead").
    public static func worthKeeping(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("!") { return nil }
        if text.hasPrefix("/") {
            // "/compact keep the decisions about pricing": the words after a command can be worth keeping.
            let words = text.split(whereSeparator: \.isWhitespace).dropFirst()
            guard words.count >= 3 else { return nil }
            return words.joined(separator: " ")
        }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3, text.contains(where: \.isLetter) else { return nil }
        return text
    }

    private static func object(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The complete lines in `data`, and how many bytes they take: a line still being written waits for the next read.
    public static func completeLines(in data: Data) -> (lines: [String], consumed: Int) {
        guard let last = data.lastIndex(of: 0x0A) else { return ([], 0) }
        let consumed = data.distance(from: data.startIndex, to: last) + 1
        let text = String(decoding: data.prefix(consumed), as: UTF8.self)
        return (text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init), consumed)
    }
}
