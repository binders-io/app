import Foundation

// Chatting with your agents (lane AC1): a conversation of its own, never a card. Claude Code answers in a session Binders
// starts for the chat, in a worktree of the agent's repository, with the permissions its card runs have, and carries the
// session on with each message. An agent that checks the board itself reads your messages, and answers them, with
// Binders' tools (`AgentChatTools`). Scripts, web hooks and shortcuts can't hold a conversation: they keep cards.

/// One chat with one agent: your messages and its replies, in order.
public struct AgentChat: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Nothing waits: its last word is in.
        case idle
        /// Binders started it for your last message, and it's answering.
        case running
        /// Your last message waits for an agent that checks the board itself to read it.
        case waiting
    }

    public var id: UUID
    /// The agent's name on the boards.
    public var agent: String
    /// Your first words, cut short: what the chat is called.
    public var title: String
    public var startedAt: Date
    public var updatedAt: Date
    public var messages: [AgentChatMessage]
    public var status: Status
    /// Claude Code's session for the chat, carried on by each message.
    public var session: UUID?
    /// Where its runs start: the chat's worktree, once the first run made it, or the agent's folder itself.
    public var directory: String?
    /// Why its last run didn't answer, until the next one does.
    public var why: String?

    public init(id: UUID = UUID(), agent: String, title: String, at: Date = Date()) {
        self.id = id
        self.agent = agent
        self.title = title
        startedAt = at
        updatedAt = at
        messages = []
        status = .idle
    }

    /// Your messages the agent hasn't had yet.
    public var unsent: [AgentChatMessage] { messages.filter { $0.from == .you && !$0.delivered } }

    /// A chat's title from your first words: the first line, cut at a word.
    public static func title(from text: String) -> String { AgentNote.card(from: text).title }
}

public struct AgentChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum From: String, Codable, Sendable { case you, agent }

    public var id: UUID
    public var from: From
    public var text: String
    public var at: Date
    /// Yours: where you wrote it ("mac" or "iphone"). The agent's: nil.
    public var via: String?
    /// Yours: the agent has it, as a run's prompt or read with its tools.
    public var delivered: Bool

    public init(id: UUID = UUID(), from: From, text: String, at: Date = Date(), via: String? = nil, delivered: Bool = false) {
        self.id = id
        self.from = from
        self.text = text
        self.at = at
        self.via = via
        self.delivered = delivered
    }
}

/// Which agents can chat, by how Binders wakes them.
public enum AgentChatReach {
    /// Claude Code, which Binders starts for the chat itself, and an agent that checks the board itself, which reads your
    /// messages with Binders' tools. Scripts, web hooks, shortcuts and the other coding tools keep cards.
    public static func chats(_ wakes: String) -> Bool { wakes == "claudeCode" || wakes == "board" }
}

// MARK: Starting Claude Code for a chat

/// The first words of a chat's first prompt, which writing capture leaves out as Binders' own.
public enum AgentChatPrompt {
    public static let marker = "Binders started you to chat with the user"

    /// The first message's prompt: what the chat is, then the user's words. Later ones are the words alone, on the same
    /// session.
    public static func first(agent: String, text: String, draftsFirst: Bool) -> String {
        let acting = draftsFirst
            ? "Before anything outside this folder that sends, posts, buys or deletes (an email, a message, a post or a comment, a purchase), say in your reply exactly what you'd do, to whom and with what words, and wait for the user's yes in the chat."
            : "The user lets you send, post or buy for them when they ask for it. If you're unsure, ask first in your reply."
        return """
        \(marker), as \(agent), from Binders' Agents page. Each message they write comes to you in this session, and what you say last is your reply.

        Work in this folder as you would on a card: a git worktree made for this chat. Commit on its branch, and never push. Binders' board tools are there when they ask about cards. \(acting)

        Reply in Markdown, briefly, as in a chat.

        The user says:
        \(text)
        """
    }

    /// Later messages: what they wrote since your last reply, one after another.
    public static func next(_ texts: [String]) -> String { texts.joined(separator: "\n\n") }

    /// A new session for a chat whose session is gone: the start, with the last of the chat before the new words.
    public static func again(agent: String, earlier: [AgentChatMessage], text: String, draftsFirst: Bool) -> String {
        let said = earlier.suffix(10).map { ($0.from == .you ? "The user: " : "You: ") + String($0.text.prefix(1_500)) }.joined(separator: "\n\n")
        return first(agent: agent, text: said.isEmpty ? text : "(Earlier in this chat:)\n\n" + said + "\n\n(Now:)\n\n" + text, draftsFirst: draftsFirst)
    }
}

