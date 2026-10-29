import Foundation

// MARK: - What an agent wears

/// What an agent's avatar wears, by what it is: Claude Code clay, Codex green, OpenCode slate blue, Copilot purple,
/// Antigravity blue, Cursor graphite, Grok white. A provider's agent wears its icon (Simple Icons, CC0); any other agent
/// its initial, in one of the vivid colours by its name, the same one every time. The Mac and the iPhone draw it alike.
public enum AgentAvatarKind: String, Sendable, CaseIterable {
    case claude, codex, opencode, copilot, antigravity, cursor, grok, manager, local, other

    /// Its provider's icon in the asset catalog, or nil for a letter.
    public var icon: String? {
        switch self {
        case .claude: "provider-claude"
        case .codex: "provider-openai"
        case .opencode: "provider-opencode"
        case .copilot: "provider-copilot"
        case .antigravity: "provider-gemini"
        case .cursor: "provider-cursor"
        default: nil
        }
    }

    /// Its colour, and whether its letter or icon is dark on it; nil for the Manager, which wears the accent.
    public func fill(name: String) -> (hex: UInt32, darkLetter: Bool)? {
        switch self {
        case .claude: (0xD97757, false)
        case .codex: (0x10A37F, false)
        case .opencode: (0x5B6CF0, false)
        case .copilot: (0x8957E5, false)
        case .antigravity: (0x3D86F4, false)
        case .cursor: (0x26262A, false)
        case .grok: (0xF2F2F3, true)
        case .manager: nil
        case .local: (0x6B7280, false)
        case .other: (Self.vivid[Self.hash(name) % Self.vivid.count], false)
        }
    }

    /// The colours any agent may wear, by its name: vivid, and each tells from the others.
    public static let vivid: [UInt32] = [0x2BB5A0, 0xE0609A, 0x3D9BFF, 0x8B6CFF, 0xE5A13A, 0x5FBF4A, 0xF0705A, 0x29B6D9]

    /// What an agent wears, by how it's woken ("claudeCode", "cliAgent", "localModel"…) and its coding tool's name, else
    /// by its name.
    public static func of(wakes: String?, tool: CLIAgent?, name: String) -> AgentAvatarKind {
        switch wakes {
        case "claudeCode": return .claude
        case "cliAgent":
            switch tool {
            case .codex: return .codex
            case .opencode: return .opencode
            case .copilot: return .copilot
            case .antigravity: return .antigravity
            case nil: break
            }
        case "localModel": return .local
        default: break
        }
        let lowered = name.lowercased()
        if lowered.contains("grok") { return .grok }
        if lowered.contains("claude") { return .claude }
        if lowered.contains("codex") { return .codex }
        if lowered.contains("copilot") { return .copilot }
        if lowered.contains("opencode") { return .opencode }
        if lowered.contains("antigravity") { return .antigravity }
        if lowered.contains("cursor") { return .cursor }
        return .other
    }

    /// Its first letter or digit, in capitals.
    public static func initial(_ name: String) -> String {
        name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "•"
    }

    /// FNV-1a, so the same name wears the same colour in every launch.
    static func hash(_ name: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash)
    }
}

// MARK: - Sessions over the link

/// An agent's sessions on your iPhone, as the Mac's Agents page has them (lane AC2): from a Mac that lists
/// `LinkFeatures.sessions`. `binders/sessions` lists an agent's (`AgentSessionList`), `binders/session` gives one as its
/// terminal (`AgentSessionShown`), `binders/session-send` sends your words into a card's session as the Mac's prompt does,
/// and `binders/session-act` stops a card's run. A chat's words go by `binders/chat-send`, and its Stop by
/// `binders/chat-act`, as before.
public enum AgentSessionLink {
    /// The most blocks a session sends: its newest. The Mac's page has the rest.
    public static let blocksSent = 150
    /// The most lines of a tool's output, and of an edit, a block sends.
    public static let outputSent = 60
    public static let diffSent = 120
    /// The most of your words, Binders' prompt, or what it said, a block sends, in characters.
    public static let textSent = 6_000

