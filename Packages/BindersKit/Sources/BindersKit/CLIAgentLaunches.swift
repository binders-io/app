import Foundation

// How Binders starts each command-line coding tool for one card, worked out ahead so it can be checked argument by
// argument: the arguments, the whole environment, the prompt for standard input, and any file it writes into the run's
// folder (the agents' log folder, outside the worktree, which no run can read). Nothing from the card goes in but its id.

/// What every launch builder needs.
public struct CLIAgentRun: Sendable {
    public var card: UUID
    /// The dispatcher's id for the run: it names OpenCode's run agent.
    public var run: UUID
    public var reason: AgentWake.Reason
    /// The agent's name on the boards: BINDERS_AGENT, in Binders' server entry only.
    public var boardName: String
    public var wake: CLIAgentWake
    /// The running Binders executable: its MCP server.
    public var binders: String
    /// The card's worktree, absolute, made by Binders.
    public var worktree: String
    /// The run's own TMPDIR: <places>/tmp/<stem>.
    public var temporary: String
    /// Binders' folder for the CLI tools (~/.binders): denied to Codex's commands but for this run's worktree and temp.
    public var places: String
    /// The realpath of Binders' own TMPDIR: denied to Codex's commands.
    public var bindersTemp: String
    public var dataFolder: String
    public var home: String
    /// More private folders: the agents' logs, the team folder.
    public var alsoPrivate: [String]
    /// "<logs>/<card8>-<stamp>": each of the run's files is this plus a suffix.
    public var runStem: String
    /// Chosen by Binders. Copilot uses it; the others make their own.
    public var session: UUID
    public var draftsFirst: Bool
    /// The login shell's PATH, or "" for the default.
    public var path: String
    /// Binders' own environment, read for HOME, USER, LOGNAME, SHELL, LANG and __CF_USER_TEXT_ENCODING only.
    public var base: [String: String]
    /// BINDERS_DATA_DIR, in a throwaway data folder only (the self-tests).
    public var throwawayData: String?
    /// Copilot's settings folder for Binders' runs: <places>/copilot.
    public var copilotHome: String
    /// Whether the worktree has AGENTS.md at its top, which OpenCode's run is pointed at.
    public var agentsFile: Bool
    /// The repository's top folder as a realpath, as Binders' record of the worktree has it: where Claude Code keeps its
    /// own cards' worktrees (.claude/worktrees), which Codex's commands are denied. Nil for the agent's folder as given.
    public var repository: String?
    /// Antigravity: the conversation the card's last run left, which this one carries on. Nil starts a new one.
    public var conversation: String?

    public init(card: UUID, run: UUID, reason: AgentWake.Reason, boardName: String, wake: CLIAgentWake, binders: String, worktree: String,
                temporary: String, places: String, bindersTemp: String, dataFolder: String, home: String, alsoPrivate: [String] = [],
                runStem: String, session: UUID, draftsFirst: Bool = true, path: String = "", base: [String: String] = [:],
                throwawayData: String? = nil, copilotHome: String, agentsFile: Bool = false, repository: String? = nil, conversation: String? = nil) {
        self.card = card
        self.run = run
        self.reason = reason
        self.boardName = boardName
        self.wake = wake
        self.binders = binders
        self.worktree = worktree
        self.temporary = temporary
        self.places = places
        self.bindersTemp = bindersTemp
        self.dataFolder = dataFolder
        self.home = home
        self.alsoPrivate = alsoPrivate
        self.runStem = runStem
        self.session = session
        self.draftsFirst = draftsFirst
        self.path = path
        self.base = base
        self.throwawayData = throwawayData
        self.copilotHome = copilotHome
        self.agentsFile = agentsFile
        self.repository = repository
        self.conversation = conversation
    }
}

