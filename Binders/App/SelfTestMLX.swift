import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// A model built in with MLX: downloaded, cleaning up a dictation, embeddings for search, and let go.
    ///
    ///     BINDERS_MLX_MODELS=<folder> Binders --selftest-mlx mlx-community/gemma-4-e2b-it-4bit [--embed mlx-community/embeddinggemma-300m-4bit] -llmProvider mlx -mlxModel <same>
    @MainActor
    static func mlxSelfTest(model: String, embedding: String?) async -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        func fetch(_ id: String) async -> Bool {
            if MLXModels.directory(for: id) != nil { return true }
            print("DOWNLOADING \(id) into \(MLXModels.folder.path)")
            var lastShown = -1
            do {
                try await MLXDownload(id: id, endpoint: AppSettings.shared.mlxEndpoint, token: nil) { fraction in
                    let step = Int(fraction * 10)
                    Task { @MainActor in
                        if step > lastShown { lastShown = step; print("  \(step * 10)%"); fflush(stdout) }
                    }
                }.run()
            } catch {
                print("DOWNLOAD FAILED: \(error.localizedDescription)")
                return false
            }
            return MLXModels.directory(for: id) != nil
        }
        check(await fetch(model), "\(model) is downloaded")
        let client = MLXClient(model: model, idleMinutes: 5)
        let loadStart = Date()
        await client.warmUp()
        let loaded = await client.residency()
        print("LOADED in \(ms(since: loadStart)) ms, \(ByteCountFormatter.string(fromByteCount: loaded?.bytes ?? 0, countStyle: .memory))")
        check(loaded != nil, "the model loads into memory")

        // The real cleanup, the way dictation uses it.
        let settings = AppSettings.shared
        print("PROVIDER: \(settings.llmProvider.rawValue) \(settings.llmModelName)")
        let controller = DictationController()
        for raw in ["um so I think we should uh meet at 2 actually no 3 pm tomorrow and bring the the slides",
                    "can you send the the pricing deck to maya by thursday and uh cc samir"] {
            let started = Date()
            let result = await controller.format(raw: raw, context: AppContext(appName: "Mail"))
            print("FORMAT (\(ms(since: started)) ms, model \(result.usedLLM ? "yes" : "no: \(result.fallbackReason ?? "")")): \(result.text)")
            check(result.usedLLM && !result.text.lowercased().contains(" um ") && !result.text.lowercased().contains("uh "), "cleanup runs on the built-in model")
        }
        let started = Date()
        let reply = (try? await client.complete(system: "Answer in one short sentence.", user: "What is the capital of Portugal?", maxTokens: 40,
                                                temperature: 0.2, timeout: 60)) ?? ""
        print("ANSWER (\(ms(since: started)) ms): \(reply)")
        check(reply.localizedCaseInsensitiveContains("Lisbon"), "it answers")

        if let embedding {
            check(await fetch(embedding), "\(embedding) is downloaded")
            let texts = ["Ship the pricing page before the launch on the 28th.", "The harbour was quiet at dusk.", "When does the launch happen?"]
            let embedStart = Date()
            let vectors = (try? await MLXEmbedder.shared.embed(texts, model: embedding)) ?? []
            print("EMBEDDED \(vectors.count) in \(ms(since: embedStart)) ms, \(vectors.first?.count ?? 0) dimensions")
            func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map(*).reduce(0, +) }
            if vectors.count == 3 {
                let related = cosine(vectors[2], vectors[0]), unrelated = cosine(vectors[2], vectors[1])
                print(String(format: "SIMILARITY: launch question ~ launch note %.3f, ~ harbour %.3f", related, unrelated))
                check(related > unrelated, "search by meaning finds the related note first")
            } else {
                check(false, "embeddings come back, one per text")
            }
        }
        await client.unload()
        check(await client.residency() == nil, "and lets the model go")

        // Settings → AI with the model built in, to look at.
        if let directory = ProcessInfo.processInfo.environment["BINDERS_SHOTS"] {
            let navigation = HubNavigation()
            navigation.selection = .settings
            navigation.pendingSettingsPage = .ai
            let hosting = NSHostingView(rootView: HubView()
                .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
                .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
                .modelContainer(Store.shared.container))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            hosting.wantsLayer = true
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1500))
            capture(hosting, name: "settings-ai-mlx", directory: URL(fileURLWithPath: directory))
            window.close()
        }
        print(failures == 0 ? "MLX_OK" : "MLX_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// Ollama against the built-in model on the same model: a cold start, dictations through the real cleanup, a digest.
    ///
    ///     BINDERS_MLX_MODELS=~/Library/Application\ Support/Binders/Models/MLX Binders --selftest-llm-bench \
    ///         --ollama gemma4:26b --mlx mlx-community/gemma-4-26b-a4b-it-4bit [--rounds 3]
    @MainActor
    static func llmBenchSelfTest(ollamaModel: String, mlxModel: String, rounds: Int) async -> Int32 {
        let settings = AppSettings.shared
        guard let url = URL(string: settings.ollamaURL) else { return 1 }
        let ollama = OllamaClient(baseURL: url, model: ollamaModel, keepAliveSeconds: 900)
        let mlx = MLXClient(model: mlxModel, idleMinutes: 15)
        let clients: [(name: String, client: LLMClient)] = [("Ollama", ollama), ("MLX", mlx)]
        guard MLXModels.directory(for: mlxModel) != nil else {
            print("ERROR: \(mlxModel) isn't downloaded in \(MLXModels.folder.path)")
            return 1
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

        // A cold start: the model freed, then the first short answer.
        print("COLD START (model freed, then a short answer)")
        for (name, client) in clients {
            await client.unload()
            try? await Task.sleep(for: .seconds(2))
            let started = Date()
            _ = try? await client.complete(system: "Answer in one word.", user: "Capital of Portugal?", maxTokens: 8, temperature: 0, timeout: 300)
            let memory = await client.residency().map { ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .memory) } ?? "?"
            print(String(format: "  %@: %.1f s, %@ in memory", name, Date().timeIntervalSince(started), memory))
        }

        let dictations = [
            "um so yeah let's do three",
            "can you send the the pricing deck to maya by thursday and uh cc samir",
            "um so I think we should uh meet at 2 actually no 3 pm tomorrow and bring the the slides",
            "hey Noah quick one um are we still on for the design review friday or should we push it to monday because I'm out thursday",
            "ok so the plan is uh first we finish the onboarding emails then we uh do the pricing page and then like the the launch post on the 28th",
            "note to self um look into why the import test is slow with fifty thousand rows I think it's the uh the indexing step not the parsing",
            "so what I'm hearing is um the customer wants annual billing at fifteen percent off uh they want it before the end of the quarter and they need SSO which we don't have yet so we should probably uh scope that properly before we promise anything",
            "Hi team um quick update from the call with Acme they're happy with the pilot uh two things came up one they want the reports weekly instead of monthly and two they asked whether we can uh export to Excel directly I said we'd look into both and get back to them by next Wednesday so can someone take the export piece and I'll handle the reporting change thanks",
        ]
        var times: [String: [Double]] = [:]
        var sample: [String: String] = [:]
        print("DICTATION CLEANUP (\(dictations.count) dictations × \(rounds) rounds, the real pipeline, Mail style)")
        for round in 0..<rounds {
            for (index, raw) in dictations.enumerated() {
                // Taking turns, so neither always goes first.
                let order = (round + index) % 2 == 0 ? clients : clients.reversed()
                for (name, client) in order {
                    let started = Date()
                    let result = await TextFormatter.format(raw: raw, context: AppContext(appName: "Mail"), client: client)
                    times[name, default: []].append(Date().timeIntervalSince(started) * 1000)
                    if round == 0, index == 6 { sample[name] = result.usedLLM ? result.text : "(no model: \(result.fallbackReason ?? ""))" }
                }
            }
        }
        for (name, _) in clients {
            let values = times[name] ?? [0]
            print(String(format: "  %@: median %.0f ms, slowest %.0f ms", name, median(values), values.max() ?? 0))
        }
        for (name, _) in clients { print("  \(name) wrote: \(sample[name] ?? "")") }

        // A digest: a long reply, where generation speed shows.
        let note = String(repeating: """
        Met with the Harbor launch group. Pricing is settled: annual plans at 15% off, monthly unchanged, and the free tier stays as it is. \
        Maya owns the pricing page and will have a draft by Wednesday. Samir is writing the support macros and wants the FAQ before Friday. \
        Noah raised the import performance: 50,000 rows take four minutes, mostly in indexing. We agreed to profile it before promising a fix. \
        The launch date stays the 28th; a slip is decided on Monday, not before. Acme asked for weekly reports and an Excel export.

        """, count: 4)
        print("DIGEST (a \(note.wordCount)-word note, twice each)")
        for (name, client) in clients {
            var durations: [Double] = []
            var length = 0
            for _ in 0..<2 {
                let started = Date()
                let output = (try? await client.stream(system: NotePrompts.digestSystemPrompt(),
                                                       user: NotePrompts.digestUserPrompt(date: "1 Oct 2026", text: note),
                                                       maxTokens: 900, temperature: 0.2, timeout: 300, stopWhen: { LoopGuard.isLooping($0) })) ?? ""
                durations.append(Date().timeIntervalSince(started))
                length = output.count
            }
            print(String(format: "  %@: %.1f s (best of two %.1f s), %d characters, about %.0f words a second", name, durations.reduce(0, +) / 2,
                         durations.min() ?? 0, length, Double(length) / 5.5 / max(0.01, durations.min() ?? 1)))
        }
        await mlx.unload()
        print("BENCH_DONE")
        return 0
    }
}