    /// The blocks a phone is sent: the newest `blocksSent`, each cut to what's sent, and how many older ones were left out.
    public static func trimmed(_ blocks: [AgentTerminalBlock]) -> (blocks: [AgentTerminalBlock], earlier: Int) {
        let kept = blocks.suffix(blocksSent)
        func cut(_ text: String) -> String { text.count > textSent ? String(text.prefix(textSent - 1)) + "…" : text }
        let trimmed = kept.map { block -> AgentTerminalBlock in
            var block = block
            switch block.kind {
            case .you(let text): block.kind = .you(cut(text))
            case .binders(let summary, let text): block.kind = .binders(summary: summary, text: cut(text))
            case .said(let text): block.kind = .said(cut(text))
            case .waiting(let text, let why): block.kind = .waiting(cut(text), why: why)
            case .tool(var tool):
                if tool.output.count > outputSent {
                    tool.more += tool.output.count - outputSent
                    tool.output = Array(tool.output.prefix(outputSent))
                }
                if tool.diff.count > diffSent {
                    tool.diffMore += tool.diff.count - diffSent
                    tool.diff = Array(tool.diff.prefix(diffSent))
                }
                block.kind = .tool(tool)
            case .run, .plan, .end: break
            }
            return block
        }
        return (trimmed, blocks.count - kept.count)
    }

    /// The link's JSON for a reply: snake_case keys, ISO dates.
    public static func object<T: Encodable>(_ value: T) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        guard let data = try? encoder.encode(value), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// A reply, read back.
    public static func decode<T: Decodable>(_ type: T.Type, from object: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // With fractions of a second or without.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) ?? Date(text, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return try? decoder.decode(type, from: data)
    }
}

/// One of an agent's sessions, as its strip lists it: a card it works on or that you meant for it, or a chat with it.
public struct AgentSessionSummary: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case card, chat }

    public var kind: Kind
    /// The card's id, or the chat's.
    public var id: String
    public var title: String
    public var updatedAt: Date
    public var running: Bool
    public var needsYou: Bool
    public var done: Bool

    public init(kind: Kind, id: String, title: String, updatedAt: Date, running: Bool, needsYou: Bool, done: Bool) {
        self.kind = kind
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.running = running
        self.needsYou = needsYou
        self.done = done
    }

    /// The few words after its title: "running", "needs you", "done", a chat's time or day.
    public func state(now: Date = Date(), calendar: Calendar = .current) -> String {
        if running { return "running" }
        if needsYou { return "needs you" }
        if kind == .chat {
            return updatedAt.formatted(calendar.isDate(updatedAt, inSameDayAs: now) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated))
        }
        return done ? "done" : "idle"
    }
}

/// `binders/sessions`: one agent, what it is, and its sessions, those running first and then the newest.
public struct AgentSessionList: Codable, Equatable, Sendable {
    public var agent: String
    /// "Claude Code · in ~/code/app".
    public var what: String
    /// What it wears (`AgentAvatarKind`).
    public var avatar: String
    /// It chats: a new session is a chat; else a card meant for it.
    public var chats: Bool
    /// Binders reads its runs, so its sessions show as a terminal; else as its conversation.
    public var terminal: Bool
    public var sessions: [AgentSessionSummary]

    public init(agent: String, what: String, avatar: String, chats: Bool, terminal: Bool, sessions: [AgentSessionSummary]) {
        self.agent = agent
        self.what = what
        self.avatar = avatar
        self.chats = chats
        self.terminal = terminal
        self.sessions = sessions
    }
}

/// `binders/session`: one session as its terminal shows it, and its prompt's words.
public struct AgentSessionShown: Codable, Equatable, Sendable {
    public var kind: AgentSessionSummary.Kind
    public var id: String
    public var title: String
    public var blocks: [AgentTerminalBlock]
    /// How many older blocks were left out.
    public var earlier: Int
    public var running: Bool
    /// What it's on now, for the working line.
    public var current: String?
    /// When the run going now started.
    public var since: Date?
    /// The sentence at the top when there's nothing yet.
    public var intro: String?
    /// Where your words go, in a line.
    public var hint: String?
    /// Why nothing can be sent now.
    public var blocked: String?
    /// A card that waits on you: its question, approval or review is the card's to answer.
    public var needsYou: Bool
    /// A card's column, as the board names it.
    public var column: String?

