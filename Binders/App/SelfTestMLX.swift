import AppKit
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