extension SelfTest {
    /// Picking apps to capture writing in, from what's running.
    @MainActor
    static func capturePickerSelfTest(directory: URL) async -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        check(WritingCaptureService.isBrowser("com.brave.Browser") && !WritingCaptureService.isBrowser("com.hnc.Discord"), "Brave is a browser, Discord isn't")
        check(WritingCaptureService.isNeverCaptured("com.1password.1password") && !WritingCaptureService.isNeverCaptured("com.hnc.Discord"), "password managers are never captured")
        check(WritingCaptureService.isAllowed(bundleID: "com.hnc.Discord", apps: ["com.hnc.Discord"]), "an added app is captured")
        check(!WritingCaptureService.isAllowed(bundleID: "com.apple.Terminal", apps: ["com.apple.Terminal"]), "a terminal isn't, even when added")
        var added: [String] = []
        let hosting = NSHostingView(rootView: CaptureAppPicker(current: ["com.apple.mail"]) { added = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(800))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capture(hosting, name: "capture-picker", directory: directory)
        captureScrollContents(hosting, name: "capture-picker", directory: directory)
        window.close()
        _ = added
        print(failures == 0 ? "CAPTURE_PICKER_OK" : "CAPTURE_PICKER_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// Prompts sent to AI tools in the terminal, kept from each one's own record while capture is on, in a throwaway home
    /// folder: Claude Code, Codex, Gemini CLI, Copilot CLI, OpenCode, a tool described in agent-harnesses.json, and a hook.
    @MainActor
    static func agentCaptureSelfTest() async -> Int32 {
        guard AppPaths.isDemo, let home = ProcessInfo.processInfo.environment["BINDERS_AGENT_HOME"] else {
            print("ERROR: set BINDERS_DATA_DIR and BINDERS_AGENT_HOME to throwaway folders")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let manager = FileManager.default
        func file(_ path: String) -> URL {
            let url = URL(fileURLWithPath: home).appendingPathComponent(path)
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        func json(_ object: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        func append(_ text: String, to url: URL) {
            if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
            let handle = try! FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        func claudeLine(_ display: String) -> String { json(["display": display, "timestamp": now, "project": "/Users/someone/Acme/app", "sessionId": "s1"]) + "\n" }
        let claude = file(".claude/history.jsonl"), codex = file(".codex/history.jsonl")
        let gemini = file(".gemini/tmp/3f2a9c/logs.json"), copilot = file(".copilot/command-history-state.json")
        let opencode = file(".local/share/opencode/opencode.db"), mine = file(".mytool/prompts.jsonl")
        append(claudeLine("An old prompt from before capture was on"), to: claude)
        append(json(["session_id": "c0", "ts": 1_700_000_000, "text": "An old Codex prompt from last week"]) + "\n", to: codex)
        try? json([["sessionId": "g", "messageId": 0, "type": "user", "message": "An old Gemini question from yesterday", "timestamp": "2026-09-30T10:00:00.000Z"]])
            .write(to: gemini, atomically: true, encoding: .utf8)
        try? json(["commandHistory": ["an old copilot request from before"]]).write(to: copilot, atomically: true, encoding: .utf8)
        func sqlite(_ sql: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [opencode.path, sql]
            try? process.run()
            process.waitUntilExit()
        }
        sqlite("""
            CREATE TABLE session (id TEXT, directory TEXT); CREATE TABLE message (id TEXT, session_id TEXT, data TEXT);
            CREATE TABLE part (id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            INSERT INTO session VALUES ('s1', '/Users/someone/Acme/site');
            INSERT INTO message VALUES ('m0', 's1', '{"role":"user"}');
            INSERT INTO part VALUES ('p0', 'm0', 's1', \(now - 86_400_000), '{"type":"text","text":"An old OpenCode request from yesterday"}');
            """)
        try? json([["id": "mytool", "name": "My Tool", "format": "jsonl", "path": "~/.mytool/prompts.jsonl", "text": "prompt", "project": "cwd"]])
            .write(to: AgentHarnesses.customFile, atomically: true, encoding: .utf8)

        let controller = DictationController()
        let capture = controller.capture
        func records() -> [WritingRecord] { (try? Store.shared.context.fetch(FetchDescriptor<WritingRecord>())) ?? [] }
        func has(_ tool: String, _ text: String) -> Bool { records().contains { $0.appName == tool && $0.text == text } }
        capture.start(requireAccessibility: false)
        check(manager.fileExists(atPath: AgentHarnesses.captureFlag.path), "capture on tells hooks to hand prompts over")
        try? await Task.sleep(for: .milliseconds(300))

        append(claudeLine("Refactor the attachment downloader so a cancelled download leaves nothing behind"), to: claude)
        append(claudeLine("/clear") + claudeLine("yes") + claudeLine("!git status --short"), to: claude)
        append(claudeLine("Use the token sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij0123 for the test run"), to: claude)
        append(json(["session_id": "c1", "ts": 1_759_334_400, "text": "Write the release notes for the built-in models"]) + "\n", to: codex)
        append(String(claudeLine("A prompt still being written").dropLast(4)), to: claude)
        try? json([["sessionId": "g", "messageId": 0, "type": "user", "message": "An old Gemini question from yesterday", "timestamp": "2026-09-30T10:00:00.000Z"],
                   ["sessionId": "g", "messageId": 1, "type": "user", "message": "Explain how the update feed is signed", "timestamp": "2026-10-02T10:00:00.000Z"],
                   ["sessionId": "g", "messageId": 2, "type": "gemini", "message": "The feed is signed with an EdDSA key", "timestamp": "2026-10-02T10:00:05.000Z"]])
            .write(to: gemini, atomically: true, encoding: .utf8)
        try? json(["commandHistory": ["an old copilot request from before", "add a test for the tables parser"]]).write(to: copilot, atomically: true, encoding: .utf8)
        sqlite("""
            INSERT INTO message VALUES ('m1', 's1', '{"role":"user"}'); INSERT INTO message VALUES ('m2', 's1', '{"role":"assistant"}');
            INSERT INTO part VALUES ('p1', 'm1', 's1', \(now + 5_000), '{"type":"text","text":"Make the site download button point at 0.6.1"}');
            INSERT INTO part VALUES ('p2', 'm1', 's1', \(now + 5_000), '{"type":"text","text":"Called the Read tool with a file","synthetic":true}');
            INSERT INTO part VALUES ('p3', 'm2', 's1', \(now + 6_000), '{"type":"text","text":"Done, the button now points at 0.6.1"}');
            """)
        append(json(["prompt": "Rename the binder picker in the toolbar", "cwd": "/Users/someone/Acme/tools"]) + "\n", to: mine)
        // A hook, the way a tool runs it: Binders as a command, the prompt on stdin.
        func hook(_ payload: String, tool: String) {
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = ["--capture-prompt", "--tool", tool]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = Pipe()
            try? process.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        hook(json(["prompt": "Add keyboard shortcuts to the pop-out window", "workspace_roots": ["/Users/someone/Acme/app"]]), tool: "Cursor")
        try? await Task.sleep(for: .seconds(2.5))

        print("KEPT: " + records().map { "[\($0.appName ?? "")] \($0.text)" }.joined(separator: " | "))
        check(has("Claude Code", "Refactor the attachment downloader so a cancelled download leaves nothing behind")
              && records().contains { $0.subject == "Claude Code · Acme/app" }, "Claude Code, filed under its project")
        check(has("Codex", "Write the release notes for the built-in models"), "Codex")
        check(has("Gemini CLI", "Explain how the update feed is signed") && !records().contains { $0.text.contains("EdDSA") }, "Gemini CLI, without the model's reply")
        check(has("GitHub Copilot CLI", "add a test for the tables parser"), "Copilot CLI")
        check(has("OpenCode", "Make the site download button point at 0.6.1") && !records().contains { $0.text.contains("Called the Read tool") || $0.text.hasPrefix("Done,") },
              "OpenCode, without its own notes or replies")
        check(has("My Tool", "Rename the binder picker in the toolbar"), "a tool described in agent-harnesses.json")
        check(has("Cursor", "Add keyboard shortcuts to the pop-out window"), "a prompt handed over by a hook")
        check(!records().contains { $0.text.hasPrefix("An old") || $0.text.hasPrefix("an old") }, "nothing from before capture was on")
        check(!records().contains { ["/clear", "yes", "!git status --short"].contains($0.text) }, "commands and short replies left out")
        check(records().contains { $0.redactions > 0 && !$0.text.contains("sk-ant-api03") }, "a key in a prompt is redacted")
        check(records().allSatisfy { $0.analyzedAt != nil }, "prompts aren't read for promises")

        capture.stop()
        check(!manager.fileExists(atPath: AgentHarnesses.captureFlag.path), "capture off: hooks hand nothing over")
        let before = records().count
        let hookBytes = (try? Data(contentsOf: AgentHarnesses.hookRecord))?.count ?? 0
        append(claudeLine("Sent after capture was turned off"), to: claude)
        hook("Also sent after capture was turned off", tool: "Cursor")
        try? await Task.sleep(for: .seconds(2))
        check(records().count == before && ((try? Data(contentsOf: AgentHarnesses.hookRecord))?.count ?? 0) == hookBytes, "and nothing is kept once it's off")
        print(failures == 0 ? "AGENT_CAPTURE_OK" : "AGENT_CAPTURE_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// Fixing what the knowledge base has wrong, through the AI tools: editing a note, and a correction that search and
    /// answers follow while the meeting stays as it was said. A throwaway store.
    @MainActor
    static func correctionsSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: run with BINDERS_DATA_DIR pointing at a throwaway folder")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let controller = DictationController()
        let knowledge = controller.knowledge
        let write = MCPServer.writeInApp(controller: controller)
        func call(_ tool: String, _ arguments: [String: Any]) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: knowledge, write: write)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        let binder = Store.shared.defaultBinder()
        let note = NoteItem(text: "# Launch plan\n\nThe launch is on the 21st. Pricing is annual, at 15% off.")
        note.binderID = binder.id
        Store.shared.insert(note)
        let meeting = MeetingRecord(title: "Launch review", appName: "Zoom", templateID: "general")
        meeting.status = "ready"
        meeting.binderID = binder.id
        meeting.summary = "## Decisions\n- The launch is on the 21st, with annual pricing.\n- Support gets the macros by Friday."
        Store.shared.insert(meeting)
        Store.shared.save()
        await knowledge.indexNow()

        // Editing a note: one passage, then the errors.
        var result = await call("update_note", ["id": note.id.uuidString, "find": "at 15% off", "replace": "at 20% off"])
        check(result.ok && note.text.contains("at 20% off") && NoteHistory.versions(of: note.id).first?.text.contains("at 15% off") == true,
              "update_note changes a passage and keeps the earlier version: \(result.text)")
        result = await call("update_note", ["id": note.id.uuidString, "find": "monthly pricing", "replace": "x"])
        check(!result.ok && result.text.contains("isn't in"), "a passage that isn't there is refused: \(result.text)")
        result = await call("correct_knowledge", ["wrong": "21st", "right": "28th"])
        check(!result.ok, "a correction too short to recognise is refused: \(result.text)")

        // A correction for what the meeting said: the meeting stays, the correction is kept, search marks it.
        result = await call("correct_knowledge", ["wrong": "The launch is on the 21st", "right": "The launch is on the 28th",
                                                  "source_id": meeting.id.uuidString, "reason": "Maya moved it on Monday"])
        print("CORRECTION: \(result.text)")
        check(result.ok && meeting.summary.contains("21st"), "the meeting stays as it was said")
        let corrections = knowledge.corrections()
        check(corrections.count == 1 && corrections[0].correction.source == "Launch review", "the correction is kept, linked to the meeting")
        // And the note that said the same is fixed when it's named.
        result = await call("correct_knowledge", ["wrong": "The launch is on the 21st", "right": "The launch is on the 28th",
                                                  "source_id": note.id.uuidString])
        check(result.ok && note.text.contains("The launch is on the 28th") && !note.text.contains("21st"), "a note that says it is fixed: \(result.text)")
        check(knowledge.corrections().count == 1, "the same correction again is the same correction, not a second one")
        await knowledge.indexNow()
        let found = await call("search_knowledge", ["query": "launch date", "kind": "meeting"])
        let hits = (try? JSONSerialization.jsonObject(with: Data(found.text.utf8)) as? [[String: Any]]) ?? []
        let marked = hits.first { $0["title"] as? String == "Launch review" }?["corrected"] as? [String: Any]
        check(marked?["right"] as? String == "The launch is on the 28th", "search marks the meeting's passage with the correction")

        // An answer from the correction, with the model in Settings (for a quick run: -llmProvider mlx -mlxModel a small one).
        if AppSettings.shared.makeLLMClient() != nil {
            let answer = await knowledge.ask("When is the launch?")
            print("ANSWER: \(answer.text)")
            print("SOURCES: " + answer.sources.map(\.title).joined(separator: " | "))
            check(answer.sources.first?.title.hasPrefix("Correction") == true, "the correction is the answer's first source")
            check(answer.text.contains("28") && !answer.text.lowercased().contains("is on the 21st"), "and the answer gives the corrected date")
            check(answer.sources.filter { $0.title.hasPrefix("Correction") }.count == 1, "the same correction is listed once")
        }
        print(failures == 0 ? "CORRECTIONS_OK" : "CORRECTIONS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// Adding code blocks to a note that already has words, every way there is: the toolbar, the / menu, typing ```.
    @MainActor
    static func codeBlockSelfTest() async -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        var text = "# Release checklist\n\nBuild the archive, then notarize it.\n\n- [ ] Upload\n- [x] Test\n\n| Step | Who |\n| --- | --- |\n| Build | Maya |\n\nLast line"
        let hosting = NSHostingView(rootView: MarkdownNoteEditor(text: Binding(get: { text }, set: { text = $0 })).frame(width: 700, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        guard let editor = find(hosting) else { check(false, "the editor opens"); return 1 }
        window.makeFirstResponder(editor)
        // Resting the pointer on selected text would otherwise ask macOS for every share extension, on the main thread.
        check(!editor.usesRolloverButtonForSelection, "no share button over a selection")
        func type(_ characters: String) {
            for character in characters {
                if character == "\n" { editor.insertNewline(nil) } else { editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            }
        }
        func at(_ phrase: String, end: Bool = true) {
            let range = (editor.string as NSString).range(of: phrase)
            editor.setSelectedRange(NSRange(location: end ? NSMaxRange(range) : range.location, length: 0))
        }
        // The toolbar's {} in the middle of a paragraph, on an empty line, over a selection, at the very end.
        at("then notarize it.")
        editor.run(.codeBlock)
        type("xcodebuild archive\nxcrun notarytool submit")
        at("- [x] Test")
        editor.insertNewline(nil)
        editor.run(.codeBlock)
        type("echo done")
        editor.setSelectedRange((editor.string as NSString).range(of: "Last line"))
        editor.run(.codeBlock)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.run(.codeBlock)
        type("let x = 1 // a comment\n")
        // The / menu, and typing a fence by hand, with a language, inside a list and next to the table.
        at("| Build | Maya |")
        editor.insertNewline(nil)
        editor.insertNewline(nil)
        type("/code")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        type("SELECT 1; -- one")
        at("- [ ] Upload")
        editor.insertNewline(nil)
        type("```swift\nfunc go() { print(\"hi\") }\n```\n")
        check(!editor.string.contains("- [ ] \n```") && !editor.string.contains("- [ ] ```") && !editor.string.contains("- [ ] func go"),
              "a code block started in a checklist leaves no empty item and no markers on its lines")
        check(editor.string.contains("\n```swift\nfunc go() { print(\"hi\") }\n```\n"), "a fence typed in a checklist opens a code block")
        // Undo all the way back, and redo again.
        while editor.undoManager?.canUndo == true { editor.undoManager?.undo() }
        check(editor.string.hasPrefix("# Release checklist") && editor.string.contains("then notarize it.") && !editor.string.contains("```"),
              "undo takes every code block back out")
        while editor.undoManager?.canRedo == true { editor.undoManager?.redo() }
        MarkdownEditor.flushAll()
        try? await Task.sleep(for: .milliseconds(300))
        print("NOTE:\n\(editor.string)\n---")
        check(editor.string.components(separatedBy: "```").count >= 9, "the code blocks are all there after redo")
        // The view drew and laid out every line without trouble.
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        editor.display()
        check(true, "nothing threw while adding, typing, undoing and drawing")
        window.close()
        print(failures == 0 ? "CODE_BLOCKS_OK" : "CODE_BLOCKS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// How long the toolbar's code block button takes in a long note on the Notes page.
    @MainActor
    static func codeBlockSpeedSelfTest() async -> Int32 {
        guard AppPaths.isDemo else { return 1 }
        let controller = DictationController()
        let binder = Store.shared.defaultBinder()
        let sections = Int(ProcessInfo.processInfo.environment["BINDERS_SPEED_SECTIONS"] ?? "") ?? 200
        var body = "# A long working note\n\n"
        for index in 0..<sections {
            body += "## Part \(index)\n\nSome words about part \(index), with **bold**, a [link](https://example.com/\(index)) and a [[Linked note]].\n\n"
            body += "- [ ] Something to do in part \(index)\n- [x] Something done\n  - nested point\n\n"
            if index % 5 == 0 { body += "```swift\nlet value\(index) = \(index) // part \(index)\nprint(value\(index))\n```\n\n" }
            if index % 10 == 0 { body += "| Name | Value |\n| --- | ---: |\n| part | \(index) |\n\n" }
        }
        let note = NoteItem(text: body)
        note.binderID = binder.id
        Store.shared.insert(note)
        let navigation = HubNavigation()
        navigation.binderID = binder.id
        navigation.selection = .binder
        navigation.pendingBinderTab = .notes
        let hosting = NSHostingView(rootView: HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(800))
        navigation.pendingNoteID = note.id
        try? await Task.sleep(for: .milliseconds(1500))
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        guard let editor = find(hosting) else { print("FAIL: editor"); return 1 }
        print("NOTE: \((editor.string as NSString).length) characters")
        window.makeFirstResponder(editor)
        for (label, place) in [("start", 30), ("middle", (editor.string as NSString).length / 2), ("end", (editor.string as NSString).length)] {
            editor.setSelectedRange(NSRange(location: place, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            try? await Task.sleep(for: .milliseconds(300))
            print("CODE_BLOCK_START \(label)")
            fflush(stdout)
            let started = Date()
            editor.run(.codeBlock)
            editor.display()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
            let typed = Date()
            MarkdownEditor.flushAll()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
            print(String(format: "CODE_BLOCK %@: %.0f ms to show, %.0f ms for the page to catch up", label,
                         typed.timeIntervalSince(started) * 1000, Date().timeIntervalSince(typed) * 1000))
            fflush(stdout)
        }
        window.close()
        return 0
    }
}