/// How Binders starts Claude Code for a chat: as for its cards (`ClaudeCodeLaunch.make`), with its permission mode, its
/// sandbox and its web, Binders' board tools as the agent and none of your other servers, and its private folders denied;
/// in a worktree of its own for the chat (or the agent's folder itself, when it works there). The first message starts
/// the session; each one after carries it on (`--resume`), where the worktree is.
public enum AgentChatLaunch {
    /// The chat's worktree and its branch: "binders-chat-" and the first 8 characters of its id.
    public static func worktreeName(for chat: UUID) -> String { "binders-chat-" + String(chat.uuidString.prefix(8)).lowercased() }

    /// Where `claude --worktree` makes it.
    public static func worktree(repository: String, chat: UUID) -> String {
        var repository = repository
        while repository.count > 1, repository.hasSuffix("/") { repository.removeLast() }
        return repository + "/.claude/worktrees/" + worktreeName(for: chat)
    }

    /// - `directory`: where the chat's first run left it (its worktree, or the agent's folder). Nil: the first run, which
    ///   makes the worktree.
    /// - `resume`: a later message, on the chat's session, in `directory`. Without it but with `directory`, a new session
    ///   there, as when the old one is gone.
    /// - `strictMCP`: as for cards; off where an organization's managed Claude Code refuses it, with the tool guard on.
    public static func claude(chat: UUID, boardName: String, wake: ClaudeCodeWake, binders: String, dataFolder: String, home: String,
                              alsoPrivate: [String] = [], session: UUID, resume: Bool, directory: String?, prompt: String,
                              strictMCP: Bool = true) -> ClaudeCodeLaunch {
        let denied = ClaudeCodeLaunch.deniedTools(dataFolder: dataFolder, home: home, alsoPrivate: alsoPrivate)
        // Board tools as the agent, across its boards, as its own server for Binders has them: no card of its own.
        let servers: [String: Any] = [
            "mcpServers": ["binders": ["type": "stdio", "command": binders, "args": ["--mcp"],
                                       "env": ["BINDERS_AGENT": boardName, "BINDERS_TOOLS": "board", "BINDERS_CHAT": chat.uuidString]]],
        ]
        let domains = (wake.allowedDomains ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var settings: [String: Any] = [
            "permissions": ["disableBypassPermissionsMode": "disable", "deny": denied],
            "sandbox": ["enabled": true, "failIfUnavailable": true, "allowUnsandboxedCommands": false,
                        "filesystem": ["denyRead": ClaudeCodeLaunch.deniedReads(dataFolder: dataFolder, home: home, alsoPrivate: alsoPrivate)],
                        "network": ["allowedDomains": domains]],
        ]
        if !strictMCP {
            let guardHook: [String: Any] = ["type": "command", "command": "\(AgentMCPEntry.quoted(binders)) --agent-hook \(ClaudeCodeToolGuard.hook)", "timeout": 10]
            settings["hooks"] = ["PreToolUse": [["matcher": "mcp__.*", "hooks": [guardHook]]]]
        }
        var arguments = ["-p", "--permission-mode", wake.safeMode, "--permission-prompts", "none", "--output-format", "stream-json", "--verbose"]
        if strictMCP { arguments.append("--strict-mcp-config") }
        arguments += ["--mcp-config", json(servers), "--settings", json(settings), "--allowedTools", "mcp__binders"]
        arguments += ClaudeCodeLaunch.taskTools + ["--disallowedTools"] + denied
        var repository = wake.repository
        while repository.count > 1, repository.hasSuffix("/") { repository.removeLast() }
        let start: String
        if resume, let directory {
            arguments += ["--resume", session.uuidString.lowercased()]
            start = directory
        } else {
            arguments += ["--session-id", session.uuidString.lowercased(), "--name", "Binders chat \(String(chat.uuidString.prefix(8)).lowercased())"]
            if directory == nil, !wake.worksInFolder { arguments += ["--worktree", worktreeName(for: chat)] }
            start = directory ?? repository
        }
        if let model = wake.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty, !model.hasPrefix("-"), AgentCommands.isAllowed(model) {
            arguments += ["--model", model]
        }
        if let budget = wake.maxBudgetUSD, budget.isFinite, budget >= 0.01 {
            arguments += ["--max-budget-usd", String(format: "%.2f", budget)]
        }
        return ClaudeCodeLaunch(arguments: arguments, directory: start, prompt: prompt,
                                environment: ["BINDERS_AGENT": boardName, "BINDERS_CHAT": chat.uuidString])
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What a chat run has said so far, from its stream-json output: the text of its messages, as they came, for the chat to
/// show while it works; and its last word when it's done.
public enum AgentChatStream {
    /// The text it has written so far in this run, each message's after the one before.
    public static func said(in output: String) -> String {
        var parts: [String] = []
        for raw in output.split(separator: "\n") where raw.hasPrefix("{") && raw.contains("\"assistant\"") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], event["type"] as? String == "assistant",
                  let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return parts.last ?? ""
    }

    /// Its reply when the run ended well: the result's text; nil when it ended in an error or said nothing.
    public static func reply(in output: String) -> (text: String?, error: Bool) {
        var reply: String?
        var error = false
        for raw in output.split(separator: "\n").reversed() where raw.hasPrefix("{") && raw.contains("\"result\"") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], event["type"] as? String == "result" else { continue }
            reply = (event["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            error = event["is_error"] as? Bool == true
            break
        }
        if reply?.isEmpty == true { reply = nil }
        return (reply, error)
    }

    /// The folder the run started in, as its start says (stream-json's init event): where its session is.
    public static func folder(in output: String) -> String? {
        for raw in output.split(separator: "\n") where raw.hasPrefix("{") && raw.contains("\"init\"") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], event["type"] as? String == "system",
                  event["subtype"] as? String == "init", let cwd = event["cwd"] as? String, cwd.hasPrefix("/") else { continue }
            return cwd
        }
        return nil
    }

