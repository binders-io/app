import AppKit
import Darwin
import Foundation
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Codex, OpenCode, GitHub Copilot CLI and Antigravity as agents Binders starts for a card, with stand-ins for the tools (Binders
    /// itself, `--stub-cli-agent`, behind a two-line script in the throwaway folder), never the real ones: what each is
    /// given, Binders' server as each tool would start it, the worktree Binders makes and commits in without touching your
    /// checkout, what goes on the card when a run finishes, stops or never takes the card, a run that outlives its
    /// dispatcher, the line a run is doing, and what Binders refuses. In a throwaway folder (BINDERS_DATA_DIR) only. A
    /// folder, when given, gets a drawing of each one's settings.
    @MainActor
    static func cliAgentsSelfTest(drawingTo directory: URL? = nil) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards, agents and git repositories")
            return 1
        }
        let manager = FileManager.default
        let data = AppPaths.support
        let places = AgentPlaces.root
        guard !manager.fileExists(atPath: places.path) else {
            print("ERROR: \(places.path) is there already; this test makes it and takes it away again")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let board = controller.board
        var dispatcher = controller.agents
        let registry = AgentRegistry.shared
        let write = MCPServer.writeInApp(controller: controller)
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func wait(_ seconds: Double = 30, until done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !done() { try? await Task.sleep(for: .milliseconds(50)) }
        }
        func events(_ id: UUID) -> [TaskEvent] { board.timeline(id) }
        func notes(_ id: UUID) -> [String] { events(id).filter { $0.kind == .comment && $0.author == "Binders" }.map(\.text) }
        func lastMove(_ id: UUID) -> TaskEvent? { events(id).last { $0.kind == .moved } }
        Store.shared.insert(BinderRecord(name: "Code", colorIndex: 4))
        let binder = Store.shared.binders(includeArchived: true).first { $0.name == "Code" }?.id

        // The secrets and switches that must never reach a run, in Binders' own environment.
        let planted = ["OPENAI_API_KEY": "sk-not-for-runs", "COPILOT_ALLOW_ALL": "false", "OPENCODE_PERMISSION": #"{"*":"allow"}"#,
                       "BINDERS_SELFTEST_SECRET": "1"]
        for (key, value) in planted { setenv(key, value, 1) }
        defer { for key in planted.keys { unsetenv(key) } }

        // A real repository, with hooks planted where git would run them, in .git/hooks and through its own core.hooksPath.
        let repo = data.appendingPathComponent("repo", isDirectory: true)
        let hookMark = data.appendingPathComponent("hook-ran.txt")
        @discardableResult
        func git(_ arguments: [String], in folder: URL? = nil) async -> AgentGit.Result {
            await AgentGit.run((folder.map { ["-C", $0.path] } ?? []) + arguments, path: "", temporary: nil, timeout: 60)
        }
        try? manager.createDirectory(at: repo, withIntermediateDirectories: true)
        await git(["init", "-q", "-b", "main"], in: repo)
        await git(["config", "user.name", "Sam"], in: repo)
        await git(["config", "user.email", "sam@example.invalid"], in: repo)
        try? "# Repo\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for number in 1...30 { try? "file \(number)\n".write(to: repo.appendingPathComponent("file\(number).txt"), atomically: true, encoding: .utf8) }
        await git(["add", "-A"], in: repo)
        await git(["commit", "-q", "-m", "First"], in: repo)
        let hook = "#!/bin/sh\ntouch \"\(hookMark.path)\"\n"
        let hooks2 = data.appendingPathComponent("hooks2", isDirectory: true)
        try? manager.createDirectory(at: hooks2, withIntermediateDirectories: true)
        for folder in [repo.appendingPathComponent(".git/hooks"), hooks2] {
            for name in ["post-checkout", "post-commit", "pre-commit"] {
                let file = folder.appendingPathComponent(name)
                try? hook.write(to: file, atomically: true, encoding: .utf8)
                try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        await git(["config", "core.hooksPath", hooks2.path], in: repo)
        func checkout() async -> String {
            var parts: [String] = []
            for arguments in [["rev-parse", "HEAD"], ["symbolic-ref", "HEAD"], ["status", "--porcelain"], ["ls-files", "-s"]] {
                parts.append(await git(arguments, in: repo).output)
            }
            parts.append(((try? manager.contentsOfDirectory(atPath: repo.path)) ?? []).filter { $0 != ".git" }.sorted().joined(separator: ","))
            return parts.joined(separator: "\n--\n")
        }
        let before = await checkout()

        // The stand-ins, and what each prints.
        let bin = data.appendingPathComponent("bin", isDirectory: true)
        let stub = data.appendingPathComponent("stub", isDirectory: true)
        try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try? manager.createDirectory(at: stub.appendingPathComponent("canned"), withIntermediateDirectories: true)
        func stand(in tool: CLIAgent, named name: String? = nil, folder: URL? = nil) -> URL {
            let place = folder ?? bin
            try? manager.createDirectory(at: place, withIntermediateDirectories: true)
            let file = place.appendingPathComponent(name ?? tool.program)
            try? "#!/bin/sh\nexec \(AgentMCPEntry.quoted(MCPHost.executable)) --stub-cli-agent \(tool.rawValue) \"$@\"\n"
                .write(to: file, atomically: true, encoding: .utf8)
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file
        }
        func set(_ tool: CLIAgent, _ name: String, _ value: String?) {
            let file = stub.appendingPathComponent("\(tool.rawValue)-\(name).txt")
            if let value { try? value.write(to: file, atomically: true, encoding: .utf8) } else { try? manager.removeItem(at: file) }
        }
        func stubbed(_ tool: CLIAgent, _ name: String) -> String {
            (try? String(contentsOf: stub.appendingPathComponent("\(tool.rawValue)-\(name)"), encoding: .utf8)) ?? ""
        }
        func clearRecordings(_ tool: CLIAgent) {
            for name in ["argv.bin", "env.bin", "cwd.txt", "stdin.txt", "mcp.jsonl", "signal.txt", "mcp-config.json"] {
                try? manager.removeItem(at: stub.appendingPathComponent("\(tool.rawValue)-\(name)"))
            }
        }
        func can(_ tool: CLIAgent, _ mode: String, _ lines: [String]) {
            try? (lines.joined(separator: "\n") + "\n").write(to: stub.appendingPathComponent("canned/\(tool.rawValue)-\(mode).jsonl"), atomically: true, encoding: .utf8)
        }
        let thread = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        let codexDone = [#"{"type":"thread.started","thread_id":"\#(thread)"}"#, #"{"type":"turn.started"}"#,
                         #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Fixed the footer link."}}"#,
                         #"{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}"#]
        can(.codex, "finish", codexDone)
        can(.codex, "edit", codexDone)
        can(.codex, "pointer", codexDone)
        can(.codex, "nested", codexDone)
        can(.codex, "delete", codexDone)
        can(.codex, "fail", [codexDone[0], codexDone[1], #"{"type":"turn.failed","error":{"message":"stream disconnected before completion"}}"#])
        can(.codex, "doing", [codexDone[0], #"{"type":"item.updated","item":{"id":"item_0","type":"todo_list","items":[{"text":"Read the card","completed":true},{"text":"Running the tests","completed":false}]}}"#])
        func opencode(_ type: String, _ part: String) -> String { #"{"type":"\#(type)","timestamp":1,"sessionID":"ses_01JABCDEF","part":\#(part)}"# }
        can(.opencode, "finish", [opencode("tool_use", #"{"id":"p1","type":"tool","tool":"binders_get_task","state":{"status":"completed","input":{},"output":"{}"}}"#),
                                  opencode("step_finish", #"{"id":"p2","type":"step-finish","reason":"tool-calls","cost":0.01}"#),
                                  opencode("text", #"{"id":"p3","type":"text","text":"Wrote the release notes."}"#),
                                  opencode("step_finish", #"{"id":"p4","type":"step-finish","reason":"stop","cost":0.03}"#)])
        can(.opencode, "unfinished", [opencode("tool_use", #"{"id":"p1","type":"tool","tool":"binders_claim_task","state":{"status":"completed","input":{},"output":"{}"}}"#),
                                      opencode("text", #"{"id":"p2","type":"text","text":"I got halfway through the notes."}"#),
                                      opencode("step_finish", #"{"id":"p3","type":"step-finish","reason":"stop","cost":0.02}"#)])
        func copilot(_ type: String, _ data: String) -> String { #"{"id":"e","timestamp":"2026-10-18T12:00:00.000Z","parentId":null,"type":"\#(type)","data":\#(data)}"# }
        let copilotResult = #"{"type":"result","timestamp":"2026-10-18T12:01:00.000Z","sessionId":"@SESSION@","exitCode":0,"usage":{"premiumRequests":2,"totalApiDurationMs":1,"sessionDurationMs":2,"codeChanges":{"linesAdded":0,"linesRemoved":0,"filesModified":[]}}}"#
        can(.copilot, "finish", [copilot("assistant.turn_start", #"{"turnId":"t1"}"#),
                                 copilot("tool.execution_start", #"{"toolCallId":"c1","toolName":"binders-get_task","arguments":{},"mcpServerName":"binders","mcpToolName":"get_task"}"#),
                                 copilot("assistant.message", #"{"content":"Checked the links.","toolRequests":[]}"#), copilotResult])
        can(.copilot, "unfinished", [copilot("assistant.turn_start", #"{"turnId":"t1"}"#),
                                     copilot("tool.execution_start", #"{"toolCallId":"c1","toolName":"binders-claim_task","arguments":{},"mcpServerName":"binders","mcpToolName":"claim_task"}"#)])
        // Antigravity's stream-json, in the shape its documentation shows.
        let conversation = "c3b66b04-872b-4fbe-a3a4-058a026ef20a"
        func agy(_ event: String, _ body: String) -> String { #"{"event":"\#(event)","conversation_id":"\#(conversation)","\#(event)":\#(body)}"# }
        let agyDone = [agy("init", #"{"cwd":"/w","tools":["run_command","write_to_file"],"permission_mode":"request-review"}"#),
                       agy("step_update", #"{"conversation_id":"\#(conversation)","step_index":1,"state":"DONE","step_type":"tool","tool_name":"mcp_binders_get_task","tool_info":{"name":"mcp_binders_get_task","parameters":{}}}"#),
                       agy("step_update", #"{"conversation_id":"\#(conversation)","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"Updated the changelog."}"#),
                       agy("result", #"{"conversation_id":"\#(conversation)","status":"SUCCESS","response":"Updated the changelog.","num_turns":1}"#)]
        can(.antigravity, "finish", agyDone)
        can(.antigravity, "plant-hooks", agyDone)
        can(.antigravity, "signin", [])
        // Your Antigravity settings, as a run needs them: Binders' tools allowed, and a command, which runs in its sandbox.
        let agySettings = AntigravityFiles.settings
        func settle(_ text: String?) {
            try? manager.createDirectory(at: agySettings.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let text { try? text.write(to: agySettings, atomically: true, encoding: .utf8) } else { try? manager.removeItem(at: agySettings) }
        }
        let agyAllowed = #"{"toolPermission":"request-review","permissions":{"allow":["mcp(binders/*)","command(git status)"]}}"#
        settle(agyAllowed)

        // The agents, each with its stand-in as its program.
        let repoPath = repo.path
        func agent(_ tool: CLIAgent, name: String? = nil, model: String? = nil, repository: String? = nil) -> AgentProfile {
            AgentProfile(name: name ?? "\(tool.shortName) · repo",
                         wake: .cliAgent(CLIAgentWake(tool: tool, repository: repository ?? repoPath, model: model ?? (tool == .opencode ? "anthropic/claude-sonnet-4-5" : nil),
                                                      executable: stand(in: tool).path)),
                         preset: tool.rawValue, wakesPerHour: 60)
        }
        let codex = agent(.codex), opencodeAgent = agent(.opencode), copilotAgent = agent(.copilot), antigravityAgent = agent(.antigravity)
        let agentsOf: [CLIAgent: AgentProfile] = [.codex: codex, .opencode: opencodeAgent, .copilot: copilotAgent, .antigravity: antigravityAgent]

        // 1. Saving.
        let echo = AgentProfile(name: "Echo", wake: .command(command: "true", folder: data.path))
        check(registry.upsert(echo) == nil, "an agent of agents.json is saved")
        let agentsJSON = data.appendingPathComponent("agents.json"), agentsCLI = data.appendingPathComponent("agents-cli.json")
        let mainBefore = try? Data(contentsOf: agentsJSON)
        var wrongProgram = codex
        wrongProgram.id = UUID()
        wrongProgram.name = "Codex · wrong"
        wrongProgram.wake = .cliAgent(CLIAgentWake(tool: .codex, repository: repoPath, executable: stand(in: .codex, named: "not-codex").path))
        check(registry.upsert(wrongProgram)?.contains("must be the codex program itself") == true, "a CLI agent runs its own program, nothing in its place")
        var checksOff = codex
        checksOff.id = UUID()
        checksOff.name = "Codex · checks off"
        // Codex's own flag for its checks off, which Binders refuses: a third-party spelling, not a name of ours.
        checksOff.wake = .cliAgent(CLIAgentWake(tool: .codex, repository: repoPath, model: "--yolo", executable: stand(in: .codex).path))
        check(registry.upsert(checksOff) == AgentCommands.message("--yolo"), "nor a model that turns its checks off: \(registry.upsert(checksOff) ?? "saved")")
        var noModel = opencodeAgent
        noModel.id = UUID()
        noModel.name = "OpenCode · bare"
        noModel.wake = .cliAgent(CLIAgentWake(tool: .opencode, repository: repoPath, executable: stand(in: .opencode).path))
        check(registry.upsert(noModel)?.contains("provider/model") == true, "OpenCode needs its model")
        var dollar = copilotAgent
        dollar.id = UUID()
        dollar.name = "Copilot $HOME"
        check(registry.upsert(dollar)?.contains("can't have $ in it") == true, "a Copilot agent's name has no $")
        var notRepo = codex
        notRepo.id = UUID()
        notRepo.name = "Codex · nowhere"
        notRepo.wake = .cliAgent(CLIAgentWake(tool: .codex, repository: data.appendingPathComponent("bin").path, executable: stand(in: .codex).path))
        check(registry.upsert(notRepo)?.hasPrefix("Choose a folder with a git repository in it: Codex works there") == true, "its folder holds a repository")
        // Check skips the repository (it says so itself), never the program: one set outside Binders that isn't claude.
        let notClaude = AgentProfile(name: "Claude Code · nowhere", wake: .claudeCode(ClaudeCodeWake(repository: data.appendingPathComponent("bin").path,
                                                                                                      executable: "/bin/echo")), preset: "claude-code")
        check(registry.problem(with: notClaude, checkingRepository: false)?.hasPrefix("The program for Claude Code must be the claude program itself") == true
              && registry.problem(with: notClaude)?.hasPrefix("Choose a folder") == true,
              "Check runs no program in claude's place, in a folder that isn't a repository too: \(registry.problem(with: notClaude, checkingRepository: false) ?? "none")")
        var readsOnly = antigravityAgent
        readsOnly.id = UUID()
        readsOnly.name = "Antigravity · reads"
        readsOnly.wake = .cliAgent(CLIAgentWake(tool: .antigravity, repository: repoPath, permissionMode: "plan", executable: stand(in: .antigravity).path))
        check(registry.upsert(readsOnly)?.hasPrefix("Antigravity can't be held to reading only") == true, "an Antigravity agent can't be set to read only")
        for agent in [codex, opencodeAgent, copilotAgent, antigravityAgent] {
            check(registry.upsert(agent) == nil, "\(agent.name) is saved: \(registry.problem(with: agent) ?? "")")
        }
        check((try? Data(contentsOf: agentsJSON)) == mainBefore, "agents.json is as it was, byte for byte")
        let cliFile = (try? Data(contentsOf: agentsCLI)).flatMap { try? AgentFile.decode($0).file }
        check(Set(cliFile?.agents.map(\.name) ?? []) == Set(["Codex · repo", "OpenCode · repo", "Copilot · repo", "Antigravity · repo"]), "and the four are in agents-cli.json")

        // 2. Held at load: a command saved before Binders refused it.
        let oldCommand = AgentProfile(name: "Old Copilot", wake: .command(command: "cd \(AgentMCPEntry.quoted(data.path)) && copilot -p x --allow-all-tools",
                                                                          folder: data.path), wakesPerHour: 30)
        registry.saveAsBefore(oldCommand)
        registry.load()
        check(registry.held[oldCommand.id] == "Binders won't run it: --allow-all-tools turns copilot's checks off. Change it in Settings → Agents.",
              "a command saved with --allow-all-tools is held, named by its program, not the cd before it: \(registry.held[oldCommand.id] ?? "not held")")
        func listed() async -> [[String: Any]] {
            ((try? JSONSerialization.jsonObject(with: Data(await call("list_agents", [:], as: .you).text.utf8))) as? [String: Any])?["agents"] as? [[String: Any]] ?? []
        }
        check(!(await listed()).contains { $0["name"] as? String == oldCommand.name }, "list_agents doesn't offer your iPhone a held agent")
        // A CLI agent held because an agent of agents.json goes by its name: the iPhone hears of that one alone.
        let clashCommand = AgentProfile(name: "Clash", wake: .command(command: "true", folder: data.path))
        var clashCLI = codex
        clashCLI.id = UUID()
        clashCLI.name = "Clash"
        registry.saveAsBefore(clashCommand)
        registry.saveAsBefore(clashCLI)
        registry.load()
        let clashes = (await listed()).filter { $0["name"] as? String == "Clash" }
        check(registry.held[clashCLI.id] != nil && clashes.count == 1 && clashes.first?["wakes"] as? String == "command",
              "two agents by one name: only the one Binders wakes is listed: \(clashes.map { $0["wakes"] as? String ?? "" })")
        registry.remove(clashCommand.id)
        registry.remove(clashCLI.id)
        let heldCard = board.create(title: "Try the old one", binderID: binder, by: .you)
        board.give(heldCard, to: oldCommand.name, by: .you)
        try? await Task.sleep(for: .milliseconds(300))
        check(!events(heldCard.id).contains { $0.kind == .woke } && !dispatcher.isWorking(on: heldCard.id), "and a card for it starts nothing")
        registry.remove(oldCommand.id)

        /// A run for a new card: the card made in Backlog, given to the agent, and the run waited for. `during` acts while
        /// the stand-in works. Nil when the run never started.
        func run(_ agent: AgentProfile, mode: String, sleep: Double = 1.5, exit: Int32 = 0, stderr: String? = nil, title: String,
                 card existing: TaskCard? = nil, during: (UUID) async -> Void = { _ in }) async -> UUID {
            guard case .cliAgent(let wake) = agent.wake else { return UUID() }
            let tool = wake.tool
            set(tool, "mode", mode)
            set(tool, "sleep", String(sleep))
            set(tool, "exit", String(exit))
            set(tool, "stderr", stderr)
            clearRecordings(tool)
            let card = existing ?? board.create(title: title, binderID: binder, by: .you)
            board.give(card, to: agent.name, by: .you)
            await wait(20) { !stubbed(tool, "cwd.txt").isEmpty || !dispatcher.isWorking(on: card.id) }
            await during(card.id)
            await wait(60) { !dispatcher.isWorking(on: card.id) }
            return card.id
        }
        /// The run's record, while it goes.
        func record(of id: UUID) -> CLIRunRecord? {
            guard let card = board.card(id), let log = AgentDoing.runLog(links: card.links, card: id, logs: AgentPlaces.logs.path) else { return nil }
            return (try? Data(contentsOf: CLIRuns.running(String(log.dropLast(".jsonl".count))))).flatMap(CLIRunRecord.decode)
        }

        // 3 to 7. The start, the board tools, the worktree, the receipt and a finished run, for each tool.
        var worktrees: [CLIAgent: String] = [:]
        for tool in CLIAgent.allCases {
            guard let agent = agentsOf[tool], case .cliAgent(var wake) = agent.wake else { continue }
            wake.executable = wake.executable.map { ($0 as NSString).expandingTildeInPath }
            var seen: CLIRunRecord?
            var temporaryWas: (path: String, mode: Int?)?
            let actor = BoardActor(name: agent.name, kind: .agent)
            let id = await run(agent, mode: "finish", sleep: 2.5, title: "Tidy the \(tool.rawValue) docs") { id in
                seen = record(of: id)
                let environment = Dictionary(uniqueKeysWithValues: stubbed(tool, "env.bin").split(separator: "\0").compactMap { pair -> (String, String)? in
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    return parts.count == 2 ? (parts[0], parts[1]) : nil
                })
                let temporary = environment["TMPDIR"] ?? ""
                temporaryWas = (temporary, (try? manager.attributesOfItem(atPath: temporary))?[.posixPermissions] as? Int)
                // As the run would: it takes the card and finishes it.
                if let card = board.card(id) { try? board.claim(card, by: actor) }
                if let card = board.card(id) { try? board.complete(card, summary: "Done with the \(tool.rawValue) docs.", by: actor) }
            }
            let card = board.card(id)
            let argv = stubbed(tool, "argv.bin").split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard let seen else {
                check(false, "\(tool.rawValue): the run started and left its record: \(dispatcher.outcomes[id]?.message ?? "no outcome")")
                continue
            }
            let inputs = AgentDispatcher.cliRun(card: id, run: seen.run, session: seen.session.flatMap(UUID.init(uuidString:)) ?? UUID(), reason: .ready,
                                                agent: agent, wake: wake, worktree: seen.worktree, repository: seen.worktreeRecord?.repository, stem: seen.stem,
                                                path: "", agentsFile: false, team: AppSettings.shared.teamFolderPath)
            let expected = try? CLIAgentLaunches.make(inputs)
            check(argv == expected?.arguments, "\(tool.rawValue): the stand-in got exactly the arguments Binders worked out, element by element")
            check(AgentPlaces.real(stubbed(tool, "cwd.txt")) == AgentPlaces.real(seen.worktree),
                  "\(tool.rawValue): it started in the card's worktree: \(stubbed(tool, "cwd.txt"))")
            var stdin = stubbed(tool, "stdin.txt")
            if tool == .antigravity {
                // One stream-json message, on one line.
                let message = (try? JSONSerialization.jsonObject(with: Data(stdin.utf8))) as? [String: Any]
                check(message?["event"] as? String == "user" && stdin.filter { $0 == "\n" }.count == 1, "Antigravity: its prompt is one stream-json message on standard input")
                stdin = (message?["message"] as? [String: Any])?["content"] as? String ?? ""
            }
            let reach = AgentRunPrompt.reach(tool, editsFiles: true)
            check(stdin.hasPrefix(AgentWake.promptMarker) && stdin.contains("Card: \(id.uuidString)") && stdin.contains("Binders commits what you change")
                  && (reach.map(stdin.contains) ?? stdin.contains("made for this card.\n")),
                  "\(tool.rawValue): its prompt, on standard input, has the card's id, says Binders commits, and what the run can do")
            let environment = Dictionary(uniqueKeysWithValues: stubbed(tool, "env.bin").split(separator: "\0").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            })
            let sh: Set = ["PWD", "SHLVL", "_", "OLDPWD"]
            let exact = expected.map { launch in launch.environment.allSatisfy { environment[$0.key] == $0.value }
                && Set(environment.keys).subtracting(launch.environment.keys).isSubset(of: sh) } ?? false
            check(exact && planted.keys.allSatisfy { environment[$0] == nil } && environment["BINDERS_TOOLS"] == nil,
                  "\(tool.rawValue): its environment is the allowlist, with none of Binders' own secrets: \(Set(environment.keys).subtracting(expected?.environment.keys.map { $0 } ?? []).sorted())")
            check(temporaryWas.map { $0.path.hasPrefix(AgentPlaces.temporary.path + "/") && $0.mode == 0o700 } == true,
                  "\(tool.rawValue): its TMPDIR is a 0700 folder of its own under \(AgentPlaces.temporary.lastPathComponent): \(temporaryWas.map { "\($0.path) \(String($0.mode ?? 0, radix: 8))" } ?? "")")
            // What each tool got, checked against the card, the agent and the places themselves, not against cliRun: Binders'
            // server for this card as this agent, in the throwaway folder, and each tool's own limits.
            func server(_ values: [String: String]) -> Bool {
                values["BINDERS_CARD"] == id.uuidString && values["BINDERS_AGENT"] == agent.name && values["BINDERS_TOOLS"] == "board"
                    && values["BINDERS_RUN"] == "1" && values["BINDERS_DATA_DIR"] == data.path
            }
            let home = NSHomeDirectory()
            var runTemporary = environment["TMPDIR"] ?? ""
            while runTemporary.count > 1, runTemporary.hasSuffix("/") { runTemporary.removeLast() }
            check(environment["HOME"] == home && runTemporary == CLIRuns.temporary(seen.stem).path, "\(tool.rawValue): its HOME is yours and its TMPDIR its own: \(runTemporary)")
            switch tool {
            case .opencode:
                let config = environment["OPENCODE_CONFIG_CONTENT"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let agentName = argv.firstIndex(of: "--agent").map { argv[$0 + 1] }
                check(environment["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1" && environment["OPENCODE_PURE"] == "1" && argv.contains("--pure")
                      && config?["default_agent"] as? String == agentName, "OpenCode: no project config, no plugins, and its run agent is the default")
                let entry = ((config?["mcp"] as? [String: Any])?["binders"] as? [String: Any])?["environment"] as? [String: String] ?? [:]
                let permission = ((config?["agent"] as? [String: Any])?[agentName ?? ""] as? [String: Any])?["permission"] as? [String: Any]
                check(server(entry) && argv.firstIndex(of: "--dir").map { argv[$0 + 1] } == seen.worktree && environment["PWD"] == seen.worktree
                      && (permission?["external_directory"] as? [String: String])?["*"] == "deny" && permission?["bash"] as? String == "deny",
                      "OpenCode: in its worktree, denied the rest and the shell, with Binders' server for this card: \(entry)")
            case .copilot:
                let file = argv.first { $0.hasPrefix("--additional-mcp-config=@") }.map { String($0.dropFirst("--additional-mcp-config=@".count)) } ?? ""
                let mode = (try? manager.attributesOfItem(atPath: file))?[.posixPermissions] as? Int
                let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
                check(environment["COPILOT_HOME"] == AgentPlaces.copilotHome.path && file.hasPrefix(AgentPlaces.logs.path + "/") && mode == 0o600
                      && text.contains(#""BINDERS_CARD":"\#(id.uuidString)""#) && !text.contains("$"),
                      "Copilot: its own settings folder, and its run file in the run folder, 0600, with literal values")
                let entry = ((((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["mcpServers"] as? [String: Any])?["binders"]
                             as? [String: Any])?["env"] as? [String: String] ?? [:]
                check(server(entry) && argv.contains("--allow-tool=write") && argv.contains("--deny-tool=shell") && !argv.contains { $0.hasPrefix("--deny-tool=write") }
                      && argv.contains("--excluded-tools=task") && argv.contains("--excluded-tools=lsp"),
                      "Copilot: it may write in its worktree (no write deny, which would deny them all), no shell, no hand-offs or language servers, and Binders' server for this card")
            case .antigravity:
                let config = (try? JSONSerialization.jsonObject(with: Data(stubbed(tool, "mcp-config.json").utf8))) as? [String: Any]
                let servers = config?["mcpServers"] as? [String: Any] ?? [:]
                let entry = (servers["binders"] as? [String: Any])?["env"] as? [String: String] ?? [:]
                check(server(entry) && servers.count == 1 && argv.contains("--sandbox") && argv.firstIndex(of: "--mode").map({ argv[$0 + 1] }) == "accept-edits"
                      && !argv.contains { $0.contains("dangerously") || $0 == "-p" || $0 == "--print" || $0.contains(id.uuidString) },
                      "Antigravity: its sandbox on, edits only, no prompt in its arguments, and Binders' server for this card alone in .agents/mcp_config.json: \(entry)")
                let tree = await git(["ls-tree", "-r", "--name-only", AgentWorktree.branch(card: id, tool: tool)], in: repo).output
                check(!manager.fileExists(atPath: AntigravityLaunch.mcpConfigPath(worktree: seen.worktree))
                      && !manager.fileExists(atPath: seen.worktree + "/" + AntigravityLaunch.workspaceFolder) && !tree.contains(".agents/"),
                      "Antigravity: the worktree's mcp_config.json is gone after the run, and never committed")
            case .codex:
                let overrides = TOMLValue.overrides(argv)
                let profile = overrides["permissions.binders.filesystem"]?.table ?? [:]
                func access(_ path: String) -> String? { profile[path]?.string }
                let denied = [data.path, AgentPlaces.logs.path, places.path, AgentPlaces.real(NSTemporaryDirectory()), home + "/.ssh", home + "/.codex",
                              home + "/.claude", home + "/.config/gh", AgentPlaces.real(repoPath) + "/.claude/worktrees"]
                check(denied.allSatisfy { access($0) == "deny" } && access(home + "/.codex/packages") == "read" && access(seen.worktree) == "write"
                      && access(runTemporary) == "write" && overrides["default_permissions"]?.string == "binders",
                      "Codex: its profile denies Binders' data, logs and folders, your keys, ~/.codex but its packaged tools, ~/.claude and Claude Code's worktrees, and opens its own worktree and TMPDIR: \(denied.filter { access($0) != "deny" })")
                let entry = (overrides["mcp_servers.binders.env"]?.table ?? [:]).compactMapValues(\.string)
                check(server(entry) && overrides["mcp_servers.binders.required"]?.bool == true && argv.contains("hooks"),
                      "Codex: Binders' server is required and for this card, and hooks are off: \(entry)")
            }
            // 4. The board tools, as the tool would start Binders' server.
            let replies = stubbed(tool, "mcp.jsonl").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            func reply(_ number: Int) -> [String: Any]? { replies.first { ($0["id"] as? Int) == number }?["result"] as? [String: Any] }
            let listed = Set(((reply(2)?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
            let other = ((reply(3)?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            let own = ((reply(4)?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            check(listed == MCPServer.boardTools.subtracting(["create_task", PullRequests.tool]), "\(tool.rawValue): Binders' server offers the board's tools for one card: \(listed.sorted())")
            check(reply(3)?["isError"] as? Bool == true && other.contains("This run works on card \(id.uuidString) only"), "\(tool.rawValue): another card is refused: \(other)")
            check(reply(4)?["isError"] as? Bool == false && own.contains(id.uuidString), "\(tool.rawValue): its own card it reads")
            // 5. The worktree, one per card and tool, beside the repository's other worktrees in Binders' folder.
            let expectedPath = AgentWorktree.path(root: places.path, repository: AgentPlaces.real(repoPath), card: id, tool: tool)
            worktrees[tool] = seen.worktree
            check(seen.worktree == expectedPath && manager.fileExists(atPath: expectedPath) && expectedPath.contains("/worktrees/repo-")
                  && expectedPath.hasSuffix("binders-\(CLIAgentLaunches.card12(id))-\(tool.rawValue)"), "\(tool.rawValue): its worktree is \(expectedPath)")
            // 6. The receipt.
            let receipt = events(id).last { $0.kind == .woke }?.text ?? ""
            check(receipt.hasPrefix("Started \(tool.name) in \(AgentWorktrees.display(seen.worktree)) (\(seen.mode)") && receipt.contains("made ready for it")
                  && receipt.contains(AgentWorktree.branch(card: id, tool: tool)), "\(tool.rawValue): the receipt names it, the worktree, the mode and why: \(receipt)")
            if tool == .copilot {
                let resume = argv.first { $0.hasPrefix("--resume=") } ?? "--resume=?"
                check(receipt.contains(resume) && receipt.contains("with your own answers to Copilot's prompts rather than the run's limits"),
                      "Copilot: the receipt has how to look in, with its session and what looking in changes")
            }
            // 7. Finished: in Review, its last words once, how it went, and the end line.
            let words = ["codex": "Fixed the footer link.", "opencode": "Wrote the release notes.", "copilot": "Checked the links.",
                         "antigravity": "Updated the changelog."][tool.rawValue] ?? ""
            let said = events(id).filter { $0.kind == .progress && $0.author == agent.name && $0.text == words }
            check(card?.column == .review && said.count == 1, "\(tool.rawValue): finished, the card is in Review, with what it said last once: \(said.count)")
            let outcome = dispatcher.outcomes[id]?.message ?? ""
            let costs = ["codex": "Finished", "opencode": "Finished, $0.04, 2 turns", "copilot": "Finished, 2 premium requests",
                         "antigravity": "Finished"][tool.rawValue] ?? ""
            check(outcome == costs, "\(tool.rawValue): how it went: \(outcome)")
            let end = notes(id).last ?? ""
            switch tool {
            case .codex:
                check(end.contains("To look in, with your own Codex settings: codex resume \(thread) -C \(AgentWorktrees.display(seen.worktree))"),
                      "Codex: the end line has the command that resumes its session: \(end)")
            case .opencode:
                check(end.contains("To look in, with your own OpenCode settings, whose build agent runs commands without asking: opencode \(AgentWorktrees.display(seen.worktree)) --session ses_01JABCDEF"),
                      "OpenCode: the end line has the command that resumes its session: \(end)")
            case .copilot:
                check(end.hasPrefix("GitHub Copilot CLI changed no files."), "Copilot: the end line: \(end)")
            case .antigravity:
                check(end == "Antigravity changed no files. To look in, with your own Antigravity settings: cd \(AgentWorktrees.display(seen.worktree)) && agy --conversation \(conversation)",
                      "Antigravity: the end line has the command that carries on its conversation: \(end)")
            }
        }
        check(await checkout() == before, "your checkout's HEAD, branch, status, index and files are as they were")
        check(!manager.fileExists(atPath: hookMark.path), "and none of its hooks ran")
        check(Set(worktrees.values).count == CLIAgent.allCases.count, "one worktree per tool")

        // 4, the rest: a run's server that didn't get its card or its name offers nothing.
        for environment in [["BINDERS_TOOLS": "board", "BINDERS_RUN": "1", "BINDERS_AGENT": "Codex · repo"],
                            ["BINDERS_TOOLS": "board", "BINDERS_RUN": "1", "BINDERS_CARD": "not-a-card", "BINDERS_AGENT": "Codex · repo"],
                            ["BINDERS_TOOLS": "card", "BINDERS_AGENT": "Codex · repo"]] {
            let replies = await mcpReplies(environment.merging(["BINDERS_DATA_DIR": data.path, "PATH": "/usr/bin:/bin"]) { a, _ in a })
            let tools = (((replies.first { ($0["id"] as? Int) == 2 })?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? [[:]]
            let refused = (replies.first { ($0["id"] as? Int) == 3 })?["error"] != nil
            check(tools.isEmpty && refused, "Binders --mcp as a run (\(environment["BINDERS_RUN"] == nil ? "BINDERS_TOOLS=card" : "BINDERS_RUN")) with \(environment["BINDERS_CARD"] ?? "no card") offers no tools and refuses a call")
        }
        // An agent's own server, BINDERS_TOOLS=board without BINDERS_RUN, as before: the board's tools.
        let own = await mcpReplies(["BINDERS_TOOLS": "board", "BINDERS_AGENT": "Codex · repo", "BINDERS_DATA_DIR": data.path, "PATH": "/usr/bin:/bin"])
        let ownTools = Set(((((own.first { ($0["id"] as? Int) == 2 })?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
        check(ownTools == MCPServer.boardTools.subtracting([PullRequests.tool]).union(AgentChatTools.all), "an agent's own server still offers the board's tools, and its chats': \(ownTools.sorted())")

        // 8. Blocked, with why.
        let halfway = await run(opencodeAgent, mode: "unfinished", title: "Write the notes") { id in
            if let card = board.card(id) { try? board.claim(card, by: BoardActor(name: opencodeAgent.name, kind: .agent)) }
        }
        check(board.card(halfway)?.column == .blocked && lastMove(halfway)?.text == "Its run ended before it finished. It said: I got halfway through the notes.",
              "a run that ended holding the card unfinished leaves it in Blocked, with what it said: \(lastMove(halfway)?.text ?? "")")
        let failed = await run(codex, mode: "fail", exit: 1, title: "Fix the flaky test") { id in
            if let card = board.card(id) { try? board.claim(card, by: BoardActor(name: codex.name, kind: .agent)) }
        }
        check(lastMove(failed)?.text == "Its run stopped (exit 1) before it finished: stream disconnected before completion.",
              "one that failed says why, in its own words: \(lastMove(failed)?.text ?? "")")
        let noResult = await run(copilotAgent, mode: "unfinished", title: "Check the links again") { id in
            if let card = board.card(id) { try? board.claim(card, by: BoardActor(name: copilotAgent.name, kind: .agent)) }
        }
        check(lastMove(noResult)?.text == "Its run ended before it finished.", "Copilot with no result line: \(lastMove(noResult)?.text ?? "")")
        let stopped = await run(codex, mode: "finish", sleep: 20, title: "Rename the module") { id in
            if let card = board.card(id) { try? board.claim(card, by: BoardActor(name: codex.name, kind: .agent)) }
            dispatcher.stop(id)
        }
        check(lastMove(stopped)?.text.hasPrefix("You stopped its run before it finished.") == true && stubbed(.codex, "signal.txt").contains("SIGINT"),
              "Stop asks it to end its turn (SIGINT), and the card says you stopped it: \(lastMove(stopped)?.text ?? "")")

        // 9. Stopped before it took the card.
        let early = await run(codex, mode: "fail", exit: 1, title: "Bump the version")
        check(board.card(early)?.column == .ready && notes(early).contains("Codex stopped (exit 1) before it took the card: stream disconnected before completion."),
              "a run that stopped before it took the card says so, in its own words, and the card stays in Ready: \(notes(early).first ?? "")")
        can(.codex, "early", [codexDone[0]])
        let noServer = await run(codex, mode: "early", exit: 1, stderr: "Error: required MCP servers failed to initialize: binders", title: "Bump it again")
        check(notes(noServer).contains("Codex stopped (exit 1) before it took the card: Error: required MCP servers failed to initialize: binders."),
              "with what the tool printed when its server didn't start: \(notes(noServer).first ?? "")")

        // 9, more: a run that ends normally but stops early says why, in the tool's own words; Codex, whose server is required,
        // isn't blamed on it; and Copilot's way of saying it isn't signed in, over several lines, is known.
        can(.opencode, "rejected", [opencode("tool_use", #"{"id":"p1","type":"tool","tool":"bash","state":{"status":"error","input":{"command":"make"},"error":"The user rejected permission to use this specific tool call."}}"#),
                                    opencode("step_finish", #"{"id":"p2","type":"step-finish","reason":"tool-calls","cost":0.0}"#)])
        let rejected = await run(opencodeAgent, mode: "rejected", title: "Build it")
        check(board.card(rejected)?.column == .ready && notes(rejected).contains("OpenCode stopped before it took the card: it stopped at a step a run can't approve: bash."),
              "exit 0 at a step a run can't approve: the card says so, in its words: \(notes(rejected).first ?? "")")
        can(.opencode, "steps", [opencode("tool_use", #"{"id":"p1","type":"tool","tool":"binders_claim_task","state":{"status":"completed","input":{},"output":"{}"}}"#),
                                 opencode("text", #"{"id":"p2","type":"text","text":"I reached the maximum steps for this run."}"#),
                                 opencode("step_finish", #"{"id":"p3","type":"step-finish","reason":"stop","cost":0.02}"#)])
        let capped = await run(opencodeAgent, mode: "steps", title: "Write all the notes") { id in
            if let card = board.card(id) { try? board.claim(card, by: BoardActor(name: opencodeAgent.name, kind: .agent)) }
        }
        check(lastMove(capped)?.text == "Its run ended before it finished: it used its 150 steps. It said: I reached the maximum steps for this run.",
              "a card it holds whose run used its steps goes to Blocked with that reason: \(lastMove(capped)?.text ?? "")")
        can(.copilot, "policy", [copilot("session.warning", #"{"warningType":"policy","message":"Third-party MCP servers are disabled by your organization's Copilot policy."}"#),
                                 copilotResult.replacingOccurrences(of: #""premiumRequests":2"#, with: #""premiumRequests":0.33"#)])
        let policy = await run(copilotAgent, mode: "policy", title: "Check the policy")
        check(notes(policy).contains("GitHub Copilot CLI stopped before it took the card: your organization's Copilot policy turns off other MCP servers, so the run couldn't reach the board.")
              && dispatcher.outcomes[policy]?.message == "Finished, 0.33 premium requests",
              "an organization's policy that turns the board off says so, and its premium requests aren't cut down: \(notes(policy).first ?? ""), \(dispatcher.outcomes[policy]?.message ?? "")")
        let unused = await run(codex, mode: "finish", title: "Look at it")
        check(board.card(unused)?.column == .ready
              && notes(unused).contains("Codex ended its run without taking the card or using Binders' board tools. Wake Now on the card starts it again."),
              "Codex ending normally without taking the card isn't put down to its server, which it requires: \(notes(unused).first ?? "")")
        can(.copilot, "signin", [])
        let signedOut = await run(copilotAgent, mode: "signin", exit: 1, stderr: """
            Error: No authentication information found.

            Copilot can be authenticated with GitHub using an OAuth Token or a Fine-Grained Personal Access Token.

            To authenticate, you can use any of the following methods:
              \u{2022} Start 'copilot' and run the '/login' command
              \u{2022} Run 'gh auth login' to authenticate with the GitHub CLI
            """, title: "Sign in first")
        check(notes(signedOut).contains("GitHub Copilot CLI isn't signed in for Binders' runs. Sign in with copilot login in Terminal, then Wake Now."),
              "Copilot not signed in, said over several lines: the card says how to sign in: \(notes(signedOut).first ?? "")")

        // 9, Antigravity: what it wasn't allowed to do, its sign-in, your settings, its .agents folder, its conversation.
        let softDenied = await run(antigravityAgent, mode: "finish", stderr: #"notice: run_command was soft-denied: "npm test" needs approval. To allow it, add "command(npm test)" to permissions.allow in settings.json"#,
                                   title: "Run the tests")
        check(notes(softDenied).contains { $0.hasPrefix("Antigravity wasn't allowed to run `npm test`. No one is there to approve a step in Binders' runs") },
              "a command Antigravity soft-denied shows on the card: \(notes(softDenied).first ?? "")")
        clearRecordings(.antigravity)
        _ = dispatcher.wakeNow(board.card(softDenied)!)
        await wait(20) { !stubbed(.antigravity, "cwd.txt").isEmpty }
        await wait(60) { !dispatcher.isWorking(on: softDenied) }
        let carried = stubbed(.antigravity, "argv.bin").split(separator: "\0").map(String.init)
        check(carried.firstIndex(of: "--conversation").map { carried[$0 + 1] } == conversation, "the card's next run carries on its conversation: \(carried)")
        let agySignedOut = await run(antigravityAgent, mode: "signin", exit: 1, stderr: "error: authentication required. Run agy in a terminal to sign in.", title: "Sign in to it")
        check(notes(agySignedOut).contains("Sign in to Antigravity: open Terminal and run agy once, then Wake Now. Binders' runs use the sign-in agy keeps on this Mac; Binders never sees it."),
              "Antigravity not signed in: the card says how to sign in: \(notes(agySignedOut).first ?? "")")
        for (settings, said) in [(#"{"toolPermission":"always-proceed","permissions":{"allow":["mcp(binders/*)"]}}"#, "sets toolPermission to always-proceed"),
                                 (#"{"permissions":{"allow":["mcp(binders/*)","read_file(~/.ssh)"]}}"#, "allows read_file(~/.ssh), which lets it read ~/.ssh"),
                                 (#"{"permissions":{"allow":["command(git status)"]}}"#, #"Add "mcp(binders/*)" to permissions.allow"#),
                                 ("{ cut short", "isn't JSON Binders can read")] {
            settle(settings)
            clearRecordings(.antigravity)
            let loosened = await run(antigravityAgent, mode: "finish", title: "With looser settings")
            check(notes(loosened).last?.hasPrefix("Binders didn't start Antigravity: ") == true && notes(loosened).last?.contains(said) == true
                  && stubbed(.antigravity, "argv.bin").isEmpty && !manager.fileExists(atPath: AgentWorktree.path(root: places.path, repository: AgentPlaces.real(repoPath), card: loosened, tool: .antigravity)),
                  "settings that \(said) stop it before any worktree is made: \(notes(loosened).last ?? "")")
        }
        settle(nil)
        let noSettings = await run(antigravityAgent, mode: "finish", title: "With no settings file")
        check(notes(noSettings).last?.contains("it couldn't reach the board") == true, "with no settings file, it couldn't reach the board, so it isn't started")
        settle(agyAllowed)
        let agyHooked = await run(antigravityAgent, mode: "plant-hooks", title: "Add a hook")
        let agyHookedTree = await git(["ls-tree", "-r", "--name-only", AgentWorktree.branch(card: agyHooked, tool: .antigravity)], in: repo).output
        check(notes(agyHooked).last?.hasPrefix("Didn't commit Antigravity's changes: the worktree has .agents/hooks.json now") == true && !agyHookedTree.contains(".agents/"),
              "a run that adds .agents/hooks.json isn't committed: \(notes(agyHooked).last ?? "")")
        clearRecordings(.antigravity)
        _ = dispatcher.wakeNow(board.card(agyHooked)!)
        await wait(30) { notes(agyHooked).last?.hasPrefix("Binders didn't start Antigravity") == true }
        check(notes(agyHooked).last?.hasPrefix("Binders didn't start Antigravity: the card's worktree has .agents/hooks.json") == true && stubbed(.antigravity, "argv.bin").isEmpty,
              "and the next run doesn't start in a worktree with it: \(notes(agyHooked).last ?? "")")

        // 10. The commit.
        let edited = await run(codex, mode: "edit", title: "Add a line to the README")
        let branch = AgentWorktree.branch(card: edited, tool: .codex)
        let log = await git(["log", "-1", "--format=%an%n%s", branch], in: repo).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = await git(["diff", "--stat", "main", branch], in: repo).output
        check(log == "Sam\nBinders card \(CLIAgentLaunches.card12(edited)): changes from Codex · repo" && diff.contains("README.md"),
              "Binders committed the run's change on its branch, as you, with its message: \(log)")
        let sha = await git(["rev-parse", "--short", branch], in: repo).output.trimmingCharacters(in: .whitespacesAndNewlines)
        check(notes(edited).last?.hasPrefix("Committed Codex's changes on \(branch): \(sha), 1 file.") == true, "the end line names the commit: \(notes(edited).last ?? "")")
        let afterCommit = await checkout()
        check(afterCommit == before && !manager.fileExists(atPath: hookMark.path), "your checkout didn't move, and no hook ran, the commit's included")
        let pointed = await run(codex, mode: "pointer", title: "Point it elsewhere")
        let pointedCommits = await git(["rev-list", "--count", "main..\(AgentWorktree.branch(card: pointed, tool: .codex))"], in: repo).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let afterPointer = await checkout()
        check(notes(pointed).last?.contains("the worktree's .git file was changed during the run") == true && pointedCommits == "0" && afterPointer == before,
              "a rewritten .git file: no commit anywhere, and your checkout untouched: \(notes(pointed).last ?? "")")
        let filterMark = data.appendingPathComponent("filter-ran.txt")
        let nested = await run(codex, mode: "nested", title: "Vendor a library")
        check(notes(nested).last?.contains("it made a git repository inside the worktree, at sub/") == true && !manager.fileExists(atPath: filterMark.path),
              "a nested repository: no commit, and its clean filter never ran: \(notes(nested).last ?? "")")
        let deleted = await run(codex, mode: "delete", title: "Clean up")
        check(notes(deleted).last?.contains("they delete 31 of the branch's 31 files") == true, "deleting every file: no commit: \(notes(deleted).last ?? "")")

        // 10, more: two first wakes at once, each waiting seconds on git for its worktree: both records are kept, and both
        // runs' changes committed.
        let twins = [board.create(title: "Fix the first typo", binderID: binder, by: .you), board.create(title: "Fix the second typo", binderID: binder, by: .you)]
        set(.codex, "mode", "edit")
        set(.codex, "sleep", "3")
        set(.codex, "exit", "0")
        set(.codex, "stderr", nil)
        for card in twins { board.give(card, to: codex.name, by: .you) }
        // Both started: both records are in the file now, not only once the runs end (which would put a lost one back).
        await wait(60) { twins.allSatisfy { card in events(card.id).contains { $0.kind == .woke && $0.text.hasPrefix("Started Codex in ") } } }
        let whileRunning = AgentWorktrees.records()
        let bothKept = twins.allSatisfy { card in whileRunning.contains { $0.card == card.id && $0.tool == .codex } }
        func ended(_ id: UUID) -> Bool { notes(id).contains { $0.hasPrefix("Committed Codex's changes") || $0.hasPrefix("Codex changed no files.") } }
        await wait(120) { twins.allSatisfy { !dispatcher.isWorking(on: $0.id) && ended($0.id) } }
        check(bothKept && twins.allSatisfy { card in notes(card.id).contains { $0.hasPrefix("Committed Codex's changes on \(AgentWorktree.branch(card: card.id, tool: .codex))") } },
              "two first wakes at once: both worktrees keep their records while they run, and both runs' changes are committed: \(bothKept), \(twins.map { notes($0.id).last ?? "" })")
        // A run whose worktree's record went missing meanwhile: committed all the same, and the record put back.
        let lost = await run(codex, mode: "edit", sleep: 2, title: "Lose the record") { id in
            AgentWorktrees.update { $0.removeAll { $0.card == id } }
        }
        check(notes(lost).last?.hasPrefix("Committed Codex's changes on \(AgentWorktree.branch(card: lost, tool: .codex))") == true
              && AgentWorktrees.records().contains { $0.card == lost && $0.tool == .codex },
              "a run whose worktree lost its record still has its changes committed, and the record is put back: \(notes(lost).last ?? "")")
        // worktrees.json is shared by every Binders on this Mac: a later one's record for a tool this one doesn't know is
        // kept when this one adds its own, and a file it can't read is never saved over.
        let laterEntry = #"{"branch":"binders-card-0000000000aa-gemini","card":"00000000-0000-0000-0000-0000000000AA","commonDir":"/nowhere/.git","gitDir":"/nowhere/.git/worktrees/x","made":"2026-10-18T12:00:00Z","path":"\#(places.path)/worktrees/later/binders-0000000000aa-gemini","ready":true,"repository":"/nowhere","tool":"gemini"}"#
        if let text = try? String(contentsOf: AgentPlaces.records, encoding: .utf8), let end = text.lastIndex(of: "]") {
            try? (text[..<end].trimmingCharacters(in: .whitespacesAndNewlines) + ",\n" + laterEntry + "\n]\n").write(to: AgentPlaces.records, atomically: true, encoding: .utf8)
        }
        let besideLater = await run(codex, mode: "finish", title: "Beside a later Binders' worktree")
        check(((try? String(contentsOf: AgentPlaces.records, encoding: .utf8)) ?? "").contains(#""tool" : "gemini""#)
              && AgentWorktrees.records().contains { $0.card == besideLater && $0.tool == .codex },
              "a later Binders' worktree record is kept when this one saves its own")
        let goodRecords = try? Data(contentsOf: AgentPlaces.records)
        try? Data("[{ cut short".utf8).write(to: AgentPlaces.records)
        let unreadable = await run(codex, mode: "finish", title: "With the record file cut short")
        check(notes(unreadable).last?.hasPrefix("Binders couldn't read its record of worktrees") == true
              && (try? Data(contentsOf: AgentPlaces.records)) == Data("[{ cut short".utf8),
              "a worktrees.json Binders can't read stops the wake and is never saved over: \(notes(unreadable).last ?? "")")
        if let goodRecords { try? AgentPlaces.write(goodRecords, to: AgentPlaces.records) }

        // 11. The worktree again, and an answer that comes while Binders commits.
        let actor = BoardActor(name: codex.name, kind: .agent)
        var answered = false
        dispatcher.beforeCommit = { id in
            guard !answered, let card = board.card(id), card.column == .blocked else { return }
            answered = true
            board.comment(card, text: "Yes, the long one.", by: .you)
        }
        set(.codex, "mode", "edit")
        let asked = await run(codex, mode: "edit", sleep: 2, title: "Write the long intro") { id in
            if let card = board.card(id) { try? board.claim(card, by: actor) }
            if let card = board.card(id) { try? board.ask(card, question: "The long one or the short one?", by: actor) }
        }
        let firstRun = stubbed(.codex, "cwd.txt")
        clearRecordings(.codex)
        await wait(10) { !stubbed(.codex, "cwd.txt").isEmpty }
        // The second run finishes the card.
        if let card = board.card(asked) { try? board.complete(card, summary: "Wrote the long intro.", by: actor) }
        await wait(60) { !dispatcher.isWorking(on: asked) }
        dispatcher.beforeCommit = nil
        let woke = events(asked).filter { $0.kind == .woke }.count
        let commits = await git(["rev-list", "--count", "main..\(AgentWorktree.branch(card: asked, tool: .codex))"], in: repo).output.trimmingCharacters(in: .whitespacesAndNewlines)
        check(answered && woke == 2 && !events(asked).contains { $0.kind == .moved && $0.toColumn == "blocked" && $0.author == codex.name },
              "an answer during the commit sends the card back to work, not to Blocked, and wakes it again: \(woke) wakes")
        check(stubbed(.codex, "cwd.txt") == firstRun && commits == "2", "the next run works in the same worktree, with the first run's commit there: \(commits) commits")

        // 12. A folder Binders didn't finish making, and a repository git can't make a worktree from.
        let blocked = board.create(title: "Start fresh", binderID: binder, by: .you)
        let squatter = URL(fileURLWithPath: AgentWorktree.path(root: places.path, repository: AgentPlaces.real(repoPath), card: blocked.id, tool: .codex))
        try? manager.createDirectory(at: squatter, withIntermediateDirectories: true)
        try? "mine".write(to: squatter.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        _ = await run(codex, mode: "finish", title: "", card: blocked)
        check(notes(blocked.id).last?.hasPrefix("A folder is already at \(squatter.path), and Binders didn't finish making it. Nothing was started.") == true
              && manager.fileExists(atPath: squatter.appendingPathComponent("keep.txt").path), "a folder with no record stops the wake, and is left alone: \(notes(blocked.id).last ?? "")")
        let empty = data.appendingPathComponent("empty-repo", isDirectory: true)
        try? manager.createDirectory(at: empty, withIntermediateDirectories: true)
        await git(["init", "-q", "-b", "main"], in: empty)
        let emptyAgent = agent(.codex, name: "Codex · empty", repository: empty.path)
        check(registry.upsert(emptyAgent) == nil, "an agent on a repository with no commits is saved")
        let unborn = await run(emptyAgent, mode: "finish", title: "Start the project")
        let unbornPath = AgentWorktree.path(root: places.path, repository: AgentPlaces.real(empty.path), card: unborn, tool: .codex)
        check(notes(unborn).last?.hasPrefix("Couldn't make a worktree for this card in") == true && !manager.fileExists(atPath: unbornPath),
              "git can't make it: the card says so, and no folder is left: \(notes(unborn).last ?? "")")
        registry.remove(emptyAgent.id)

        // 12, more: OpenCode checks a path by its text, then follows a link: it isn't started in a worktree with a link that
        // leads outside it, even one whose end isn't there yet, as a write through it would make it. Links that stay
        // inside, there or not yet, don't stop it.
        let linked = data.appendingPathComponent("linked-repo", isDirectory: true)
        let beyond = data.appendingPathComponent("beyond", isDirectory: true)
        try? manager.createDirectory(at: linked, withIntermediateDirectories: true)
        try? manager.createDirectory(at: beyond, withIntermediateDirectories: true)
        await git(["init", "-q", "-b", "main"], in: linked)
        await git(["config", "user.name", "Sam"], in: linked)
        await git(["config", "user.email", "sam@example.invalid"], in: linked)
        try? "# Linked\n".write(to: linked.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? manager.createSymbolicLink(atPath: linked.appendingPathComponent("inside").path, withDestinationPath: "README.md")
        try? manager.createSymbolicLink(atPath: linked.appendingPathComponent("dist").path, withDestinationPath: "build/out")
        await git(["add", "-A"], in: linked)
        await git(["commit", "-q", "-m", "First"], in: linked)
        let linkedAgent = agent(.opencode, name: "OpenCode · linked", repository: linked.path)
        check(registry.upsert(linkedAgent) == nil, "an OpenCode agent on a repository with links is saved")
        let inward = await run(linkedAgent, mode: "finish", title: "Links that stay inside")
        check(events(inward).contains { $0.kind == .woke && $0.text.hasPrefix("Started OpenCode in ") },
              "links that stay in the worktree, there or not yet, don't stop OpenCode: \(notes(inward).first ?? "")")
        try? manager.createSymbolicLink(atPath: linked.appendingPathComponent("notes").path, withDestinationPath: beyond.appendingPathComponent("new.txt").path)
        await git(["add", "-A"], in: linked)
        await git(["commit", "-q", "-m", "Link out"], in: linked)
        clearRecordings(.opencode)
        let outward = await run(linkedAgent, mode: "finish", title: "A link that leads out")
        check(notes(outward).last == AgentWorktree.outwardLinkProblem("notes", tool: .opencode) && stubbed(.opencode, "argv.bin").isEmpty
              && !manager.fileExists(atPath: beyond.appendingPathComponent("new.txt").path),
              "a link in the worktree that leads outside it stops OpenCode, and names the link: \(notes(outward).last ?? "")")
        registry.remove(linkedAgent.id)

        // 13. A version Binders didn't check, and Codex settings from an administrator.
        set(.codex, "version", "0.163.0")
        let newer = await run(codex, mode: "finish", title: "Use the new Codex")
        check(notes(newer).last == "Binders didn't start Codex: this is Codex 0.163.0, and Binders' options were checked with 0.162.0. Open its agent in Settings → Agents and press Check to use this version.",
              "a newer minor version needs Check first: \(notes(newer).last ?? "")")
        CLIProgram.accept("0.163.0", for: .codex)
        let accepted = await run(codex, mode: "finish", title: "Use it now")
        check(events(accepted).contains { $0.kind == .woke && $0.text.contains("Codex 0.163.0; Binders checked 0.162.0") }, "accepted, it starts, and the receipt names both versions")
        CLIProgram.accept(nil, for: .codex)
        set(.codex, "version", nil)
        let managed = URL(fileURLWithPath: AgentPlaces.root.path + "/etc/codex/requirements.toml")
        try? manager.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "".write(to: managed, atomically: true, encoding: .utf8)
        let administered = await run(codex, mode: "finish", title: "Under management")
        check(notes(administered).last?.contains("this Mac has Codex settings from an administrator (/etc/codex/requirements.toml)") == true,
              "Codex settings from an administrator stop it, named: \(notes(administered).last ?? "")")
        try? manager.removeItem(at: managed)
        let rules = URL(fileURLWithPath: AgentPlaces.root.path + "/etc/codex/rules/allow.rules")
        try? manager.createDirectory(at: rules.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"prefix_rule(pattern = ["git"], decision = "allow")"#.write(to: rules, atomically: true, encoding: .utf8)
        let ruled = await run(codex, mode: "finish", title: "Under an administrator's rules")
        check(notes(ruled).last?.contains("this Mac has Codex settings from an administrator (/etc/codex/rules)") == true,
              "an administrator's rules stop it too, as rules there load even with --ignore-rules: \(notes(ruled).last ?? "")")
        try? manager.removeItem(at: URL(fileURLWithPath: AgentPlaces.root.path + "/etc/codex"))

        // 14. Copilot's settings folder for runs, set back before each run.
        let config = AgentPlaces.copilotHome.appendingPathComponent("config.json")
        try? #"{"trusted_folders":["\#(worktrees[.copilot] ?? "/")"],"disableAllHooks":false,"model":"gpt-5"}"#.write(to: config, atomically: true, encoding: .utf8)
        try? "{}".write(to: AgentPlaces.copilotHome.appendingPathComponent("permissions-config.json"), atomically: true, encoding: .utf8)
        _ = await run(copilotAgent, mode: "finish", title: "Check the links once more")
        let reset = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        check((reset["trusted_folders"] as? [String]) == [] && reset["disableAllHooks"] as? Bool == true && reset["model"] as? String == "gpt-5"
              && !manager.fileExists(atPath: AgentPlaces.copilotHome.appendingPathComponent("permissions-config.json").path),
              "a trusted folder and hooks turned on while looking in are set back, and its approvals deleted, before the next run")
        let hooksFolder = AgentPlaces.copilotHome.appendingPathComponent("hooks", isDirectory: true)
        try? manager.createDirectory(at: hooksFolder, withIntermediateDirectories: true)
        try? "{}".write(to: hooksFolder.appendingPathComponent("planted.json"), atomically: true, encoding: .utf8)
        clearRecordings(.copilot)
        let hooked = await run(copilotAgent, mode: "finish", title: "With a hook planted")
        check(notes(hooked).last?.contains("now has hooks/, probably added while you looked in on a run") == true && stubbed(.copilot, "argv.bin").isEmpty,
              "a hook planted there stops the next run, and nothing starts: \(notes(hooked).last ?? "")")
        try? manager.removeItem(at: hooksFolder)

        // 15. A run that outlives its dispatcher.
        let outlived = board.create(title: "Write the long changelog", binderID: binder, by: .you)
        set(.codex, "mode", "finish")
        set(.codex, "sleep", "4")
        set(.codex, "exit", "0")
        clearRecordings(.codex)
        board.give(outlived, to: codex.name, by: .you)
        await wait(20) { !stubbed(.codex, "cwd.txt").isEmpty }
        if let card = board.card(outlived.id) { try? board.claim(card, by: actor) }
        if let card = board.card(outlived.id) { try? board.complete(card, summary: "Wrote it.", by: actor) }
        // A run record a later Binders wrote, for a tool this one doesn't know, with a temp folder an hour old.
        let laterStem = "0000aaaa-20261018T120000"
        let laterTemp = AgentPlaces.temporary.appendingPathComponent(laterStem, isDirectory: true)
        let laterRecord = AgentPlaces.logs.appendingPathComponent(laterStem + ".run.json")
        AgentPlaces.ensure(laterTemp)
        try? #"{"card":"00000000-0000-0000-0000-0000000000AA","tool":"gemini"}"#.write(to: laterRecord, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: laterTemp.path)
        // Binders quits; another opens and takes up the run from its record.
        dispatcher.abandonCLIRuns()
        let reopened = AgentDispatcher(registry: registry)
        reopened.board = board
        board.dispatcher = reopened
        reopened.start()
        dispatcher = reopened
        check(reopened.isWorking(on: outlived.id), "a new Binders adopts the run still going: the card shows it working")
        check(manager.fileExists(atPath: laterTemp.path), "a run record this build can't read still has its run's temp folder kept")
        try? manager.removeItem(at: laterRecord)
        try? manager.removeItem(at: laterTemp)
        _ = reopened.wakeNow(board.card(outlived.id)!)
        check(reopened.outcomes[outlived.id]?.message.contains("is already working on it") == true, "a Wake Now meanwhile waits for it")
        set(.codex, "sleep", "0.5")
        await wait(30) { !reopened.isWorking(on: outlived.id) || events(outlived.id).filter { $0.kind == .woke }.count >= 2 }
        await wait(30) { events(outlived.id).filter { $0.kind == .woke }.count >= 2 }
        await wait(30) { !reopened.isWorking(on: outlived.id) }
        let ends = notes(outlived.id).filter { $0.hasPrefix("Codex changed no files.") || $0.hasPrefix("Committed") }
        check(ends.count == 2 && events(outlived.id).filter { $0.kind == .woke }.count == 2,
              "its end steps happen once, then the waiting wake starts the next run: \(ends.count) end lines")
        // One that ended while Binders was closed, still holding its card.
        let gone = board.create(title: "Finish the migration", binderID: binder, by: .you)
        try? board.claim(gone, by: actor)
        let goneStem = CLIRuns.newStem(for: gone.id)
        try? "".write(toFile: goneStem + ".jsonl", atomically: true, encoding: .utf8)
        CLIRuns.write(CLIRunRecord(card: gone.id, run: UUID(), agent: codex.id, agentName: codex.name, tool: .codex, mode: "workspace sandbox, no network",
                                   worktree: "/nowhere", stem: goneStem, session: nil, pid: 999_999, processStart: 1, startedAt: Date()))
        let again = AgentDispatcher(registry: registry)
        again.board = board
        board.dispatcher = again
        again.start()
        dispatcher = again
        await wait(20) { board.card(gone.id)?.column == .blocked }
        check(lastMove(gone.id)?.text == "Its run ended while Binders was closed, before it finished.", "a run that ended while Binders was closed ends at once: \(lastMove(gone.id)?.text ?? "")")

        // 16. What a run is doing, from its own output.
        let reader = AgentDoingReader.shared
        let doingCard = await run(codex, mode: "doing", sleep: 4, title: "Run the whole suite") { id in
            if let card = board.card(id) { try? board.claim(card, by: actor) }
            // The stand-in prints its plan once Binders' server has answered it: looked at again until it has.
            var line: String?
            let end = Date().addingTimeInterval(8)
            while Date() < end, line == nil {
                try? await Task.sleep(for: .milliseconds(200))
                reader.forget()
                line = board.card(id).map { AgentDoing.lines(for: [$0], on: Store.shared.context)[id] } ?? nil
            }
            check(line == "Running the tests", "while it runs, the card says what it's doing, from its own output: \(line ?? "nothing")")
        }
        reader.forget()
        check(board.card(doingCard).map { AgentDoing.lines(for: [$0], on: Store.shared.context)[doingCard] == nil } == true, "and nothing once it's done")

        // 17. Changed outside Binders.
        if var text = try? String(contentsOf: agentsCLI, encoding: .utf8) {
            let other = stand(in: .codex, folder: data.appendingPathComponent("bin2", isDirectory: true))
            text = text.replacingOccurrences(of: stand(in: .codex).path, with: other.path)
            try? text.write(to: agentsCLI, atomically: true, encoding: .utf8)
        }
        registry.load()
        clearRecordings(.codex)
        let outside = board.create(title: "Changed behind my back", binderID: binder, by: .you)
        board.give(outside, to: codex.name, by: .you)
        try? await Task.sleep(for: .milliseconds(500))
        check(registry.changedOutside.contains(codex.id) && stubbed(.codex, "argv.bin").isEmpty && !events(outside.id).contains { $0.kind == .woke },
              "a program changed in agents-cli.json is held: nothing starts until it's saved again")
        registry.upsert(codex)

        // 17, more: paused here, then resumed in Mac 0.8.0, which writes agents.json and the Keychain but never opens
        // agents-cli.json: resumed.
        registry.setPaused(true)
        let cliSaysPaused = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: agentsCLI))) as? [String: Any])?["paused"] as? Bool
        if var main = (try? JSONSerialization.jsonObject(with: Data(contentsOf: agentsJSON))) as? [String: Any] {
            main["paused"] = false
            try? JSONSerialization.data(withJSONObject: main, options: [.prettyPrinted, .sortedKeys]).write(to: agentsJSON)
        }
        Keychain.write("0", for: "selftest-agents-paused")
        registry.load()
        check(cliSaysPaused == false && !registry.paused, "paused here and resumed in Mac 0.8.0: resumed, as agents-cli.json never holds the pause")
        registry.setPaused(false)

        // 17, in the folder itself: a workspace that holds several repositories and isn't one. No worktree, no branch, no
        // commit; it changes the files there, and one card runs there at a time.
        let workspace = data.appendingPathComponent("workspace", isDirectory: true)
        try? manager.createDirectory(at: workspace.appendingPathComponent("service-a"), withIntermediateDirectories: true)
        try? "# Workspace\n".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        var folderAgent = agent(.codex, name: "Codex · workspace", repository: workspace.path)
        check(registry.problem(with: folderAgent)?.contains("turn on Work in the Folder Itself") == true, "a folder that isn't a repository asks for Work in the Folder Itself")
        if case .cliAgent(var wake) = folderAgent.wake {
            wake.inFolder = true
            folderAgent.wake = .cliAgent(wake)
        }
        check(registry.upsert(folderAgent) == nil, "with it on, any folder will do: \(registry.problem(with: folderAgent) ?? "")")
        let worktreesBefore = AgentWorktrees.records().count
        let inFolder = await run(folderAgent, mode: "edit", title: "Change two services")
        check(AgentPlaces.real(stubbed(.codex, "cwd.txt")) == AgentPlaces.real(workspace.path), "it started in the folder itself: \(stubbed(.codex, "cwd.txt"))")
        check(stubbed(.codex, "argv.bin").split(separator: "\0").contains("--skip-git-repo-check"), "Codex may run there though it isn't a repository")
        check(events(inFolder).contains { $0.kind == .woke && $0.text.contains(", the folder itself") && $0.text.contains("Binders commits nothing") },
              "the receipt says it works in the folder itself and nothing is committed")
        check(notes(inFolder).last?.contains("uncommitted") == true && AgentWorktrees.records().count == worktreesBefore,
              "its end says the changes are there uncommitted, and no worktree was made: \(notes(inFolder).last ?? "")")
        check(((try? String(contentsOf: workspace.appendingPathComponent("README.md"), encoding: .utf8)) ?? "").contains("A line the stand-in added."),
              "what it changed is in the folder")
        registry.remove(folderAgent.id)

        // 17, pull requests: let have them, a run's commit on the card's branch is pushed and its pull request opened, by
        // Binders. A local origin and a stand-in gh, so nothing reaches GitHub.
        let origin = data.appendingPathComponent("origin.git", isDirectory: true)
        try? manager.createDirectory(at: origin, withIntermediateDirectories: true)
        await git(["init", "-q", "--bare", "-b", "main"], in: origin)
        await git(["remote", "add", "origin", origin.path], in: repo)
        await git(["push", "-q", "origin", "main"], in: repo)
        await git(["remote", "set-head", "origin", "main"], in: repo)
        let ghBin = data.appendingPathComponent("gh-bin", isDirectory: true)
        try? manager.createDirectory(at: ghBin, withIntermediateDirectories: true)
        try? "#!/bin/sh\necho 'https://github.com/example/repo/pull/12'\n".write(to: ghBin.appendingPathComponent("gh"), atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghBin.appendingPathComponent("gh").path)
        PullRequestOpener.testPath = ghBin.path + ":/usr/bin:/bin"
        AgentDispatcher.pullRequestsInDemo = true
        var prAgent = agent(.codex, name: "Codex · pull requests")
        if case .cliAgent(var wake) = prAgent.wake {
            wake.pullRequests = true
            prAgent.wake = .cliAgent(wake)
        }
        check(registry.upsert(prAgent) == nil, "an agent that opens pull requests is saved")
        let withPR = await run(prAgent, mode: "edit", title: "Add a line for review")
        await wait(30) { board.card(withPR)?.links.contains("https://github.com/example/repo/pull/12") == true }
        let prBranch = AgentWorktree.branch(card: withPR, tool: .codex)
        check(board.card(withPR)?.links.contains("https://github.com/example/repo/pull/12") == true, "its pull request's link is on the card")
        check(await git(["rev-parse", "--verify", "-q", "refs/heads/\(prBranch)"], in: origin).ok, "Binders pushed the card's branch to origin")
        check(events(withPR).contains { $0.text.contains("Opened a pull request for \(prBranch)") }, "the card says so")
        check(!stubbed(.codex, "stdin.txt").contains("Never push.\n") || stubbed(.codex, "stdin.txt").contains("opens a pull request"),
              "the run is told Binders opens it")
        registry.remove(prAgent.id)
        AgentDispatcher.pullRequestsInDemo = false
        PullRequestOpener.testPath = nil
        await git(["remote", "remove", "origin"], in: repo)

        // 18. Never the real tools.
        let real = AgentProfile(name: "Codex · real", wake: .cliAgent(CLIAgentWake(tool: .codex, repository: repoPath)), preset: "codex", wakesPerHour: 30)
        check(registry.upsert(real) == nil, "a Codex agent on your PATH is saved")
        clearRecordings(.codex)
        let realCard = board.create(title: "Not in a test", binderID: binder, by: .you)
        board.give(realCard, to: real.name, by: .you)
        try? await Task.sleep(for: .milliseconds(300))
        check(dispatcher.outcomes[realCard.id]?.message == "Not run in a throwaway folder" && stubbed(.codex, "argv.bin").isEmpty,
              "in a throwaway folder, only a stand-in runs, never the tool on your PATH")
        registry.remove(real.id)

        // Drawn: each one's settings.
        if let directory {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (tool, agent) in [(CLIAgent.codex, codex), (.opencode, opencodeAgent), (.copilot, copilotAgent), (.antigravity, antigravityAgent)] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 660), styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.alphaValue = 0
                let hosting = NSHostingView(rootView: AgentEditor(agent: agent, isNew: false).modelContainer(Store.shared.container))
                hosting.wantsLayer = true
                window.contentView = hosting
                window.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(1500))
                capture(hosting, name: "cli-agent-\(tool.rawValue)", directory: directory)
                window.close()
                check(manager.fileExists(atPath: directory.appendingPathComponent("cli-agent-\(tool.rawValue).png").path), "draws cli-agent-\(tool.rawValue).png")
            }
        }

        // 19. Tidy up: the agents, Binders' folder for them, and the dispatcher the board had.
        for agent in [codex, opencodeAgent, copilotAgent, antigravityAgent, echo] { registry.remove(agent.id) }
        board.dispatcher = controller.agents
        controller.agents.board = board
        try? manager.removeItem(at: places)
        check(!manager.fileExists(atPath: places.path), "Binders' folder for the runs is gone")

        print(failures == 0 ? "CLI_AGENTS_OK" : "CLI_AGENTS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// What `Binders --mcp` answers initialize, tools/list and a call, started with this environment alone.
    @MainActor
    private static func mcpReplies(_ environment: [String: String]) async -> [[String: Any]] {
        let lines = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
                     #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                     #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_tasks","arguments":{}}}"#].joined(separator: "\n") + "\n"
        let result = try? await AutomationService.runProcess(MCPHost.executable, ["--mcp"], stdin: lines, environment: environment, timeout: 30)
        return (result?.stdout ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}
