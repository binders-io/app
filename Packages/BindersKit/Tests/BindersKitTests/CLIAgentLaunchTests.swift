import XCTest
@testable import BindersKit

/// How Binders starts each command-line tool for a card, argument by argument: what keeps its checks on, what keeps your
/// own settings and secrets out, and Binders' server for that card only.
final class CLIAgentLaunchTests: XCTestCase {
    private let card = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let run = UUID(uuidString: "16FD2706-8BAF-433B-82EB-8C7FADA847DA")!
    private let session = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
    private let home = "/Users/sam"
    private let data = "/Users/sam/Library/Application Support/Binders"
    private let binders = "/Applications/Binders.app/Contents/MacOS/Binders"
    private let places = "/Users/sam/.binders"
    private let logs = "/Users/sam/Library/Logs/Binders/Agents"
    private let team = "/Volumes/Team/Binders"
    private let bindersTemp = "/private/var/folders/xy/T"

    private func worktree(_ tool: CLIAgent) -> String { "\(places)/worktrees/app-1a2b3c4d/binders-3f2504e04f89-\(tool.rawValue)" }
    private var temporary: String { "\(places)/tmp/3f2504e0-20261018T120000" }

    /// A run with the fixed parts, and Binders' own environment holding the things that must never reach a run.
    private func run(_ tool: CLIAgent, mode: String = "acceptEdits", model: String? = nil, name: String? = nil, worktree path: String? = nil,
                     domains: [String]? = nil, throwaway: String? = nil, agentsFile: Bool = false, reason: AgentWake.Reason = .ready) -> CLIAgentRun {
        let defaultModel: String? = tool == .opencode ? "anthropic/claude-sonnet-4-5" : nil
        let wake = CLIAgentWake(tool: tool, repository: "/Users/sam/code/app", permissionMode: mode, model: model ?? defaultModel, allowedDomains: domains)
        return CLIAgentRun(card: card, run: run, reason: reason, boardName: name ?? "\(tool.shortName) · app", wake: wake, binders: binders,
                           worktree: path ?? worktree(tool), temporary: temporary, places: places, bindersTemp: bindersTemp, dataFolder: data,
                           home: home, alsoPrivate: [logs, team], runStem: "\(logs)/3f2504e0-20261018T120000", session: session,
                           path: "/opt/homebrew/bin:/Users/sam/.local/bin:/usr/bin:/bin",
                           base: ["HOME": home, "USER": "sam", "LOGNAME": "sam", "SHELL": "/bin/zsh", "LANG": "en_GB.UTF-8",
                                  "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x2", "OPENAI_API_KEY": "sk-not-for-runs", "GH_TOKEN": "ghs_x",
                                  "SSH_AUTH_SOCK": "/private/tmp/ssh/agent", "COPILOT_ALLOW_ALL": "false", "OPENCODE_PERMISSION": #"{"*":"allow"}"#,
                                  "XDG_CONFIG_HOME": "/Users/sam/.config", "CODEX_HOME": "/Users/sam/.codex-other", "BINDERS_TOOLS": "everything"],
                           throwawayData: throwaway, copilotHome: "\(places)/copilot", agentsFile: agentsFile)
    }

    private func launch(_ run: CLIAgentRun) throws -> CLIAgentLaunch { try CLIAgentLaunches.make(run) }