    /// Whether Claude Code said the session to carry on isn't there (moved, or cleaned up): the chat starts a new one.
    public static func sessionGone(in output: String) -> Bool {
        output.contains("No conversation found with session ID") || output.contains("No conversation found")
    }
}

// MARK: Agents that check the board themselves

/// Binders' tools for chat, offered to an agent's own server for Binders (`MCPConfinement.board`): the messages you wrote
/// it that it hasn't read, and its reply to one chat.
public enum AgentChatTools {
    public static let list = "list_messages"
    public static let reply = "reply_message"
    public static let all: Set<String> = [list, reply]
}

// MARK: Over the phone link

extension AgentChat {
    /// What the phone link says about a chat. `messages`: all of them, or none for a list.
    public func jsonObject(messages withMessages: Bool, live: String? = nil) -> [String: Any] {
        func iso(_ date: Date) -> String { date.formatted(.iso8601) }
        var object: [String: Any] = ["id": id.uuidString, "agent": agent, "title": title, "started_at": iso(startedAt), "updated_at": iso(updatedAt),
                                     "status": status.rawValue, "count": messages.count]
        if let why { object["why"] = why }
        if let last = messages.last { object["last"] = ["from": last.from.rawValue, "text": String(last.text.prefix(200)), "at": iso(last.at)] }
        if withMessages {
            object["messages"] = messages.map { message -> [String: Any] in
                var entry: [String: Any] = ["id": message.id.uuidString, "from": message.from.rawValue, "text": message.text, "at": iso(message.at),
                                            "delivered": message.delivered]
                if let via = message.via { entry["via"] = via }
                return entry
            }
        }
        if let live, !live.isEmpty { object["live"] = live }
        return object
    }
}

// MARK: Reading Markdown in a chat

/// A reply's Markdown as blocks to draw, the same on the Mac and the iPhone: paragraphs, headings, bullets ("- ", "* ",
/// "• "), numbered items, fenced code, quotes and rules. Inline emphasis, code and links stay in each block's text, for
/// the platform's inline Markdown.
public enum ChatMarkdown {
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, String)
        case bullet(depth: Int, String)
        case numbered(depth: Int, number: String, String)
        case code(String)
        case quote(String)
        case rule
    }

    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            let depth = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if line.isEmpty {
                flush()
            } else if let level = heading(line) {
                flush()
                blocks.append(.heading(level: level, String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" || line == "___" {
                flush()
                blocks.append(.rule)
            } else if let item = bullet(line) {
                flush()
                blocks.append(.bullet(depth: depth, item))
            } else if let (number, item) = numbered(line) {
                flush()
                blocks.append(.numbered(depth: depth, number: number, item))
            } else if line.hasPrefix(">") {
                flush()
                let words = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case .quote(let before)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(before + "\n" + words)
                } else {
                    blocks.append(.quote(words))
                }
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bullet(_ line: String) -> String? {
        for mark in ["- ", "* ", "• ", "+ "] where line.hasPrefix(mark) {
            // "**bold** line" isn't a bullet.
            if mark == "* ", line.hasPrefix("**") { return nil }
            return String(line.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return (String(digits) + ".", String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }
}
