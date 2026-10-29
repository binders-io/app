import Foundation

// The coding agents' command-line tools Binders starts for a card, as Claude Code is started: Codex, OpenCode, GitHub
// Copilot CLI and Antigravity CLI (agy). Each runs on its own in a git worktree Binders makes for the card, with Binders' board tools for that card
// only and the tool's own checks on. These agents live in agents-cli.json, beside agents.json, which no Mac 0.8.0 opens.
// The parts here can be worked out and tested away from the app: the tools, how an agent is set up, what a run is given,
// and the record a run leaves while it goes. The app runs the wakes.

/// A coding agent's command-line tool Binders can start for a card. An unknown raw value fails to decode, so an entry naming
/// a tool a later Binders added is kept as it is and never run as something else.
public enum CLIAgent: String, Codable, CaseIterable, Sendable {
    case codex, opencode, copilot, antigravity

    /// Its name, as Settings and the cards say it.
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .copilot: "GitHub Copilot CLI"
        case .antigravity: "Antigravity"
        }
    }

    /// Its name in an agent's name on the boards: "Codex · app".
    public var shortName: String {
        switch self {
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .copilot: "Copilot"
        case .antigravity: "Antigravity"
        }
    }

    /// The program's name: on the login shell's PATH, and the name an override must have. Antigravity's is agy.
    public var program: String { self == .antigravity ? "agy" : rawValue }

    /// Who it sends cards to, when how Binders starts it fixes that: OpenAI for Codex, GitHub for Copilot, Google for
    /// Antigravity. OpenCode sends them to the provider of the model you choose, so it's nil here.
    public var company: String? {
        switch self {
        case .codex: "OpenAI"
        case .opencode: nil
        case .copilot: "GitHub (Microsoft)"
        case .antigravity: "Google"
        }
    }

    /// Whether a run may use commands: Codex in its sandbox, and Antigravity in its terminal sandbox, where only the
    /// commands your Antigravity settings allow run (it refuses the rest, with no one there to approve them). The others
    /// get no shell at all.
    public var runsCommands: Bool { self == .codex || self == .antigravity }

    /// Whether a run can be held to reading only. Antigravity can't: its plan mode is a way of working, not a limit, and
    /// it writes in its workspace without asking.
    public var readsOnly: Bool { self != .antigravity }

    /// Whether "Sites its commands may reach" applies. None of them in this build: Codex's sites wait on a supervised
    /// check of its network proxy, and the others run no commands.
    public var honoursSites: Bool { false }

    /// Whether an agent needs a model of its own: OpenCode, so the destination is the provider you chose and never a
    /// fallback it picks for itself.
    public var needsModel: Bool { self == .opencode }

    /// The version Binders' options were checked against.
    public var checkedVersion: String {
        switch self {
        case .codex: "0.162.0"
        case .opencode: "1.18.27"
        case .copilot: "1.0.10"
        // Taken from Antigravity's documentation and changelog at this build, not from a run of it.
        case .antigravity: "1.4.7"
        }
    }

    /// What prints its version, and nothing else. Copilot's keeps the launcher on the build that's installed.
    public var versionArguments: [String] {
        switch self {
        case .codex, .opencode, .antigravity: ["--version"]
        case .copilot: ["--no-auto-update", "--version"]
        }
    }

    /// How much of a version must match the checked one: major and minor for Codex, OpenCode and Antigravity, all of it
    /// for Copilot, whose 1.0.x releases carry new features.
    public var pinnedParts: Int {
        switch self {
        case .codex, .opencode, .antigravity: 2
        case .copilot: 3
        }
    }

    /// The version in what its version arguments printed, when it's in this tool's shape ("codex-cli 0.162.0", a bare
    /// "1.18.27", "GitHub Copilot CLI 1.0.10."; for agy, whose shape its documentation doesn't show, a bare version or
    /// one after "agy", "Antigravity" or "Antigravity CLI", with or without "version" and "v"). Nil when it isn't: then
    /// it isn't the tool.
    public func version(in output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let number = #"(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)"#
        let pattern = switch self {
        case .codex: #"^codex-cli "# + number + "$"
        case .opencode: "^" + number + "$"
        case .copilot: #"^GitHub Copilot CLI "# + number + #"\.?$"#
        case .antigravity: #"^(?i:(?:agy|antigravity(?: cli)?)(?: version)? )?v?"# + number + #"(?: .*)?$"#
        }
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        var version = String(line[range])
        // Copilot ends its sentence with a full stop, which the number pattern may have taken.
        if version.hasSuffix(".") { version.removeLast() }
        return version
    }

    /// Whether Binders starts this version: the one it checked, in its first `pinnedParts` parts, or the one you accepted
    /// with Check in Settings.
    public func starts(_ version: String, accepted: String? = nil) -> Bool {
        if let accepted, !accepted.isEmpty, accepted == version { return true }
        if pinnedParts >= 3 { return version == checkedVersion }
        func parts(_ text: String) -> [Int]? {
            let core = text.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? text
            let numbers = core.split(separator: ".").map { Int($0) }
            guard numbers.count >= 3, numbers.allSatisfy({ $0 != nil }) else { return nil }
            return numbers.compactMap { $0 }
        }
        guard let installed = parts(version), let checked = parts(checkedVersion) else { return false }
        return Array(installed.prefix(pinnedParts)) == Array(checked.prefix(pinnedParts))
    }

    /// What the receipt says about the version when it isn't exactly the checked one: "Codex 0.162.1; Binders checked
    /// 0.162.0". Nil when it is.
    public func versionNote(_ version: String) -> String? {
        version == checkedVersion ? nil : "\(name) \(version); Binders checked \(checkedVersion)"
    }
}