    public init(kind: AgentSessionSummary.Kind, id: String, title: String, blocks: [AgentTerminalBlock], earlier: Int = 0, running: Bool,
                current: String? = nil, since: Date? = nil, intro: String? = nil, hint: String? = nil, blocked: String? = nil,
                needsYou: Bool = false, column: String? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.blocks = blocks
        self.earlier = earlier
        self.running = running
        self.current = current
        self.since = since
        self.intro = intro
        self.hint = hint
        self.blocked = blocked
        self.needsYou = needsYou
        self.column = column
    }
}

// MARK: - Blocks on the wire

extension AgentSessionStep.Status: Codable {}
extension AgentSessionPlanItem.Status: Codable {}

extension AgentTerminalTool: Codable {
    private enum CodingKeys: String, CodingKey { case name, argument, status, summary, output, diff, more, diffMore }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try values.decode(String.self, forKey: .name),
                  argument: try values.decodeIfPresent(String.self, forKey: .argument) ?? "",
                  status: (try? values.decode(AgentSessionStep.Status.self, forKey: .status)) ?? .ok,
                  summary: try values.decodeIfPresent(String.self, forKey: .summary),
                  output: try values.decodeIfPresent([String].self, forKey: .output) ?? [],
                  diff: try values.decodeIfPresent([String].self, forKey: .diff) ?? [])
        more = try values.decodeIfPresent(Int.self, forKey: .more) ?? 0
        diffMore = try values.decodeIfPresent(Int.self, forKey: .diffMore) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(argument, forKey: .argument)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(summary, forKey: .summary)
        if !output.isEmpty { try values.encode(output, forKey: .output) }
        if !diff.isEmpty { try values.encode(diff, forKey: .diff) }
        if more > 0 { try values.encode(more, forKey: .more) }
        if diffMore > 0 { try values.encode(diffMore, forKey: .diffMore) }
    }
}

/// A block as `{"id", "type", …}`: "run" and "said" with `text`, "you" with `text`, "binders" with `summary` and `text`,
/// "tool" with `tool`, "plan" with `plan`, "end" with `ok` and `text`, "waiting" with `text` and `why`. A type this build
/// doesn't know reads as what it said, with its `text`.
extension AgentTerminalBlock: Codable {
    private enum CodingKeys: String, CodingKey { case id, type, text, summary, tool, plan, ok, why }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        let kind: Kind = switch try values.decodeIfPresent(String.self, forKey: .type) ?? "" {
        case "run": .run(text)
        case "you": .you(text)
        case "binders": .binders(summary: try values.decodeIfPresent(String.self, forKey: .summary) ?? "", text: text)
        case "tool": .tool(try values.decode(AgentTerminalTool.self, forKey: .tool))
        case "plan": .plan(try values.decodeIfPresent([AgentSessionPlanItem].self, forKey: .plan) ?? [])
        case "end": .end(ok: try values.decodeIfPresent(Bool.self, forKey: .ok) ?? true, line: text)
        case "waiting": .waiting(text, why: try values.decodeIfPresent(String.self, forKey: .why) ?? "")
        default: .said(text)
        }
        self.init(id: try values.decode(String.self, forKey: .id), kind: kind)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        switch kind {
        case .run(let text):
            try values.encode("run", forKey: .type)
            try values.encode(text, forKey: .text)
        case .you(let text):
            try values.encode("you", forKey: .type)
            try values.encode(text, forKey: .text)
        case .binders(let summary, let text):
            try values.encode("binders", forKey: .type)
            try values.encode(summary, forKey: .summary)
            try values.encode(text, forKey: .text)
        case .said(let text):
            try values.encode("said", forKey: .type)
            try values.encode(text, forKey: .text)
        case .tool(let tool):
            try values.encode("tool", forKey: .type)
            try values.encode(tool, forKey: .tool)
        case .plan(let items):
            try values.encode("plan", forKey: .type)
            try values.encode(items, forKey: .plan)
        case .end(let ok, let line):
            try values.encode("end", forKey: .type)
            try values.encode(ok, forKey: .ok)
            try values.encode(line, forKey: .text)
        case .waiting(let text, let why):
            try values.encode("waiting", forKey: .type)
            try values.encode(text, forKey: .text)
            try values.encode(why, forKey: .why)
        }
    }
}
