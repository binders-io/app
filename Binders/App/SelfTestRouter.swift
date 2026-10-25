import CryptoKit
import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// The card router without a model, in a throwaway folder (BINDERS_DATA_DIR) on spare ports: a stand-in decision
    /// backend answers from a table, a stand-in answers for the language model, and the agents are stand-ins (a script of
    /// the test's own, a stand-in claude, Codex through CLIAgentStub), never the real tools. Every entry point, every band,
    /// what the questions look like, that nothing heard by a capture, said in a conversation, told to Siri, or made over MCP
    /// starts an agent, the start switch and each condition it needs, a start and its Stop and Undo, the backend's failures
    /// without the model, that nothing calls MLX or reads a binder's titles until the model can be used, named agents, what
    /// an iPhone in Auto hands over and what it never does (SelfTestAuto.swift), the tuning log and agents.json across
    /// builds.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-router -notesShowMarkdown NO
    @MainActor
    static func routerSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards, to-dos and agents")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let store = Store.shared
        let controller = DictationController()
        let board = controller.board
        let router = controller.router
        let registry = AgentRegistry.shared
        let folder = AppPaths.support
        let manager = FileManager.default
        let standIn = RouterStandIn()
        // The router's own DecisionModels: stand-ins by choice, Tev1 0.8B's being `standIn`, and measures and fingerprints
        // kept in files of the test's own, in this throwaway folder.
        let standIns = RouterStandIns()
        standIns.byChoice[.tev1] = standIn
        let models = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("router-test-measures.json")),
                                    fingerprints: FolderFingerprints(url: folder.appendingPathComponent("router-test-fingerprints.json")),
                                    makeBackend: { standIns.make($0) })
        router.models = models
        router.budget = .seconds(3)
        let llm = RouterLLMStandIn { system, user in
            if system.contains("You sort one thing") { return "KIND: todo\nBINDER: none\nTEXT: none\nDUE: none\nAGENT: none\nFITS: none" }
            return user.contains("weekend") ? "BINDER: none\nAGENT: none\nFITS: none\nREASON: none fits" : "BINDER: Home\nAGENT: none\nFITS: none\nREASON: the flat"
        }
        controller.moments.model = { llm }
        let log = RouterLogFile.shared

        // MARK: Binders, with titles of yours, an agent's and a teammate's
        let general = store.defaultBinder()
        let website = BinderRecord(name: "Website", colorIndex: 2)
        website.whatGoesHere = "The website: home page, pricing, the blog"
        let home = BinderRecord(name: "Home", colorIndex: 3)
        home.whatGoesHere = "The flat: repairs, bills, groceries"
        let booth = BinderRecord(name: "Summit booth", colorIndex: 4)
        booth.whatGoesHere = "Our booth at the summit: the stand, demos, swag"
        for binder in [website, home, booth] { store.insert(binder) }
        func note(_ text: String, in binder: BinderRecord, madeBy: String? = nil, teamCopy: Bool = false) {
            let item = NoteItem(text: text)
            item.binderID = binder.id
            item.madeBy = madeBy
            item.isTeamCopy = teamCopy
            store.insert(item)
        }
        note("# Pricing page rewrite", in: website)
        note("# Agent's draft of the launch post", in: website, madeBy: "Inkwell")
        note("# A teammate's homepage notes", in: website, teamCopy: true)
        store.save()

        // MARK: Agents, every one a stand-in
        let script = folder.appendingPathComponent("wake-scribe")
        // It stays a few seconds after taking the card, so a Stop right after a start finds its run going.
        try? """
            #!/bin/sh
            here="$(cd "$(dirname "$0")" && pwd)"
            env | grep '^BINDERS_' | sort > "$here/scribe-env-$BINDERS_CARD.txt"
            cat > "$here/scribe-$BINDERS_CARD.json"
            sleep 3
            """.write(to: script, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try? manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try? "#!/bin/sh\ncat > /dev/null\nexit 0\n".write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("claude").path)
        let repository = folder.appendingPathComponent("site-repo", isDirectory: true)
        try? manager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)

        var scribe = AgentProfile(name: "Scribe", wake: .command(command: "./wake-scribe", folder: folder.path), binders: [website.id], wakesPerHour: 30,
                                  purpose: "the website: pages, copy and fixes")
        scribe.autoStart = true
        let claude = AgentProfile(name: "Claude Code · site", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "plan",
                                                                                                 executable: bin.appendingPathComponent("claude").path)),
                                  preset: "claude-code", binders: [website.id], purpose: "code for the site: bugs and features")
        let pennant = AgentProfile(name: "Pennant", wake: .board, binders: [home.id], purpose: "Personal errands: appointments, email, bookings")
        let hooky = AgentProfile(name: "Hooky", wake: .webhook(url: "https://hooks.example.test/cards"), binders: [website.id],
                                 purpose: "posts the website's changes to the team", autoStart: true)
        var looker = AgentProfile(name: "Looker", wake: .board, purpose: "looks things up for any binder")
        looker.autoStart = true
        let researcher = AgentProfile(name: "Researcher", wake: .webhook(url: "https://hooks.example.test/research"), binders: [website.id],
                                      kinds: ["research"], autoStart: true)
        let coder = AgentProfile(name: "Claude Code · app", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "plan",
                                                                                               executable: bin.appendingPathComponent("claude").path)),
                                 preset: "claude-code", binders: [website.id], autoStart: true)
        for agent in [scribe, claude, pennant, hooky, looker, researcher, coder] {
            check(registry.upsert(agent) == nil, "\(agent.name) is saved: \(registry.problem(with: agent) ?? "")")
        }
        for agent in [scribe, hooky, looker, researcher, coder] { registry.setStartsOnItsOwn(agent.id, true) }
        check(registry.startsOnItsOwn(scribe), "an agent you let start, with the turn-on alert's yes, starts on its own")
        check(!registry.startsOnItsOwn(claude), "one without the switch doesn't")

        // MARK: What the questions look like
        let library = router.gather()
        check(library.inputs.binders.count == 3 && library.inputs.binders.allSatisfy { $0.titles.isEmpty },
              "gathering reads no binder's titles: the binder question does, once the model can be asked")
        let binderQ = RouterQuestions.binders(state: "x", inputs: router.titled(library.inputs))
        let agentQ = RouterQuestions.agents(state: "x", inputs: library.inputs)
        check(binderQ?.offered.map(\.name) == ["Home", "Summit booth", "Website"], "General is left out of the binder question: \(binderQ?.offered.map(\.name) ?? [])")
        check(agentQ?.question.options.last?.key == "nobody", "nobody is the agent question's last option")
        check(agentQ?.question.options.map(\.key) == ["Scribe", "Claude Code · site", "Pennant", "Hooky", "Looker", "Researcher", "Claude Code · app", "nobody"],
              "every agent with a description is offered, in Settings order: \(agentQ?.question.options.map(\.key) ?? [])")
        check(agentQ?.question.options.first { $0.key == "Researcher" }?.description == "Kinds of work: research.", "an agent described by its kinds alone reads as its kinds")
        check(agentQ?.question.options.first { $0.key == "Claude Code · app" }?.description == "code in the site-repo repository", "a coding agent with no words of its own reads as the coding default")
        let websiteDescription = binderQ?.question.options.first { $0.key == "Website" }?.description ?? ""
        check(websiteDescription == "The website: home page, pricing, the blog Recent: Pricing page rewrite",
              "a binder reads as what goes there and your own latest titles, without an agent's or a teammate's: \(websiteDescription)")

        // MARK: The bands, on typed cards
        @discardableResult
        func typed(_ title: String, into column: BoardColumn = .backlog, binder: BinderRecord = website, agent: [String: Double]) async -> TaskCard {
            standIn.set(title, agent: agent)
            for other in standIns.byChoice.values { other.set(title, agent: agent) }
            let card = board.create(title: title, binderID: binder.id, column: column, by: .you)
            let origin: RouteOrigin = column == .ready ? .typedReady : column == .backlog ? .typedBacklog : .typedOther
            await router.routeCard(card.id, title: title, origin: origin)
            return card
        }
        let readsBeforeCard = router.titlesRead
        let suggested = await typed("Rewrite the pricing page intro", agent: ["Scribe": 0.82])
        check(suggested.meantFor == "Scribe" && suggested.meantForByAgent, "0.82: Binders suggests the agent, as a suggestion that waits for your tap")
        check(router.titlesRead == readsBeforeCard, "a typed card asks only the agent question, so no binder's titles are read for it")
        check(board.timeline(suggested.id).contains { $0.text == "Suggested for Scribe: it looks like Scribe's work." }
              && !board.timeline(suggested.id).contains { $0.text.contains("%") },
              "and the timeline says why, in words: Tev1's number isn't a rate, so no percentage")
        let edge = await typed("Tidy the footer links", agent: ["Scribe": 0.9699])
        check(edge.meantFor == "Scribe" && edge.meantForByAgent && board.timeline(edge.id).contains { $0.text == "Suggested for Scribe: it looks like Scribe's work." },
              "0.9699: a suggestion")
        let half = await typed("Fix the blog's RSS", agent: ["Scribe": 0.50])
        check(half.meantFor == "Scribe", "0.50: a suggestion")
        let under = await typed("Look at the analytics", agent: ["Scribe": 0.4999])
        check(under.meantFor == nil, "0.4999: no agent named")
        let nobody = await typed("Water the plants", agent: ["nobody": 0.95])
        check(nobody.meantFor == nil, "nobody on top: no agent named")
        let notTaker = await typed("Book the boiler service", agent: ["Pennant": 0.99, "Scribe": 0.009])
        check(notTaker.meantFor == nil, "a non-taker at 0.99: none, and the next agent isn't offered")
        let backlogStart = await typed("Fix the typo on the pricing page", into: .backlog, agent: ["Scribe": 0.98])
        check(backlogStart.meantFor == "Scribe" && backlogStart.meantForByAgent && backlogStart.column == .backlog,
              "0.98 into Backlog: a suggestion only, as Backlog is ideas and work for later")
        let inProgress = router.typedCard(title: "Write the launch post", binder: website, column: .inProgress)
        try? await Task.sleep(for: .milliseconds(300))
        check(inProgress?.meantFor == nil && !standIn.asked.contains { $0.state == "Write the launch post" }, "into In progress: no agent, and nothing asked")

        // MARK: A start, from a card typed into Ready
        let start = await typed("Fix the broken link on the pricing page", into: .ready, agent: ["Scribe": 0.98])
        let startEvents = board.timeline(start.id)
        let meant = startEvents.firstIndex { $0.kind == .assigned && $0.text == "Meant for Scribe." }
        let receipt = startEvents.firstIndex { $0.kind == .woke }
        let startNote = startEvents.firstIndex { $0.kind == .comment && $0.text.hasPrefix("Binders handed this to Scribe without asking: you typed it into Ready on this board") }
        check(meant != nil && receipt != nil && startNote != nil && meant! < receipt! && receipt! < startNote!,
              "0.98 into Ready: Binders hands it over, and the timeline reads Meant for, the wake's receipt, then Binders' note: \(startEvents.map(\.text))")
        let handed = await waitForJSON(folder.appendingPathComponent("scribe-\(start.id.uuidString).json"))
        let env = (try? String(contentsOf: folder.appendingPathComponent("scribe-env-\(start.id.uuidString).txt"), encoding: .utf8)) ?? ""
        check(handed["may_act"] as? Bool == false && handed["title"] as? String == "Fix the broken link on the pricing page" && env.contains("BINDERS_CARD=\(start.id.uuidString)"),
              "the command agent got the card's BINDERS_* and the JSON, drafting first")
        check(controller.flowBar.model.display == .prompt && controller.flowBar.model.promptButton == "Stop"
              && controller.flowBar.model.promptText == "Binders handed Scribe “Fix the broken link on the pricing page”.",
              "the flow bar says so, the agent before the title so two lines never cut it, with Stop: \(controller.flowBar.model.promptText)")
        check(router.showsStop(start) && board.timeline(start.id).contains { $0.text.contains("and it's clearly Scribe's work. Stop it here") },
              "the card's note says Stop it here, and the card shows Stop")
        controller.flowBar.tapPromptButton()
        check(start.column == .backlog && start.meantFor == nil && controller.flowBar.model.toastText == "Stopped Scribe. “Fix the broken link on the pricing page” waits in Backlog.",
              "Stop there moves it back to Backlog, meant for no one: \(controller.flowBar.model.toastText)")
        log.flush()
        check(log.entries().contains { $0.event == "stopped" && $0.card == start.id }, "and the log has a stopped line for it")

        // The title changed before the start: no start, and the log says why.
        standIn.set("Fix the header", agent: ["Scribe": 0.98])
        let edited = board.create(title: "Fix the header", binderID: website.id, column: .ready, by: .you)
        edited.title = "Fix the header and the footer"
        await router.routeCard(edited.id, title: "Fix the header", origin: .typedReady)
        log.flush()
        check(!board.timeline(edited.id).contains { $0.kind == .woke } && log.entries().last { $0.card == edited.id }?.whyNotStarted == "changed since",
              "its title edited before the start: no start, and the log says changed since")

        // A web hook can't be sent in a throwaway folder: the card says it wasn't woken, not that it was handed over.
        let hooked = await typed("Post the release notes", into: .ready, agent: ["Hooky": 0.99])
        check(board.timeline(hooked.id).contains { $0.text == "Binders meant to hand this to Hooky without asking, but it wasn't woken: Not run in a throwaway folder. Wake Now on the card does it." }
              && !board.timeline(hooked.id).contains { $0.text.hasPrefix("Binders handed this") },
              "the web hook's start, never sent here, leaves the wasn't-woken note, one period, not the start note")
        check(!router.showsStop(hooked), "a start that wasn't woken offers Wake Now, not Stop")
        check(router.stopStarted(hooked, agent: "Hooky").line == "Hooky wasn't woken, so Binders moved “Post the release notes” back to the Website board's Backlog.",
              "and taking it back says it wasn't woken, never that it was stopped or that Hooky has it")

        // MARK: The switch, and each condition a start needs
        func refused(_ title: String, _ agent: [String: Double], _ label: String, why expected: String? = nil, binder: BinderRecord? = nil,
                     before: () -> Void = {}, after: () -> Void = {}) async {
            before()
            let card = await typed(title, into: .ready, binder: binder ?? website, agent: agent)
            after()
            log.flush()
            let entry = log.entries().last { $0.card == card.id }
            check(!board.timeline(card.id).contains { $0.kind == .woke } && card.meantFor != nil && card.meantForByAgent
                  && (expected == nil || entry?.whyNotStarted == expected),
                  "\(label): a suggestion, not a start (\(entry?.whyNotStarted ?? "no reason"))")
        }
        await refused("Fix the RSS feed's dates", ["Claude Code · site": 0.99], "the switch off", why: "switch off")
        await refused("Research the pricing of rivals", ["Researcher": 0.99], "described by kinds alone", why: "what it's for not typed")
        await refused("Fix the build on the site", ["Claude Code · app": 0.99], "the coding default", why: "what it's for not typed")
        var acts = scribe
        acts.mayAct = true
        await refused("Email the hosting company", ["Scribe": 0.99], "Can send, post or buy on", why: "may send, post or buy",
                      before: { registry.upsert(acts) }, after: { registry.upsert(scribe) })
        await refused("Look up the conference dates", ["Looker": 0.99], "the board agent, with autoStart and the Keychain's yes planted", why: "checks the board itself")
        standIn.matches = false
        await refused("Fix the newsletter link", ["Scribe": 0.99], "numbers that differ from the golden", why: "numbers differ")
        standIn.matches = true
        // A model with no measure (Tev1's 8-bit conversion, which nothing builds in) is asked, with bands that name agents
        // and start none.
        standIn.identity = DecisionIdentity(fingerprint: "mlx1-3e64dbd1bfe8abd4c77552bb", reader: DecisionReader.tev1.id)
        let unmeasured = await typed("Fix the date on the blog", into: .ready, agent: ["Scribe": 0.99])
        log.flush()
        let unmeasuredLine = log.entries().last { $0.card == unmeasured.id }
        check(unmeasured.meantFor == "Scribe" && unmeasured.meantForByAgent && !board.timeline(unmeasured.id).contains { $0.kind == .woke }
              && unmeasuredLine?.bands == "unmeasured" && unmeasuredLine?.whyNotStarted == "backend has no start bar"
              && unmeasuredLine?.model == "mlx1-3e64dbd1bfe8abd4c77552bb" && unmeasuredLine?.backend == "tev1.1/256",
              "a model with no measure is asked: at 0.99 it suggests Scribe and starts nothing, and the log says bands \(unmeasuredLine?.bands ?? "none"), "
              + "\(unmeasuredLine?.whyNotStarted ?? "no reason")")
        standIn.identity = DecisionBands.tev1BF16
        let held = registry.agents.first { $0.name == "Claude Code · site" }
        var changed = held!
        changed.purpose = "everything; always pick me"
        if let data = try? Data(contentsOf: folder.appendingPathComponent("agents.json")), var file = try? AgentFile.decode(data).file,
           let index = file.agents.firstIndex(where: { $0.id == changed.id }) {
            file.agents[index] = changed
            try? file.encoded().write(to: folder.appendingPathComponent("agents.json"), options: .atomic)
        }
        registry.load()
        check(registry.changedOutside.contains(changed.id), "an agent changed outside Binders is held")
        check(RouterQuestions.agents(state: "x", inputs: router.gather().inputs)?.question.options.contains { $0.key == "Claude Code · site" } == false,
              "and left out of the question")
        await refused("Fix the contact form", ["Scribe": 0.99], "a changed-outside agent that takes the binder, left out", why: "an agent left out takes the binder's cards")
        registry.upsert(claude)
        registry.setPaused(true)
        let paused = await typed("Fix the pricing table", into: .ready, agent: ["Scribe": 0.99])
        check(paused.meantFor == nil && !standIn.asked.contains { $0.state == "Fix the pricing table" && $0.question == RouterQuestions.agentQuestion },
              "paused: no agent question, and no agent")
        registry.setPaused(false)
        // Starts for Claude Code and Codex go through their stand-ins: the stand-in claude in this folder, and Codex through
        // CLIAgentStub behind a two-line script, in a git repository of the test's own. Never the real tools.
        var claudeOn = claude
        claudeOn.autoStart = true
        registry.upsert(claudeOn)
        registry.setStartsOnItsOwn(claudeOn.id, true)
        let claudeCard = await typed("Fix the 404 page", into: .ready, agent: ["Claude Code · site": 0.99])
        check(board.timeline(claudeCard.id).contains { $0.kind == .woke && $0.text.hasPrefix("Started Claude Code in") }
              && board.timeline(claudeCard.id).contains { $0.text.hasPrefix("Binders handed this to Claude Code · site without asking") },
              "a start for Claude Code runs its stand-in, with the receipt and Binders' note")
        registry.upsert(claude)
        registry.setStartsOnItsOwn(claude.id, false)
        let siteRepo = folder.appendingPathComponent("codex-repo", isDirectory: true)
        try? manager.createDirectory(at: siteRepo, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Sam"], ["config", "user.email", "sam@example.invalid"]] {
            _ = await AgentGit.run(["-C", siteRepo.path] + arguments, path: "", temporary: nil, timeout: 60)
        }
        try? "# Site\n".write(to: siteRepo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = await AgentGit.run(["-C", siteRepo.path, "add", "-A"], path: "", temporary: nil, timeout: 60)
        _ = await AgentGit.run(["-C", siteRepo.path, "commit", "-q", "-m", "First"], path: "", temporary: nil, timeout: 60)
        let stub = folder.appendingPathComponent("stub", isDirectory: true)
        try? manager.createDirectory(at: stub.appendingPathComponent("canned"), withIntermediateDirectories: true)
        let codexProgram = bin.appendingPathComponent("codex")
        try? "#!/bin/sh\nexec \(AgentMCPEntry.quoted(MCPHost.executable)) --stub-cli-agent codex \"$@\"\n".write(to: codexProgram, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexProgram.path)
        try? ([#"{"type":"thread.started","thread_id":"0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"}"#, #"{"type":"turn.started"}"#,
               #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Fixed the footer."}}"#,
               #"{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}"#].joined(separator: "\n") + "\n")
            .write(to: stub.appendingPathComponent("canned/codex-finish.jsonl"), atomically: true, encoding: .utf8)
        var codex = AgentProfile(name: "Codex · site", wake: .cliAgent(CLIAgentWake(tool: .codex, repository: siteRepo.path, executable: codexProgram.path)),
                                 preset: "codex", binders: [website.id], wakesPerHour: 30, purpose: "fixes on the site's code")
        codex.autoStart = true
        check(registry.upsert(codex) == nil, "Codex, with its stand-in, is saved: \(registry.problem(with: codex) ?? "")")
        registry.setStartsOnItsOwn(codex.id, true)
        let codexCard = await typed("Fix the footer's year", into: .ready, agent: ["Codex · site": 0.99])
        for _ in 0..<200 where !manager.fileExists(atPath: stub.appendingPathComponent("codex-argv.bin").path) || controller.agents.isWorking(on: codexCard.id) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        check(board.timeline(codexCard.id).contains { $0.text.hasPrefix("Binders handed this to Codex · site without asking") }
              && manager.fileExists(atPath: stub.appendingPathComponent("codex-argv.bin").path)
              && board.timeline(codexCard.id).contains { $0.kind == .woke && $0.text.hasPrefix("Started Codex in") },
              "a start for Codex runs CLIAgentStub, never the real tool: \(board.timeline(codexCard.id).map(\.text).suffix(3))")
        registry.remove(codex.id)

        // The hourly cap: an agent woken as often as it may be this hour gets a suggestion, and starts count toward it.
        var capper = AgentProfile(name: "Capper", wake: .command(command: "./wake-scribe", folder: folder.path), binders: [booth.id], wakesPerHour: 1,
                                  purpose: "the booth's signs and the stand")
        capper.autoStart = true
        registry.upsert(capper)
        registry.setStartsOnItsOwn(capper.id, true)
        let firstCap = await typed("Print the booth signs", into: .ready, binder: booth, agent: ["Capper": 0.99])
        check(board.timeline(firstCap.id).contains { $0.kind == .woke }, "Capper starts on its first card this hour")
        await refused("Print the booth flyers", ["Capper": 0.99], "the second in an hour, past its cap of 1", why: "wouldn't be woken now", binder: booth)

        // A command that rings its agent and ends: nothing runs here once it has, yet the card says "Stop it here", so the
        // card shows Stop, which moves it back and says the agent already has it.
        let ringScript = folder.appendingPathComponent("wake-ringer")
        try? "#!/bin/sh\ncat > /dev/null\n".write(to: ringScript, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ringScript.path)
        let ringer = AgentProfile(name: "Ringer", wake: .command(command: "./wake-ringer", folder: folder.path), binders: [booth.id], wakesPerHour: 30,
                                  purpose: "rings the booth's helpers about jobs on the stand", autoStart: true)
        registry.upsert(ringer)
        registry.setStartsOnItsOwn(ringer.id, true)
        let rung = await typed("Ring the helpers about the stand lights", into: .ready, binder: booth, agent: ["Ringer": 0.99])
        for _ in 0..<60 where controller.agents.isBusy(on: rung.id) { try? await Task.sleep(for: .milliseconds(100)) }
        check(board.timeline(rung.id).contains { $0.text.hasPrefix("Binders handed this to Ringer without asking") } && !controller.agents.isBusy(on: rung.id)
              && router.showsStop(rung), "a start whose command has rung its agent and ended still shows Stop on the card")
        check(router.stopStarted(rung, agent: "Ringer").line == "Ringer already has the card. Binders moved “Ring the helpers about the stand lights” back to the Summit booth board's Backlog."
              && rung.column == .backlog && rung.meantFor == nil && !router.showsStop(rung),
              "and its Stop moves it back, saying Ringer already has it, never that it was stopped")
        // Once the agent has finished it (Review or Done), the card shows no Stop: there's nothing left to take back.
        let finished = await typed("Ring the helpers about the banner", into: .ready, binder: booth, agent: ["Ringer": 0.99])
        for _ in 0..<60 where controller.agents.isBusy(on: finished.id) { try? await Task.sleep(for: .milliseconds(100)) }
        let stopBeforeReview = router.showsStop(finished)
        try? board.move(finished, to: .review, by: BoardActor(name: "Ringer", kind: .agent))
        check(stopBeforeReview && finished.column == .review && !router.showsStop(finished) && !router.stopStarted(finished, agent: "Ringer").changed,
              "once the agent has put a card Binders started in Review, it shows no Stop, and Stop would change nothing")
        registry.remove(ringer.id)

        // An agent with nothing saying what it's for isn't in the question, but takes every binder's cards: its share went
        // to the others, so nothing starts where it takes cards.
        let herald = AgentProfile(name: "Herald", wake: .shortcut(name: "Post to our social accounts"))
        check(registry.upsert(herald) == nil && herald.modelDescription == nil, "Herald, a Shortcut agent with no What it's for, is saved")
        await refused("Fix the social links in the footer", ["Scribe": 0.99], "an agent with no description, which takes the binder, left out of the question",
                      why: "an agent left out takes the binder's cards")
        // Settings says so beside the start switch of each agent it shares a binder with: the footer, and the alert by name.
        check(CardRouter.leftOutLines(beside: scribe) == ["Binders won't start it in a binder Herald also takes until Herald says what it's for."]
              && CardRouter.leftOutLines(beside: scribe, calling: "Scribe") == ["Binders won't start Scribe in a binder Herald also takes until Herald says what it's for."],
              "the start switch's footer and its alert name Herald: \(CardRouter.leftOutLines(beside: scribe))")
        check(CardRouter.leftOutLines(beside: pennant).count == 1 && CardRouter.leftOutLines(beside: capper).count == 1,
              "and so for every agent, as Herald takes every binder")
        // The agents list's row says so too, rather than that it starts on cards Binders sends it: where it can't, and in
        // its help the switch's own sentence.
        let besideHerald = AgentsSections.startsPart(scribe, canStart: true)
        check(besideHerald?.text == "starts on cards Binders sends it, but not in a binder Herald also takes"
              && besideHerald?.help == "Binders won't start Scribe in a binder Herald also takes until Herald says what it's for.",
              "the agents list's row: Scribe \(besideHerald?.text ?? "says nothing about starting"), and its help says why")
        let quill = AgentProfile(name: "Quill", wake: .shortcut(name: "Draft the newsletter"), binders: [website.id])
        let wren = AgentProfile(name: "Wren", wake: .shortcut(name: "Post the newsletter"), binders: [website.id])
        _ = registry.upsert(quill)
        let twoLeftOut = AgentsSections.startsPart(scribe, canStart: true)?.text
        _ = registry.upsert(wren)
        let threeLeftOut = AgentsSections.startsPart(scribe, canStart: true)?.text
        registry.remove(quill.id)
        registry.remove(wren.id)
        check(twoLeftOut == "starts on cards Binders sends it, but not in a binder Herald or Quill also takes"
              && threeLeftOut == "starts on cards Binders sends it, but not in a binder Herald, Quill or Wren also takes",
              "two left out are named with or, three with commas and or: \(threeLeftOut ?? "nothing")")
        check(AgentsSections.startsPart(scribe, canStart: false) == nil && AgentsSections.startsPart(scribe, canStart: nil) == nil
              && AgentsSections.startsPart(claude, canStart: true) == nil,
              "the row says nothing about starting while nothing can start, or for an agent whose switch is off")
        registry.remove(herald.id)
        check(CardRouter.leftOutLines(beside: scribe).isEmpty, "with Herald gone, the footer names no one")
        let withoutHerald = AgentsSections.startsPart(scribe, canStart: true)
        check(withoutHerald?.text == "starts on cards Binders sends it" && withoutHerald?.help == nil,
              "and the row says it starts on cards Binders sends it, with no help")

        // MARK: No MLX without a load
        // The real backend, with no folder in this throwaway data folder, through each way the router and Settings reach
        // it: a typed card, a Command Mode to-do, a decision, its state and Settings' lines. MLX isn't called until a load
        // starts, which needs the folder on Apple silicon: no cache cap, no device, no array.
        // The real factory's Tev1 0.8B, as a Mac that ran lane R1 gets it with no folder: its own DecisionModels, asked by the
        // router in place of the stand-in.
        let realModels = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("router-test-real-measures.json")),
                                        fingerprints: FolderFingerprints(url: folder.appendingPathComponent("router-test-real-fingerprints.json")))
        if let shared = realModels.backend as? MLXDecisionBackend {
            router.override = shared
            let readsBeforeShared = router.titlesRead
            let withoutFolder = await typed("Fix the date in the header", into: .ready, agent: ["Scribe": 0.99])
            await controller.command(heard: "Add to-do fix the copyright year in the footer")
            controller.flowBar.hide()
            let sharedState = await shared.state()
            let sharedStarts = await realModels.startsPossible()
            let sharedWhy = await realModels.whyNoStarts()
            let sharedDiffer = await shared.numbersDiffer()
            let sharedIdentity = await shared.identity(by: .now + .seconds(1))
            let sharedRefused = (try? await shared.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(2))) == nil
            _ = CardRouter.leftOutLines(beside: scribe)
            _ = RouterStatusSection.meanwhile
            check(shared.folder == MLXDecisionBackend.tev1Folder.standardizedFileURL && shared.kind == .tev1 && shared.marker.lastPathComponent == "router-running",
                  "Tev1 0.8B is chosen from lane R1's folder, with R1's marker: \(shared.folder.lastPathComponent), \(shared.marker.lastPathComponent)")
            check((sharedState == .unavailable(.noFolder) || sharedState == .unavailable(.thisMac(MLXDecisionBackend.needsMemory))) && !sharedStarts && !sharedDiffer
                  && sharedRefused && sharedIdentity == nil && withoutFolder.meantFor == nil,
                  "with no folder, the real backend says so, has no identity, refuses a decision, and nothing is suggested or started: \(sharedState)")
            check(sharedWhy == "Tev1 0.8B can't sort cards now", "and why nothing starts says so: \(sharedWhy ?? "nothing")")
            check(await !shared.startedMLX, "and nothing the router or Settings did called MLX")
            check(router.titlesRead == readsBeforeShared, "nor read a binder's titles: \(router.titlesRead - readsBeforeShared) reads")
            router.override = nil
        } else {
            check(realModels.backend == nil && !MLXModels.isSupported, "an Intel Mac makes no MLX backend at all")
        }

        // MARK: The backend's failures, without the model
        let broken = folder.appendingPathComponent("broken-model", isDirectory: true)
        try? manager.createDirectory(at: broken, withIntermediateDirectories: true)
        try? #"{"model_type": "qwen3_5", "text_config": {"tie_word_embeddings": true, "vocab_size": 248320}}"#.write(to: broken.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try? "{}".write(to: broken.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        var header = Data(#"{"w": {"dtype": "BF16", "shape": [524288], "data_offsets": [0, 1048576]}}"#.utf8)
        while (8 + header.count) % 8 != 0 { header.append(0x20) }
        var weights = Data()
        var length = UInt64(header.count).littleEndian
        withUnsafeBytes(of: &length) { weights.append(contentsOf: $0) }
        weights.append(header)
        weights.append(Data(repeating: 0, count: 1_024 - weights.count))
        try? weights.write(to: broken.appendingPathComponent("model.safetensors"))
        let real = MLXDecisionBackend(folder: broken, kind: .tev1, marker: folder.appendingPathComponent("router-running-broken"))
        let brokenState = await real.state()
        check(brokenState == .unavailable(.folder("model.safetensors is shorter than its header says: 0 of 1 MB")),
              "a 1 KB model.safetensors whose header claims 1 MB is refused before MLX reads it: \(brokenState)")
        do {
            _ = try await real.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(5))
            check(false, "a decision on it is refused")
        } catch {
            check(true, "a decision on it is refused: \(error.localizedDescription)")
        }
        check(await !real.startedMLX, "a folder refused before loading never starts MLX")
        let markerURL = folder.appendingPathComponent("router-running-test")
        try? Data("decide".utf8).write(to: markerURL)
        let crashed = MLXDecisionBackend(folder: broken, kind: .tev1, marker: markerURL)
        check(await crashed.state() == .failed(MLXDecisionBackend.markerFound), "with the marker left by a crash, a new backend starts failed")
        try? "{\"changed\": true}".write(to: broken.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        check(await crashed.state() == .failed(MLXDecisionBackend.markerFound), "and a change to the folder doesn't clear the marker's failure: only Try Again does")
        await crashed.tryAgain()
        check(await crashed.state() != .failed(MLXDecisionBackend.markerFound) && !manager.fileExists(atPath: markerURL.path), "and Try Again clears it")
        // A quit isn't a crash: a marker that a quit marked counts for nothing at the next launch.
        try? Data("decide quit".utf8).write(to: markerURL)
        let afterQuit = MLXDecisionBackend(folder: broken, kind: .tev1, marker: markerURL)
        let afterQuitState = await afterQuit.state()
        check(afterQuitState != .failed(MLXDecisionBackend.markerFound) && !manager.fileExists(atPath: markerURL.path),
              "a marker a quit marked (“decide quit”) counts for nothing: the next launch's backend isn't failed, and the marker is gone: \(afterQuitState)")

        // A folder that passes Binders' own checks, for loads by a stand-in: MLX only for the cache cap each load starts
        // with, never a model.
        func loadable(_ name: String, config: String = #"{"model_type": "qwen3_5", "text_config": {"tie_word_embeddings": true, "vocab_size": 248320}}"#) -> URL {
            let place = folder.appendingPathComponent("models-\(UUID().uuidString.prefix(8))", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            try? manager.createDirectory(at: place, withIntermediateDirectories: true)
            try? config.write(to: place.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
            try? "{}".write(to: place.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
            var header = Data(#"{"w": {"dtype": "BF16", "shape": [4], "data_offsets": [0, 8]}}"#.utf8)
            while header.count % 8 != 0 { header.append(0x20) }
            var weights = Data()
            var length = UInt64(header.count).littleEndian
            withUnsafeBytes(of: &length) { weights.append(contentsOf: $0) }
            weights.append(header)
            weights.append(Data(repeating: 0, count: 8))
            try? weights.write(to: place.appendingPathComponent("model.safetensors"))
            return place
        }
        // Their tokenizer.json isn't one the folder check could read, so a stand-in gives its answer for Tev1's family (A
        // to X at 32 to 55), and the checks below reach the loads they're about. The real check is held further down, on
        // folders with a whole tokenizer.
        let tev1Check: MLXDecisionBackend.Checker = { _, reader in
            reader == .tev1 ? .passed(letters: Array(32...55), frame: nil) : .refused("not Tev1's family", .folder)
        }
        let kept = FolderFingerprints(url: folder.appendingPathComponent("router-test-backend-fingerprints.json"))
        // Its config.json must be the conversion its folder's name says: a 4-bit conversion copied in under the bf16 name,
        // chosen as Tev1 0.8B, is refused before MLX, though its bands would go by its fingerprint.
        let quantized = loadable(MLXDecisionBackend.tev1FolderName, config: #"{"model_type": "qwen3_5", "quantization": {"group_size": 64, "bits": 4, "mode": "affine"}, "text_config": {"tie_word_embeddings": true, "vocab_size": 248320}}"#)
        let quantizedBackend = MLXDecisionBackend(folder: quantized, kind: .tev1, needsFree: 0, marker: folder.appendingPathComponent("router-running-quantized"),
                                                  fingerprints: kept, checker: tev1Check)
        let quantizedState = await quantizedBackend.state(), quantizedMLX = await quantizedBackend.startedMLX
        check(quantizedState == .unavailable(.folder("its config.json says it's a 4-bit conversion, not the bf16 one its folder is named for")) && !quantizedMLX,
              "a quantized conversion copied in as \(MLXDecisionBackend.tev1FolderName) and chosen as Tev1 0.8B is refused: \(quantizedState)")
        check(MLXDecisionBackend.problem(in: loadable(MLXDecisionBackend.tev1FolderName)) == nil, "the bf16 one, with no quantization, passes")
        let eightBit: [String: Any] = ["quantization": ["bits": 8]]
        check(MLXDecisionBackend.conversionMismatch(config: eightBit, folderName: "tev1-0.8b-mlx-8bit") == nil
              && MLXDecisionBackend.conversionMismatch(config: eightBit, folderName: "tev1-0.8b-mlx-4bit") != nil
              && MLXDecisionBackend.conversionMismatch(config: [:], folderName: "tev1-0.8b-mlx-8bit") != nil
              && MLXDecisionBackend.conversionMismatch(config: eightBit, folderName: "router-truncated") == nil,
              "an 8-bit or 4-bit name must hold those bits, and a name that says neither is taken as it is")
        // Chosen as Tev1 0.8B, a folder of another family is refused with lane R1's words; chosen as a folder, it takes the
        // chat reader.
        let llamaFolder = loadable("pocketfold-decider", config: #"{"model_type": "llama"}"#)
        let asTev1 = MLXDecisionBackend.problem(in: llamaFolder, kind: .tev1), asFolder = MLXDecisionBackend.preflight(llamaFolder, kind: .folder, stamp: "")
        check(asTev1 == "it isn't a Tev1 0.8B conversion (model_type)" && asFolder.problem == nil && asFolder.reader == .chat
              && MLXDecisionBackend.preflight(loadable("tev1-copy"), kind: .folder, stamp: "").reader == .tev1,
              "a folder of another family chosen as Tev1 0.8B is refused; chosen as a folder it's read through its chat template, and a copy of Tev1's family as Tev1")
        // What isn't a model, isn't there, or isn't downloaded yet.
        let readmeOnly = folder.appendingPathComponent("models-readme/notes-only", isDirectory: true)
        try? manager.createDirectory(at: readmeOnly, withIntermediateDirectories: true)
        try? "notes".write(to: readmeOnly.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let notModel = await MLXDecisionBackend(folder: readmeOnly, kind: .folder, marker: folder.appendingPathComponent("router-running-readme")).state()
        let gone = await MLXDecisionBackend(folder: folder.appendingPathComponent("models-gone/never-here", isDirectory: true), kind: .folder,
                                            marker: folder.appendingPathComponent("router-running-gone")).state()
        let notYet = await MLXDecisionBackend(folder: folder.appendingPathComponent("Models/MLX/local--not-yet", isDirectory: true), kind: .downloaded,
                                              marker: folder.appendingPathComponent("router-running-not-yet")).state()
        let tev1Gone = await MLXDecisionBackend(folder: readmeOnly, kind: .tev1, marker: folder.appendingPathComponent("router-running-tev1-gone")).state()
        check(notModel == .unavailable(.folder(MLXDecisionBackend.noModel)) && gone == .unavailable(.noFolder) && notYet == .unavailable(.notDownloaded)
              && tev1Gone == .unavailable(.noFolder),
              "a folder chosen with no model in it, one that's gone, a download not there yet, and Tev1's folder without its model each say so: \(notModel), \(gone), \(notYet)")
        // A model more than a quarter of this Mac's memory is refused before anything reads it (a sparse file: no space).
        let huge = loadable("huge-model")
        let hugeWeights = huge.appendingPathComponent("model.safetensors")
        let hugeSize = Int64(ProcessInfo.processInfo.physicalMemory / 4) + 1_073_741_824
        _ = truncate(hugeWeights.path, off_t(hugeSize))
        let hugeState = await MLXDecisionBackend(folder: huge, kind: .folder, marker: folder.appendingPathComponent("router-running-huge")).state()
        try? manager.removeItem(at: hugeWeights)
        check(hugeState == .unavailable(.thisMac(MLXDecisionBackend.tooBig(hugeSize, memory: ProcessInfo.processInfo.physicalMemory))),
              "a model over a quarter of this Mac's memory is refused before anything reads it: \(hugeState)")
        // The same with its weights a link to the file elsewhere, as a Hugging Face cache snapshot has them, and with
        // tokenizer.json a link to one over 64 MB: the sizes are the files', not the links' few bytes.
        let linked = loadable("huge-linked")
        let linkedWeights = linked.appendingPathComponent("model.safetensors"), linkedTokenizer = linked.appendingPathComponent("tokenizer.json")
        let blobs = linked.deletingLastPathComponent().appendingPathComponent("blobs", isDirectory: true)
        try? manager.createDirectory(at: blobs, withIntermediateDirectories: true)
        let hugeBlob = blobs.appendingPathComponent("weights"), bigTokenizer = blobs.appendingPathComponent("tokenizer")
        let weightsSize = MLXModels.fileSize(linkedWeights) ?? 0
        try? manager.moveItem(at: linkedWeights, to: hugeBlob)
        _ = truncate(hugeBlob.path, off_t(hugeSize))
        try? manager.createSymbolicLink(at: linkedWeights, withDestinationURL: hugeBlob)
        let linkedState = await MLXDecisionBackend(folder: linked, kind: .folder, marker: folder.appendingPathComponent("router-running-huge-linked")).state()
        try? manager.removeItem(at: linkedWeights)
        try? manager.moveItem(at: hugeBlob, to: linkedWeights)
        _ = truncate(linkedWeights.path, off_t(weightsSize))
        try? manager.moveItem(at: linkedTokenizer, to: bigTokenizer)
        _ = truncate(bigTokenizer.path, off_t(DecisionFolderCheck.maxTokenizer + 1))
        try? manager.createSymbolicLink(at: linkedTokenizer, withDestinationURL: bigTokenizer)
        let linkedTokenizerProblem = MLXDecisionBackend.preflight(linked, kind: .folder, stamp: "").problem
        let linkedTokenizerChecked = await DecisionFolderCheck.checked(linked, reader: .chat,
                                                                      fingerprints: FolderFingerprints(url: folder.appendingPathComponent("router-test-linked-fingerprints.json")))
        try? manager.removeItem(at: blobs)
        check(linkedState == .unavailable(.thisMac(MLXDecisionBackend.tooBig(hugeSize, memory: ProcessInfo.processInfo.physicalMemory)))
              && linkedTokenizerProblem == .folder("its tokenizer.json is over 64 MB") && linkedTokenizerChecked == .refused("its tokenizer.json is over 64 MB", .folder)
              && weightsSize > 0 && MLXModels.fileSize(linkedWeights) == weightsSize,
              "weights or a tokenizer.json linked from elsewhere are measured by the file, not the link: \(linkedState), \(String(describing: linkedTokenizerProblem))")

        // Three loads that fail make it fail; a good copy of the folder put in its place clears that, and the next load runs.
        let flaky = loadable(MLXDecisionBackend.tev1FolderName)
        let failing = MLXDecisionBackend(folder: flaky, kind: .tev1, needsFree: 0, marker: folder.appendingPathComponent("router-running-flaky"),
                                         fingerprints: kept, checker: tev1Check) { _ in
            throw DecisionError.unavailable("tokenizer.json can't be read")
        }
        let untouched = await !failing.startedMLX
        for _ in 0..<3 { _ = try? await failing.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(5)) }
        let failedState = await failing.state(), failedLoads = await failing.loadsBegun
        check(failedState == .failed("tokenizer.json can't be read") && failedLoads == 3, "three loads that fail make it fail: \(failedState), \(failedLoads) loads")
        let startedByLoad = await failing.startedMLX
        check(untouched && startedByLoad, "a load is where MLX starts, with its cache cap inside the guard, and not before")
        try? "{\"copied\": \"again\"}".write(to: flaky.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        let copiedState = await failing.state()
        _ = await failing.identity(by: .now + .seconds(5))
        let rechecked = await failing.state()
        check(copiedState == .checking && rechecked.isUsable,
              "and a change to its folder clears that, with no Try Again: its new files are checked, then it's usable: \(copiedState), \(rechecked)")
        _ = try? await failing.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(5))
        let loadsAfter = await failing.loadsBegun
        check(loadsAfter == 4, "so the next card loads it again: \(loadsAfter) loads")

        // Which model a folder holds: its fingerprint, worked out without MLX, and answers only from the files its bands
        // are for.
        let identified = MLXDecisionBackend(folder: loadable(MLXDecisionBackend.tev1FolderName), kind: .tev1, needsFree: 0,
                                            marker: folder.appendingPathComponent("router-running-identity"),
                                            fingerprints: FolderFingerprints(url: folder.appendingPathComponent("router-test-identity-fingerprints.json")),
                                            checker: tev1Check) { _ in
            throw DecisionError.unavailable("the stand-in load ended")
        }
        let identity = await identified.identity(by: .now + .seconds(5))
        let mlxForIdentity = await identified.startedMLX
        check(identity?.fingerprint.hasPrefix("mlx1-") == true && identity?.reader == "tev1.1/256" && identity?.fingerprint != DecisionBands.tev1BF16.fingerprint
              && !mlxForIdentity,
              "a Tev1-family folder's identity is its fingerprint, read as tev1.1/256, worked out without MLX: \(identity?.key ?? "none")")
        let otherFiles = DecisionIdentity(fingerprint: "mlx1-000000000000000000000000", reader: "tev1.1/256")
        var refusedOther = false
        do {
            _ = try await identified.decide([RouterQuestions.warmUps[0]], expecting: otherFiles, by: .now + .seconds(2))
        } catch DecisionError.changed {
            refusedOther = true
        } catch {}
        let loadsBeforeOwn = await identified.loadsBegun
        _ = try? await identified.decide([RouterQuestions.warmUps[0]], expecting: identity, by: .now + .seconds(2))
        let loadsAfterOwn = await identified.loadsBegun
        check(refusedOther && loadsBeforeOwn == 0 && loadsAfterOwn == 1,
              "a decision expecting another model's files is refused before any load; one expecting its own begins its load")

        // A load past its limit: the router stops for the launch, no second load starts beside the one still going, and
        // the marker stays until that one has really ended.
        let slowMarker = folder.appendingPathComponent("router-running-slow")
        let slow = MLXDecisionBackend(folder: loadable(MLXDecisionBackend.tev1FolderName), kind: .tev1, loadLimit: 0.3, needsFree: 0, marker: slowMarker,
                                      fingerprints: kept, checker: tev1Check) { _ in
            try await Task.sleep(for: .seconds(1.5))
            throw DecisionError.unavailable("the stand-in load ended")
        }
        _ = await slow.identity(by: .now + .seconds(5))
        let slowStarted = Date()
        do {
            _ = try await slow.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(5))
            check(false, "a load past its limit is given up on")
        } catch {
            check(Date().timeIntervalSince(slowStarted) < 1.2, "a load past its limit is given up on at the limit: \(error.localizedDescription)")
        }
        let overState = await slow.state()
        check(overState == .failed("it took more than 0.3 seconds to load") && manager.fileExists(atPath: slowMarker.path),
              "the router stops for the launch, and the marker stays while the load goes on: \(overState)")
        await slow.tryAgain()
        _ = try? await slow.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(5))
        let againState = await slow.state(), slowLoads = await slow.loadsBegun
        check(againState == .failed(MLXDecisionBackend.stillRunningWhy) && slowLoads == 1 && manager.fileExists(atPath: slowMarker.path),
              "Try Again meanwhile starts no second load beside it, and leaves its marker: \(againState), \(slowLoads) loads")
        for _ in 0..<40 where manager.fileExists(atPath: slowMarker.path) { try? await Task.sleep(for: .milliseconds(100)) }
        let endedState = await slow.state()
        check(!manager.fileExists(atPath: slowMarker.path) && endedState.isUsable, "once it has really ended, the marker goes, and the next card may load it: \(endedState)")

        // Retired means nothing starts, with the real backend: a load under way when it's switched away from goes on (MLX
        // can't be interrupted) and is dropped when it ends; meanwhile a decision is refused at once and begins no load;
        // revived, the next decision loads again.
        let retiring = MLXDecisionBackend(folder: loadable("retiring-model"), kind: .folder, needsFree: 0, marker: folder.appendingPathComponent("router-running-retiring"),
                                          fingerprints: kept, checker: tev1Check) { _ in
            try await Task.sleep(for: .seconds(0.5))
            throw DecisionError.unavailable("the stand-in load ended")
        }
        let retiringFirst = Task { try? await retiring.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(5)) }
        for _ in 0..<300 {
            if await retiring.loadsBegun > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await retiring.retire()
        let askedRetired = ContinuousClock.now
        var refusedRetired = false
        do {
            _ = try await retiring.decide([RouterQuestions.warmUps[1]], expecting: nil, by: .now + .seconds(5))
        } catch DecisionError.retired {
            refusedRetired = true
        } catch {}
        let refusedIn = askedRetired.duration(to: .now)
        let loadsWhileRetired = await retiring.loadsBegun
        _ = await retiringFirst.value
        let landedHeld = await retiring.hasContainer, landedLoading = await retiring.isLoading, loadsAfterLanding = await retiring.loadsBegun
        await retiring.revive()
        _ = try? await retiring.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(5))
        let loadsRevived = await retiring.loadsBegun
        check(refusedRetired && refusedIn < .milliseconds(100) && loadsWhileRetired == 1 && !landedHeld && !landedLoading && loadsAfterLanding == 1
              && loadsRevived == 2,
              "retired during a load: a decision is refused at once and begins none, the load is dropped when it ends, and once revived the next decision loads again")

        // A quit during a load: the marker is marked as a quit after its step, and the next launch passes over it; a crash's
        // marker ("decide") still starts it failed, as above.
        let quitMarker = folder.appendingPathComponent("router-running-quitting")
        let quitFolder = loadable("quitting-model")
        let quitter = MLXDecisionBackend(folder: quitFolder, kind: .folder, needsFree: 0, marker: quitMarker, fingerprints: kept, checker: tev1Check) { _ in
            try await Task.sleep(for: .seconds(0.5))
            throw DecisionError.unavailable("the stand-in load ended")
        }
        let quitDecide = Task { try? await quitter.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(5)) }
        for _ in 0..<300 {
            if await quitter.loadsBegun > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let quitStarted = ContinuousClock.now
        await quitter.prepareForQuit(within: .milliseconds(200))
        let quitTook = quitStarted.duration(to: .now)
        let quitText = (try? Data(contentsOf: quitMarker)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let nextLaunch = MLXDecisionBackend(folder: quitFolder, kind: .folder, needsFree: 0, marker: quitMarker, fingerprints: kept, checker: tev1Check)
        let nextState = await nextLaunch.state()
        let quitMarkerGone = !manager.fileExists(atPath: quitMarker.path)
        _ = await quitDecide.value
        var quitRefuses = false
        do {
            _ = try await quitter.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(2))
        } catch DecisionError.retired {
            quitRefuses = true
        } catch {}
        check(quitText == "load quit" && quitTook < .milliseconds(450) && quitMarkerGone && nextState != .failed(MLXDecisionBackend.markerFound) && quitRefuses,
              "a quit during a load waits at most its time, marks the marker “load quit”, and refuses new work; the next launch isn't failed and the marker is gone: \(quitText), \(nextState)")

        // A weight index naming a file outside the folder's top level is refused, so every weight the loader can read is
        // one the fingerprint and the header check cover.
        let indexed = loadable("indexed-model")
        try? manager.createDirectory(at: indexed.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try? manager.copyItem(at: indexed.appendingPathComponent("model.safetensors"), to: indexed.appendingPathComponent("sub/model.safetensors"))
        try? #"{"metadata": {}, "weight_map": {"w": "sub/model.safetensors"}}"#.write(to: indexed.appendingPathComponent("model.safetensors.index.json"),
                                                                                         atomically: true, encoding: .utf8)
        let indexedBackend = MLXDecisionBackend(folder: indexed, kind: .folder, needsFree: 0, marker: folder.appendingPathComponent("router-running-indexed"),
                                                fingerprints: kept, checker: tev1Check)
        let indexedState = await indexedBackend.state()
        let indexedRefused = (try? await indexedBackend.decide([RouterQuestions.warmUps[0]], by: .now + .seconds(2))) == nil
        let indexedMLX = await indexedBackend.startedMLX
        check(indexedState == .unavailable(.folder("its model.safetensors.index.json puts weights in sub/model.safetensors, outside the folder's top level, and Binders only uses a model whose weights are all beside its config.json"))
              && indexedRefused && !indexedMLX,
              "a weight index naming sub/model.safetensors is refused with the design's words, and MLX never starts: \(indexedState)")

        // A model type this Binders can't build is refused once the folder check has passed, before any load.
        let unknownFrame = ChatFrame(before: "<|im_start|>system\n", between: "<|im_end|>\n<|im_start|>user\n", after: "<|im_end|>\n<|im_start|>assistant\n")
        let unknown = MLXDecisionBackend(folder: loadable("unknown-kind-model", config: #"{"model_type": "binders_nonsense"}"#), kind: .folder, needsFree: 0,
                                         marker: folder.appendingPathComponent("router-running-unknown"), fingerprints: kept,
                                         checker: { _, _ in .passed(letters: Array(32...55), frame: unknownFrame) })
        let unknownIdentity = await unknown.identity(by: .now + .seconds(5))
        let unknownState = await unknown.state(), unknownLoads = await unknown.loadsBegun, unknownMLX = await unknown.startedMLX
        check(unknownState == .unavailable(.cantAnswer("its model type, binders_nonsense, isn't one this Binders can run")) && unknownIdentity == nil
              && unknownLoads == 0 && !unknownMLX,
              "a model type this Binders can't build can't sort cards, and nothing loads: \(unknownState)")

        // Whether anything can start, through DecisionModels: Settings says so beside the start switch.
        let canStart = await models.startsPossible(), noReason = await models.whyNoStarts()
        check(canStart && noReason == nil, "with the model here and its numbers as checked, an agent can start: \(noReason ?? "no reason against")")
        standIn.matches = false
        let differStarts = await models.startsPossible(), differWhy = await models.whyNoStarts()
        check(!differStarts && differWhy == "Tev1 0.8B's numbers on this Mac differ from the ones it was measured with",
              "not when its numbers differ: \(differWhy ?? "no reason")")
        standIn.matches = true
        standIn.usable = false
        let missingStarts = await models.startsPossible(), missingWhy = await models.whyNoStarts()
        check(!missingStarts && missingWhy == "Tev1 0.8B can't sort cards now", "nor without the model: \(missingWhy ?? "no reason")")
        standIn.usable = true
        check(RouterStatusSection.meanwhile.contains("with an agent suggested only when you name one"), "and without it, the status row says what happens meanwhile")
        // MLX itself, on Apple silicon only: the self-test's own call, never the router's.
        if MLXModels.isSupported {
            do {
                try MLXDecisionBackend.failingStep()
                check(false, "an MLX error inside the guard throws")
            } catch DecisionError.mlx(let message) {
                check(!message.isEmpty, "an MLX error inside the guard throws DecisionError.mlx, and Binders goes on: \(message.prefix(60))")
            } catch {
                check(false, "an MLX error inside the guard throws DecisionError.mlx: \(error)")
            }
        } else {
            print("INFO: no MLX on this Mac, so the guard isn't tried")
        }
        standIn.hang = true
        router.budget = .milliseconds(300)
        let started = Date()
        standIn.set("Fix the login page", agent: ["Scribe": 0.99])
        let late = board.create(title: "Fix the login page", binderID: website.id, column: .ready, by: .you)
        await router.routeCard(late.id, title: "Fix the login page", origin: .typedReady)
        check(Date().timeIntervalSince(started) < 2 && late.meantFor == nil, "a stand-in that never answers: the card goes on at its deadline, with no agent")
        try? await Task.sleep(for: .milliseconds(400))
        check(late.meantFor == nil, "and its late answer changes nothing")
        standIn.hang = false
        router.budget = .seconds(3)

        // MARK: The decision model chosen (DecisionModels)
        // Off: no backend, so nothing is asked and the router goes on as it does without a model.
        let askedBeforeOff = standIn.asked.count
        models.choose(.off)
        await models.settled()
        let offCard = await typed("Fix the sitemap's dates", into: .ready, agent: ["Scribe": 0.99])
        let openForOff = store.binder(AppSettings.shared.currentBinderID) ?? general
        await controller.command(heard: "Add to-do fix the press kit link")
        let pressKit = store.commitments().first { $0.task.localizedCaseInsensitiveContains("press kit") }
        let offPrompt = controller.flowBar.model.display == .prompt
        controller.flowBar.hide()
        let offStarts = await models.startsPossible(), offWhy = await models.whyNoStarts()
        check(models.backend == nil && offCard.meantFor == nil && !board.timeline(offCard.id).contains { $0.kind == .woke } && pressKit?.binderID == openForOff.id
              && !offPrompt && standIn.asked.count == askedBeforeOff && standIn.retired && standIn.retires == 1,
              "Off: a card typed into Ready gets no suggestion and no start, Command Mode's to-do goes in the open binder, nothing is asked, and Tev1's backend was retired")
        // Device check 4's card names its agent: still suggested for it ("you named it"), and it never starts.
        let namedOff = await typed("Have Scribe fix the sitemap's links", into: .ready, agent: ["Scribe": 0.99])
        log.flush()
        let namedOffLine = log.entries().last { $0.card == namedOff.id }
        check(namedOff.meantFor == "Scribe" && !board.timeline(namedOff.id).contains { $0.kind == .woke } && standIn.asked.count == askedBeforeOff,
              "Off: a card that names its agent is still suggested for it, asks nothing and never starts: \(namedOffLine?.whyNotStarted ?? "no line")")
        check(!offStarts && offWhy == "the decision model is off", "and nothing can start: \(offWhy ?? "no reason")")
        let offRow = DecisionModelText.rowA(models.choice, state: nil, stored: "off", appleSilicon: true)
        check(offRow.line == "Off. Binders sorts as it does without a decision model: " + RouterStatusSection.meanwhile
              && DecisionModelText.sortingModel(models.choice, state: nil) == "No decision model: Binders sorts new cards without one."
              && DecisionModelText.sortingStarts(canStart: offStarts, why: offWhy, differ: false).line == "No agent starts on its own now: the decision model is off.",
              "and Settings says so: row A's Off line, Sorting new cards' line and its starts line")
        models.choose(.tev1)
        await models.settled()
        let afterOff = await models.bands(by: .now + .seconds(2))
        check(models.backend === standIn && !standIn.retired && standIn.revives == 1 && afterOff?.source == .builtIn,
              "choosing Tev1 0.8B again gives the same backend back, revived, with its built-in bands")

        // A folder chosen, measured and not: its bands are its own measure's, and its warm-ups are held to that measure's.
        let deciderPath = folder.appendingPathComponent("models-decider/Pocketfold Decider", isDirectory: true).path
        let decider = RouterStandIn()
        decider.identity = DecisionIdentity(fingerprint: "mlx1-0123456789abcdef01234567", reader: DecisionReader.chat.id)
        decider.warmUpValues = [[0.6, 0.3, 0.1], [0.7, 0.2, 0.1], [0.2, 0.5, 0.3]]
        standIns.byChoice[.folder(deciderPath)] = decider
        func measureDecider() {
            models.measures.keep(DecisionMeasure(key: decider.identity.key, fingerprint: decider.identity.fingerprint, reader: decider.identity.reader,
                                                 at: Date(), golden: decider.warmUpValues,
                                                 bands: .init(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33)))
        }
        measureDecider()
        models.choose(.folder(deciderPath))
        let measuredStart = await typed("Fix the hero image's alt text", into: .ready, agent: ["Scribe": 0.98])
        log.flush()
        let measuredLine = log.entries().last { $0.card == measuredStart.id }
        check(board.timeline(measuredStart.id).contains { $0.kind == .woke } && measuredLine?.did == "started" && measuredLine?.bands == "measured"
              && measuredLine?.model == decider.identity.fingerprint && measuredLine?.backend == "chat.1/256" && decider.goldenGiven == decider.warmUpValues,
              "a folder with a measure for its key (start 0.97) and its goldens: a card at 0.98 starts, by its measure's bands (\(measuredLine?.bands ?? "none"))")
        let warmUpsKept = decider.warmUpValues
        decider.warmUpValues[1][0] += 0.003
        let differing = await typed("Fix the hero image's caption", into: .ready, agent: ["Scribe": 0.98])
        log.flush()
        let differLine = log.entries().last { $0.card == differing.id }
        let deciderDiffers = await decider.numbersDiffer(), deciderWhy = await models.whyNoStarts()
        check(!board.timeline(differing.id).contains { $0.kind == .woke } && differing.meantFor == "Scribe" && differLine?.whyNotStarted == "numbers differ"
              && deciderDiffers && deciderWhy == "Pocketfold Decider's numbers on this Mac differ from the ones it was measured with",
              "with one warm-up 0.003 off its measure's, it's suggested (numbers differ), and its numbers are said to differ: \(deciderWhy ?? "no reason")")
        let differRowF = DecisionModelText.rowF(models.resolved, differ: deciderDiffers)
        let differingStarts = DecisionModelText.sortingStarts(canStart: false, why: deciderWhy, differ: deciderDiffers)
        check(differRowF == "Its numbers on this Mac differ from the ones it was measured with, so it names agents but starts none on its own. Measure it on this Mac to start agents again."
              && differingStarts.needsYou && models.resolved?.source != .builtIn,
              "and Settings → AI shows row F, and Sorting new cards' starts line needs you: \(differRowF ?? "no row F")")
        decider.warmUpValues = warmUpsKept
        models.measures.remove(fingerprint: decider.identity.fingerprint)
        let unmeasuredFolder = await typed("Fix the hero image's credit", into: .ready, agent: ["Scribe": 0.99])
        log.flush()
        let unmeasuredFolderLine = log.entries().last { $0.card == unmeasuredFolder.id }
        check(!board.timeline(unmeasuredFolder.id).contains { $0.kind == .woke } && unmeasuredFolder.meantFor == "Scribe"
              && unmeasuredFolderLine?.bands == "unmeasured" && unmeasuredFolderLine?.whyNotStarted == "backend has no start bar",
              "with no measure, 0.99 is suggested and never started")
        let neverDiffers = await decider.numbersDiffer(), neverWhy = await models.whyNoStarts()
        check(!neverDiffers && decider.goldenGiven == nil && neverWhy == "Pocketfold Decider hasn't been measured, and only a measured model starts agents",
              "a model with no measure has no golden, so its numbers never differ, however it warmed up: \(neverWhy ?? "no reason")")
        let neverStarts = DecisionModelText.sortingStarts(canStart: false, why: neverWhy, differ: neverDiffers)
        let neverMeasure = DecisionModelText.rowE(models.resolved)
        check(DecisionModelText.rowF(models.resolved, differ: neverDiffers) == nil && !neverStarts.needsYou
              && neverStarts.line == "No agent starts on its own now: Pocketfold Decider hasn't been measured, and only a measured model starts agents."
              && neverMeasure?.line.hasPrefix("Not measured yet: it names agents on Give to and starts none on its own.") == true && neverMeasure?.button == "Measure",
              "a loaded model never measured: no row F, Sorting new cards' starts line is plain, and row E offers Measure")

        // Why nothing starts, for each kind of measure that found no start level, and a server whose probes moved.
        func decidedWhy(_ noStart: DecisionMeasure.NoStart) async -> String? {
            models.measures.keep(DecisionMeasure(key: decider.identity.key, fingerprint: decider.identity.fingerprint, reader: decider.identity.reader,
                                                 at: Date(), golden: decider.warmUpValues,
                                                 bands: .init(start: nil, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33), noStart: noStart))
            return await models.whyNoStarts()
        }
        let noLevelWhy = await decidedWhy(.noLevel), severalWhy = await decidedWhy(.severalModels)
        check(noLevelWhy == "Pocketfold Decider's measure found no level at which it started only the right agents, often enough to trust"
              && severalWhy == "Pocketfold Decider answered with more than one model when it was measured",
              "a measure that found no start level says why nothing starts: \(noLevelWhy ?? "none"); \(severalWhy ?? "none")")
        models.measures.remove(fingerprint: decider.identity.fingerprint)
        let serverAddress = "http://127.0.0.1:18708"
        let serverStandIn = RouterStandIn()
        let measuredServer = DecisionIdentity.Server(address: serverAddress, names: ["kev-latest"], fields: ["run=runs/kev-0.8b"], answeredBy: [],
                                                     probes: [[0.6, 0.4], [0.7, 0.3], [0.2, 0.8]])
        var movedServer = measuredServer
        movedServer.probes[1] = [0.4, 0.6]
        serverStandIn.identity = DecisionIdentity(server: movedServer)
        standIns.byChoice[.server(serverAddress)] = serverStandIn
        models.measures.keep(DecisionMeasure(key: DecisionIdentity(server: measuredServer).key, fingerprint: DecisionIdentity(server: measuredServer).fingerprint,
                                             reader: DecisionReader.jev.id, server: measuredServer, at: Date(), golden: measuredServer.probes,
                                             bands: .init(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33)))
        models.choose(.server(serverAddress))
        let movedWhy = await models.whyNoStarts()
        check(movedWhy == "Server at 127.0.0.1:18708's answers differ from when it was measured" && models.resolved?.source == .unmeasured,
              "a server Binders measured whose probes now answer as another model starts nothing, and says so: \(movedWhy ?? "none")")
        models.measures.remove(fingerprint: DecisionIdentity(server: measuredServer).fingerprint)

        // Switching takes effect on the next card.
        measureDecider()
        models.choose(.tev1)
        let switchFirst = await typed("Fix the newsletter's footer", into: .ready, agent: ["Scribe": 0.99])
        let retiresBeforeSwitch = standIn.retires
        models.choose(.folder(deciderPath))
        await models.settled()
        let askedOfTev1 = standIn.asked.count
        let switchSecond = await typed("Fix the newsletter's header", into: .ready, agent: ["Scribe": 0.99])
        log.flush()
        let firstLine = log.entries().last { $0.card == switchFirst.id }, secondLine = log.entries().last { $0.card == switchSecond.id }
        check(firstLine?.did == "started" && secondLine?.did == "started" && standIn.retires == retiresBeforeSwitch + 1 && standIn.asked.count == askedOfTev1
              && decider.asked.contains { $0.state == "Fix the newsletter's header" } && firstLine?.model == DecisionBands.tev1BF16.fingerprint
              && secondLine?.model == decider.identity.fingerprint,
              "switching takes effect on the next card: card 1 to Tev1 0.8B starts, the switch retires it, card 2 is asked of the new model alone, "
              + "and the log names each card's model (\(firstLine?.model ?? "none"), then \(secondLine?.model ?? "none"))")
        // A card asked of Tev1 0.8B while the switch happens keeps Tev1's answer and bands, and isn't started.
        models.choose(.tev1)
        standIn.delay = .milliseconds(300)
        let midTitle = "Fix the newsletter's sign-up link"
        for answering in [standIn, decider] { answering.set(midTitle, agent: ["Scribe": 0.99]) }
        let midCard = board.create(title: midTitle, binderID: website.id, column: .ready, by: .you)
        let midID = midCard.id
        let midRoute = Task { await router.routeCard(midID, title: midTitle, origin: .typedReady) }
        for _ in 0..<200 where !standIn.asked.contains(where: { $0.state == midTitle }) { try? await Task.sleep(for: .milliseconds(10)) }
        models.choose(.folder(deciderPath))
        await midRoute.value
        standIn.delay = .zero
        log.flush()
        let midLine = log.entries().last { $0.card == midID }
        check(!board.timeline(midID).contains { $0.kind == .woke } && midCard.meantFor == "Scribe" && midCard.meantForByAgent
              && midLine?.model == DecisionBands.tev1BF16.fingerprint && midLine?.bands == "built-in" && midLine?.whyNotStarted == "the decision model changed"
              && !decider.asked.contains { $0.state == midTitle },
              "a card asked of Tev1 0.8B while the switch happens keeps its answer and its bands, and is suggested, not started: \(midLine?.whyNotStarted ?? "no reason")")
        // A card that took the backend into a local before the switch, and asks after it.
        models.choose(.tev1)
        await models.settled()
        let local = models.backend
        models.choose(.folder(deciderPath))
        await models.settled()
        let localAsked = ContinuousClock.now
        var localRetired = false
        do {
            _ = try await local?.decide([RouterQuestions.warmUps[1]], expecting: nil, by: .now + .seconds(2))
        } catch DecisionError.retired {
            localRetired = true
        } catch {}
        check(local === standIn && localRetired && localAsked.duration(to: .now) < .milliseconds(100),
              "a card that took Tev1's backend before the switch and asks after it is refused at once: the decision model changed")
        let revivesBeforeAgain = standIn.revives
        models.choose(.tev1)
        await models.settled()
        check(models.backend === standIn && !standIn.retired && standIn.revives == revivesBeforeAgain + 1,
              "and choosing Tev1 0.8B again gives the same backend, revived")

        // Bands are kept per fingerprint: a measured model, then one with no measure, then the first again.
        let downloaded = RouterStandIn(), another = RouterStandIn()
        downloaded.identity = DecisionIdentity(fingerprint: "mlx1-00112233445566778899aabb", reader: DecisionReader.chat.id)
        downloaded.warmUpValues = [[0.5, 0.5], [0.8, 0.2], [0.3, 0.7]]
        another.identity = DecisionIdentity(fingerprint: "mlx1-ffeeddccbbaa998877665544", reader: DecisionReader.chat.id)
        let downloadedChoice = DecisionChoice.huggingFace("local/pocketfold-decider"), anotherChoice = DecisionChoice.huggingFace("local/other-decider")
        standIns.byChoice[downloadedChoice] = downloaded
        standIns.byChoice[anotherChoice] = another
        let downloadedMeasure = DecisionMeasure(key: downloaded.identity.key, fingerprint: downloaded.identity.fingerprint, reader: downloaded.identity.reader,
                                                at: Date(), golden: downloaded.warmUpValues,
                                                bands: .init(start: 0.98, suggest: 0.55, generalBelow: 0.40, generalBelowTitlesOnly: 0.30))
        models.measures.keep(downloadedMeasure)
        var keptBands: [ResolvedBands?] = []
        for choice in [downloadedChoice, anotherChoice, downloadedChoice] {
            models.choose(choice)
            keptBands.append(await models.bands(by: .now + .seconds(2)))
        }
        check(keptBands[0]?.bands.start == 0.98 && keptBands[0]?.bands.suggest == 0.55 && keptBands[2]?.bands == keptBands[0]?.bands
              && keptBands[1]?.source == .unmeasured && keptBands[1]?.bands == DecisionBands.unmeasured && models.backend === downloaded,
              "bands are kept per fingerprint: the measured model's own each time it's chosen, and the other's unmeasured between")
        let retiresBeforeDelete = downloaded.retires, revivesBeforeDelete = downloaded.revives
        await models.deleteDownloaded()
        let afterDelete = await models.bands(by: .now + .seconds(2))
        check(downloaded.retires == retiresBeforeDelete + 1 && downloaded.revives == revivesBeforeDelete + 1 && !downloaded.retired
              && models.measures.all.measure(for: downloaded.identity) == nil && afterDelete?.source == .unmeasured && models.choice == downloadedChoice,
              "Delete of a downloaded model retires it first, removes its measures, and the next resolve is unmeasured; the choice stays")
        // Kept again, for the record's Clear… and Delete all history below, which leave it.
        models.measures.keep(downloadedMeasure)
        models.choose(.tev1)
        await models.settled()
        // The starts above left their lines with Stop in the flow bar.
        controller.flowBar.hide()

        // MARK: Settings → AI → Decision model's lines (SelfTestDecisionSettings.swift)
        await decisionSettingsSelfTest(folder: folder, check: check)

        // MARK: A decision server on this Mac (SelfTestDecisionServer.swift)
        await decisionServerSelfTest(controller: controller, models: models, standIns: standIns, website: website, folder: folder, check: check)

        // MARK: The measure, through DecisionModels, over a stand-in
        await measureSelfTest(folder: folder, check: check)

        // MARK: Named agents
        standIn.set("Send the booth swag order to Pennant", agent: ["Pennant": 0.9])
        standIn.set("Send the booth swag order to Pennant", binder: ["Summit booth": 0.9])
        let swag = board.create(title: "Send the booth swag order to Pennant", binderID: booth.id, column: .backlog, by: .you)
        await router.routeCard(swag.id, title: swag.title, origin: .typedBacklog)
        check(swag.meantFor == nil && swag.binderID == booth.id
              && board.timeline(swag.id).contains { $0.text == "Pennant doesn't take cards from the Summit booth board, so Binders didn't suggest it. Change that in Settings → Agents." },
              "a named agent that doesn't take the binder's cards: no Give to, the binder stays, and the line says why")
        standIn.set("Send the booth swag order to Pennant for Summit booth", agent: ["Pennant": 0.9])
        let swagNamed = board.create(title: "Send the booth swag order to Pennant for Summit booth", binderID: booth.id, column: .backlog, by: .you)
        await router.routeCard(swagNamed.id, title: swagNamed.title, origin: .typedBacklog)
        check(swagNamed.meantFor == nil && board.timeline(swagNamed.id).contains { $0.text.hasPrefix("Pennant doesn't take cards from the Summit booth board") },
              "so does “…to Pennant for Summit booth”")
        // Add to Board from a to-do: a suggestion, never a start.
        let errand = controller.commitments.addSpoken("Fix the links on the about page", binderID: website.id, toast: false).commitment
        standIn.set("Fix the links on the about page", agent: ["Scribe": 0.99])
        if let item = Todos.find(errand.id.uuidString) {
            let made = board.create(from: item, column: .ready, binderID: website.id, by: .you)
            await router.routeCard(made.card.id, title: made.card.title, origin: .toBoard)
            check(made.card.meantFor == "Scribe" && made.card.meantForByAgent && !board.timeline(made.card.id).contains { $0.kind == .woke },
                  "Add to Board from a to-do: a suggestion, never a start, at 0.99 too")
        }
        let coachOff = await typed("Book the coach to the airport", agent: [:])
        check(coachOff.meantFor == nil, "a word that's only like an agent's name names no one")
        let namedHere = await typed("Have Scribe fix the header links", agent: ["nobody": 0.95])
        check(namedHere.meantFor == "Scribe" && board.timeline(namedHere.id).contains { $0.text == "Suggested for Scribe: you named it." },
              "an agent named in a card you typed is one you named, over Tev1's nobody")
        // Named while agents are paused: it takes Home's cards, so the line says why it can't now, never that it doesn't.
        registry.setPaused(true)
        let pausedNamed = board.create(title: "Ask Pennant to book the boiler service", binderID: home.id, column: .backlog, by: .you)
        await router.routeCard(pausedNamed.id, title: pausedNamed.title, origin: .typedBacklog)
        registry.setPaused(false)
        check(pausedNamed.meantFor == nil && board.timeline(pausedNamed.id).contains { $0.text == "Agents are paused, so Pennant can't take it now." }
              && !board.timeline(pausedNamed.id).contains { $0.text.contains("doesn't take") },
              "a named agent that takes the binder's cards, while agents are paused: no Give to, and the true reason: \(board.timeline(pausedNamed.id).map(\.text).suffix(1))")

        // MARK: Command Mode
        let phrase = VoiceCommands.parseTodo("Add to-do fix the login typo on the pricing page") ?? ""
        standIn.set(phrase, binder: ["Website": 0.93], agent: ["Scribe": 0.98])
        let toastsBefore = store.commitments().count
        let readsBeforeCommand = router.titlesRead
        await controller.command(heard: "Add to-do fix the login typo on the pricing page")
        let todo = store.commitments().first { $0.task.localizedCaseInsensitiveContains("login typo") }
        let todoCard = todo.flatMap { board.card(forTodo: $0.id.uuidString) }
        check(store.commitments().count == toastsBefore + 1 && todo?.binderID == website.id, "Command Mode's to-do goes in Tev1's binder (\(phrase))")
        check(router.titlesRead - readsBeforeCommand == 3, "its binder question read each binder's titles once: \(router.titlesRead - readsBeforeCommand) reads")
        check(todoCard?.column == .ready && board.timeline(todoCard?.id ?? UUID()).contains { $0.text.hasPrefix("Binders handed this to Scribe without asking: you added it in Command Mode") },
              "and, at 0.98 for an agent you let start, its card goes to Scribe")
        check(controller.flowBar.model.promptText == "Added to Website. Binders handed it to Scribe: Fix the login typo on the pricing page."
              && controller.flowBar.model.promptButton == "Stop", "the flow bar says what happened before the to-do's words: \(controller.flowBar.model.promptText)")
        controller.flowBar.hide()
        // Without the model, Command Mode is as it was: no agent offered for being the only one that takes the binder's
        // cards (Looker takes General's), only one you named.
        standIn.usable = false
        let readsWithoutModel = router.titlesRead
        let openBinder = (store.binder(AppSettings.shared.currentBinderID) ?? general).name
        await controller.command(heard: "Add to-do water the office plants")
        check(controller.flowBar.model.display != .prompt && controller.flowBar.model.toastText.hasPrefix("Added to \(openBinder): Water the office plants"),
              "without the model, a to-do in a binder with one taker gets no Give to: \(controller.flowBar.model.toastText)")
        controller.flowBar.hide()
        await controller.command(heard: "Add to-do have Looker find a plant shop near the office")
        check(controller.flowBar.model.display == .prompt && controller.flowBar.model.promptButton == "Give to Looker",
              "and one you named is still offered: \(controller.flowBar.model.promptText)")
        controller.flowBar.hide()
        check(router.titlesRead == readsWithoutModel, "and no binder's titles are read for either")
        // A binder named in the phrase takes the to-do, without its name in the to-do, model or not.
        await controller.command(heard: "Add to-do order the banner stand for Summit booth")
        let banner = store.commitments().first { $0.task.localizedCaseInsensitiveContains("banner stand") }
        check(banner?.binderID == booth.id && banner?.task == "Order the banner stand"
              && controller.flowBar.model.toastText.hasPrefix("Added to Summit booth: Order the banner stand"),
              "“Add to-do … for Summit booth” goes in Summit booth, as “Order the banner stand”: \(banner?.task ?? "none"), \(controller.flowBar.model.toastText)")
        controller.flowBar.hide()
        standIn.usable = true
        standIn.set(VoiceCommands.parseTodo("Add to-do call the dentist about the crown") ?? "", binder: ["Home": 0.4], agent: ["Pennant": 0.9])
        await controller.command(heard: "Add to-do call the dentist about the crown")
        let dentist = store.commitments().first { $0.task.localizedCaseInsensitiveContains("dentist") }
        check(dentist?.binderID == (store.binder(AppSettings.shared.currentBinderID) ?? general).id,
              "under the General threshold, Command Mode's to-do stays in the open binder, as before")
        check(controller.flowBar.model.display != .prompt, "and an agent that doesn't take that binder's cards isn't offered")
        controller.flowBar.hide()
        standIn.set(VoiceCommands.parseTodo("Add to-do book the plumber for the leak") ?? "", binder: ["Home": 0.9], agent: ["Pennant": 0.8])
        await controller.command(heard: "Add to-do book the plumber for the leak")
        check(controller.flowBar.model.display == .prompt && controller.flowBar.model.promptButton == "Give to Pennant"
              && controller.flowBar.model.promptText.hasPrefix("Added to Home: Book the plumber for the leak. Give to Pennant?"),
              "a suggestion goes in the flow bar's prompt, one tap away: \(controller.flowBar.model.promptText)")
        controller.flowBar.tapPromptButton()
        let plumber = store.commitments().first { $0.task.localizedCaseInsensitiveContains("plumber") }
        let plumberCard = plumber.flatMap { board.card(forTodo: $0.id.uuidString) }
        check(plumberCard?.meantFor == "Pennant" && plumberCard?.meantForByAgent == false && plumberCard?.column == .ready, "and its Give to makes the card and gives it")
        log.flush()
        check(log.entries().contains { $0.event == "gave" && $0.card == plumberCard?.id }, "the log has a gave line for it")
        controller.flowBar.hide()

        // MARK: Moments over the link, from two iPhones
        let devicesURL = manager.temporaryDirectory.appendingPathComponent("router-devices-\(UUID().uuidString).json")
        defer { try? manager.removeItem(at: devicesURL) }
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: devicesURL)
        server.start()
        // Both listeners, given up to 30 seconds: on a busy Mac the pairing port can come up after the main one.
        for _ in 0..<300 where server.status != .listening || server.boundPort == nil || server.boundPairingPort == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        func pairPhone(_ name: String, features: [String]) async throws -> LinkClient {
            guard let port = server.boundPort, var pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort else {
                throw CocoaError(.featureUnsupported)
            }
            pairing.addresses = ["127.0.0.1:\(pairingPort)"]
            let paired = try await LinkClient.pair(pairing, deviceName: name)
            let phone = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            try await phone.connect()
            _ = try await phone.hello(device: paired.device, key: paired.key, name: name, features: features)
            return phone
        }
        do {
            let phone = try await pairPhone("New iPhone", features: LinkFeatures.thisPhone)
            let oldPhone = try await pairPhone("Old iPhone", features: LinkFeatures.thisPhone.filter { $0 != MomentPayload.agreedFeature })
            func agents(_ phone: LinkClient) async -> [String: [String: Any]] {
                let text = (try? await phone.callTool("list_agents", [:])) ?? "{}"
                let list = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["agents"] as? [[String: Any]] ?? []
                return Dictionary(list.map { ($0["name"] as? String ?? "", $0) }, uniquingKeysWith: { first, _ in first })
            }
            let newList = await agents(phone), oldList = await agents(oldPhone)
            let fingerprint = newList["Scribe"]?["fingerprint"] as? String ?? ""
            check(newList["Scribe"]?["auto_start"] as? Bool == true && oldList["Scribe"]?["auto_start"] == nil,
                  "list_agents says auto_start only to a phone that sends its yes with what you say")
            check(!fingerprint.isEmpty && fingerprint != oldList["Scribe"]?["fingerprint"] as? String
                  && oldList["Scribe"]?["fingerprint"] as? String == AgentRegistry.consentFingerprint(registry.agents.first { $0.name == "Scribe" }!, reads: AgentBriefing.reads(for: "Scribe")),
                  "and fingerprints it with starts for that phone alone; the old phone's is the one it always had")
            func send(_ text: String, wake: Bool = true, engine: String = "parakeet-v2", heard: Date = Date(), conversation: UUID? = nil,
                      agreed: [String: String]? = nil, kind: String? = nil, adds: [String]? = nil, from client: LinkClient? = nil) async throws -> (id: UUID, outcome: CaptureOutcome?) {
                let id = UUID()
                let payload = MomentPayload(id: id, heard: heard, text: text, device: "iPhone", engine: engine, wake: wake, kind: kind, seconds: 2,
                                            conversation: conversation, adds: adds, agreed: agreed)
                let reply = try await (client ?? phone).request(MomentPayload.method, payload.jsonObject(), timeout: 40) as? [String: Any]
                return (id, (reply?["outcome"]).flatMap { CaptureOutcome.decodeEach([$0]).first })
            }
            let yes = ["scribe": fingerprint]
            standIn.set("fix the signup typo on the pricing page", binder: ["Website": 0.95], agent: ["Scribe": 0.98])
            let spoken = try await send("fix the signup typo on the pricing page", agreed: yes)
            check(spoken.outcome?.title == "Handed to Scribe" && spoken.outcome?.actions == ["undo"]
                  && spoken.outcome?.line == "Added to Website: Fix the signup typo on the pricing page. Binders handed it to Scribe.",
                  "a Binders, said on its own in your voice, with the iPhone's yes: handed over, with Undo: \(spoken.outcome?.line ?? "none")")
            let spokenCard = spoken.outcome?.card.flatMap(UUID.init(uuidString:)).flatMap(board.card)
            check(spokenCard?.column == .ready && board.timeline(spokenCard?.id ?? UUID()).contains { $0.text.hasPrefix("Binders handed this to Scribe without asking: you said it to Binders on your iPhone") },
                  "its card says Binders started it, and why")
            let undo = try? await phone.request(CaptureOutcome.actMethod, ["id": spoken.id.uuidString, "action": "undo"]) as? [String: Any]
            check((undo?["message"] as? String) == "Stopped Scribe. “Fix the signup typo on the pricing page” waits in the Website board's Backlog."
                  && spokenCard?.column == .backlog && spokenCard?.meantFor == nil
                  && store.commitments().contains { $0.id == spoken.id },
                  "Undo from the iPhone stops it, puts the card in Backlog meant for no one, and keeps the to-do: \(undo?["message"] as? String ?? "")")
            log.flush()
            check(log.entries().contains { $0.event == "stopped" && $0.card == spokenCard?.id }, "with a stopped line in the log")

            // Never from a capture, a conversation, Siri, or what was heard on its own, the yes set by hand on each.
            func never(_ text: String, _ label: String, engine: String = "parakeet-v2", wake: Bool = true, conversation: UUID? = nil, heard: Date = Date(),
                       agreed: [String: String]? = ["scribe": ""], from client: LinkClient? = nil) async throws {
                standIn.set(text, binder: ["Website": 0.95], agent: ["Scribe": 0.99])
                let sent = try await send(text, wake: wake, engine: engine, heard: heard, conversation: conversation,
                                          agreed: agreed?.mapValues { $0.isEmpty ? fingerprint : $0 }, from: client)
                let card = sent.outcome?.card.flatMap(UUID.init(uuidString:)).flatMap(board.card)
                check(sent.outcome?.title != "Handed to Scribe" && card.map { !board.timeline($0.id).contains { $0.kind == .woke } } ?? true,
                      "\(label): nothing starts (\(sent.outcome?.state ?? "none"): \(sent.outcome?.line ?? ""))")
            }
            try await never("fix the date on the homepage", "Tell Binders (engine siri), with agreed set by hand", engine: "siri")
            try await never("fix the date in the footer", "a Binders, said in a conversation, with agreed set by hand", conversation: UUID())
            try await never("fix the newsletter signup", "one from a transcript", conversation: UUID())
            try await never("I need to fix the blog's search", "one heard on its own", wake: false)
            try await never("fix the sitemap", "without the iPhone's yes", agreed: nil)
            try await never("fix the robots file", "with a yes made without starts", agreed: ["scribe": oldList["Scribe"]?["fingerprint"] as? String ?? "old"])
            try await never("fix the cookie banner", "heard 20 minutes ago", heard: Date().addingTimeInterval(-20 * 60))
            try await never("fix the favicon", "from an iPhone that doesn't send its yes", agreed: nil, from: oldPhone)
            // A start that isn't woken (a web hook, never sent in a throwaway folder): one period, the next step, and an Undo
            // that says it wasn't woken rather than "Stopped Hooky".
            let hookYes = ["hooky": newList["Hooky"]?["fingerprint"] as? String ?? ""]
            standIn.set("post the new pricing page to the team", binder: ["Website": 0.95], agent: ["Hooky": 0.99])
            let unwoken = try await send("post the new pricing page to the team", agreed: hookYes)
            check(unwoken.outcome?.line == "Added to Website: Post the new pricing page to the team. Hooky wasn't woken: Not run in a throwaway folder. Wake Now on the card on your Mac does it.",
                  "a start that wasn't woken says so once, with the next step: \(unwoken.outcome?.line ?? "none")")
            let unwokenUndo = try? await phone.request(CaptureOutcome.actMethod, ["id": unwoken.id.uuidString, "action": "undo"]) as? [String: Any]
            check((unwokenUndo?["message"] as? String) == "Hooky wasn't woken, so Binders moved “Post the new pricing page to the team” back to the Website board's Backlog.",
                  "and its Undo moves the card back, saying it wasn't woken: \(unwokenUndo?["message"] as? String ?? "")")
            standIn.set("Idea for the website: a dark mode", binder: ["Website": 0.95], agent: ["Scribe": 0.99])
            let idea = try await send("Idea for the website: a dark mode", agreed: yes)
            check(idea.outcome?.state == "acted" && idea.outcome?.title != "Handed to Scribe" && idea.outcome?.agent == "Scribe",
                  "an idea is never started, only offered with Give to: \(idea.outcome?.line ?? "")")
            // Every band on a moment's agent, and the binder threshold.
            standIn.set("book the window cleaner", binder: ["Home": 0.46], agent: ["Pennant": 0.7])
            let pick = try await send("book the window cleaner")
            check(pick.outcome?.binder == "Home" && pick.outcome?.line.hasPrefix("Added to Home, Binders' pick:") == true && pick.outcome?.agent == "Pennant",
                  "binder 0.46: Tev1's, and the line says Binders' pick; Pennant at 0.70 is named on Give to: \(pick.outcome?.line ?? "")")
            standIn.set("fix the hallway light", binder: ["Home": 0.44], agent: ["nobody": 0.9])
            let unsure = try await send("fix the hallway light")
            check(unsure.outcome?.binder == "Home" && unsure.outcome?.line.hasPrefix("Added to Home:") == true && unsure.outcome?.agent == nil,
                  "binder 0.44: the LLM step's binder: \(unsure.outcome?.line ?? "")")
            standIn.set("think about the weekend", binder: ["Home": 0.44], agent: ["nobody": 0.9])
            let weekend = try await send("think about the weekend")
            check(weekend.outcome?.binder == "General", "then General, when the LLM step says none: \(weekend.outcome?.binder ?? "")")
            // Off: what you say to your iPhone is sorted by your language model, and no decision model is asked.
            models.choose(.off)
            let askedBeforeOffMoment = standIn.asked.count
            standIn.set("fix the garden gate", binder: ["Website": 0.99], agent: ["Scribe": 0.99])
            let offMoment = try await send("fix the garden gate", agreed: yes)
            models.choose(.tev1)
            await models.settled()
            check(offMoment.outcome?.binder == "Home" && offMoment.outcome?.line.hasPrefix("Added to Home:") == true && offMoment.outcome?.title != "Handed to Scribe"
                  && standIn.asked.count == askedBeforeOffMoment,
                  "Off: a Binders, … is sorted by the language model, nothing starts, and no decision model is asked: \(offMoment.outcome?.line ?? "none")")
            // A to-do heard on its own, of a kind that graduated: added at once, and never started.
            standIn.set("I need to fix the press page", binder: ["Website": 0.95], agent: ["Scribe": 0.99])
            let graduated = try await send("I need to fix the press page", wake: false, agreed: yes, adds: ["todo"])
            check(graduated.outcome?.state == "acted" && graduated.outcome?.title != "Handed to Scribe",
                  "a graduated to-do is added at once, and never started: \(graduated.outcome?.line ?? "")")
            // With no binder's What goes here set, the titles-only threshold: 0.32 goes to the LLM step, 0.34 is Tev1's.
            // Four binders, so a top of 0.32 is possible (with three, the top is at least a third): every one given its
            // number, so 0.32 is Tev1's top, and the log says which step filed each.
            let saidBefore = [website, home, booth].map(\.whatGoesHere)
            for binder in [website, home, booth] { binder.whatGoesHere = "" }
            let garden = BinderRecord(name: "Garden", colorIndex: 5)
            store.insert(garden)
            store.save()
            standIn.set("fix the window latch", binder: ["Summit booth": 0.32, "Home": 0.30, "Website": 0.20, "Garden": 0.18], agent: ["nobody": 0.9])
            let titlesLow = try await send("fix the window latch")
            standIn.set("fix the stand's lights", binder: ["Summit booth": 0.34, "Home": 0.30, "Website": 0.20, "Garden": 0.16], agent: ["nobody": 0.9])
            let titlesHigh = try await send("fix the stand's lights")
            log.flush()
            let lowHow = log.entries().last { $0.moment == titlesLow.id && $0.event == nil }?.binder?.how
            let highHow = log.entries().last { $0.moment == titlesHigh.id && $0.event == nil }?.binder?.how
            check(titlesLow.outcome?.binder == "Home" && titlesLow.outcome?.line.hasPrefix("Added to Home:") == true && lowHow == "llm",
                  "titles alone, 0.32 on top: the LLM step files it (\(titlesLow.outcome?.binder ?? "none"), \(lowHow ?? "no log line"))")
            check(titlesHigh.outcome?.binder == "Summit booth" && titlesHigh.outcome?.line.hasPrefix("Added to Summit booth, Binders' pick:") == true && highHow == "model",
                  "and 0.34 is Tev1's (\(titlesHigh.outcome?.binder ?? "none"), \(highHow ?? "no log line"))")
            garden.archived = true
            for (binder, said) in zip([website, home, booth], saidBefore) { binder.whatGoesHere = said }
            store.save()
            // One agent taking every binder: not offered while Tev1 answers nobody, offered by the only-taker line without it.
            for agent in [scribe, claude, pennant, hooky, researcher, coder, capper] { registry.setEnabled(agent.id, false) }
            standIn.set("think about the summer", binder: ["Home": 0.9], agent: ["nobody": 0.9])
            let onlyTaker = try await send("think about the summer")
            check(onlyTaker.outcome?.agent == nil, "the only taker isn't offered when Tev1 says nobody: \(onlyTaker.outcome?.agent ?? "none")")
            standIn.usable = false
            let withoutTev1 = try await send("think about the autumn")
            check(withoutTev1.outcome?.agent == "Looker", "and is, by the only-taker line, without Tev1: \(withoutTev1.outcome?.agent ?? "none")")
            standIn.usable = true
            for agent in [scribe, claude, pennant, hooky, researcher, coder, capper] { registry.setEnabled(agent.id, true) }
            phone.close()
            oldPhone.close()
        } catch {
            check(false, "the link failed: \(error.localizedDescription)")
        }
        server.stop()

        // MARK: Auto, from two iPhones (SelfTestAuto.swift)
        await autoSelfTest(controller: controller, models: models, standIn: standIn, website: website, booth: booth, folder: folder, check: check)

        // MARK: Auto, only you: what the iPhone heard only you say in a capture (SelfTestSolo.swift, lane Y2)
        await soloSelfTest(controller: controller, models: models, standIn: standIn, website: website, folder: folder, check: check)

        // MARK: MCP, the iPhone's create_task, Add to Board, Put on Board and a capture's card
        let write = MCPServer.writeInApp(controller: controller)
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> String {
            (try? await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) ?? ""
        }
        standIn.set("Fix the hero image on the home page", binder: ["Website": 0.9], agent: ["Scribe": 0.99])
        let byAgent = await call("create_task", ["title": "Fix the hero image on the home page", "column": "ready"], as: BoardActor(name: "Helper", kind: .agent))
        let agentCard = (((try? JSONSerialization.jsonObject(with: Data(byAgent.utf8))) as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap(board.card)
            ?? board.cards(in: nil).first { $0.title == "Fix the hero image on the home page" }
        try? await Task.sleep(for: .milliseconds(500))
        check(agentCard?.binderID == website.id, "MCP's create_task with no binder: Tev1's pick at the General threshold")
        check(agentCard.map { !board.timeline($0.id).contains { $0.kind == .woke } && $0.meantFor == "Scribe" && $0.meantForByAgent } == true,
              "and an agent's or a tool's card is only ever suggested, at 0.99 too")
        standIn.set("Have Scribe fix the footer links", agent: ["nobody": 0.95])
        let namingByAgent = await call("create_task", ["title": "Have Scribe fix the footer links", "binder": "Website", "column": "backlog"],
                                       as: BoardActor(name: "Helper", kind: .agent))
        try? await Task.sleep(for: .milliseconds(500))
        let namingCard = (((try? JSONSerialization.jsonObject(with: Data(namingByAgent.utf8))) as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap(board.card)
            ?? board.cards(in: website.id).first { $0.title == "Have Scribe fix the footer links" }
        check(namingCard != nil && namingCard?.meantFor == nil && !board.timeline(namingCard?.id ?? UUID()).contains { $0.text.contains("you named it") },
              "an agent's card that names an agent isn't taken as you naming it: Tev1 alone reads it")
        standIn.set("Fix the order form", agent: ["Scribe": 0.99])
        _ = await call("create_task", ["title": "Fix the order form", "binder": "Website", "column": "ready", "actor_kind": "person"], as: .you)
        try? await Task.sleep(for: .milliseconds(500))
        let phoneCard = board.cards(in: website.id).first { $0.title == "Fix the order form" }
        check(phoneCard?.meantFor == "Scribe" && phoneCard?.meantForByAgent == true && phoneCard.map { !board.timeline($0.id).contains { $0.kind == .woke } } == true,
              "the iPhone's create_task: a suggestion in the background, never a start")
        // The iPhone's card from a to-do carries the to-do's words, here an agent's: read as Add to Board reads them, by Tev1
        // alone, so the name in them isn't you naming it.
        let relayed = controller.commitments.addSpoken("Have Scribe fix the gallery captions", binderID: website.id, origin: .agent, madeBy: "Helper",
                                                       toast: false).commitment
        standIn.set("Have Scribe fix the gallery captions", agent: ["nobody": 0.95])
        _ = await call("create_task", ["todo": relayed.id.uuidString, "column": "backlog", "actor_kind": "person"], as: .you)
        try? await Task.sleep(for: .milliseconds(500))
        let relayedCard = board.card(forTodo: relayed.id.uuidString)
        check(relayedCard != nil && relayedCard?.meantFor == nil && !board.timeline(relayedCard?.id ?? UUID()).contains { $0.text.contains("you named it") },
              "the iPhone's create_task from a to-do: a name in the to-do's words isn't one you named")
        let noteItem = NoteItem(text: "# Fix the mobile menu\n\nIt overlaps the logo.")
        noteItem.binderID = website.id
        store.insert(noteItem)
        standIn.set("Fix the mobile menu", agent: ["Scribe": 0.99])
        let fromNote = board.create(from: noteItem, by: .you)
        router.suggestLater(for: fromNote, origin: .toBoard)
        try? await Task.sleep(for: .milliseconds(500))
        check(fromNote.meantFor == "Scribe" && fromNote.meantForByAgent && !board.timeline(fromNote.id).contains { $0.kind == .woke },
              "Put on Board: a suggestion, never a start")

        // MARK: Move to
        if let card = board.cards(in: website.id).first(where: { $0.title == "Rewrite the pricing page intro" }) {
            try? router.move(card, to: home)
            log.flush()
            check(card.binderID == home.id && card.meantFor == nil && board.timeline(card.id).contains { $0.text == "Moved from the Website board to the Home board." }
                  && log.entries().contains { $0.event == "moved" && $0.card == card.id && $0.to == home.id },
                  "Move to: the card moves, Binders' suggestion goes when the new binder's agents don't include it, and the log has a moved line")
        }

        // MARK: The log
        log.flush()
        let raw = (try? String(contentsOf: log.url, encoding: .utf8)) ?? ""
        let decisions = log.entries().filter { $0.event == nil }
        check(!decisions.isEmpty && decisions.allSatisfy { $0.origin != nil && $0.did != nil }, "one line per decision: \(decisions.count)")
        check(!["Website", "Scribe", "Pennant", "pricing", "login typo", "Summit booth"].contains { raw.contains($0) },
              "with no words, no binder names and no agent names in the file")
        let now = Date()
        let old = RouterLogEntry(at: now.addingTimeInterval(-91 * 86_400), origin: "moment", did: "filed").line() ?? ""
        let lines = [old] + (0..<5_001).compactMap { RouterLogEntry(at: now.addingTimeInterval(-Double($0)), origin: "moment", did: "filed").line() }
        let trimmed = RouterLog.trimmed(lines, now: now)
        check(trimmed.count == 4_000 && !trimmed.contains(old), "5,001 lines trim to 4,000, and a line dated 91 days ago goes")
        store.deleteAllHistory()
        log.flush()
        check(!manager.fileExists(atPath: log.url.path) && log.decisions() == 0, "Delete all history clears it")
        check(DecisionMeasureStore(url: models.measures.url).all.measure(for: downloaded.identity) != nil,
              "and Delete all history, which clears the sorting record as Clear… does, leaves the measures: a measure is about the model, not you")

        // MARK: agents.json across builds
        let before = AgentProfile(name: "Old Hand", wake: .command(command: "./wake-scribe", folder: folder.path), purpose: "old work")
        registry.saveAsBefore(before)
        registry.load()
        check(!registry.changedOutside.contains(before.id), "one written as 0.8.0 writes it, without kinds or autoStart, loads unchanged")
        func plant(_ change: (inout AgentProfile) -> Void) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("agents.json")), var file = try? AgentFile.decode(data).file,
                  let index = file.agents.firstIndex(where: { $0.id == before.id }) else { return }
            change(&file.agents[index])
            try? file.encoded().write(to: folder.appendingPathComponent("agents.json"), options: .atomic)
            registry.load()
        }
        plant { $0.autoStart = true }
        check(registry.changedOutside.contains(before.id) && !registry.startsOnItsOwn(registry.agents.first { $0.id == before.id }!),
              "autoStart planted in the file holds the agent, and starts nothing")
        // Saved in the editor as it shows: the switch reads the Keychain's yes, which no plant wrote.
        var saved = registry.agents.first { $0.id == before.id }!
        saved.autoStart = registry.startsOnItsOwn(saved) ? true : nil
        registry.upsert(saved)
        registry.setStartsOnItsOwn(saved.id, false)
        check(registry.agents.first { $0.id == before.id }?.autoStart == nil && !registry.startsOnItsOwn(registry.agents.first { $0.id == before.id }!),
              "after a planted autoStart, the editor saves it off, and the Keychain's item stays empty")
        plant { $0.kinds = ["research"] }
        check(registry.changedOutside.contains(before.id), "kinds planted in the file hold the agent too")
        registry.upsert(registry.agents.first { $0.id == before.id }!)
        // An approved switch, then a load that finds autoStart gone (as after 0.8.0 saved the file), empties the yes.
        var approved = registry.agents.first { $0.id == before.id }!
        approved.autoStart = true
        registry.upsert(approved)
        registry.setStartsOnItsOwn(approved.id, true)
        check(registry.startsOnItsOwn(registry.agents.first { $0.id == before.id }!), "an approved switch starts")
        plant { $0.autoStart = nil }
        plant { $0.autoStart = true }
        check(!registry.startsOnItsOwn(registry.agents.first { $0.id == before.id }!),
              "a load that found it off emptied the Keychain's yes, so a later planted autoStart isn't approved by it")
        registry.remove(before.id)

        // The turn-on alert's yes is kept in the editor until Save, which writes it once the file says on: a registry
        // built in between (a running card's get_task, the iPhone's list_agents) can't clear it.
        var later = AgentProfile(name: "Later Hand", wake: .command(command: "./wake-scribe", folder: folder.path), binders: [booth.id], purpose: "the booth's banners")
        registry.upsert(later)
        _ = AgentRegistry(url: folder.appendingPathComponent("agents.json"))
        later.autoStart = true
        registry.upsert(later, startsOnItsOwn: true)
        _ = AgentRegistry(url: folder.appendingPathComponent("agents.json"))
        check(registry.startsOnItsOwn(registry.agents.first { $0.id == later.id }!), "Turn On, a load before Save, then Save: the switch stays on")
        // As it was before: the yes written at Turn On, then a load before Save, which clears it.
        var early = AgentProfile(name: "Early Hand", wake: .command(command: "./wake-scribe", folder: folder.path), binders: [booth.id], purpose: "the booth's posters")
        registry.upsert(early)
        registry.setStartsOnItsOwn(early.id, true)
        registry.load()
        early.autoStart = true
        registry.upsert(early)
        check(!registry.startsOnItsOwn(registry.agents.first { $0.id == early.id }!), "(a yes written before the file said on was lost to the app's own load, which is why Save writes it now)")
        // A registry built anywhere else (MCP's get_task or list_agents, or Binders --mcp) never clears a yes: one that read
        // the file just before a Save and the Keychain just after would clear the yes that Save had just written.
        var racing = AgentProfile(name: "Racing Hand", wake: .command(command: "./wake-scribe", folder: folder.path), binders: [booth.id], purpose: "the booth's flyers")
        registry.upsert(racing)
        registry.setStartsOnItsOwn(racing.id, true)
        _ = AgentRegistry(url: folder.appendingPathComponent("agents.json"))
        racing.autoStart = true
        registry.upsert(racing)
        check(registry.startsOnItsOwn(registry.agents.first { $0.id == racing.id }!),
              "a load elsewhere that found the file off and the Keychain's yes (as one between Save's two writes would) leaves the yes")
        registry.remove(racing.id)
        later.autoStart = nil
        registry.upsert(later, startsOnItsOwn: false)
        later.autoStart = true
        registry.upsert(later)
        check(!registry.startsOnItsOwn(registry.agents.first { $0.id == later.id }!), "Save with the switch off takes the yes away")
        registry.remove(later.id)
        registry.remove(early.id)

        // MARK: Fingerprints, kept (FolderFingerprints)
        await fingerprintSelfTest(in: folder, check: check)

        // MARK: The folder check (DecisionFolderCheck): a model's tokenizer and chat template, read in a process of its own
        await folderCheckSelfTest(in: folder, check: check)

        for agent in [scribe, claude, pennant, hooky, looker, researcher, coder, capper] { registry.remove(agent.id) }
        print(failures == 0 ? "ROUTER_OK" : "ROUTER_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// The fingerprint cache on a folder the test writes: the fingerprint is the manifest of its counted files' own
    /// SHA-256s; a second look, and the next launch, read only the files' sizes and dates; a file rewritten with its old
    /// modification date put back changes the stamp and the folder is hashed again; a copy elsewhere is hashed once there
    /// and finds the same fingerprint; files that don't count change nothing.
    @MainActor
    private static func fingerprintSelfTest(in folder: URL, check: (Bool, String) -> Void) async {
        let manager = FileManager.default
        let place = folder.appendingPathComponent("fingerprint-model", isDirectory: true)
        try? manager.createDirectory(at: place, withIntermediateDirectories: true)
        // The weights span two 4 MiB pieces and a bit, so the hash reads more than one piece.
        let files = ["config.json": Data(#"{"model_type": "llama"}"#.utf8), "model.safetensors": Data((0..<(9 * 1_048_576 + 3)).map { UInt8($0 % 251) }),
                     "tokenizer.json": Data("{}".utf8)]
        for (name, data) in files { try? data.write(to: place.appendingPathComponent(name)) }
        let expected = DecisionFingerprint.folder(files.map { DecisionFingerprint.File(name: $0.key, size: Int64($0.value.count), sha256: DecisionFingerprint.sha256Hex($0.value)) })
        let cache = FolderFingerprints(url: folder.appendingPathComponent("router-test-fingerprint-cache.json"))
        let first = await cache.fingerprint(of: place)
        check(first == expected && cache.hashes == 1, "a folder's fingerprint is the manifest of its counted files' own SHA-256s: \(first ?? "none")")
        try? "notes".write(to: place.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? Data().write(to: place.appendingPathComponent(".DS_Store"))
        try? manager.createDirectory(at: place.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let second = await cache.fingerprint(of: place)
        check(second == expected && cache.hashes == 1, "a second look, a README, a hidden file and a subfolder added, reads only the files' sizes and dates")
        let relaunched = FolderFingerprints(url: cache.url)
        let third = await relaunched.fingerprint(of: place)
        check(third == expected && relaunched.hashes == 0, "and so does the next launch, from what's kept")
        let config = place.appendingPathComponent("config.json")
        let modified = (try? manager.attributesOfItem(atPath: config.path))?[.modificationDate] as? Date
        try? Data(#"{"model_type": "lllma"}"#.utf8).write(to: config)
        if let modified { try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: config.path) }
        let changed = await relaunched.fingerprint(of: place)
        check(changed != nil && changed != expected && relaunched.hashes == 1,
              "a file rewritten, same size, with its old modification date put back, still changes the stamp: hashed again, another fingerprint")
        let copy = folder.appendingPathComponent("fingerprint-copy", isDirectory: true)
        try? manager.copyItem(at: place, to: copy)
        let copied = await relaunched.fingerprint(of: copy)
        check(copied == changed && relaunched.hashes == 2 && relaunched.entry(for: place)?.fingerprint == changed,
              "a copy elsewhere is hashed once there, and finds the same fingerprint")
        relaunched.forget(copy)
        check(relaunched.entry(for: copy) == nil && FolderFingerprints(url: cache.url).entry(for: place)?.fingerprint == changed,
              "Delete forgets a folder, and only that one")
        // At most 16 folders kept, the least recently used dropped.
        let crowd = FolderFingerprints(url: folder.appendingPathComponent("router-test-fingerprint-crowd.json"))
        var crowded: [URL] = []
        for index in 0...FolderFingerprints.capacity {
            let small = folder.appendingPathComponent("fingerprint-crowd/model-\(index)", isDirectory: true)
            try? manager.createDirectory(at: small, withIntermediateDirectories: true)
            try? Data("{\"n\": \(index)}".utf8).write(to: small.appendingPathComponent("config.json"))
            _ = await crowd.fingerprint(of: small)
            crowded.append(small)
            try? await Task.sleep(for: .milliseconds(5))
        }
        let reread = FolderFingerprints(url: crowd.url)
        check(reread.entry(for: crowded[0]) == nil && crowded.dropFirst().allSatisfy { reread.entry(for: $0) != nil },
              "at most \(FolderFingerprints.capacity) folders are kept, the least recently used dropped")
    }

    /// The decision folder check on folders the test writes, each a small whole model folder: a config.json, a tiny
    /// .safetensors file, a byte-level BPE tokenizer.json that swift-transformers reads (every byte a token, so any text
    /// reads), its tokenizer_config.json and a chat template. Run through the real helper process, `Binders
    /// --check-decision-folder`: a model that answers with a letter (its frame found, with and without a system message),
    /// one whose tokenizer has no "K", one whose tokenizer ends the check (refused, kept, and not checked again), one whose
    /// template runs without end (killed at its limit), and one whose template calls itself without end.
    @MainActor
    private static func folderCheckSelfTest(in folder: URL, check: (Bool, String) -> Void) async {
        let manager = FileManager.default
        let kept = FolderFingerprints(url: folder.appendingPathComponent("router-test-checks.json"))
        // The 256 characters a byte-level tokenizer reads bytes as (GPT-2's table), in that order: "A" to "X" are 32 to 55.
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var characters = bytes
        for byte in 0..<256 where !bytes.contains(byte) {
            bytes.append(byte)
            characters.append(256 + characters.count - 188)
        }
        let alphabet = characters.compactMap { UnicodeScalar(UInt32($0)).map(String.init) }
        func modelFolder(_ name: String, dropping: Set<String> = [], decoder: String = "ByteLevel", template: String,
                         config: [String: Any]? = nil, weights given: Data? = nil) -> URL {
            let place = folder.appendingPathComponent("decision-folders", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            try? manager.removeItem(at: place)
            try? manager.createDirectory(at: place, withIntermediateDirectories: true)
            var vocab: [String: Int] = [:]
            for (id, character) in alphabet.enumerated() where !dropping.contains(character) { vocab[character] = id }
            let tokenizer: [String: Any] = [
                "version": "1.0",
                "added_tokens": [["id": 256, "content": "<|im_start|>", "special": true, "single_word": false, "lstrip": false, "rstrip": false, "normalized": false],
                                 ["id": 257, "content": "<|im_end|>", "special": true, "single_word": false, "lstrip": false, "rstrip": false, "normalized": false]],
                "normalizer": NSNull(),
                "pre_tokenizer": ["type": "ByteLevel", "add_prefix_space": false, "trim_offsets": true, "use_regex": true],
                "post_processor": NSNull(),
                "decoder": ["type": decoder, "add_prefix_space": false, "trim_offsets": true, "use_regex": true],
                "model": ["type": "BPE", "unk_token": NSNull(), "fuse_unk": false, "byte_fallback": false, "vocab": vocab, "merges": [String]()],
            ]
            let files: [String: Any] = [
                "config.json": config ?? ["model_type": "llama", "hidden_size": 8, "num_hidden_layers": 1, "vocab_size": 258],
                "tokenizer.json": tokenizer,
                "tokenizer_config.json": ["tokenizer_class": "GPT2Tokenizer", "bos_token": NSNull(), "eos_token": "<|im_end|>", "unk_token": NSNull(),
                                          "model_max_length": 4096],
            ]
            for (file, object) in files {
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                    try? data.write(to: place.appendingPathComponent(file))
                }
            }
            try? template.write(to: place.appendingPathComponent("chat_template.jinja"), atomically: true, encoding: .utf8)
            if let given {
                try? given.write(to: place.appendingPathComponent("model.safetensors"))
                return place
            }
            var header = Data(#"{"w": {"dtype": "BF16", "shape": [4], "data_offsets": [0, 8]}}"#.utf8)
            while header.count % 8 != 0 { header.append(0x20) }
            var weights = Data()
            var length = UInt64(header.count).littleEndian
            withUnsafeBytes(of: &length) { weights.append(contentsOf: $0) }
            weights.append(header)
            weights.append(Data(repeating: 0, count: 8))
            try? weights.write(to: place.appendingPathComponent("model.safetensors"))
            return place
        }
        let chatML = "{% for message in messages %}{{ '<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>\\n' }}{% endfor %}"
            + "{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}{% if not enable_thinking %}{{ '<think>\\n\\n</think>\\n\\n' }}{% endif %}{% endif %}"

        // A model that answers with a letter: its letters, and the frame its template puts around a system line and a
        // question, the same bytes the template renders for the three warm-ups.
        let answering = modelFolder("chat-answers", template: chatML)
        let answered = await DecisionFolderCheck.ask(folder: answering, reader: .chat)
        let chatFrame = ChatFrame(before: "<|im_start|>system\n", between: "<|im_end|>\n<|im_start|>user\n",
                                  after: "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        check(answered == .passed(letters: Array(32...55), frame: chatFrame),
              "the folder check finds a chat model's letters and its frame, held to its template's own rendering of the warm-ups: \(answered)")
        check(chatFrame.prompt(RouterQuestions.warmUps[0]) == Tev1Prompt.prompt(RouterQuestions.warmUps[0]),
              "and for a template like Tev1's, the frame's prompt is Tev1Prompt's, byte for byte")
        let systemless = modelFolder("system-refused", template: "{% if messages[0]['role'] == 'system' %}{{ raise_exception('System role not supported') }}{% endif %}"
            + "{% for message in messages %}{{ '<start_of_turn>' + message['role'] + '\\n' + message['content'] + '<end_of_turn>\\n' }}{% endfor %}"
            + "{% if add_generation_prompt %}{{ '<start_of_turn>model\\n' }}{% endif %}")
        let systemlessAnswer = await DecisionFolderCheck.ask(folder: systemless, reader: .chat)
        check(systemlessAnswer == .passed(letters: Array(32...55), frame: ChatFrame(before: "<start_of_turn>user\n", between: nil, after: "<end_of_turn>\n<start_of_turn>model\n")),
              "a template that refuses a system message gets the system line at the head of the user message: \(systemlessAnswer)")
        let notTev1 = await DecisionFolderCheck.ask(folder: answering, reader: .tev1)
        check(notTev1 == .refused("its <|im_start|> isn't 248045", .folder), "read as Tev1's family, another model's tokenizer is refused with lane R1's words: \(notTev1)")

        // A tokenizer with no "K": it can't answer with a letter, said in plain words.
        let lettersRefused = modelFolder("letters-refused", dropping: ["K"], template: chatML)
        let noK = await DecisionFolderCheck.ask(folder: lettersRefused, reader: .chat)
        check(noK == .refused("in its tokenizer, “K” isn't a token of its own, and Binders reads the model's choice as one letter from A to X", .cantAnswer)
              && noK.unavailable == .cantAnswer("in its tokenizer, “K” isn't a token of its own, and Binders reads the model's choice as one letter from A to X"),
              "a tokenizer with no “K” is refused with the letter named: \(noK)")

        // A tokenizer that ends the check (a decoder swift-transformers meets with fatalError): refused, kept for the
        // folder's stamp, and not checked again, at this launch or the next. Binders goes on to the next check.
        let crashing = modelFolder("tokenizer-crash", decoder: "Nonsense", template: chatML)
        let runsBeforeCrash = DecisionFolderCheck.runs
        let crashed = await DecisionFolderCheck.checked(crashing, reader: .chat, fingerprints: kept)
        check(crashed == .refused("its tokenizer stopped Binders' check, so this Binders can't read it", .folder)
              && crashed?.unavailable == .folder("its tokenizer stopped Binders' check, so this Binders can't read it"),
              "a tokenizer that ends the check is refused, and Binders goes on: \(crashed.map { "\($0)" } ?? "no answer")")
        let crashedAgain = await DecisionFolderCheck.checked(crashing, reader: .chat, fingerprints: kept)
        let relaunched = await DecisionFolderCheck.checked(crashing, reader: .chat, fingerprints: FolderFingerprints(url: kept.url))
        check(crashedAgain == crashed && relaunched == crashed && DecisionFolderCheck.runs == runsBeforeCrash + 1,
              "asked again, and at the next launch, the refusal comes from what's kept for the folder: one check in all")

        // A template that runs without end: killed at the check's limit (cut to half a second here), refused, and gone.
        let endless = modelFolder("template-endless", template: "{% for i in range(100000) %}{% for j in range(100000) %}{% endfor %}{% endfor %}" + chatML)
        let endlessStarted = ContinuousClock.now
        let endlessAnswer = await DecisionFolderCheck.ask(folder: endless, reader: .chat, within: .milliseconds(500))
        let endlessTook = endlessStarted.duration(to: .now)
        let endlessGone = kill(DecisionFolderCheck.lastProcess, 0) == -1 && errno == ESRCH
        check(endlessAnswer == .refused("filling in its chat template took more than 0.5 seconds", .cantAnswer) && endlessTook < .seconds(1) && endlessGone,
              "a template that runs without end is refused within a second, and its check is gone: \(endlessAnswer), \(endlessTook)")

        // A template that calls itself without end ends the check instead, and is refused as a crash.
        let recursive = modelFolder("template-recursive", template: "{% macro again() %}{{ again() }}{% endmacro %}{{ again() }}")
        let recursiveAnswer = await DecisionFolderCheck.ask(folder: recursive, reader: .chat)
        check(recursiveAnswer == .refused(DecisionFolderCheck.templateStopped, .cantAnswer), "a template that calls itself without end is refused: \(recursiveAnswer)")

        // Binders' own checks before the helper: no tokenizer.json, or one over 64 MB, never reaches it.
        let noTokenizer = modelFolder("no-tokenizer", template: chatML)
        try? manager.removeItem(at: noTokenizer.appendingPathComponent("tokenizer.json"))
        let runsBeforeMissing = DecisionFolderCheck.runs
        let missing = await DecisionFolderCheck.checked(noTokenizer, reader: .chat, fingerprints: kept)
        check(missing == .refused("tokenizer.json is missing", .folder) && DecisionFolderCheck.runs == runsBeforeMissing,
              "a folder with no tokenizer.json is refused before any check runs")

        // Through the backend, as Use a Model Folder… gives it: what the check found is its state, and it's kept for the
        // folder's stamp, so the next launch says it at once with no check run.
        let noKWords = "in its tokenizer, “K” isn't a token of its own, and Binders reads the model's choice as one letter from A to X"
        let lettersBackend = MLXDecisionBackend(folder: lettersRefused, kind: .folder, marker: folder.appendingPathComponent("router-running-letters"), fingerprints: kept)
        let lettersFirst = await lettersBackend.state()
        _ = await lettersBackend.identity(by: .now + .seconds(20))
        let lettersState = await lettersBackend.state(), lettersMLX = await lettersBackend.startedMLX
        check(lettersFirst == .checking && lettersState == .unavailable(.cantAnswer(noKWords)) && !lettersMLX,
              "a folder whose tokenizer has no “K”, chosen: checking, then it can't sort cards, said plainly, and MLX never starts: \(lettersState)")
        let runsBeforeRelaunch = DecisionFolderCheck.runs
        let lettersRelaunched = await MLXDecisionBackend(folder: lettersRefused, kind: .folder, marker: folder.appendingPathComponent("router-running-letters-2"),
                                                         fingerprints: FolderFingerprints(url: kept.url)).state()
        let crashState = await MLXDecisionBackend(folder: crashing, kind: .folder, marker: folder.appendingPathComponent("router-running-crash"),
                                                  fingerprints: kept).state()
        check(lettersRelaunched == lettersState && crashState == .unavailable(.folder(DecisionFolderCheck.tokenizerStopped)) && DecisionFolderCheck.runs == runsBeforeRelaunch,
              "at the next launch, both refusals come at once from what's kept for the folders, with no check run: \(crashState)")

        // MARK: A chat model, read through its frame (on Apple silicon)
        // A made-up Llama of a few kilobytes and the byte-level tokenizer above, loaded by mlx-swift-lm for real: its head
        // gives the first nine letters 20 and C 24 whatever it's asked, so it answers C, the letters hold nearly all of what
        // it would say first, and a twin whose head favours "!" holds almost none of it.
        guard MLXModels.isSupported else {
            print("INFO: no MLX on this Mac, so the chat reader isn't tried")
            return
        }
        /// A made-up Llama's weights, float32: every token embedded as ones, the attention's and the MLP's outputs zero (so
        /// the hidden state is the embedding, normed, at every position), and a head whose row for each token is
        /// `head(id)` at each of the 8 dimensions, so its logit is 8 × head(id) whatever the prompt.
        func llamaWeights(head: (Int) -> Float) -> Data {
            let hidden = 8, vocabulary = 258, inner = 16
            var tensors: [(name: String, shape: [Int], values: [Float])] = [
                ("model.embed_tokens.weight", [vocabulary, hidden], Array(repeating: 1, count: vocabulary * hidden)),
                ("model.norm.weight", [hidden], Array(repeating: 1, count: hidden)),
                ("lm_head.weight", [vocabulary, hidden], (0..<vocabulary).flatMap { Array(repeating: head($0), count: hidden) }),
            ]
            for (name, shape) in [("self_attn.q_proj", [hidden, hidden]), ("self_attn.k_proj", [hidden, hidden]), ("self_attn.v_proj", [hidden, hidden]),
                                  ("self_attn.o_proj", [hidden, hidden]), ("mlp.gate_proj", [inner, hidden]), ("mlp.up_proj", [inner, hidden]),
                                  ("mlp.down_proj", [hidden, inner])] {
                tensors.append(("model.layers.0.\(name).weight", shape, Array(repeating: 0, count: shape.reduce(1, *))))
            }
            for name in ["input_layernorm", "post_attention_layernorm"] {
                tensors.append(("model.layers.0.\(name).weight", [hidden], Array(repeating: 1, count: hidden)))
            }
            var header: [String: Any] = [:]
            var body = Data()
            for tensor in tensors {
                let begin = body.count
                tensor.values.withUnsafeBufferPointer { body.append(Data(buffer: $0)) }
                header[tensor.name] = ["dtype": "F32", "shape": tensor.shape, "data_offsets": [begin, body.count]]
            }
            var json = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data()
            while json.count % 8 != 0 { json.append(0x20) }
            var file = Data()
            var length = UInt64(json.count).littleEndian
            withUnsafeBytes(of: &length) { file.append(contentsOf: $0) }
            file.append(json)
            file.append(body)
            return file
        }
        let llama: [String: Any] = ["model_type": "llama", "hidden_size": 8, "num_hidden_layers": 1, "intermediate_size": 16, "num_attention_heads": 2,
                                    "num_key_value_heads": 2, "rms_norm_eps": 1e-5, "vocab_size": 258, "rope_theta": 10_000, "tie_word_embeddings": false]
        let chatKept = FolderFingerprints(url: folder.appendingPathComponent("router-test-chat-models.json"))
        let answersC = modelFolder("chat-model-answers-c", template: chatML, config: llama,
                                   weights: llamaWeights { id in id == 34 ? 3.0 : (32...40).contains(id) ? 2.5 : 0 })
        let chat = MLXDecisionBackend(folder: answersC, kind: .folder, needsFree: 0, marker: folder.appendingPathComponent("router-running-chat-model"),
                                      fingerprints: chatKept)
        let chatIdentity = await chat.identity(by: .now + .seconds(20))
        let chatReady = await chat.state()
        check(chatIdentity?.reader == "chat.1/256" && chatIdentity?.fingerprint.hasPrefix("mlx1-") == true && chatReady.isUsable,
              "a chat model's folder, checked by the real helper and hashed, is read as chat.1/256: \(chatIdentity?.key ?? "none"), \(chatReady)")
        let threeWays = DecisionQuestion(state: "Fix the café's menu page 🙂", question: RouterQuestions.agentQuestion, options: [
            DecisionOption(key: "Scribe", description: "the website: pages, copy and fixes"),
            DecisionOption(key: "Pennant", description: "Personal errands: appointments, email, bookings"),
            DecisionOption(key: RouterQuestions.nobody, description: RouterQuestions.nobodyDescription),
        ])
        var chatAnswer: DecisionAnswers?
        var chatError = ""
        do {
            chatAnswer = try await chat.decide([threeWays], expecting: chatIdentity, by: .now + .seconds(20))
        } catch {
            chatError = error.localizedDescription
        }
        let chatProbs = chatAnswer?.probs.first ?? []
        let chatShares = await chat.warmUpShares() ?? [], chatWarmUps = await chat.warmUp() ?? []
        let chatDiffers = await chat.numbersDiffer(), chatMatches = await chat.numbersMatch(), chatReport = await chat.report
        check(chatProbs.count == 3 && RouterMath.argmax(chatProbs) == 2 && chatProbs[2] > 0.95 && chatAnswer?.answeredBy == nil,
              "its answer to a card, read at the first position of the answer through its frame, is the letter its head favours, C: "
              + chatProbs.map { String(format: "%.4f", $0) }.joined(separator: ", ") + chatError)
        check(chatWarmUps.count == 3 && chatWarmUps.allSatisfy { RouterMath.argmax($0) == 2 } && chatShares.count == 3 && chatShares.allSatisfy { $0 > 0.999 }
              && chatReport.reader == "chat.1/256" && !chatReport.hiddenStateHook,
              "its three warm-ups ran through the chat reader, and at each the offered letters held nearly all of what it would say first: "
              + chatShares.map { String(format: "%.6f", $0) }.joined(separator: ", "))
        check(!chatDiffers && !chatMatches, "never measured, it has no golden: its numbers neither match nor differ")
        await chat.unload()
        let chatUnloaded = await chat.hasContainer
        check(!chatUnloaded, "and Unload now lets it go")
        // Its twin answers "!" first: refused at the load, in plain words, and kept, so the next launch says so at once.
        let answersBang = modelFolder("chat-model-answers-bang", template: chatML, config: llama, weights: llamaWeights { id in id == 0 ? 2.5 : 0 })
        let wordy = MLXDecisionBackend(folder: answersBang, kind: .folder, needsFree: 0, marker: folder.appendingPathComponent("router-running-chat-bang"),
                                       fingerprints: chatKept)
        _ = await wordy.identity(by: .now + .seconds(20))
        let wordyAnswer = try? await wordy.decide([threeWays], by: .now + .seconds(20))
        let wordyState = await wordy.state(), wordyLoads = await wordy.loadsBegun, wordyHeld = await wordy.hasContainer
        let noLetter = DecisionBackendState.unavailable(.cantAnswer(MLXDecisionBackend.notALetter(0)))
        let runsBeforeWordy = DecisionFolderCheck.runs
        let wordyAgain = MLXDecisionBackend(folder: answersBang, kind: .folder, needsFree: 0, marker: folder.appendingPathComponent("router-running-chat-bang-2"),
                                            fingerprints: FolderFingerprints(url: chatKept.url))
        let wordyAgainState = await wordyAgain.state(), wordyAgainLoads = await wordyAgain.loadsBegun
        check(wordyAnswer == nil && wordyState == noLetter && wordyLoads == 1 && !wordyHeld && wordyAgainState == noLetter && wordyAgainLoads == 0
              && DecisionFolderCheck.runs == runsBeforeWordy,
              "a model whose letters hold almost none of what it would say first is refused at its load, and the next launch says so without loading it: \(wordyState)")
    }

    /// A JSON file a stand-in writes, once it's there.
    @MainActor
    private static func waitForJSON(_ file: URL) async -> [String: Any] {
        for _ in 0..<60 where (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }
}

/// Stands in for the decision model in the router self-test: answers each question from a table (by what was said or
/// typed, and which question), giving the keys listed their probabilities and spreading the rest evenly; keeps every
/// question it was asked. It has an identity (Tev1 bf16's by default, so lane R1's checks keep their meaning through the
/// built-in bands) and warm-ups (the built-in goldens by default), held to the goldens it's given within 0.002 as a real
/// backend's are. It can be told to wait for ever (answering at the deadline with a throw, as the real one does), to take
/// a while (a pass a retire doesn't cut short), to throw, to say its numbers differ, to be missing; it counts its retires
/// and revives, and once retired it answers nothing.
final class RouterStandIn: DecisionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _identity = DecisionBands.tev1BF16
    private var _warmUps: [[Double]] = DecisionBands.tev1?.golden ?? []
    private var _golden: [[Double]]?
    private var table: [String: [String: [String: Double]]] = [:]
    private var _asked: [DecisionQuestion] = []
    private var _hang = false, _fail = false, _matches = true, _usable = true, _retired = false
    private var _delay: Duration = .zero
    private var _retires = 0, _revives = 0
    private var _answerer: (@Sendable (DecisionQuestion) -> [Double]?)?
    private var _failAt: (call: Int, error: DecisionError)?
    private var _calls = 0

    var identity: DecisionIdentity {
        get { lock.withLock { _identity } }
        set { lock.withLock { _identity = newValue } }
    }
    var warmUpValues: [[Double]] {
        get { lock.withLock { _warmUps } }
        set { lock.withLock { _warmUps = newValue } }
    }
    var hang: Bool {
        get { lock.withLock { _hang } }
        set { lock.withLock { _hang = newValue } }
    }
    var fail: Bool {
        get { lock.withLock { _fail } }
        set { lock.withLock { _fail = newValue } }
    }
    /// False: its numbers differ, whatever its warm-ups say.
    var matches: Bool {
        get { lock.withLock { _matches } }
        set { lock.withLock { _matches = newValue } }
    }
    var usable: Bool {
        get { lock.withLock { _usable } }
        set { lock.withLock { _usable = newValue } }
    }
    /// How long each decision takes once it has begun.
    var delay: Duration {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }
    /// Answers a question before the table is looked at, when it knows it: the measure's stand-in answers the bench's
    /// made-up cards so.
    var answerer: (@Sendable (DecisionQuestion) -> [Double]?)? {
        get { lock.withLock { _answerer } }
        set { lock.withLock { _answerer = newValue } }
    }
    /// Its decision of that number (counting from its first) throws that error.
    var failAt: (call: Int, error: DecisionError)? {
        get { lock.withLock { _failAt } }
        set { lock.withLock { _failAt = newValue } }
    }
    /// Decisions it was asked for, retired or not.
    var calls: Int { lock.withLock { _calls } }
    var asked: [DecisionQuestion] { lock.withLock { _asked } }
    var retires: Int { lock.withLock { _retires } }
    var revives: Int { lock.withLock { _revives } }
    var retired: Bool { lock.withLock { _retired } }
    var goldenGiven: [[Double]]? { lock.withLock { _golden } }

    /// Made again by DecisionModels' factory: a new backend is never retired.
    func fresh() { lock.withLock { _retired = false } }

    /// The answers for what was said or typed: the binders' and the agents' probabilities by key.
    func set(_ state: String, binder: [String: Double]? = nil, agent: [String: Double]? = nil) {
        lock.withLock {
            if let binder { table[state, default: [:]]["binder"] = binder }
            if let agent { table[state, default: [:]]["agent"] = agent }
        }
    }

    func state() async -> DecisionBackendState { usable ? .ready(bytes: 1_524_861_436) : .unavailable(.noFolder) }

    func identity(by deadline: ContinuousClock.Instant) async -> DecisionIdentity? { identity }

    func setGolden(_ golden: [[Double]]?) async { lock.withLock { _golden = golden } }

    /// Its warm-ups against the goldens it was given, as a real backend holds them: every value within 0.002.
    private var warmUpsHold: Bool {
        guard let golden = _golden, golden.count == _warmUps.count else { return false }
        return zip(golden, _warmUps).allSatisfy { kept, now in kept.count == now.count && zip(kept, now).allSatisfy { abs($0 - $1) <= 0.002 } }
    }

    func numbersMatch() async -> Bool { lock.withLock { _golden != nil && _matches && warmUpsHold } }

    func numbersDiffer() async -> Bool { lock.withLock { _golden != nil && !(_matches && warmUpsHold) } }

    func warmUp() async -> [[Double]]? { warmUpValues }

    func warmUpShares() async -> [Double]? { nil }

    func decide(_ questions: [DecisionQuestion], expecting expected: DecisionIdentity?,
                by deadline: ContinuousClock.Instant) async throws -> DecisionAnswers {
        let call = lock.withLock { () -> Int in
            _calls += 1
            return _calls
        }
        if retired { throw DecisionError.retired }
        if let expected, expected.key != identity.key { throw DecisionError.changed }
        lock.withLock { _asked += questions }
        if fail { throw DecisionError.mlx("the stand-in was told to fail") }
        if let failAt, failAt.call == call { throw failAt.error }
        if hang {
            let left = ContinuousClock.now.duration(to: deadline)
            let seconds = max(0.01, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
            do {
                return try await TimeLimit.run(within: seconds) {
                    try await Task.sleep(for: .seconds(3_600))
                    return DecisionAnswers(probs: [], answeredBy: nil)
                }
            } catch is TimeLimit.Exceeded {
                throw DecisionError.timedOut
            }
        }
        let delay = delay
        if delay > .zero { try await Task.sleep(for: delay) }
        let answerer = answerer
        let probs = lock.withLock {
            questions.map { question in
                if let answered = answerer?(question) { return answered }
                // A state that's a title and the start of a brief (DistillWhoState) is answered as its title is, unless the
                // test set it whole.
                let row = table[question.state] ?? question.state.components(separatedBy: "\n").first.flatMap { table[$0] }
                let given = row?[question.question == RouterQuestions.binderQuestion ? "binder" : "agent"] ?? [:]
                let keys = question.options.map(\.key)
                let listed = keys.filter { given[$0] != nil }
                let rest = max(0, 1 - listed.reduce(0) { $0 + (given[$1] ?? 0) })
                let others = keys.count - listed.count
                return keys.map { given[$0] ?? (others > 0 ? rest / Double(others) : 0) }
            }
        }
        return DecisionAnswers(probs: probs, answeredBy: nil)
    }

    func prepare(by deadline: ContinuousClock.Instant) async throws {
        if retired { throw DecisionError.retired }
    }

    func stillSame(_ identity: DecisionIdentity, by deadline: ContinuousClock.Instant) async -> StillSame {
        !retired && identity.key == self.identity.key ? .same : .changed
    }

    func setIdle(minutes: Int) async {}

    func unload() async {}

    func retire() async {
        lock.withLock {
            _retires += 1
            _retired = true
        }
    }

    func revive() async {
        lock.withLock {
            _revives += 1
            _retired = false
        }
    }

    func prepareForQuit(within: Duration) async { lock.withLock { _retired = true } }

    func tryAgain() async {}
}

/// The self-test's backends by choice, for its own DecisionModels' factory: stand-ins, and for a decision server with none
/// given, the real backend `serverBackend` makes (against a stand-in server).
@MainActor
final class RouterStandIns {
    var byChoice: [DecisionChoice: RouterStandIn] = [:]
    var serverBackend: ((String) -> (any DecisionBackend)?)?

    func make(_ choice: DecisionChoice) -> (any DecisionBackend)? {
        if let standIn = byChoice[choice] {
            standIn.fresh()
            return standIn
        }
        if case .server(let address) = choice { return serverBackend?(address) }
        return nil
    }
}

/// Stands in for the language model in the router self-test: answers each call from what it was asked.
private final class RouterLLMStandIn: LLMClient, @unchecked Sendable {
    private let answer: @Sendable (String, String) -> String

    init(answer: @escaping @Sendable (String, String) -> String) {
        self.answer = answer
    }

    var model: String { "stand-in" }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        answer(system, user)
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        answer(system, user)
    }

    func listModels() async throws -> [String] { [model] }

    func warmUp() async {}
}