/// How Binders starts one of them for a card. Its settings sit right under the "cliAgent" key, and nils are left out.
public struct CLIAgentWake: Codable, Equatable, Sendable {
    public var tool: CLIAgent
    /// The folder of the git repository it works on; each run works in a worktree of it Binders makes for the card.
    public var repository: String
    /// "acceptEdits" (edits files in its worktree, for a new agent) or "plan" (reads only). Anything else, or none, runs as
    /// "plan" (`safeMode`).
    public var permissionMode: String
    /// The model's name; for OpenCode "provider/model", which it needs. Nil leaves it to the tool (Codex, Copilot,
    /// Antigravity).
    public var model: String?
    /// The sites its commands may reach. Kept, but used only by a tool whose `honoursSites` is true: none in this build.
    public var allowedDomains: [String]?
    /// The program, when it isn't the one on the login shell's PATH. Set outside Binders, shown in Settings.
    public var executable: String?
    /// "Work in the folder itself", as Claude Code's (`ClaudeCodeWake.inFolder`): each run starts in `repository` as it
    /// is, with no worktree, so the folder needn't be a git repository (a workspace holding several, say). It changes your
    /// files there directly, Binders commits nothing, and one card runs in the folder at a time. Nil means off.
    public var inFolder: Bool?
    /// "Open a pull request when it finishes" (`PullRequests`). Nil means off.
    public var pullRequests: Bool?

    /// Whether each run works in the folder itself, with no worktree: only when you turned it on.
    public var worksInFolder: Bool { inFolder == true }

    /// How its pull requests are opened, when you turned them on and it can: Binders, after it commits in a worktree; the
    /// run itself in the folder itself, where only a tool that runs git (Codex) can make a branch and commit. Nil: none.
    public var pullRequestWay: PullRequests.Way? {
        guard pullRequests == true else { return nil }
        if !worksInFolder { return .binders }
        return tool == .codex && editsFiles ? .tool : nil
    }

    /// The modes Binders starts these tools in. Neither turns their checks off.
    public static let modes = ["acceptEdits", "plan"]

    /// The modes a tool can be set to: Antigravity edits files or doesn't run, as it can't be held to reading only.
    public static func modes(for tool: CLIAgent) -> [String] { tool.readsOnly ? modes : ["acceptEdits"] }

    /// The mode a new agent starts with.
    public static let newAgentMode = "acceptEdits"

    /// The mode it runs in: `permissionMode` when it's one of `modes`, and "plan" otherwise.
    public var safeMode: String { Self.modes.contains(permissionMode) ? permissionMode : "plan" }

    /// Whether a run may change files in its worktree.
    public var editsFiles: Bool { safeMode == "acceptEdits" }

    public init(tool: CLIAgent, repository: String, permissionMode: String = Self.newAgentMode, model: String? = nil,
                allowedDomains: [String]? = nil, executable: String? = nil, inFolder: Bool? = nil, pullRequests: Bool? = nil) {
        self.tool = tool
        self.repository = repository
        self.permissionMode = permissionMode
        self.model = model
        self.allowedDomains = allowedDomains
        self.executable = executable
        self.inFolder = inFolder
        self.pullRequests = pullRequests
    }

    private enum CodingKeys: String, CodingKey {
        case tool, repository, permissionMode, model, allowedDomains, executable, inFolder, pullRequests
    }