/// A run, worked out ahead.
public struct CLIAgentLaunch: Equatable, Sendable {
    /// After the program.
    public var arguments: [String]
    /// The worktree.
    public var directory: String
    /// The prompt, on standard input, which is then closed.
    public var stdin: String
    /// The whole environment: never merged with Binders' own.
    public var environment: [String: String]
    /// Files to write before it starts, by absolute path, with their contents: in the run's folder, except Antigravity's
    /// workspace MCP file, which goes in the worktree (`AntigravityLaunch.mcpConfig`) and is taken out when the run ends.
    public var files: [String: String]
    /// The session, when it's known up front (Copilot's).
    public var session: String?
    /// How to look in, when it's known up front (Copilot's).
    public var lookIn: String?
    /// For the receipt: "workspace sandbox, no network".
    public var mode: String
}

public enum CLIAgentLaunches {
    /// Why a launch can't be built.
    public struct Refusal: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// The launch for `run`, by its tool.
    public static func make(_ run: CLIAgentRun) throws -> CLIAgentLaunch {
        switch run.wake.tool {
        case .codex: CodexLaunch.make(run)
        case .opencode: try OpenCodeLaunch.make(run)
        case .copilot: try CopilotLaunch.make(run)
        case .antigravity: try AntigravityLaunch.make(run)
        }
    }

    // MARK: What every run is denied

    /// One path of the shared list, and whether it's a folder.
    public struct PrivatePath: Equatable, Sendable {
        public var path: String
        public var isFolder: Bool

        public init(path: String, isFolder: Bool) {
            self.path = path
            self.isFolder = isFolder
        }
    }

    /// Your keys and sign-ins, by where they sit in your home folder, and whether each is a folder.
    static let keys: [(String, Bool)] = [(".gnupg", true), (".netrc", false), (".git-credentials", false), (".npmrc", false), (".pypirc", false),
                                         (".aws", true), (".azure", true), (".config/gcloud", true), (".kube", true), (".docker", true),
                                         (".config/gh", true)]

    /// The coding tools' own sign-ins, sessions and histories: the whole of each tool's folder (Codex's, OpenCode's
    /// three, Copilot's, Grok's, Gemini's and Antigravity's (~/.gemini), Cursor's), and of Claude Code's the sign-in and what its sessions leave behind
    /// (transcripts, prompt history, file history, to-do lists, pastes, pasted images, backups of ~/.claude.json). Not the
    /// rest of ~/.claude: a Claude Code run's own skills and plans are there. Codex's profile reopens its packaged tools in
    /// ~/.codex/packages (`CodexLaunch.reopened`) and denies all of ~/.claude.
    static let toolSessions: [(String, Bool)] = [(".codex", true), (".local/share/opencode", true), (".local/state/opencode", true),
                                                 (".config/opencode", true), (".copilot", true), (".claude/projects", true),
                                                 (".claude/history.jsonl", false), (".claude/file-history", true), (".claude/todos", true),
                                                 (".claude/paste-cache", true), (".claude/image-cache", true), (".claude/backups", true),
                                                 (".claude/.credentials.json", false), (".claude.json", false),
                                                 (".grok", true), (".gemini", true), (".cursor", true)]

    /// What no run may read or change, in order: ~/.ssh, Binders' data folder, the other private folders (the agents'
    /// logs, the team folder), your other keys and sign-ins, and the coding tools' own sign-ins, sessions and histories.
    /// Codex's permission profile and Claude Code's deny rules and sandbox both use it.
    public static func privateList(home: String, dataFolder: String, alsoPrivate: [String]) -> [PrivatePath] {
        let home = trimmed(home)
        var list = [PrivatePath(path: home + "/.ssh", isFolder: true), PrivatePath(path: trimmed(dataFolder), isFolder: true)]
        list += alsoPrivate.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { PrivatePath(path: trimmed($0), isFolder: true) }
        list += (keys + toolSessions).map { PrivatePath(path: home + "/" + $0.0, isFolder: $0.1) }
        var seen: Set<String> = []
        return list.filter { seen.insert($0.path).inserted }
    }

    /// The same, as paths.
    public static func privatePaths(home: String, dataFolder: String, alsoPrivate: [String]) -> [String] {
        privateList(home: home, dataFolder: dataFolder, alsoPrivate: alsoPrivate).map(\.path)
    }

    // MARK: The environment