    /// The value of a `-c key=value` override.
    private func override(_ key: String, in arguments: [String]) -> String? {
        arguments.lazy.filter { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }.first
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    // MARK: Codex

    func testCodexLaunchLine() throws {
        let line = try launch(run(.codex))
        var arguments = line.arguments
        let filesystem = try XCTUnwrap(arguments.firstIndex { $0.hasPrefix("permissions.binders.filesystem=") })
        arguments[filesystem] = "permissions.binders.filesystem=<the shared list>"
        let worktree = worktree(.codex)
        XCTAssertEqual(arguments, [
            "exec", "--json", "--cd", worktree, "--ignore-user-config", "--ignore-rules", "--strict-config",
            "--disable", "apps", "--disable", "plugins", "--disable", "shell_snapshot", "--disable", "skill_mcp_dependency_install",
            "--disable", "hooks",
            "-c", #"approvals_reviewer="user""#,
            "-c", #"web_search="disabled""#,
            "-c", "allow_login_shell=false",
            "-c", #"shell_environment_policy.inherit="core""#,
            "-c", "shell_environment_policy.ignore_default_excludes=false",
            "-c", #"shell_environment_policy.set={ ZDOTDIR = "\#(temporary)/zsh" }"#,
            "-c", #"default_permissions="binders""#,
            "-c", #"permissions.binders.extends=":workspace""#,
            "-c", "permissions.binders.filesystem=<the shared list>",
            "-c", #"mcp_servers.binders.command="\#(binders)""#,
            "-c", #"mcp_servers.binders.args=["--mcp"]"#,
            "-c", #"mcp_servers.binders.env={ BINDERS_TOOLS = "board", BINDERS_RUN = "1", BINDERS_CARD = "\#(card.uuidString)", BINDERS_AGENT = "Codex · app" }"#,
            "-c", "mcp_servers.binders.required=true",
            "-c", #"mcp_servers.binders.default_tools_approval_mode="approve""#,
            "-",
        ])
        XCTAssertEqual(line.directory, worktree)
        XCTAssertEqual(line.mode, "workspace sandbox, no network")
        XCTAssertTrue(line.files.isEmpty)
        XCTAssertNil(line.session, "Codex makes its own thread id")
        XCTAssertEqual(try launch(run(.codex, model: "gpt-5.1-codex")).arguments.suffix(3), ["-m", "gpt-5.1-codex", "-"])
    }

    func testCodexPlanMode() throws {
        let arguments = try launch(run(.codex, mode: "plan")).arguments
        XCTAssertEqual(override("permissions.binders.extends", in: arguments), #"":read-only""#)
        let table = try XCTUnwrap(TOMLValue.parse(try XCTUnwrap(override("permissions.binders.filesystem", in: arguments)))?.table)
        XCTAssertEqual(table[worktree(.codex)], .string("read"))
        XCTAssertEqual(table[temporary], .string("read"))
        XCTAssertEqual(try launch(run(.codex, mode: "plan")).mode, "read-only sandbox, no network")
        XCTAssertEqual(try launch(run(.codex, mode: "bypassPermissions")).arguments, arguments, "an unknown mode runs as plans only")
    }

    /// The shared list, as the paths after ~/.ssh and Binders' own folders: your other keys and sign-ins, then the coding
    /// tools' folders, sessions and histories.
    private let sharedRest = [".gnupg", ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".aws", ".azure", ".config/gcloud", ".kube", ".docker",
                              ".config/gh", ".codex", ".local/share/opencode", ".local/state/opencode", ".config/opencode", ".copilot",
                              ".claude/projects", ".claude/history.jsonl", ".claude/file-history", ".claude/todos", ".claude/paste-cache",
                              ".claude/image-cache", ".claude/backups", ".claude/.credentials.json", ".claude.json", ".grok", ".gemini", ".cursor"]

    func testCodexDeniesTheSharedListAndReopensItsOwnFolders() throws {
        let arguments = try launch(run(.codex)).arguments
        let text = try XCTUnwrap(override("permissions.binders.filesystem", in: arguments))
        let table = try XCTUnwrap(TOMLValue.parse(text)?.table)
        let shared = ["/Users/sam/.ssh", data, logs, team] + sharedRest.map { "\(home)/\($0)" }
        let denied = shared + ["\(home)/.claude", places, bindersTemp, "/Users/sam/code/app/.claude/worktrees"]
        for path in denied { XCTAssertEqual(table[path], .string("deny"), path) }
        XCTAssertEqual(table["\(home)/.codex/packages"], .string("read"), "Codex's own packaged tools, inside the ~/.codex it denies")
        XCTAssertEqual(table[worktree(.codex)], .string("write"))
        XCTAssertEqual(table[temporary], .string("write"))
        XCTAssertEqual(table.count, denied.count + 3)
        // Every session store the review found, Codex's and the others': the whole of ~/.codex holds Codex's databases.
        for path in [".codex", ".claude/history.jsonl", ".claude/file-history", ".claude/todos", ".local/state/opencode"] {
            XCTAssertEqual(table["\(home)/\(path)"], .string("deny"), path)
        }
        // The more specific entries come after the broad deny they reopen.
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"\(places)\" = \"deny\"")).lowerBound,
                          try XCTUnwrap(text.range(of: "\"\(worktree(.codex))\" = \"write\"")).lowerBound)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"\(home)/.codex\" = \"deny\"")).lowerBound,
                          try XCTUnwrap(text.range(of: "\"\(home)/.codex/packages\" = \"read\"")).lowerBound)
        XCTAssertEqual(CLIAgentLaunches.privatePaths(home: home, dataFolder: data, alsoPrivate: [logs, team, " "]), shared,
                       "the shared list, with nothing for a blank folder")
    }

    func testCodexCantReadClaudeCodesWorktreesOfOtherCards() throws {
        var given = run(.codex)
        given.repository = "/Users/sam/real/app"
        let table = try XCTUnwrap(TOMLValue.parse(try XCTUnwrap(override("permissions.binders.filesystem", in: try launch(given).arguments)))?.table)
        XCTAssertEqual(table["/Users/sam/real/app/.claude/worktrees"], .string("deny"), "the repository as Binders' record has it, a realpath")
        XCTAssertNil(table["/Users/sam/code/app/.claude/worktrees"])
        XCTAssertEqual(CodexLaunch.claudeWorktrees("/Users/sam/code/app/"), "/Users/sam/code/app/.claude/worktrees")
        XCTAssertEqual(ClaudeCodeLaunch.worktree(repository: "/Users/sam/code/app", card: card).hasPrefix(CodexLaunch.claudeWorktrees("/Users/sam/code/app") + "/"),
                       true, "where Claude Code's runs make theirs")
        let plan = try XCTUnwrap(TOMLValue.parse(try XCTUnwrap(override("permissions.binders.filesystem", in: try launch(run(.codex, mode: "plan")).arguments)))?.table)
        XCTAssertEqual(plan["\(home)/.codex/packages"], .string("read"))
        XCTAssertEqual(plan["/Users/sam/code/app/.claude/worktrees"], .string("deny"))
    }

    func testCodexPathsAreTOMLStrings() throws {
        let odd = "/Users/sam/.binders/worktrees/my \"app\" \\ 1/binders-3f2504e04f89-codex"
        let arguments = try launch(run(.codex, name: "Codex \"quoted\" · app", worktree: odd)).arguments
        let table = try XCTUnwrap(TOMLValue.parse(try XCTUnwrap(override("permissions.binders.filesystem", in: arguments)))?.table)
        XCTAssertEqual(table[odd], .string("write"), "a quote, a backslash and a space come back as they were")
        let env = try XCTUnwrap(TOMLValue.parse(try XCTUnwrap(override("mcp_servers.binders.env", in: arguments)))?.table)
        XCTAssertEqual(env["BINDERS_AGENT"], .string("Codex \"quoted\" · app"))
        XCTAssertEqual(value(after: "--cd", in: arguments), odd, "argv carries it as it is")
        XCTAssertEqual(CodexLaunch.toml("a\"b\\c\nd\u{1}"), #""a\"b\\c\nd\u0001""#)
        // Every override reads back as Codex reads it, keys with dots inside inline tables only.
        let all = TOMLValue.overrides(arguments)
        XCTAssertEqual(all["mcp_servers.binders.command"], .string(binders))
        XCTAssertEqual(all["mcp_servers.binders.args"], .array([.string("--mcp")]))
        XCTAssertEqual(all["mcp_servers.binders.required"], .bool(true))
        XCTAssertEqual(all["shell_environment_policy.set"]?.table?["ZDOTDIR"], .string(temporary + "/zsh"))
    }

    func testCodexKeepsTheShellProfileOut() throws {
        let arguments = try launch(run(.codex)).arguments
        XCTAssertTrue(zip(arguments, arguments.dropFirst()).contains { $0 == "--disable" && $1 == "shell_snapshot" }, "no snapshot of your ~/.zshrc")
        XCTAssertEqual(override("allow_login_shell", in: arguments), "false", "no login shell, so no ~/.zprofile")
        XCTAssertEqual(override("shell_environment_policy.inherit", in: arguments), #""core""#)
        XCTAssertEqual(override("shell_environment_policy.ignore_default_excludes", in: arguments), "false")
        XCTAssertEqual(override("shell_environment_policy.set", in: arguments), #"{ ZDOTDIR = "\#(temporary)/zsh" }"#, "and no ~/.zshenv either")
    }

    func testCodexServerValuesAreLiteral() throws {
        let arguments = try launch(run(.codex)).arguments
        XCTAssertNil(override("mcp_servers.binders.env_vars", in: arguments), "nothing passed on from its own environment")
        let env = try XCTUnwrap(TOMLValue.parse(try XCTUnwrap(override("mcp_servers.binders.env", in: arguments)))?.table)
        XCTAssertEqual(env, ["BINDERS_TOOLS": .string("board"), "BINDERS_RUN": .string("1"), "BINDERS_CARD": .string(card.uuidString),
                             "BINDERS_AGENT": .string("Codex · app")], "board, which a Binders before this one also confines to the card")
    }

    func testCodexTakesTheThrowawayDataDirOnlyInSelfTests() throws {
        let plain = try launch(run(.codex))
        XCTAssertNil(plain.environment["BINDERS_DATA_DIR"])
        XCTAssertFalse(try XCTUnwrap(override("mcp_servers.binders.env", in: plain.arguments)).contains("BINDERS_DATA_DIR"))
        let test = try launch(run(.codex, throwaway: "/private/tmp/selftest"))
        XCTAssertEqual(test.environment["BINDERS_DATA_DIR"], "/private/tmp/selftest")
        let env = try XCTUnwrap(TOMLValue.parse(try XCTUnwrap(override("mcp_servers.binders.env", in: test.arguments)))?.table)
        XCTAssertEqual(env["BINDERS_DATA_DIR"], .string("/private/tmp/selftest"))
    }

    func testCodexSitesComeWithTheDocumentedProxyKey() throws {
        let sites = run(.codex, domains: ["registry.npmjs.org", " "])
        let on = CodexLaunch.make(sites, sites: true).arguments
        XCTAssertEqual(override("permissions.binders.network", in: on), #"{ enabled = true, domains = { "registry.npmjs.org" = "allow" } }"#)
        XCTAssertEqual(override("features.network_proxy", in: on), "true", "the boolean form OpenAI documents for profiles")
        XCTAssertFalse(on.contains { $0.hasPrefix("features.network_proxy.") }, "never the older table form")
        let off = try launch(sites).arguments
        XCTAssertFalse(off.contains { $0.contains("network") }, "this build: neither, so its commands reach nothing")
        XCTAssertFalse(CodexLaunch.make(run(.codex), sites: true).arguments.contains { $0.contains("network") }, "no sites listed: neither")
    }

    func testEveryCodexKeyIsOneCodexKnows() throws {
        let keys = Set(try CLIAgentTests.fixture("codex-0.162.0-config-keys.txt").split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init))
        let features = Set(try CLIAgentTests.fixture("codex-0.162.0-features.txt").split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init))
        XCTAssertEqual(keys, Set(CodexLaunch.configKeys))
        let arguments = CodexLaunch.make(run(.codex, domains: ["registry.npmjs.org"]), sites: true).arguments
        for (flag, value) in zip(arguments, arguments.dropFirst()) {
            if flag == "-c" {
                let path = String(value.prefix { $0 != "=" }).split(separator: ".").enumerated()
                    .map { index, part in index == 1 && ["permissions", "mcp_servers"].contains(String(value.prefix { $0 != "." })) ? "<name>" : String(part) }
                    .joined(separator: ".")
                XCTAssertTrue(keys.contains(path), path)
            }
            if flag == "--disable" { XCTAssertTrue(features.contains(value), value) }
        }
        XCTAssertTrue(features.isSuperset(of: CodexLaunch.disabledFeatures))
    }

    // MARK: OpenCode

    func testOpenCodeLaunchLine() throws {
        let line = try launch(run(.opencode))
        let worktree = worktree(.opencode)
        XCTAssertEqual(line.arguments, ["run", "--dir", worktree, "--agent", "binders-card-16fd2706", "--format", "json",
                                        "--title", "Binders card 3f2504e04f89", "--model", "anthropic/claude-sonnet-4-5", "--pure"])
        XCTAssertEqual(line.directory, worktree)
        XCTAssertEqual(line.environment["PWD"], worktree, "it takes its folder from PWD, not the process's")
        XCTAssertEqual(line.mode, "edits files in its worktree, no commands")
        XCTAssertNil(line.session)
        XCTAssertTrue(line.files.isEmpty, "its config goes in the environment")
    }

    func testOpenCodeConfigIsExactAndOrdered() throws {
        let text = try XCTUnwrap(try launch(run(.opencode)).environment["OPENCODE_CONFIG_CONTENT"])
        XCTAssertEqual(text, #"{"$schema":"https://opencode.ai/config.json","share":"disabled","default_agent":"binders-card-16fd2706","formatter":false,"lsp":false,"mcp":{"binders":{"type":"local","command":["/Applications/Binders.app/Contents/MacOS/Binders","--mcp"],"environment":{"BINDERS_TOOLS":"board","BINDERS_RUN":"1","BINDERS_CARD":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","BINDERS_AGENT":"OpenCode · app"},"enabled":true}},"agent":{"binders-card-16fd2706":{"description":"Works on one Binders card in its own git worktree.","mode":"primary","steps":150,"permission":{"*":"deny","read":{"*":"allow","*.env":"deny","*.env.*":"deny","*.env.example":"allow"},"glob":"allow","grep":"allow","list":"allow","edit":{"*":"allow","*opencode.json":"deny","*opencode.jsonc":"deny","*.opencode/*":"deny","*.git":"deny"},"todowrite":"allow","bash":"deny","task":"deny","webfetch":"deny","websearch":"deny","skill":"deny","lsp":"deny","question":"deny","plan_enter":"deny","plan_exit":"deny","binders_list_tasks":"allow","binders_get_task":"allow","binders_claim_task":"allow","binders_update_task":"allow","binders_ask_on_task":"allow","binders_comment_task":"allow","binders_release_task":"allow","binders_complete_task":"allow","binders_request_approval":"allow","external_directory":{"*":"deny","/Users/sam/.local/share/opencode/tool-output/*":"deny"},"doom_loop":"ask"}}}}"#)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(text.utf8)), "and it's JSON")
    }

    func testOpenCodePlanModeHasNoEdit() throws {
        let line = try launch(run(.opencode, mode: "plan"))
        let text = try XCTUnwrap(line.environment["OPENCODE_CONFIG_CONTENT"])
        XCTAssertFalse(text.contains(#""edit""#), "\"*\": \"deny\" covers it")
        XCTAssertTrue(text.contains(#""permission":{"*":"deny","read":"#))
        XCTAssertEqual(line.mode, "reads only, no commands")
    }

    func testOpenCodesAgentIsNamedForTheRun() throws {
        let one = try launch(run(.opencode))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(one.environment["OPENCODE_CONFIG_CONTENT"]).utf8)) as? [String: Any])
        XCTAssertEqual(config["default_agent"] as? String, value(after: "--agent", in: one.arguments), "--agent and default_agent agree")
        XCTAssertEqual(Array((config["agent"] as? [String: Any] ?? [:]).keys), [value(after: "--agent", in: one.arguments) ?? ""])
        var other = run(.opencode)
        other.run = UUID(uuidString: "C2D1A6F0-1B2C-4D3E-8F90-123456789ABC")!
        XCTAssertEqual(value(after: "--agent", in: try launch(other).arguments), "binders-card-c2d1a6f0", "no file can define the next run's agent ahead")
        XCTAssertEqual(OpenCodeLaunch.agentName(run: run), "binders-card-16fd2706")
    }

    func testOpenCodeSkipsTheProjectAndPlugins() throws {
        let line = try launch(run(.opencode))
        XCTAssertEqual(line.environment["OPENCODE_DISABLE_PROJECT_CONFIG"], "1", "the repository's own settings, agents and plugins")
        XCTAssertEqual(line.environment["OPENCODE_PURE"], "1")
        XCTAssertTrue(line.arguments.contains("--pure"), "no external plugins, yours included")
        for key in ["OPENCODE_DISABLE_SHARE", "OPENCODE_DISABLE_AUTOUPDATE", "OPENCODE_DISABLE_CLAUDE_CODE", "OPENCODE_DISABLE_LSP_DOWNLOAD", "NO_COLOR"] {
            XCTAssertEqual(line.environment[key], "1", key)
        }
    }

    func testOpenCodeDeniesItsToolOutputFolder() throws {
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(try launch(run(.opencode)).environment["OPENCODE_CONFIG_CONTENT"]).utf8))
                                   as? [String: Any])
        let permission = try XCTUnwrap(((config["agent"] as? [String: Any])?["binders-card-16fd2706"] as? [String: Any])?["permission"] as? [String: Any])
        XCTAssertEqual(permission["external_directory"] as? [String: String],
                       ["*": "deny", "/Users/sam/.local/share/opencode/tool-output/*": "deny"], "that exact glob, or OpenCode allows it")
        XCTAssertEqual(config["formatter"] as? Bool, false)
        XCTAssertEqual(config["lsp"] as? Bool, false)
    }

    func testOpenCodeAllowsOnlyBindersBoardTools() throws {
        let text = try XCTUnwrap(try launch(run(.opencode)).environment["OPENCODE_CONFIG_CONTENT"])
        XCTAssertFalse(text.contains("binders_*"), "exact names: a server of yours named binders.x would match a wildcard")
        XCTAssertFalse(text.contains("binders_create_task"), "a run makes no new cards")
        XCTAssertEqual(OpenCodeLaunch.boardTools.count, 9)
        for tool in OpenCodeLaunch.boardTools { XCTAssertTrue(text.contains(#""\#(tool)":"allow""#), tool) }
    }

    func testOpenCodeConfigCantPullInAFile() throws {
        let name = "x {file:~/.ssh/id_ed25519} {env:OPENAI_API_KEY}"
        let text = try XCTUnwrap(try launch(run(.opencode, name: name)).environment["OPENCODE_CONFIG_CONTENT"])
        XCTAssertFalse(text.contains("{file:"))
        XCTAssertFalse(text.contains("{env:"))
        XCTAssertTrue(text.contains("\\u007bfile:"), "written as an escape, which the JSON parser turns back into a brace")
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let server = try XCTUnwrap((config["mcp"] as? [String: Any])?["binders"] as? [String: Any])
        XCTAssertEqual((server["environment"] as? [String: String])?["BINDERS_AGENT"], name, "the JSON reads it back as it was")
    }

    func testOpenCodeNeedsItsModel() {
        for model in ["", "sonnet", "--yolo", "-anthropic/x"] {
            XCTAssertThrowsError(try launch(run(.opencode, model: model)), model) { error in
                XCTAssertTrue((error as? CLIAgentLaunches.Refusal)?.message.contains("provider/model") == true)
            }
        }
    }

    func testOpenCodeReadsAGENTSOnlyWhenItsThere() throws {
        func instructions(_ agentsFile: Bool) throws -> [String]? {
            let text = try XCTUnwrap(try launch(run(.opencode, agentsFile: agentsFile)).environment["OPENCODE_CONFIG_CONTENT"])
            return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["instructions"] as? [String]
        }
        XCTAssertNil(try instructions(false))
        XCTAssertEqual(try instructions(true), [worktree(.opencode) + "/AGENTS.md"], "the repository's AGENTS.md comes back this way")
    }

    // MARK: GitHub Copilot CLI

    func testCopilotLaunchLine() throws {
        let line = try launch(run(.copilot))
        XCTAssertEqual(line.arguments, ["--no-auto-update", "--output-format=json", "--stream=off", "--no-color", "--no-ask-user",
                                        "--resume=6ba7b810-9dad-11d1-80b4-00c04fd430c8", "--disable-builtin-mcps",
                                        "--additional-mcp-config=@\(logs)/3f2504e0-20261018T120000.mcp.json", "--allow-tool=binders",
                                        "--allow-tool=write", "--deny-tool=shell", "--excluded-tools=task", "--excluded-tools=lsp"])
        XCTAssertFalse(line.arguments.contains { $0.hasPrefix("--deny-tool=write") }, "1.0.10 reads any write deny as a deny of every write")
        XCTAssertEqual(line.directory, worktree(.copilot))
        XCTAssertEqual(line.session, "6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        XCTAssertEqual(line.environment["COPILOT_HOME"], "\(places)/copilot")
        XCTAssertEqual(line.environment["COPILOT_AUTO_UPDATE"], "false")
        XCTAssertEqual(line.lookIn, "cd ~/.binders/worktrees/app-1a2b3c4d/binders-3f2504e04f89-copilot && COPILOT_HOME=~/.binders/copilot copilot --resume=6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        XCTAssertEqual(line.mode, "edits files in its worktree, no commands")
        XCTAssertEqual(try launch(run(.copilot, model: "claude-sonnet-4.5")).arguments.last, "--model=claude-sonnet-4.5", "one element, --flag=value")
    }

    func testCopilotPlanModeHasNoWrite() throws {
        let line = try launch(run(.copilot, mode: "plan"))
        XCTAssertFalse(line.arguments.contains("--allow-tool=write"))
        XCTAssertTrue(line.arguments.contains("--deny-tool=shell"))
        XCTAssertTrue(line.arguments.contains("--excluded-tools=task") && line.arguments.contains("--excluded-tools=lsp"),
                      "no hand-offs to custom agents and no language servers, whose programs start outside every rule")
        XCTAssertFalse(line.arguments.contains { $0.hasPrefix("--deny-tool=write") })
        XCTAssertEqual(line.mode, "reads only, no commands")
    }

    func testCopilotRunFileHasLiteralValues() throws {
        let line = try launch(run(.copilot, throwaway: "/private/tmp/selftest"))
        XCTAssertEqual(Array(line.files.keys), ["\(logs)/3f2504e0-20261018T120000.mcp.json"])
        XCTAssertEqual(line.files.values.first,
                       #"{"mcpServers":{"binders":{"type":"local","command":"/Applications/Binders.app/Contents/MacOS/Binders","args":["--mcp"],"env":{"BINDERS_TOOLS":"board","BINDERS_RUN":"1","BINDERS_CARD":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","BINDERS_AGENT":"Copilot · app","BINDERS_DATA_DIR":"/private/tmp/selftest"},"tools":["*"]}}}"#)
        XCTAssertFalse(line.files.values.first?.contains("$") == true, "nothing for Copilot to expand")
    }

    func testCopilotRefusesADollarInThePathOrTheName() {
        XCTAssertThrowsError(try launch(run(.copilot, name: "Bot $HOME")))
        var run = run(.copilot)
        run.binders = "/Users/sam/$x/Binders"
        XCTAssertThrowsError(try launch(run))
        XCTAssertNoThrow(try launch(self.run(.codex, name: "Bot $HOME")), "Codex's values are literal TOML")
    }

    // MARK: All three

    func testTheEnvironmentIsTheAllowlist() throws {
        let common: Set = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "__CF_USER_TEXT_ENCODING"]
        let own: [CLIAgent: Set<String>] = [
            .codex: [],
            .opencode: ["PWD", "OPENCODE_CONFIG_CONTENT", "OPENCODE_DISABLE_PROJECT_CONFIG", "OPENCODE_PURE", "OPENCODE_DISABLE_SHARE",
                        "OPENCODE_DISABLE_AUTOUPDATE", "OPENCODE_DISABLE_CLAUDE_CODE", "OPENCODE_DISABLE_LSP_DOWNLOAD", "NO_COLOR"],
            .copilot: ["COPILOT_HOME", "COPILOT_AUTO_UPDATE", "NO_COLOR"],
            .antigravity: ["PWD", "NO_COLOR"],
        ]
        for tool in CLIAgent.allCases {
            let environment = try launch(run(tool)).environment
            XCTAssertEqual(Set(environment.keys), common.union(own[tool] ?? []), tool.rawValue)
            XCTAssertEqual(environment["TMPDIR"], temporary + "/", "the run's own temp folder")
            XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/Users/sam/.local/bin:/usr/bin:/bin")
            XCTAssertEqual(environment["LANG"], "en_GB.UTF-8")
            for key in ["BINDERS_TOOLS", "BINDERS_RUN", "BINDERS_CARD", "BINDERS_AGENT", "OPENAI_API_KEY", "GH_TOKEN", "SSH_AUTH_SOCK", "COPILOT_ALLOW_ALL",
                        "OPENCODE_PERMISSION", "XDG_CONFIG_HOME", "CODEX_HOME"] {
                XCTAssertNil(environment[key], "\(tool.rawValue): \(key)")
            }
        }
        XCTAssertEqual(CLIAgentLaunches.environment(base: [:], home: "/h", path: "", temporary: "/t", throwawayData: nil),
                       ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/h", "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8", "TMPDIR": "/t/"])
    }

    func testNoLaunchTurnsTheChecksOff() throws {
        for tool in CLIAgent.allCases {
            for mode in ["acceptEdits", "plan", "bypassPermissions", "", "auto"] {
                for model in ["", "--yolo", "--dangerously-skip-permissions", "gpt-5", "anthropic/claude-sonnet-4-5", "anthropic/--yolo"] {
                    guard let line = try? launch(run(tool, mode: mode, model: model)) else {
                        // Antigravity starts only to edit files: any other mode is refused, never run as something looser.
                        XCTAssertTrue(tool == .opencode || tool == .antigravity && mode != "acceptEdits", "only OpenCode refuses a model: \(tool) \(mode) \(model)")
                        continue
                    }
                    let command = ([tool.program] + line.arguments.map(AgentMCPEntry.quoted)).joined(separator: " ")
                    XCTAssertTrue(AgentCommands.isAllowed(command), "\(tool) \(mode) \(model): \(AgentCommands.refusal(command) ?? "")")
                    for (key, value) in line.environment {
                        XCTAssertTrue(AgentCommands.isAllowed(tool.program + " " + AgentMCPEntry.quoted(value)), "\(tool) \(key)")
                    }
                    for (_, contents) in line.files { XCTAssertTrue(AgentCommands.isAllowed(tool.program + " " + AgentMCPEntry.quoted(contents))) }
                    XCTAssertFalse(line.arguments.contains { $0.hasPrefix("-") && $0.lowercased().contains("yolo") }, "no model argument that's a flag") // the coding tools' own flag, not a name of ours
                    XCTAssertFalse(line.arguments.contains { $0 == "-m" || $0 == "--model" } && model.hasPrefix("-"))
                    // Antigravity's --sandbox turns its sandbox on, which Binders always does; Codex's would set a looser one.
                    for flag in ["--sandbox", "-s", "--share", "--auto", "--add-dir", "--autopilot"] where !(tool == .antigravity && flag == "--sandbox") {
                        XCTAssertFalse(line.arguments.contains { $0 == flag || $0.hasPrefix(flag + "=") }, "\(tool): \(flag)")
                    }
                    XCTAssertFalse(line.arguments.contains { $0.hasPrefix("--allow-all") || $0 == "--yolo" })
                }
            }
        }
    }

    func testEveryLongFlagIsInTheToolsHelp() throws {
        let help: [CLIAgent: String] = [.codex: try CLIAgentTests.fixture("codex-0.162.0-exec-help.txt"),
                                        .opencode: try CLIAgentTests.fixture("opencode-1.18.27-run-help.txt"),
                                        .copilot: try CLIAgentTests.fixture("copilot-1.0.10-help.txt"),
                                        // From Antigravity's documentation and changelog: Binders couldn't run agy --help.
                                        .antigravity: try CLIAgentTests.fixture("agy-1.4.7-documented-flags.txt")]
        for tool in CLIAgent.allCases {
            let text = try XCTUnwrap(help[tool])
            let arguments = try launch(run(tool, model: tool == .opencode ? nil : "a-model")).arguments
            let flags = Set(arguments.filter { $0.hasPrefix("--") }.map { String($0.prefix { $0 != "=" }) })
            XCTAssertFalse(flags.isEmpty)
            for flag in flags {
                let pattern = "(^|[\\s,])" + NSRegularExpression.escapedPattern(for: flag) + "([\\s=\\[,]|$)"
                XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), "\(tool.rawValue): \(flag) isn't in its help")
            }
        }
    }

    func testEveryRunsServerIsBoardOnlyEvenForAnOlderBinders() throws {
        // A Binders before this one (Mac 0.8.0) offers every tool unless BINDERS_TOOLS is exactly "board", and then confines
        // the board to BINDERS_CARD; BINDERS_RUN is this build's, so a server without the card or the name offers nothing.
        let codex = try XCTUnwrap(TOMLValue.parse(try XCTUnwrap(override("mcp_servers.binders.env", in: try launch(run(.codex)).arguments)))?.table)
        let opencode = try XCTUnwrap((((try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(try launch(run(.opencode)).environment["OPENCODE_CONFIG_CONTENT"]).utf8))
            as? [String: Any])?["mcp"] as? [String: Any])?["binders"] as? [String: Any])?["environment"] as? [String: String])
        let copilot = try XCTUnwrap((((try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(try launch(run(.copilot)).files.values.first).utf8))
            as? [String: Any])?["mcpServers"] as? [String: Any])?["binders"] as? [String: Any])?["env"] as? [String: String])
        let claude = ClaudeCodeLaunch.make(card: card, reason: .ready, boardName: "Claude Code · app", wake: ClaudeCodeWake(repository: "/r"), binders: binders,
                                           dataFolder: data, home: home, worktreeExists: false, session: session)
        let claudeConfig = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value(after: "--mcp-config", in: claude.arguments)).utf8)) as? [String: Any])
        let claudeEnv = try XCTUnwrap(((claudeConfig["mcpServers"] as? [String: Any])?["binders"] as? [String: Any])?["env"] as? [String: String])
        XCTAssertEqual(codex["BINDERS_TOOLS"], .string("board"))
        XCTAssertEqual(codex["BINDERS_RUN"], .string("1"))
        for env in [opencode, copilot, claudeEnv] {
            XCTAssertEqual(env["BINDERS_TOOLS"], "board")
            XCTAssertEqual(env["BINDERS_RUN"], "1")
            XCTAssertEqual(env["BINDERS_CARD"], card.uuidString)
            XCTAssertEqual(MCPConfinement.read(env), .card(card))
        }
    }

    func testNothingGoesIntoTheWorktree() throws {
        // But Antigravity's server for the run, which it reads only from the workspace (AntigravityTests).
        for tool in CLIAgent.allCases where tool != .antigravity {
            let line = try launch(run(tool))
            for path in line.files.keys {
                XCTAssertTrue(path.hasPrefix(logs + "/"), path)
                XCTAssertFalse(path.hasPrefix(worktree(tool)), path)
            }
        }
    }

    func testThePromptSaysBindersCommitsAndWhatTheRunCanDo() throws {
        let codex = try launch(run(.codex)).stdin
        XCTAssertTrue(codex.hasPrefix(AgentWake.promptMarker))
        XCTAssertTrue(codex.contains("Card: \(card.uuidString)"))
        XCTAssertTrue(codex.contains("4. Binders commits what you change here on its branch when you stop. Never push."))
        XCTAssertTrue(codex.contains("3. Work only in this folder: a git worktree made for this card.\n"), "Codex edits and runs commands in its sandbox")
        XCTAssertTrue(try launch(run(.codex, mode: "plan")).stdin.contains("made for this card. This run can read its files and run commands, but not change anything."))
        for tool in [CLIAgent.opencode, .copilot] {
            XCTAssertTrue(try launch(run(tool)).stdin.contains("made for this card. This run can read and edit its files, but not run commands."))
            XCTAssertTrue(try launch(run(tool, mode: "plan")).stdin.contains("made for this card. This run can read its files, but not edit them or run commands."))
        }
        XCTAssertTrue(try launch(run(.copilot, reason: .answered)).stdin.contains("The user answered your question or your request for approval."))
        // Woken for your comment: the same words a Claude Code run gets, for each tool.
        for tool in CLIAgent.allCases {
            XCTAssertTrue(try launch(run(tool, reason: .commented)).stdin.contains("The user commented on it: their comment is on its timeline."), "\(tool)")
        }
        XCTAssertFalse(codex.contains("Commit on its branch"), "a CLI run doesn't commit itself")
    }

    func testLookInLinesTakeOnlyIDsInTheirShape() {
        XCTAssertEqual(CodexLaunch.lookIn(thread: "0199A1B2-C3D4-7E5F-8A9B-0C1D2E3F4A5B", worktree: worktree(.codex), home: home),
                       "codex resume 0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b -C ~/.binders/worktrees/app-1a2b3c4d/binders-3f2504e04f89-codex")
        XCTAssertNil(CodexLaunch.lookIn(thread: "x; rm -rf ~", worktree: worktree(.codex), home: home))
        XCTAssertNil(CodexLaunch.lookIn(thread: nil, worktree: worktree(.codex), home: home))
        XCTAssertEqual(OpenCodeLaunch.lookIn(session: "ses_01JABCDEF", worktree: worktree(.opencode), home: home),
                       "opencode ~/.binders/worktrees/app-1a2b3c4d/binders-3f2504e04f89-opencode --session ses_01JABCDEF")
        XCTAssertNil(OpenCodeLaunch.lookIn(session: "ses_x;open .", worktree: worktree(.opencode), home: home))
        XCTAssertEqual(CLIAgentLaunches.pastable("/Users/sam/My Code/x", home: home), "~/'My Code/x'", "quoted where the shell would split it")
        XCTAssertEqual(CLIAgentLaunches.pastable("/Volumes/Work Disk/x", home: home), "'/Volumes/Work Disk/x'")
        XCTAssertEqual(CLIAgentLaunches.card12(card), "3f2504e04f89")
    }
}