    /// The tool and the repository are needed, and a tool this build doesn't know fails, so the agent isn't read. A
    /// missing mode reads as "plan".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try container.decode(CLIAgent.self, forKey: .tool)
        repository = try container.decode(String.self, forKey: .repository)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode) ?? "plan"
        model = try container.decodeIfPresent(String.self, forKey: .model)
        allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains)
        executable = try container.decodeIfPresent(String.self, forKey: .executable)
        inFolder = try container.decodeIfPresent(Bool.self, forKey: .inFolder)
        pullRequests = try container.decodeIfPresent(Bool.self, forKey: .pullRequests)
    }

    /// The model it's started with: a name, never another flag, and nothing that turns checks off. Nil leaves it to the tool.
    public var launchModel: String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty, !model.hasPrefix("-"),
              AgentCommands.isAllowed(model) else { return nil }
        return model
    }

    /// OpenCode's provider, from the model ("anthropic" for "anthropic/claude-sonnet-4-5"), in lowercase and kept to the
    /// characters a provider's id has. Nil without one.
    public var provider: String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), let slash = model.firstIndex(of: "/") else { return nil }
        let prefix = model[..<slash].lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        return prefix.isEmpty ? nil : prefix
    }

    /// Whether an OpenCode model is "provider/model".
    public static func isOpenCodeModel(_ model: String) -> Bool {
        model.range(of: #"^[A-Za-z0-9._-]+/\S+$"#, options: .regularExpression) != nil
    }
}

/// A CLI run Binders started, kept beside its log until its end steps are done: so a quit, a crash or an update while it
/// runs doesn't lose its end. The next Binders adopts a run that's still going and ends one that stopped meanwhile.
public struct CLIRunRecord: Codable, Equatable, Sendable {
    public var card: UUID
    public var run: UUID
    public var agent: UUID
    public var agentName: String
    public var tool: CLIAgent
    /// The receipt's words for how it runs: "workspace sandbox, no network".
    public var mode: String
    public var worktree: String
    /// The log's path without its extension; the run's temp folder has its last part as its name.
    public var stem: String
    /// Copilot's session, known up front.
    public var session: String?
    public var pid: Int32
    /// The kernel's start time for that pid, in seconds since 1970, so a reused pid is never taken for the run.
    public var processStart: Double
    /// For the two-hour limit.
    public var startedAt: Date
    /// Binders' record of the run's worktree as it was when the run started (its git folder and branch among it), so the
    /// commit after the run never depends on worktrees.json alone, and a record lost from there is put back.
    public var worktreeRecord: AgentWorktreeRecord?

    public init(card: UUID, run: UUID, agent: UUID, agentName: String, tool: CLIAgent, mode: String, worktree: String, stem: String,
                session: String?, pid: Int32, processStart: Double, startedAt: Date, worktreeRecord: AgentWorktreeRecord? = nil) {
        self.card = card
        self.run = run
        self.agent = agent
        self.agentName = agentName
        self.tool = tool
        self.mode = mode
        self.worktree = worktree
        self.stem = stem
        self.session = session
        self.pid = pid
        self.processStart = processStart
        self.startedAt = startedAt
        self.worktreeRecord = worktreeRecord
    }

    /// As Binders writes it: JSON with sorted keys and ISO 8601 dates.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> CLIRunRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CLIRunRecord.self, from: data)
    }
}

/// A JSON value kept as it was read, for an agent this build can't read: it's written back as it was found.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// JSON written in the order it's built, for text where order counts: OpenCode's permission rules, where the last match
/// wins. Compact, with slashes as they are.
public indirect enum OrderedJSON: Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([OrderedJSON])
    case object([(key: String, value: OrderedJSON)])

    /// The text. With `escapingBraces`, every `{` and `}` inside a string, a key's included, is written as a JSON escape
    /// ({, }), so text that substitutes `{env:…}` and `{file:…}` before it parses the JSON never sees a brace
    /// in a value, and the parser turns each back into one.
    public func text(escapingBraces: Bool = false) -> String {
        var out = ""
        write(into: &out, escapingBraces: escapingBraces)
        return out
    }

    private func write(into out: inout String, escapingBraces: Bool) {
        switch self {
        case .string(let text): out += Self.quoted(text, escapingBraces: escapingBraces)
        case .int(let number): out += String(number)
        case .bool(let value): out += value ? "true" : "false"
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out, escapingBraces: escapingBraces)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                out += Self.quoted(member.key, escapingBraces: escapingBraces) + ":"
                member.value.write(into: &out, escapingBraces: escapingBraces)
            }
            out += "}"
        }
    }

    /// A JSON string: quotes, backslashes and control characters escaped, and braces too when asked.
    static func quoted(_ text: String, escapingBraces: Bool) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "{" where escapingBraces: out += "\\u007b"
            case "}" where escapingBraces: out += "\\u007d"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