    /// The run's whole environment, from an allowlist: PATH (the login shell's, or the system's), HOME, USER, LOGNAME,
    /// SHELL, the run's own TMPDIR, LANG, __CF_USER_TEXT_ENCODING when it's set, BINDERS_DATA_DIR in a throwaway data
    /// folder, and the tool's own (`extra`). Nothing else: no API keys or tokens, no SSH agent, none of the tools' switches.
    public static func environment(base: [String: String], home: String, path: String, temporary: String, throwawayData: String?,
                                   extra: [String: String] = [:]) -> [String: String] {
        var environment: [String: String] = [:]
        environment["PATH"] = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/usr/bin:/bin:/usr/sbin:/sbin" : path
        environment["HOME"] = home
        for key in ["USER", "LOGNAME", "SHELL", "__CF_USER_TEXT_ENCODING"] {
            if let value = base[key], !value.isEmpty { environment[key] = value }
        }
        environment["SHELL"] = environment["SHELL"] ?? "/bin/zsh"
        environment["LANG"] = base["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8"
        environment["TMPDIR"] = temporary.hasSuffix("/") ? temporary : temporary + "/"
        if let throwawayData { environment["BINDERS_DATA_DIR"] = throwawayData }
        environment.merge(extra) { _, added in added }
        return environment
    }

    /// The values Binders' server gets for one run, in this order: the board tools (BINDERS_TOOLS=board, which a Binders
    /// before this one also confines to BINDERS_CARD), a run Binders started (BINDERS_RUN, so this one offers nothing when
    /// the card or the name didn't arrive), this card, this agent, and the throwaway data folder in the self-tests.
    static func serverValues(_ run: CLIAgentRun) -> [(String, String)] {
        var values = [("BINDERS_TOOLS", "board"), ("BINDERS_RUN", "1"), ("BINDERS_CARD", run.card.uuidString), ("BINDERS_AGENT", run.boardName)]
        // The run opens its own pull requests only where it commits itself (`PullRequests.Way.tool`).
        if run.wake.pullRequestWay == .tool { values.append((PullRequests.environmentKey, "1")) }
        if let data = run.throwawayData { values.append(("BINDERS_DATA_DIR", data)) }
        return values
    }

    /// The prompt for a CLI run: Binders commits, and it says what the run can do.
    static func prompt(_ run: CLIAgentRun) -> String {
        AgentRunPrompt.text(card: run.card, reason: run.reason, draftsFirst: run.draftsFirst, commits: .binders,
                            reach: AgentRunPrompt.reach(run.wake.tool, editsFiles: run.wake.editsFiles), inFolder: run.wake.worksInFolder,
                            pullRequests: run.wake.pullRequestWay)
    }

    // MARK: Small parts

    /// The first 12 hex digits of the card's id, lowercased, with no dash.
    public static func card12(_ card: UUID) -> String {
        String(card.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
    }

    /// The path without a trailing slash, unless it's the root.
    static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// A path to paste into Terminal: "~/…" inside the home folder, quoted only where the shell would split it, so "~"
    /// still expands.
    public static func pastable(_ path: String, home: String) -> String {
        let path = trimmed(path), home = trimmed(home)
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/+-@%:,")
        func plain(_ text: String) -> Bool { !text.isEmpty && text.unicodeScalars.allSatisfy(safe.contains) }
        if home.count > 1, path.hasPrefix(home + "/") {
            let rest = String(path.dropFirst(home.count + 1))
            return "~/" + (plain(rest) ? rest : AgentMCPEntry.quoted(rest))
        }
        return plain(path) ? path : AgentMCPEntry.quoted(path)
    }
}

// MARK: - Codex

/// `codex exec` for one card, in Codex's own sandbox, set per run by a permission profile: it writes only to the worktree,
/// its own temp folder and /tmp (Codex's own default), and its commands can't read your keys, sign-ins, the coding
/// tools' folders and sessions (Codex's own but its packaged tools, and all of ~/.claude), other cards' worktrees
/// (Binders' and Claude Code's), Binders' data, team or log folders, or Binders' temp files. Your Codex settings, rules,
/// hooks, plugins, apps and shell profile stay out; only Binders' server comes in, for this card. No network for its
/// commands in this build.
public enum CodexLaunch {
    /// The `-c` keys Binders sets, as key paths (with <name> for a map's key): each is checked against Codex's
    /// config.schema.json at the build Binders' options were checked with.
    public static let configKeys = ["approvals_reviewer", "web_search", "allow_login_shell", "shell_environment_policy.inherit",
                                    "shell_environment_policy.ignore_default_excludes", "shell_environment_policy.set",
                                    "default_permissions", "permissions.<name>.extends", "permissions.<name>.filesystem",
                                    "permissions.<name>.network", "mcp_servers.<name>.command", "mcp_servers.<name>.args",
                                    "mcp_servers.<name>.env", "mcp_servers.<name>.required", "mcp_servers.<name>.default_tools_approval_mode",
                                    "features.network_proxy"]

    /// The features Binders turns off: ChatGPT's connectors, plugins (their servers and hooks), the shell snapshot that
    /// would replay your profile's exports into its commands, skills adding an MCP server of their own, and hooks (one an
    /// administrator put in /etc/codex counts as trusted and runs outside the sandbox).
    public static let disabledFeatures = ["apps", "plugins", "shell_snapshot", "skill_mcp_dependency_install", "hooks"]

    /// The name of the run's permission profile.
    static let profile = "binders"

    /// Inside ~/.codex, which the shared list denies, what its commands may still read: Codex's packaged tools (the codex
    /// program its helpers link to, its rg), in your home folder.
    static let reopened = [".codex/packages"]

    /// Where Claude Code keeps the worktrees of its own cards in a repository (`ClaudeCodeLaunch.worktree`).
    static func claudeWorktrees(_ repository: String) -> String {
        CLIAgentLaunches.trimmed(repository) + "/.claude/worktrees"
    }

    public static func make(_ run: CLIAgentRun, sites: Bool = CLIAgent.codex.honoursSites) -> CLIAgentLaunch {
        let worktree = CLIAgentLaunches.trimmed(run.worktree), temporary = CLIAgentLaunches.trimmed(run.temporary)
        let home = CLIAgentLaunches.trimmed(run.home)
        let edits = run.wake.editsFiles
        // Denied: the shared list, all of ~/.claude (Claude Code's folder, nothing a Codex command needs), Binders' folder
        // and temp folder, and Claude Code's worktrees for the repository's other cards. Then reopened, as the more
        // specific entry wins: Codex's packaged tools, to read, and this run's own folders inside ~/.binders.
        var filesystem: [(String, String)] = CLIAgentLaunches.privatePaths(home: run.home, dataFolder: run.dataFolder, alsoPrivate: run.alsoPrivate)
            .map { ($0, "deny") }
        filesystem += [(home + "/.claude", "deny"), (CLIAgentLaunches.trimmed(run.places), "deny"), (CLIAgentLaunches.trimmed(run.bindersTemp), "deny"),
                       (claudeWorktrees(run.repository ?? run.wake.repository), "deny")]
        filesystem += reopened.map { (home + "/" + $0, "read") }
        filesystem += [(worktree, edits ? "write" : "read"), (temporary, edits ? "write" : "read")]
        var seen: Set<String> = []
        filesystem = filesystem.filter { !$0.0.isEmpty && seen.insert($0.0).inserted }

        var arguments = ["exec", "--json", "--cd", worktree, "--ignore-user-config", "--ignore-rules", "--strict-config"]
        // In the folder itself, which needn't be a git repository: Codex refuses one that isn't, unless told.
        if run.wake.worksInFolder { arguments.append("--skip-git-repo-check") }
        for feature in disabledFeatures { arguments += ["--disable", feature] }
        func set(_ key: String, _ value: String) { arguments += ["-c", "\(key)=\(value)"] }
        set("approvals_reviewer", toml("user"))
        set("web_search", toml("disabled"))
        set("allow_login_shell", "false")
        set("shell_environment_policy.inherit", toml("core"))
        set("shell_environment_policy.ignore_default_excludes", "false")
        set("shell_environment_policy.set", table([("ZDOTDIR", toml(temporary + "/zsh"))]))
        set("default_permissions", toml(profile))
        set("permissions.\(profile).extends", toml(edits ? ":workspace" : ":read-only"))
        set("permissions.\(profile).filesystem", table(filesystem.map { (toml($0.0), toml($0.1)) }))
        let domains = (run.wake.allowedDomains ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        if sites, !domains.isEmpty {
            // The profile's own network rules, enforced only through the network proxy, as OpenAI documents for profiles.
            set("permissions.\(profile).network", table([("enabled", "true"), ("domains", table(domains.map { (toml($0), toml("allow")) }))]))
            set("features.network_proxy", "true")
        }
        set("mcp_servers.binders.command", toml(run.binders))
        set("mcp_servers.binders.args", "[" + toml("--mcp") + "]")
        set("mcp_servers.binders.env", table(CLIAgentLaunches.serverValues(run).map { ($0.0, toml($0.1)) }))
        set("mcp_servers.binders.required", "true")
        set("mcp_servers.binders.default_tools_approval_mode", toml("approve"))
        if let model = run.wake.launchModel { arguments += ["-m", model] }
        arguments.append("-")
        return CLIAgentLaunch(arguments: arguments, directory: worktree, stdin: CLIAgentLaunches.prompt(run),
                              environment: CLIAgentLaunches.environment(base: run.base, home: run.home, path: run.path, temporary: run.temporary,
                                                                        throwawayData: run.throwawayData),
                              files: [:], session: nil, lookIn: nil,
                              mode: edits ? "workspace sandbox, no network" : "read-only sandbox, no network")
    }

    /// A TOML basic string: backslashes, quotes and control characters escaped.
    public static func toml(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// An inline table of keys (bare or already quoted) and TOML values.
    static func table(_ entries: [(String, String)]) -> String {
        entries.isEmpty ? "{}" : "{ " + entries.map { "\($0.0) = \($0.1)" }.joined(separator: ", ") + " }"
    }

    /// The command that looks in on a finished run, with your own Codex settings, when its thread id is a UUID.
    public static func lookIn(thread: String?, worktree: String, home: String) -> String? {
        guard let thread, let id = UUID(uuidString: thread) else { return nil }
        return "codex resume \(id.uuidString.lowercased()) -C \(CLIAgentLaunches.pastable(worktree, home: home))"
    }
}

// MARK: - OpenCode

/// `opencode run` for one card. OpenCode has no sandbox, so the run gets no commands and no web: it reads and edits files
/// in its worktree, keeps a to-do list, and uses Binders' board tools for this card, under a run agent named for this run
/// that no file can define ahead of time. The repository's own OpenCode settings, agents and plugins stay out, and so do
/// your plugins.
public enum OpenCodeLaunch {
    /// Binders' board tools, as OpenCode names a tool of the server named binders.
    public static let boardTools = ["list_tasks", "get_task", "claim_task", "update_task", "ask_on_task", "comment_task", "release_task",
                                    "complete_task", "request_approval"].map { "binders_" + $0 }

    /// The run agent's name: "binders-card-" and the first 8 hex digits of the run's id.
    public static func agentName(run: UUID) -> String {
        "binders-card-" + String(run.uuidString.lowercased().prefix(8))
    }

    public static func make(_ run: CLIAgentRun) throws -> CLIAgentLaunch {
        guard let model = run.wake.launchModel, CLIAgentWake.isOpenCodeModel(model) else {
            throw CLIAgentLaunches.Refusal("OpenCode needs its model as provider/model, such as anthropic/claude-sonnet-4-5.")
        }
        let worktree = CLIAgentLaunches.trimmed(run.worktree)
        let agent = agentName(run: run.run)
        let arguments = ["run", "--dir", worktree, "--agent", agent, "--format", "json", "--title", "Binders card \(CLIAgentLaunches.card12(run.card))",
                         "--model", model, "--pure"]
        let extra = ["PWD": worktree, "OPENCODE_CONFIG_CONTENT": config(run, agent: agent).text(escapingBraces: true),
                     "OPENCODE_DISABLE_PROJECT_CONFIG": "1", "OPENCODE_PURE": "1", "OPENCODE_DISABLE_SHARE": "1",
                     "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_CLAUDE_CODE": "1", "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
                     "NO_COLOR": "1"]
        return CLIAgentLaunch(arguments: arguments, directory: worktree, stdin: CLIAgentLaunches.prompt(run),
                              environment: CLIAgentLaunches.environment(base: run.base, home: run.home, path: run.path, temporary: run.temporary,
                                                                        throwawayData: run.throwawayData, extra: extra),
                              files: [:], session: nil, lookIn: nil,
                              mode: run.wake.editsFiles ? "edits files in its \(run.wake.worksInFolder ? "folder" : "worktree"), no commands" : "reads only, no commands")
    }

    /// The run's config, in OPENCODE_CONFIG_CONTENT: its rules in the order OpenCode reads them, where the last match
    /// wins, so it's written by an ordered encoder.
    static func config(_ run: CLIAgentRun, agent: String) -> OrderedJSON {
        let worktree = CLIAgentLaunches.trimmed(run.worktree), home = CLIAgentLaunches.trimmed(run.home)
        func allow(_ key: String) -> (key: String, value: OrderedJSON) { (key, .string("allow")) }
        func deny(_ key: String) -> (key: String, value: OrderedJSON) { (key, .string("deny")) }
        var permission: [(key: String, value: OrderedJSON)] = [deny("*")]
        permission.append(("read", .object([allow("*"), deny("*.env"), deny("*.env.*"), allow("*.env.example")])))
        permission += [allow("glob"), allow("grep"), allow("list")]
        if run.wake.editsFiles {
            permission.append(("edit", .object([allow("*"), deny("*opencode.json"), deny("*opencode.jsonc"), deny("*.opencode/*"), deny("*.git")])))
        }
        permission.append(allow("todowrite"))
        permission += ["bash", "task", "webfetch", "websearch", "skill", "lsp", "question", "plan_enter", "plan_exit"].map(deny)
        permission += boardTools.map(allow)
        // OpenCode adds its own tool-output folder after every agent's rules unless that exact glob is denied.
        permission.append(("external_directory", .object([deny("*"), deny(home + "/.local/share/opencode/tool-output/*")])))
        permission.append(("doom_loop", .string("ask")))

        var top: [(key: String, value: OrderedJSON)] = [("$schema", .string("https://opencode.ai/config.json")), ("share", .string("disabled")),
                                                        ("default_agent", .string(agent)), ("formatter", .bool(false)), ("lsp", .bool(false))]
        if run.agentsFile { top.append(("instructions", .array([.string(worktree + "/AGENTS.md")]))) }
        let environment = CLIAgentLaunches.serverValues(run).map { (key: $0.0, value: OrderedJSON.string($0.1)) }
        top.append(("mcp", .object([("binders", .object([("type", .string("local")), ("command", .array([.string(run.binders), .string("--mcp")])),
                                                         ("environment", .object(environment)), ("enabled", .bool(true))]))])))
        top.append(("agent", .object([(agent, .object([("description", .string(run.wake.worksInFolder ? "Works on one Binders card in its folder." : "Works on one Binders card in its own git worktree.")),
                                                       ("mode", .string("primary")), ("steps", .int(150)), ("permission", .object(permission))]))])))
        return .object(top)
    }

    /// The command that looks in on a finished run, with your own OpenCode settings, when its session id is OpenCode's.
    public static func lookIn(session: String?, worktree: String, home: String) -> String? {
        guard let session, session.range(of: #"^ses_[A-Za-z0-9]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return "opencode \(CLIAgentLaunches.pastable(worktree, home: home)) --session \(session)"
    }
}

// MARK: - GitHub Copilot CLI

/// `copilot` in prompt mode for one card, which denies whatever no rule allows. 1.0.10 has no sandbox, so the run gets no
/// commands: it reads and edits files in its worktree and uses Binders' board tools for this card. It runs on a Copilot
/// settings folder of Binders' own, set back to safe values before each run, so your own servers, plugins, hooks and
/// trusted folders stay out.
public enum CopilotLaunch {
    public static func make(_ run: CLIAgentRun) throws -> CLIAgentLaunch {
        // Copilot expands $VAR in a server's values: a dollar sign would be read as a variable.
        for (what, value) in [("Binders' path", run.binders), ("the agent's name", run.boardName), ("the data folder", run.throwawayData ?? "")]
        where value.contains("$") {
            throw CLIAgentLaunches.Refusal("GitHub Copilot CLI would read the $ in \(what) as a variable.")
        }
        let worktree = CLIAgentLaunches.trimmed(run.worktree)
        let session = run.session.uuidString.lowercased()
        let file = run.runStem + ".mcp.json"
        var arguments = ["--no-auto-update", "--output-format=json", "--stream=off", "--no-color", "--no-ask-user", "--resume=\(session)",
                         "--disable-builtin-mcps", "--additional-mcp-config=@\(file)", "--allow-tool=binders"]
        // Writes only in Edits mode, and never a write deny: Copilot 1.0.10 reads any deny of kind write, whatever its
        // argument, as a deny of every write. A rewritten .git file is caught by Binders' own check before it commits.
        if run.wake.editsFiles { arguments.append("--allow-tool=write") }
        arguments.append("--deny-tool=shell")
        // No hand-offs and no language servers. A custom agent's own MCP servers start when the task tool hands it work,
        // and a language server from lsp.json starts when the lsp tool is used, both outside every permission rule. One
        // --flag=value element each; Copilot adds repeated values up.
        arguments += ["--excluded-tools=task", "--excluded-tools=lsp"]
        if let model = run.wake.launchModel { arguments.append("--model=\(model)") }
        let server: OrderedJSON = .object([("type", .string("local")), ("command", .string(run.binders)), ("args", .array([.string("--mcp")])),
                                           ("env", .object(CLIAgentLaunches.serverValues(run).map { (key: $0.0, value: OrderedJSON.string($0.1)) })),
                                           ("tools", .array([.string("*")]))])
        let extra = ["COPILOT_HOME": run.copilotHome, "COPILOT_AUTO_UPDATE": "false", "NO_COLOR": "1"]
        return CLIAgentLaunch(arguments: arguments, directory: worktree, stdin: CLIAgentLaunches.prompt(run),
                              environment: CLIAgentLaunches.environment(base: run.base, home: run.home, path: run.path, temporary: run.temporary,
                                                                        throwawayData: run.throwawayData, extra: extra),
                              files: [file: OrderedJSON.object([("mcpServers", .object([("binders", server)]))]).text()],
                              session: session, lookIn: lookIn(session: session, worktree: worktree, copilotHome: run.copilotHome, home: run.home),
                              mode: run.wake.editsFiles ? "edits files in its \(run.wake.worksInFolder ? "folder" : "worktree"), no commands" : "reads only, no commands")
    }

    /// The command that looks in on the run, in its worktree, with Binders' settings folder for Copilot.
    public static func lookIn(session: String, worktree: String, copilotHome: String, home: String) -> String {
        "cd \(CLIAgentLaunches.pastable(worktree, home: home)) && COPILOT_HOME=\(CLIAgentLaunches.pastable(copilotHome, home: home)) copilot --resume=\(session)"
    }
}

/// Copilot's settings folder for Binders' runs, made ready before each run. A look-in on a run can trust a folder, add a
/// server or approve a tool there, so before the next run Binders sets those back, and refuses to start while anything
/// that runs code or changes where cards go is in it. The app does the files; these are the decisions.
public enum CopilotHome {
    /// Files that would add a server, a language server or a provider.
    public static let blockingFiles = ["lsp-config.json", "providers.json"]
    /// Folders that add hooks, extensions, plugins, agents or skills when they hold anything.
    public static let blockingFolders = ["hooks", "extensions", "installed-plugins", "agents", "skills"]
    /// Approvals given while looking in, which a run must never inherit.
    public static let deleted = ["permissions-config.json", "permissions-config"]
    /// The settings files set back: config.json (1.0.10) and settings.json (later versions).
    public static let settingsFiles = ["config.json", "settings.json"]

    /// Why a run can't start with the folder as it is, or nil. `present` are the names of the files there and of its
    /// folders that hold anything; `mcpConfig` is mcp-config.json when there is one.
    public static func problem(present: Set<String>, mcpConfig: Data?, folder: String) -> String? {
        var found: [String] = []
        if let mcpConfig {
            guard let object = (try? JSONSerialization.jsonObject(with: mcpConfig)) as? [String: Any] else {
                return blocked("mcp-config.json, which isn't JSON Binders can read", folder: folder)
            }
            if let servers = object["mcpServers"] as? [String: Any], !servers.isEmpty { found.append("mcp-config.json with a server in it") }
        }
        found += blockingFiles.filter(present.contains)
        found += blockingFolders.filter(present.contains).map { $0 + "/" }
        guard !found.isEmpty else { return nil }
        return blocked(found.joined(separator: ", "), folder: folder)
    }

    private static func blocked(_ what: String, folder: String) -> String {
        "Binders didn't start GitHub Copilot CLI: its settings folder for Binders' runs, \(folder), now has \(what), probably added while you looked in on a run. Remove it there, then Wake Now."
    }

    /// A settings file set back to what a run needs: no trusted folders, hooks off, no commit trailer, no updates, no IDE,
    /// and no other API address, allowed sites, hooks or experiments. Everything else in it stays. Nil data starts empty.
    /// Throws when it isn't a JSON object.
    public static func reset(_ data: Data?) throws -> Data {
        var object: [String: Any] = [:]
        if let data, !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            guard let read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw CLIAgentLaunches.Refusal("not JSON") }
            object = read
        }
        object["trusted_folders"] = [String]()
        object["disableAllHooks"] = true
        object["includeCoAuthoredBy"] = false
        object["auto_update"] = false
        var ide = object["ide"] as? [String: Any] ?? [:]
        ide["auto_connect"] = false
        object["ide"] = ide
        for key in ["copilot_url", "allowed_urls", "hooks", "experimental"] { object[key] = nil }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

/// Codex's settings from an administrator, which outrank anything Binders passes: they could change a run's sandbox or
/// where it sends cards, and the rules, hooks, skills and agents in their folder load even with `--ignore-rules` (an
/// allow rule there runs a command outside the sandbox, and a hook there counts as trusted). So Binders won't start Codex
/// while anything is in /etc/codex, or a managed profile sets them. The app looks; this decides.
public enum CodexManaged {
    /// The folder Codex reads them from, every file and folder in it.
    public static let folder = "/etc/codex"
    /// The settings files in it, named first when one is there.
    public static let files = ["/etc/codex/config.toml", "/etc/codex/requirements.toml", "/etc/codex/managed_config.toml"]
    /// The managed preferences' application and the keys Codex asks whether an administrator forced.
    public static let application = "com.openai.codex"
    public static let forcedKeys = ["config_toml_base64", "requirements_toml_base64"]

    /// What in the folder counts, by name: anything but a hidden file, which Codex reads none of.
    public static func counts(_ name: String) -> Bool { !name.isEmpty && !name.hasPrefix(".") }

    /// Where they are, said for a person: the first settings file, else the first other thing in the folder, or a managed
    /// profile. `existing` is what's in the folder, as /etc/codex/<name>.
    static func which(existing: [String], forced: [String]) -> String? {
        if let file = files.first(where: existing.contains) { return file }
        if let other = existing.sorted().first { return other }
        return forced.isEmpty ? nil : "a managed \(application) profile"
    }

    /// Why Binders won't start Codex, for the card. Nil when there are none.
    public static func problem(existing: [String], forced: [String]) -> String? {
        which(existing: existing, forced: forced).map {
            "Binders didn't start Codex: this Mac has Codex settings from an administrator (\($0)), and they could change the run's sandbox or where it sends cards."
        }
    }

    /// The same, for Check in Settings.
    public static func found(existing: [String], forced: [String]) -> String? {
        which(existing: existing, forced: forced).map { "Codex settings from an administrator are on this Mac (\($0)), so Binders won't start Codex." }
    }
}
