import AppKit
import ApplicationServices
import CryptoKit
import SwiftData
import SwiftUI
import BindersKit

/// Headless checks that exercise the real engines and formatter without permissions or UI.
///
///     Binders --selftest-audio speech.wav [--model parakeetV2] [--bundle com.tinyspeck.slackmacgap]
///     Binders --selftest-text "um so let's meet at 2 actually 3" [--bundle …] [--url …]
///     Binders --selftest-command "make this shorter" --selection "Some long text"
///     Binders --selftest-meeting recording.wav [--snapshot dir] [--keep]
///     Binders --selftest-snapshot dir
///     Binders --selftest-align reference.wav candidate.wav
///     Binders --selftest-notes <meeting id> [--save]
///     Binders --selftest-rescue <meeting id> --file recording.wav [--offset seconds]
///     Binders --selftest-conversation   (in a throwaway BINDERS_DATA_DIR)
///     Binders --selftest-teamdb-schema | -cases | -live | -outbox | -security | -vectors | -boards | -agents | -team | -notes | -move
///                                       | -meetings | -knowledge | -todos | -update | -reads | -move-folders | -reach | -open-perf
///                                       | -join-copies
///                                                                           (each with a throwaway Postgres)
enum SelfTest {
    static func start(arguments: [String]) {
        Task { @MainActor in
            let code = await run(arguments)
            fflush(stdout)
            exit(code)
        }
    }

    @MainActor
    private static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let settings = AppSettings.shared
        let context = AppContext(bundleID: value("--bundle"), appName: value("--app") ?? value("--bundle"), url: value("--url"),
                                 textBeforeCursor: value("--before"), selectedText: value("--selection"))
        print("LLM: \(settings.llmProvider.rawValue) \(settings.llmModelName) · AI formatting \(settings.aiFormatting ? "on" : "off")")
        print("CATEGORY: \(StyleResolver.category(for: context, overrides: settings.styles.appOverrides).rawValue)")
        // --vocab "Term=heard as,heard as;Other term" tries dictionary words without touching the store.
        let vocabulary = value("--vocab").map { list in
            list.split(separator: ";").map { entry in
                let parts = entry.split(separator: "=", maxSplits: 1)
                return VocabularyTerm(term: String(parts[0]).trimmed,
                                      aliases: parts.count > 1 ? parts[1].split(separator: ",").map { String($0).trimmed } : [])
            }
        } ?? Store.shared.vocabulary()

        if let path = value("--selftest-audio") {
            let model = value("--model").flatMap(SpeechModelID.init(rawValue:)) ?? settings.speechModel
            let engine: any SpeechEngine = model.isParakeet ? ParakeetEngine(modelID: model) : WhisperEngine()
            print("MODEL: \(model.rawValue) downloaded=\(engine.isDownloaded())")
            do {
                let loadStart = Date()
                var lastReported = -1
                try await engine.load { fraction in
                    let percent = Int(fraction * 100)
                    if percent / 10 != lastReported / 10 {
                        lastReported = percent
                        print("  progress \(percent)%")
                    }
                }
                print("LOAD_MS: \(ms(since: loadStart))")
                let samples = try AudioRecorder.readSamples(from: URL(fileURLWithPath: path))
                print("AUDIO_SECONDS: \(String(format: "%.2f", Double(samples.count) / AudioRecorder.sampleRate)) silent=\(AudioMath.isSilent(samples))")
                let audio = AudioMath.normalize(samples)
                var raw = ""
                for pass in 1...2 {
                    let start = Date()
                    raw = try await engine.transcribe(audio, language: settings.languageHint, vocabulary: vocabulary, boost: settings.vocabularyBoost)
                    print("ASR_MS_PASS\(pass): \(ms(since: start))")
                }
                print("RAW: \(raw)")
                await printFormatted(raw: raw, context: context, vocabulary: vocabulary)
                return 0
            } catch {
                print("ERROR: \(error.localizedDescription)")
                return 1
            }
        }

        if let raw = value("--selftest-text") {
            await printFormatted(raw: raw, context: context, vocabulary: vocabulary)
            return 0
        }

        if let instruction = value("--selftest-command") {
            let start = Date()
            let outcome = await TextFormatter.command(instruction: instruction, context: context)
            print("COMMAND_MS: \(ms(since: start))")
            print("OUTCOME: \(outcome)")
            return 0
        }

        if let path = value("--selftest-meeting") {
            let speech = SpeechService()
            speech.activate(value("--model").flatMap(SpeechModelID.init(rawValue:)) ?? settings.speechModel, download: true)
            let service = MeetingService(speech: speech, flowBar: FlowBarController())
            let start = Date()
            guard let record = await service.importRecording(URL(fileURLWithPath: path)) else {
                print("ERROR: nothing transcribed")
                return 1
            }
            print("MEETING_MS: \(ms(since: start))")
            print("STATUS: \(record.status)\(record.errorMessage.map { " (\($0))" } ?? "")")
            print("SPEAKERS: \(record.speakerNames)")
            print("----- MARKDOWN -----")
            print(service.markdown(for: record))
            if let question = value("--ask") {
                let askStart = Date()
                await service.ask(question, about: record)
                print("ASK_MS: \(ms(since: askStart))")
                print("Q: \(question)")
                print("A: \(record.chat.last?.text ?? "(none)")")
            }
            if let directory = value("--snapshot") {
                for tab in [MeetingDetailView.DetailTab.summary, .transcript] {
                    await render(MeetingDetailView(meeting: record, onDelete: {}, initialTab: tab)
                        .environment(service)
                        .environment(TeamSyncService(flowBar: nil))
                        .modelContainer(Store.shared.container),
                        size: NSSize(width: 820, height: 760), name: "meeting-\(tab)", directory: URL(fileURLWithPath: directory))
                }
            }
            if !args.contains("--keep") { Store.shared.deleteMeeting(record) }
            return 0
        }

        if let systemPath = value("--selftest-finalize") {
            // Finishes a meeting from saved recordings with no live transcript, like after a quit or storage failure.
            let speech = SpeechService()
            speech.activate(settings.speechModel, download: true)
            let service = MeetingService(speech: speech, flowBar: FlowBarController())
            let record = MeetingRecord(title: MeetingService.placeholderPrefix + "finalize test", appName: "Self-test",
                                       templateID: settings.meetingTemplateID)
            let systemURL = AppPaths.meetings.appendingPathComponent("\(record.id.uuidString)-system.wav")
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: systemPath), to: systemURL)
            record.systemAudioFile = systemURL.lastPathComponent
            var micURL: URL?
            if let micPath = value("--mic") {
                let url = AppPaths.meetings.appendingPathComponent("\(record.id.uuidString)-mic.wav")
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: micPath), to: url)
                record.micAudioFile = url.lastPathComponent
                micURL = url
            }
            record.status = "processing"
            Store.shared.insert(record)
            let start = Date()
            await service.finalize(record, micURL: micURL, systemURL: systemURL)
            print("FINALIZE_MS: \(ms(since: start))")
            guard record.modelContext != nil, !record.isDeleted else {
                print("DISCARDED: audio files left = \([systemURL, micURL].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }.count)")
                return 0
            }
            print("STATUS: \(record.status)\(record.errorMessage.map { " (\($0))" } ?? "")")
            print("SPEAKERS: \(record.speakerNames)")
            print("ID: \(record.id.uuidString)")
            print(service.markdown(for: record))
            if !args.contains("--keep") { Store.shared.deleteMeeting(record) }
            return 0
        }

        if let path = value("--selftest-extract"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
            guard let client = settings.makeLLMClient() else { print("ERROR: no model"); return 1 }
            let start = Date()
            do {
                let output = try await client.complete(system: EntityExtraction.systemPrompt(), user: "Title: Test\n\n\(text)",
                                                       maxTokens: 1500, temperature: 0, timeout: 300)
                print("EXTRACT_MS: \(ms(since: start)) chars=\(output.count)")
                print("RAW: \(output)")
                let parsed = EntityExtraction.parse(output)
                print("PARSED: \(parsed.entities.map { "\($0.name) [\($0.type)]" }.joined(separator: ", "))")
                print("RELATIONS: \(parsed.relations.map { "\($0.from) -\($0.label)-> \($0.to)" }.joined(separator: "; "))")
            } catch {
                print("ERROR: \(error.localizedDescription)")
            }
            return 0
        }

        if let question = value("--selftest-knowledge") {
            let speech = SpeechService()
            speech.activate(settings.speechModel, download: true)
            let meetings = MeetingService(speech: speech, flowBar: FlowBarController())
            var imported: MeetingRecord?
            if let path = value("--meeting") {
                imported = await meetings.importRecording(URL(fileURLWithPath: path))
                print("IMPORTED: \(imported?.title ?? "nothing")")
            }
            let knowledge = KnowledgeService()
            let indexStart = Date()
            await knowledge.indexNow()
            print("INDEX_MS: \(ms(since: indexStart)) — \(knowledge.status)")
            let entities = await knowledge.store.entities(limit: 25)
            print("ENTITIES: " + entities.map { "\($0.name) [\($0.type), \($0.documents)]" }.joined(separator: ", "))
            let searchStart = Date()
            let hits = await knowledge.search(value("--query") ?? question)
            print("SEARCH_MS: \(ms(since: searchStart)) — \(hits.count) hits")
            for hit in hits.prefix(6) {
                let preview = hit.snippet.isEmpty ? String(hit.text.prefix(110)) : hit.snippet
                print("  HIT [\(hit.kind.rawValue)] \(hit.title) · \(hit.metaLine): \(preview.replacingOccurrences(of: "\n", with: " "))")
            }
            print("VOICE_LOOKUP: \(KnowledgeQueryIntent.query(from: question) ?? "(not a lookup)")")
            let askStart = Date()
            let answer = await knowledge.ask(question)
            print("ASK_MS: \(ms(since: askStart))")
            print("ANSWER: \(answer.text)")
            let graph = await knowledge.store.graph(documentLimit: 60, entityLimit: 140)
            print("GRAPH: \(graph.nodes.count) nodes, \(graph.edges.count) edges")
            if let directory = value("--snapshot") {
                let navigation = HubNavigation()
                navigation.pendingKnowledgeQuery = question
                let dir = URL(fileURLWithPath: directory)
                await render(KnowledgeGraphView(selectedEntityID: .constant(nil)).environment(knowledge).padding(),
                             size: NSSize(width: 900, height: 640), name: "knowledge-graph", directory: dir)
                if let top = entities.first {
                    await render(EntityDetailView(entityID: top.id, onSelect: { _ in }, onAsk: { _ in }, onRemoved: {}).environment(knowledge).padding(),
                                 size: NSSize(width: 760, height: 700), name: "knowledge-entity", directory: dir)
                }
                await render(KnowledgeAnswerView(answer: answer).padding(), size: NSSize(width: 700, height: 420), name: "knowledge-answer", directory: dir)
            }
            if let imported, !args.contains("--keep") {
                Store.shared.deleteMeeting(imported)
                await knowledge.indexNow()
            }
            return 0
        }

        func meeting(_ id: UUID) -> MeetingRecord? {
            try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })).first
        }

        if let referencePath = value("--selftest-align") {
            // Where does a second recording of the same event start? Prints the offset of the candidate against the reference.
            guard let index = args.firstIndex(of: "--selftest-align"), args.indices.contains(index + 2) else {
                print("Usage: --selftest-align reference.wav candidate.wav")
                return 1
            }
            let start = Date()
            do {
                let reference = try AudioRecorder.readSamples(from: URL(fileURLWithPath: referencePath))
                let candidate = try AudioRecorder.readSamples(from: URL(fileURLWithPath: args[index + 2]))
                guard let match = AudioAlign.align(referenceLevels: AudioAlign.levels(reference), candidateLevels: AudioAlign.levels(candidate)) else {
                    print("NO_MATCH")
                    return 1
                }
                print("OFFSET: \(String(format: "%.3f", match.offset))")
                print("CONFIDENCE: \(String(format: "%.1f", match.confidence)) (\(match.confidence >= AudioAlign.strongMatch ? "strong" : "weak"))")
                print("ALIGN_MS: \(ms(since: start))")
                return 0
            } catch {
                print("ERROR: \(error.localizedDescription)")
                return 1
            }
        }

        if let id = value("--selftest-notes").flatMap(UUID.init(uuidString:)) {
            // Rewrites the notes for a stored meeting and prints them; the store is only changed with --save.
            let service = MeetingService(speech: SpeechService(), flowBar: FlowBarController())
            guard let record = meeting(id) else {
                print("ERROR: no meeting \(id)")
                return 1
            }
            let before = (record.summary, record.title, record.speakerNamesJSON, record.errorMessage, record.templateID)
            let start = Date()
            await service.summarize(record, templateID: value("--template"))
            print("NOTES_MS: \(ms(since: start))")
            print("SPEAKERS: \(record.speakerNames)")
            print("STATUS: \(record.errorMessage ?? "ok")")
            print("----- NOTES -----")
            print("# \(record.title)\n\n\(record.summary)")
            if !args.contains("--save") {
                (record.summary, record.title, record.speakerNamesJSON, record.errorMessage, record.templateID) = before
                Store.shared.save()
            }
            return 0
        }

        if let id = value("--selftest-rescue").flatMap(UUID.init(uuidString:)), let path = value("--file") {
            // Replaces a stored meeting's mic track with another recording, lines it up, re-transcribes and rewrites notes. Persists.
            let speech = SpeechService()
            speech.activate(settings.speechModel, download: true)
            let service = MeetingService(speech: speech, flowBar: FlowBarController())
            guard let record = meeting(id) else {
                print("ERROR: no meeting \(id)")
                return 1
            }
            let start = Date()
            let result = await service.replaceMicTrack(record, with: URL(fileURLWithPath: path), offset: value("--offset").flatMap(Double.init))
            print("RESCUE_MS: \(ms(since: start))")
            if let result {
                print("OFFSET: \(String(format: "%.3f", result.offset)) CONFIDENCE: \(String(format: "%.1f", result.confidence)) AGAINST: \(result.matchedAgainst) SEGMENTS: \(result.segments)")
            } else {
                print("FAILED: \(service.activity[id] ?? "unknown")")
            }
            print("SPEAKERS: \(record.speakerNames)")
            print("STATUS: \(record.errorMessage ?? "ok")")
            print("----- MARKDOWN -----")
            print(service.markdown(for: record))
            if args.contains("--cleanup") { Store.shared.deleteMeeting(record) }
            return result == nil ? 1 : 0
        }

        if let path = value("--selftest-render-notes"), let directory = value("--dir"),
           let markdown = try? String(contentsOfFile: path, encoding: .utf8) {
            // Renders the notes view (clickable tasks and all) for a Markdown file, to eyeball the renderer headlessly.
            await render(ScrollView { MarkdownBlocks(markdown: markdown, onToggleTask: { _ in }).padding(20) },
                         size: NSSize(width: 700, height: 520), name: "notes-render", directory: URL(fileURLWithPath: directory))
            return 0
        }

        if let path = value("--selftest-digest"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
            // Writes a digest for the note text in a file with the configured model; the note is discarded afterwards.
            let controller = DictationController()
            let note = NoteItem(text: text)
            Store.shared.insert(note)
            let start = Date()
            await controller.knowledge.digest(note)
            print("DIGEST_MS: \(ms(since: start))")
            print("STATUS: \(controller.knowledge.status.extractionIssue ?? "ok")")
            print("----- DIGEST -----")
            print(note.digest)
            if let directory = value("--snapshot") {
                await render(NoteEditor(note: note, onDelete: {})
                    .environment(controller.knowledge)
                    .environment(TeamSyncService(flowBar: nil))
                    .environment(AppSettings.shared),
                    size: NSSize(width: 920, height: 560), name: "note-digest", directory: URL(fileURLWithPath: directory))
            }
            Store.shared.delete(note)
            return 0
        }

        if args.contains("--selftest-notes-view") {
            // Opens the notes page on a throwaway store, clicks from note to note and resizes the window: opening a note
            // mustn't count as editing it, and the editor's text must stay within its column at every width.
            guard AppPaths.isDemo else {
                print("ERROR: run with BINDERS_DATA_DIR pointing at a throwaway folder")
                return 1
            }
            let controller = DictationController()
            let binder = Store.shared.defaultBinder()
            let texts = [
                "# Retrieval reading list\n\nPapers on search over small, personal corpora.\n\n- [ ] BM25 revisited, and whether good tokenisation closes the gap with dense retrieval on recall@10\n- [x] Hybrid search survey\n- Reciprocal rank fusion with k=60, and what happens when one retriever returns far fewer results\n  - Nested: try k=20 as well, on the mixed-language subset\n1. Chunking at 300 tokens with 50 overlap did best in their tests, sentence-level chunks did worst\n\n> Dense retrieval only pulls ahead past about 50k chunks, which is more than most people's notes will ever reach.",
                "# Chunking experiment\n\nTried 300 tokens with 50 overlap against sentence-level chunks. **Recall@10** went from 0.61 to 0.68, and \"why\" questions improved the most.\n\n```\nchunk=300 overlap=50\n```",
                "# Questions for the authors\n\n1. Is the eval set licensed for reuse?\n2. Did they try a multilingual encoder on mixed-language notes?",
            ]
            let notes = texts.enumerated().map { index, text in
                let note = NoteItem(text: text)
                note.binderID = binder.id
                note.updatedAt = Date().addingTimeInterval(-Double(index + 1) * 86_400)
                Store.shared.insert(note)
                return note
            }
            let before = notes.map(\.updatedAt)
            let navigation = HubNavigation()
            navigation.binderID = binder.id
            navigation.selection = .binder
            navigation.pendingBinderTab = .notes
            let hosting = NSHostingView(rootView: HubView()
                .environment(controller)
                .environment(controller.meetings)
                .environment(controller.knowledge)
                .environment(controller.team)
                .environment(controller.capture)
                .environment(controller.commitments)
                .environment(navigation)
                .environment(AppSettings.shared)
                .modelContainer(Store.shared.container))
            // Sized and set up like the real window.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720), styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 840, height: 560)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            hosting.wantsLayer = true
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(800))
            for note in notes + notes.reversed() {
                navigation.pendingNoteID = note.id
                try? await Task.sleep(for: .milliseconds(500))
            }
            var failed = false
            for (note, date) in zip(notes, before) where note.updatedAt != date {
                print("MOVED: opening “\(note.title)” marked it as edited")
                failed = true
            }
            func textViews(in view: NSView) -> [MarkdownTextView] {
                (view as? MarkdownTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
            }
            let directory = value("--dir").map { URL(fileURLWithPath: $0) }
            if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            // The hub window's narrowest is 840 points wide.
            print("OPENED: window \(Int(window.contentLayoutRect.width)), page \(Int(hosting.frame.width))")
            for width in stride(from: 1180, through: 840, by: -20).map({ $0 }) + stride(from: 860, through: 1400, by: 60).map({ $0 }) {
                window.setContentSize(NSSize(width: width, height: 720))
                try? await Task.sleep(for: .milliseconds(150))
                if hosting.frame.width > window.contentLayoutRect.width + 1 {
                    print("CLIPPED at \(width): the page is \(Int(hosting.frame.width)) wide in a \(Int(window.contentLayoutRect.width)) window")
                    failed = true
                }
                for textView in textViews(in: hosting) {
                    guard let clip = textView.enclosingScrollView?.contentView else { continue }
                    let off = abs(textView.frame.width - clip.bounds.width)
                    if off > 1 {
                        print("MISALIGNED at \(width): text \(Int(textView.frame.width)) wide in a \(Int(clip.bounds.width)) column")
                        failed = true
                    }
                    let line = (textView.textContainer?.size.width ?? 0) - 2 * (textView.textContainer?.lineFragmentPadding ?? 0)
                    if line < 240 {
                        print("CRAMPED at \(width): lines are \(Int(line)) points wide")
                        failed = true
                    }
                }
                if let directory, width == 840 || width == 1400 { capture(hosting, name: width == 840 ? "notes-narrowest" : "notes-wide", directory: directory) }
            }
            window.close()
            notes.forEach { Store.shared.delete($0) }
            print(failed ? "FAIL" : "OK")
            return failed ? 1 : 0
        }

        if args.contains("--selftest-notes-stress") {
            return await notesStressSelfTest()
        }

        if args.contains("--selftest-code-block-speed") {
            return await codeBlockSpeedSelfTest()
        }

        if let directory = value("--selftest-mermaid") {
            // Lane MM1: Mermaid diagrams drawn in the note editor, offline, in light and dark, with their mistakes.
            return await mermaidSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if args.contains("--selftest-code-blocks") {
            return await codeBlockSelfTest()
        }

        if args.contains("--selftest-corrections") {
            return await correctionsSelfTest()
        }

        if args.contains("--selftest-index") {
            return await indexSelfTest(noteCount: Int(value("--notes") ?? "") ?? 2_000)
        }

        if let directory = value("--selftest-ask") {
            // Ask's passages at once and its answer as it's written: the model clients, the Knowledge page, Command Mode's
            // panel and the phone link, with stand-ins for the models.
            return await askSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if let directory = value("--selftest-pages") {
            // Home, Today, the work-streams digest, the board's columns and the graph, on a heavy user's library.
            return await pagesSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if let directory = value("--selftest-window-fit") {
            // The main window keeps its size with a note, a meeting and a capture far longer than it. Seeds the demo data.
            return await windowFitSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if let directory = value("--selftest-settings") {
            // Settings in six pages: each part on one page, and a link to a part landing on its section. Seeds the demo data.
            return await settingsSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if let directory = value("--selftest-motion") {
            // Filing, rolling counts, the recording dot and the waveform, and how each behaves under Reduce Motion.
            return await motionSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if let directory = value("--selftest-theme") {
            // The design tokens: their values, how they read and follow the appearance, and a sheet of them in both.
            return await themeSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if args.contains("--selftest-agent-capture") {
            return await agentCaptureSelfTest()
        }

        if let directory = value("--selftest-capture-picker") {
            return await capturePickerSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if args.contains("--selftest-llm-bench") {
            return await llmBenchSelfTest(ollamaModel: value("--ollama") ?? AppSettings.shared.ollamaModel,
                                          mlxModel: value("--mlx") ?? "mlx-community/gemma-4-26b-a4b-it-4bit",
                                          rounds: Int(value("--rounds") ?? "") ?? 3)
        }

        if let model = value("--selftest-mlx") {
            return await mlxSelfTest(model: model, embedding: value("--embed"))
        }

        // The router model's dev tools: parity with Python and the router bench (SelfTestRouterModel.swift). They need the
        // model folder, so they aren't in the normal run.
        if args.contains("--selftest-router-model") {
            return await routerModelSelfTest(args)
        }
        if args.contains("--selftest-router-bench") {
            return await routerBenchSelfTest(args)
        }
        if args.contains("--selftest-solo-bench") {
            // Lane Y2's reading of a capture that's only you, on its bench, through this data folder's language model.
            return await soloBenchSelfTest(args)
        }

        if args.contains("--selftest-menus") {
            return await menusSelfTest()
        }

        if args.contains("--selftest-new-note") {
            return await newNoteSelfTest()
        }

        if let directory = value("--selftest-popouts") {
            return await popoutsSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if let directory = value("--selftest-slash") {
            return await slashMenuSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if args.contains("--selftest-notes-editing") {
            return await notesEditingSelfTest()
        }

        if let directory = value("--selftest-notes-media") {
            return await notesMediaSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if args.contains("--selftest-notes-speed") {
            return await notesSpeedSelfTest()
        }

        if args.contains("--selftest-notes-delete") {
            return await notesDeleteSelfTest()
        }

        if args.contains("--selftest-merge") {
            // Exercises rename and merge on a throwaway knowledge index: mentions move, relations follow, old names become aliases.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("binders-merge-\(UUID().uuidString).sqlite")
            let store = KnowledgeStore(url: url)
            defer { try? FileManager.default.removeItem(at: url) }
            await store.upsert(KnowledgeDocument(id: "note:1", kind: .note, sourceID: "1", title: "Booth", createdAt: Date(), contentHash: "h1"),
                               chunks: [KnowledgeChunk(text: "Noah Chen owns the booth. Samyr will run the tests."), KnowledgeChunk(text: "Samir built the smoke suite.")])
            guard let job = await store.nextEntityJob(kinds: [.note]) else { print("FAIL: no job"); return 1 }
            await store.saveEntities(job: job, result: ExtractionResult(
                entities: [ExtractedEntity(name: "Noah Chen", type: "person"), ExtractedEntity(name: "Samyr", type: "person"), ExtractedEntity(name: "Samir", type: "person")],
                relations: [ExtractedRelation(from: "Samyr", to: "Noah Chen", label: "works with")]))
            let initial = await store.entities(limit: 10)
            func id(_ name: String, in list: [KnowledgeEntity]) -> Int64? { list.first { $0.name == name }?.id }
            guard let samyr = id("Samyr", in: initial), let samir = id("Samir", in: initial), let noah = id("Noah Chen", in: initial) else {
                print("FAIL: entities \(initial.map(\.name))"); return 1
            }
            guard await store.merge(samyr, into: samir) else { print("FAIL: merge"); return 1 }
            let merged = await store.entities(limit: 10)
            print("AFTER_MERGE: \(merged.map { "\($0.name)=\($0.mentions)" })")
            print("RELATIONS: \(await store.relations(of: samir).map { "\($0.label) \($0.other)" })")
            let survivor = await store.rename(entityID: samir, to: "Samir Haddad")
            print("RENAMED_ID: \(survivor ?? -1) (was \(samir))")
            await store.upsert(KnowledgeDocument(id: "note:2", kind: .note, sourceID: "2", title: "Later", createdAt: Date(), contentHash: "h2"),
                               chunks: [KnowledgeChunk(text: "Samyr and Samir are the same person; Noah Chen agrees.")])
            guard let job2 = await store.nextEntityJob(kinds: [.note]) else { print("FAIL: no second job"); return 1 }
            await store.saveEntities(job: job2, result: ExtractionResult(
                entities: [ExtractedEntity(name: "Samyr", type: "person"), ExtractedEntity(name: "Samir", type: "person"), ExtractedEntity(name: "Noah Chen", type: "person")], relations: []))
            let after = await store.entities(limit: 10)
            let aliases = await store.aliases(of: survivor ?? samir)
            print("AFTER_REEXTRACTION: \(after.map { "\($0.name)=\($0.documents)docs" })")
            print("ALIASES: \(aliases)")
            let renameMerge = await store.rename(entityID: noah, to: "samir haddad")
            let end = await store.entities(limit: 10)
            print("RENAME_ONTO_EXISTING: \(renameMerge ?? -1) → \(end.map { "\($0.name)=\($0.documents)docs" })")
            let ok = merged.first { $0.name == "Samir" }?.mentions == 2 && after.count == 2 && aliases.contains("Samyr") && aliases.contains("Samir")
                && end.count == 1 && end.first?.documents == 2
            print(ok ? "MERGE_OK" : "MERGE_FAIL")
            return ok ? 0 : 1
        }

        if args.contains("--selftest-capture-rules") {
            // The allow, deny and recipient rules writing capture applies, on representative inputs.
            let apps = WritingCaptureService.defaultApps
            let hosts = WritingCaptureService.defaultHosts
            let checks: [(String, Bool, Bool)] = [
                ("teams desktop allowed", WritingCaptureService.isAllowed(bundleID: "com.microsoft.teams2", apps: apps), true),
                ("password manager denied", WritingCaptureService.isAllowed(bundleID: "com.1password.1password", apps: apps + ["com.1password.1password"]), false),
                ("terminal denied even if listed", WritingCaptureService.isAllowed(bundleID: "com.mitchellh.ghostty", apps: apps + ["com.mitchellh.ghostty"]), false),
                ("teams web allowed", WritingCaptureService.isAllowed(url: "https://teams.microsoft.com/v2/", hosts: hosts, allSites: false), true),
                ("gmail allowed", WritingCaptureService.isAllowed(url: "https://mail.google.com/mail/u/0/#inbox?compose=new", hosts: hosts, allSites: false), true),
                ("random site not allowed", WritingCaptureService.isAllowed(url: "https://example.com/post", hosts: hosts, allSites: false), false),
                ("random site allowed with all sites", WritingCaptureService.isAllowed(url: "https://example.com/post", hosts: hosts, allSites: true), true),
                ("login page never", WritingCaptureService.isAllowed(url: "https://login.microsoftonline.com/", hosts: hosts, allSites: true), false),
                ("banking site never", WritingCaptureService.isAllowed(url: "https://onlinebanking.example.com/accounts", hosts: hosts + ["example.com"], allSites: true), false),
                ("placeholder reads as empty", ContextReader.comparable("\u{200B}Type a message\n\u{2060}\u{2060}\u{2060}") == ContextReader.comparable("Type a message"), true),
                ("real text is not the placeholder", ContextReader.comparable("Type a message to Noah about the booth") == ContextReader.comparable("Type a message"), false),
                ("subject field is a header", WritingCaptureService.isHeaderOrSearchField(label: "subject"), true),
                ("search box is not writing", WritingCaptureService.isHeaderOrSearchField(label: "search (⌘ e) | search"), true),
                ("compose box is writing", WritingCaptureService.isHeaderOrSearchField(label: "type a message"), false),
                ("body is writing", WritingCaptureService.isHeaderOrSearchField(label: "message body | to noah about the booth"), false),
            ]
            var ok = true
            for (name, got, want) in checks {
                print("\(got == want ? "ok  " : "FAIL") \(name)")
                ok = ok && got == want
            }
            let teams = WritingCaptureService.recipients(from: AppContext(appName: "Microsoft Teams", windowTitle: "(2) Chat | Noah Chen | Microsoft Teams"), header: .init())
            let channel = WritingCaptureService.recipients(from: AppContext(appName: "Microsoft Teams", windowTitle: "General (Acme) | Microsoft Teams"), header: .init())
            let mail = WritingCaptureService.recipients(from: AppContext(appName: "Mail", windowTitle: "Re: Booth graphics"), header: .init(to: ["Noah Chen", "Samir Haddad"], subject: "Re: Booth graphics"))
            let selfChat = WritingCaptureService.recipients(from: AppContext(appName: "Microsoft Teams", windowTitle: "Chat | Maya Okafor (You) | Microsoft Teams"), header: .init())
            let browser = WritingCaptureService.recipients(from: AppContext(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Google - Google Chrome"), header: .init())
            let outlook = WritingCaptureService.recipients(from: AppContext(appName: "Microsoft Outlook", windowTitle: "Test • maya@example.com"), header: .init(to: ["\u{FFFC}"], subject: "Test"))
            print("RECIPIENTS teams=\(teams) channel=\(channel) mail=\(mail) self=\(selfChat) browser=\(browser) outlook=\(outlook)")
            ok = ok && teams == ["Noah Chen"] && channel == ["General (Acme)"] && mail == ["Noah Chen", "Samir Haddad"]
                && selfChat == ["Maya Okafor"] && browser.isEmpty && outlook.isEmpty
            print("SOURCES \(WritingCaptureService.source(bundleID: "com.google.Chrome", url: "https://teams.microsoft.com/x")) \(WritingCaptureService.source(bundleID: "com.apple.mail", url: nil)) \(WritingCaptureService.source(bundleID: "com.google.Chrome", url: "https://example.com"))")
            print(ok ? "CAPTURE_RULES_OK" : "CAPTURE_RULES_FAIL")
            return ok ? 0 : 1
        }

        if let path = value("--selftest-commitments"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
            // Promise detection on a sample message: the cheap screen, then the model, then the resolved due dates.
            let screened = CommitmentDetection.mayContainCommitment(text)
            print("SCREEN: \(screened ? "may contain a commitment" : "nothing to check")")
            guard screened else { return 0 }
            guard let client = settings.makeLLMClient() else { print("ERROR: no language model configured"); return 1 }
            let prompt = CommitmentDetection.userPrompt(text: text, app: value("--app"), recipients: value("--to"), subject: nil, date: Date())
            do {
                let started = Date()
                let output = try await client.complete(system: CommitmentDetection.systemPrompt(), user: prompt, maxTokens: 600, temperature: 0, timeout: 300)
                let found = CommitmentDetection.parse(output)
                print("MODEL: \(found.count) found in \(Int(Date().timeIntervalSince(started))) s")
                for raw in found {
                    let item = CommitmentDetection.personalize(raw, recipient: value("--to"))
                    let due = CommitmentDetection.dueDate(from: item.due, relativeTo: Date())
                    print("- [\(item.kind)] \(item.task) · to \(item.to ?? "?") · due \(item.due ?? "-") → \(due.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "no date")")
                    if let quote = item.quote { print("  \"\(quote)\"") }
                }
                if found.isEmpty { print("RAW: \(output.prefix(400))") }
                return 0
            } catch {
                print("ERROR: \(error.localizedDescription)")
                return 1
            }
        }

        if let feed = value("--selftest-update-check") {
            // Does Sparkle see a newer, signed version in this feed? Shows no window and installs nothing.
            let probe = UpdateProbe(feed: feed)
            let line = await probe.run()
            print(line)
            return line.hasPrefix("UPDATE_FOUND") || line.hasPrefix("NO_UPDATE") ? 0 : 1
        }

        if let path = value("--selftest-ollama-verify") {
            // Only the checks, on an app that is already on disk.
            let app = URL(fileURLWithPath: path)
            do {
                try OllamaInstaller.verifySignature(of: app)
                try await OllamaInstaller.verifyNotarization(of: app)
                print("VERIFY_OK")
                return 0
            } catch {
                print("VERIFY_REJECTED: \((error as? OllamaInstaller.InstallError)?.message ?? error.localizedDescription)")
                return 1
            }
        }

        if let directory = value("--selftest-ollama-install") {
            // The real download, signature check and notarization check, installed into a throwaway folder and never
            // launched. Also proves the signature check refuses an app that Ollama did not sign.
            let target = URL(fileURLWithPath: directory, isDirectory: true)
            let started = Date()
            let ok = await OllamaInstaller.shared.install(serverURL: settings.ollamaURL, into: target, launchAfter: false)
            print(ok ? "INSTALL_OK in \(ms(since: started)) ms" : "INSTALL_FAILED \(OllamaInstaller.shared.statusLine ?? "")")
            let placed = target.appendingPathComponent("Ollama.app")
            print("PLACED: \(FileManager.default.fileExists(atPath: placed.path))")
            do {
                try OllamaInstaller.verifySignature(of: Bundle.main.bundleURL)
                print("FAIL: an app signed by someone else passed the check")
                return 1
            } catch {
                print("REJECTS_OTHER_SIGNERS: \((error as? OllamaInstaller.InstallError)?.message.prefix(60) ?? "yes")")
            }
            return ok ? 0 : 1
        }

        if let name = value("--selftest-model-pull") {
            // Exercises the in-app model download against the local Ollama. An installed model returns at once.
            let ok = await ModelDownloader.shared.pull(name, from: settings.ollamaURL)
            print(ok ? "PULL_OK \(name)" : "PULL_FAILED \(name): \(ModelDownloader.shared.error ?? "unknown")")
            return ok ? 0 : 1
        }

        if args.contains("--selftest-model-status") {
            // Is the language model in memory, and does asking Ollama to free it work? --unload frees it.
            guard let client = settings.makeLLMClient() else { print("ERROR: no language model configured"); return 1 }
            func report(_ label: String) async {
                if let residency = await client.residency() {
                    let size = ByteCountFormatter.string(fromByteCount: residency.bytes, countStyle: .memory)
                    print("\(label): \(client.model) in memory, \(size), frees \(residency.expiresAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "never")")
                } else {
                    print("\(label): \(client.model) not in memory")
                }
            }
            print("RECOMMENDED for \(ModelDownloader.memoryGB) GB: \(ModelDownloader.recommendation.model) (\(ModelDownloader.recommendation.downloadGB) GB download)")
            await report("BEFORE")
            if args.contains("--unload") {
                await client.unload()
                try? await Task.sleep(for: .seconds(1))
                await report("AFTER UNLOAD")
            }
            print("MODEL_STATUS_OK")
            return 0
        }

        if args.contains("--selftest-capture-notify") {
            // Does an AXObserver on an application element deliver value and focus changes? Checked against this
            // process's own text view, which AppKit posts notifications for like any other app.
            final class Box { var names: [String] = [] }
            let box = Box()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            let textView = NSTextView(frame: window.contentView!.bounds)
            window.contentView?.addSubview(textView)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
            var observer: AXObserver?
            let created = AXObserverCreate(getpid(), { _, _, name, refcon in
                Unmanaged<Box>.fromOpaque(refcon!).takeUnretainedValue().names.append(name as String)
            }, &observer)
            guard created == .success, let observer else { print("NOTIFY_FAIL observer \(created.rawValue)"); return 1 }
            let app = AXUIElementCreateApplication(getpid())
            let refcon = Unmanaged.passUnretained(box).toOpaque()
            for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXFocusedUIElementChangedNotification] {
                let added = AXObserverAddNotification(observer, app, name as CFString, refcon)
                print("register \(name): \(added == .success ? "ok" : "error \(added.rawValue)")")
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            try? await Task.sleep(for: .seconds(0.5))
            textView.insertText("hello there capture", replacementRange: NSRange(location: 0, length: 0))
            try? await Task.sleep(for: .seconds(0.3))
            textView.insertText(" again", replacementRange: NSRange(location: textView.string.count, length: 0))
            try? await Task.sleep(for: .seconds(0.7))
            let counts = Dictionary(grouping: box.names, by: { $0 }).mapValues(\.count)
            print("received: \(counts)")
            let ok = (counts[kAXValueChangedNotification] ?? 0) >= 1
            print(ok ? "NOTIFY_OK" : "NOTIFY_FAIL")
            return ok ? 0 : 1
        }

        if args.contains("--selftest-capture-probe") {
            // What writing capture sees in a running app (roles, sizes, recipients), never the text. Defaults to the
            // frontmost app; --probe-app <bundle id> targets another one, --tree dumps its editable fields once.
            let seconds = value("--seconds").flatMap(Double.init) ?? 15
            print("trusted=\(AXIsProcessTrusted())")
            let end = Date().addingTimeInterval(seconds)
            var first = true
            while Date() < end {
                let app = value("--probe-app").flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
                    ?? NSWorkspace.shared.frontmostApplication
                guard let app else { print("no app"); return 1 }
                let bundleID = app.bundleIdentifier ?? ""
                print("--- \(Date().formatted(date: .omitted, time: .standard)) \(app.localizedName ?? "?") (\(bundleID)) allowed=\(WritingCaptureService.isAllowed(bundleID: bundleID, apps: settings.captureApps))")
                for line in ContextReader.probeReport(pid: app.processIdentifier, tree: args.contains("--tree") && first, enhanced: args.contains("--enhanced"), showText: args.contains("--show-text")) { print(line) }
                first = false
                fflush(stdout)
                try? await Task.sleep(for: .seconds(1.5))
            }
            return 0
        }

        if args.contains("--selftest-mcp-hosts") {
            // Which tools are here and whether Binders is in them; --add <host> adds it, as the Settings button would.
            for host in MCPHost.allCases {
                let status = host.status
                print("\(host.rawValue): \(status.present ? "present" : "absent"), \(status.configured ? "configured" : "not configured"), \(host.configURL.path)")
            }
            if let name = value("--add") {
                guard let host = MCPHost(rawValue: name) else {
                    print("No such host: \(name)")
                    return 2
                }
                do {
                    print(try await host.add())
                } catch {
                    print("FAILED: \(error.localizedDescription)")
                    return 1
                }
            }
            return 0
        }
        if let path = value("--selftest-store-check") {
            // Opens a copy of a store (never the real one) and counts what's in it: a check that a new schema migrates.
            let store = Store(url: URL(fileURLWithPath: path))
            func count<T: PersistentModel>(_ type: T.Type) -> Int { (try? store.context.fetchCount(FetchDescriptor<T>())) ?? -1 }
            print("FALLBACK: \(store.isFallback)")
            print("COUNTS: binders=\(count(BinderRecord.self)) notes=\(count(NoteItem.self)) meetings=\(count(MeetingRecord.self)) segments=\(count(MeetingSegmentRecord.self)) transcripts=\(count(TranscriptRecord.self)) writing=\(count(WritingRecord.self)) commitments=\(count(CommitmentRecord.self)) cards=\(count(TaskCard.self))")
            return store.isFallback ? 1 : 0
        }
        if args.contains("--selftest-board") {
            return await boardSelfTest()
        }
        if args.contains("--selftest-board-groups") {
            // A note's cards as one group on the board, and acting on many at once (lane DS5). A folder after the flag gets
            // drawings.
            return await boardGroupsSelfTest(drawingTo: value("--selftest-board-groups").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }
        if args.contains("--selftest-put-on-board") {
            // Put on Board tracked as Distill's cards are (lane DS6): the whole note, a selection, each line of a list. A
            // folder after the flag gets drawings.
            return await putOnBoardSelfTest(drawingTo: value("--selftest-put-on-board").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }
        if args.contains("--selftest-mcp-reads") {
            return await mcpReadsSelfTest()
        }
        if args.contains("--selftest-capture-records") {
            return captureRecordsSelfTest()
        }
        if args.contains("--selftest-capture-worker") {
            return await captureWorkerSelfTest()
        }
        if args.contains("--selftest-capture-index") {
            return captureIndexSelfTest()
        }
        if args.contains("--selftest-agents") {
            return await agentsSelfTest()
        }
        if args.contains("--selftest-agent-reports") {
            return await agentReportsSelfTest()
        }
        if args.contains("--selftest-agent-comments") {
            // Your comment wakes the agent holding a card in progress, with stand-ins for its command and a phone on the link.
            return await agentCommentsSelfTest()
        }
        if args.contains("--selftest-card-windows") {
            return await cardWindowsSelfTest()
        }
        if args.contains("--selftest-agent-handoffs") {
            return await agentHandoffsSelfTest()
        }
        if args.contains("--selftest-distill-repeats") {
            // Lane BF2: repeats in a note's proposals left out, in a throwaway BINDERS_DATA_DIR.
            return await distillRepeatsSelfTest()
        }
        if let directory = value("--selftest-agents-page") {
            // The Agents page as where you talk to your agents, drawn into the folder given, in a throwaway BINDERS_DATA_DIR.
            return await agentsPageSelfTest(drawingTo: URL(fileURLWithPath: directory))
        }
        if args.contains("--selftest-agent-chat") {
            // Chats with your agents (lane AC1), with a stand-in claude, in a throwaway BINDERS_DATA_DIR.
            return await agentChatSelfTest()
        }
        if args.contains("--selftest-manager-local") {
            // The Manager on a local model (lane MG2), with a stand-in model, in a throwaway BINDERS_DATA_DIR.
            return await managerLocalSelfTest()
        }
        if args.contains("--selftest-manager") {
            // The Manager (lane MG1), with a stand-in claude, in a throwaway BINDERS_DATA_DIR.
            return await managerSelfTest()
        }
        if args.contains("--selftest-agent-sessions") {
            // A folder after the flag gets a drawing of a Claude Code agent's settings, posting to your open session.
            return await agentSessionsSelfTest(drawingTo: value("--selftest-agent-sessions").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }
        if args.contains("--selftest-claude-managed") {
            // A Claude Code that an organization manages, with a stand-in claude, in a throwaway BINDERS_DATA_DIR (lane RF1).
            return await claudeManagedSelfTest()
        }
        if args.contains("--selftest-pull-requests") {
            // Pull requests for agents' work (lane PR1), to a local origin with a stand-in gh, in a throwaway BINDERS_DATA_DIR.
            return await pullRequestsSelfTest()
        }
        if args.contains("--selftest-cli-agents") {
            // Codex, OpenCode, GitHub Copilot CLI and Antigravity as agents, with stand-ins for the tools, in a throwaway BINDERS_DATA_DIR.
            // A folder after the flag gets a drawing of each one's settings.
            return await cliAgentsSelfTest(drawingTo: value("--selftest-cli-agents").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }
        if args.contains("--selftest-moment") {
            return await momentSelfTest()
        }
        if args.contains("--selftest-distill") {
            // Distill (lane DS1), with a stand-in model, the router's stand-in decision model and stand-in agents.
            return await distillSelfTest()
        }
        if args.contains("--selftest-distill-background") {
            // Distill in the background while you write (lane DS9), with the v2 stand-in.
            return await distillBackgroundSelfTest()
        }
        if let directory = value("--selftest-distill-list") {
            // The Distill list, the Distill button and the distilling motion (lane DS9), with frames to look at.
            return await distillListSelfTest(to: URL(fileURLWithPath: directory, isDirectory: true))
        }
        if args.contains("--selftest-distill-marks") {
            // Work in the note (lane DS4): cards marked at the words they came from, with stand-in items. A folder after the
            // flag gets a drawing.
            return await distillMarksSelfTest(drawingTo: value("--selftest-distill-marks").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }
        if args.contains("--selftest-distill-more") {
            // Distill finished (lane RF2): what of a section's change reaches an agent, and Distill's smaller gaps.
            return await distillMoreSelfTest()
        }
        if args.contains("--selftest-distill-long") {
            // Distill on a long note (lane DS2): read in parts, asked again for a list, thinking left out, with stand-ins.
            return await distillLongSelfTest()
        }
        if args.contains("--selftest-distill-slow") {
            // Distill with a slow model (lane DS7): a stall, not a stopwatch, ends a reply; what was written is kept; parts sized by speed.
            return await distillSlowSelfTest()
        }
        if args.contains("--selftest-distill-schema") {
            // Distill's reply held to its JSON schema (lane DS3): Ollama's format, response_format, xgrammar, with stand-ins.
            return await distillSchemaSelfTest()
        }
        if args.contains("--selftest-distill-who") {
            // Who Distill's items are meant for (lane AS1): the reader told who can take work, with stand-ins.
            return await distillWhoSelfTest()
        }
        if let directory = value("--selftest-distill-draw") {
            // Drawings of Distill's Work bar, panel, review sheet, report, Work list, history and a distilled card.
            return await distillDrawSelfTest(to: URL(fileURLWithPath: directory, isDirectory: true))
        }
        if args.contains("--selftest-distill-bench") {
            // Distill's prompt and reading, measured on the bench's spec notes with a real model: the one in Settings → AI,
            // or an OpenAI-compatible server given with --model-url and --model.
            return await distillBenchSelfTest(url: value("--model-url"), model: value("--model"), rounds: value("--rounds").flatMap(Int.init) ?? 1)
        }
        if args.contains("--selftest-router") {
            // The card router with a stand-in decision backend, in a throwaway BINDERS_DATA_DIR: no model needed.
            return await routerSelfTest()
        }
        if args.contains("--selftest-fallback") {
            // A folder after the flag gets a drawing of the hub with its banner.
            return await fallbackSelfTest(drawingTo: value("--selftest-fallback").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }
        if args.contains("--selftest-agent-text") {
            // A folder after the flag gets drawings of an agent's note and of an answer that left agents' notes out.
            return await agentTextSelfTest(drawingTo: value("--selftest-agent-text").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }
        if args.contains("--selftest-agent-doing") {
            // In throwaway BINDERS_DATA_DIR and BINDERS_AGENT_HOME folders. A folder after the flag gets drawings of a card,
            // its page and Home's digest saying what a run is doing.
            return await agentDoingSelfTest(drawingTo: value("--selftest-agent-doing").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }
        if args.contains("--selftest-mcp-fresh") {
            return await mcpFreshSelfTest()
        }
        if args.contains("--selftest-todo-origin") {
            return await todoOriginSelfTest()
        }
        if args.contains("--selftest-automation-hooks") {
            // A folder after the flag gets drawings of the automation editor: a kept token, and a link it refuses.
            return await automationHooksSelfTest(drawingTo: value("--selftest-automation-hooks").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }
        if args.contains("--selftest-dedupe") {
            return await dedupeSelfTest()
        }
        if let page = value("--selftest-draw"), let out = args.drop(while: { $0 != "--selftest-draw" }).dropFirst(2).first {
            return await drawSelfTest(page: page, to: URL(fileURLWithPath: out), colour: value("--colour").flatMap { Int($0) }, size: value("--size"))
        }
        if let directory = value("--selftest-board-serve") {
            // The app's side of real agents on the Harbor board in a throwaway folder, drawing the board as it changes.
            let size = NSSize(width: Double(value("--width") ?? "") ?? 1600, height: Double(value("--height") ?? "") ?? 1000)
            return await boardServe(to: URL(fileURLWithPath: directory), empty: args.contains("--empty-board"), size: size,
                                    keep: args.contains("--keep"))
        }
        if args.contains("--selftest-link-serve") {
            return await linkServe()
        }
        if args.contains("--selftest-link") {
            return await linkSelfTest()
        }
        if args.contains("--selftest-conversation") {
            return await conversationSelfTest()
        }
        if let path = value("--selftest-allday") {
            return await allDaySelfTest(file: URL(fileURLWithPath: path))
        }
        if args.contains("--selftest-board-tasks") {
            return await boardTasksSelfTest()
        }
        if let directory = value("--selftest-tags") {
            // Tags and properties on the demo data: MCP filters, #tag search in ⌘O, the properties panel and Today.
            guard AppPaths.isDemo else {
                print("ERROR: set BINDERS_DATA_DIR to an empty folder; this seeds fictional data there")
                return 1
            }
            let controller = DictationController()
            guard await DemoData.seed(knowledge: controller.knowledge) else { return 1 }
            var failures = 0
            func check(_ passed: Bool, _ label: String) {
                print("\(passed ? "PASS" : "FAIL"): \(label)")
                if !passed { failures += 1 }
            }
            guard let harbor = Store.shared.binders().first(where: { $0.name == DemoData.binderName }) else { return 1 }
            let note = NoteItem(text: "# Pricing table plan\n\nRebuild the comparison table with annual plans. #pricing #q4/launch\n\n- [ ] Check the discount with finance")
            note.binderID = harbor.id
            note.properties = NoteProperties(status: "Draft", owner: "Priya", due: Calendar.current.startOfDay(for: Date()))
            Store.shared.insert(note)
            func list(_ text: String) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? [] }
            let byTag = list((try? await MCPServer.call("list_notes", ["tag": "#Pricing"], knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller))) ?? "")
            check(byTag.count == 1 && byTag.first?["status"] as? String == "Draft" && (byTag.first?["tags"] as? [String]) == ["pricing", "q4/launch"],
                  "list_notes finds a note by its tag, with its properties: \(byTag.count)")
            let byStatus = list((try? await MCPServer.call("list_notes", ["status": "done"], knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller))) ?? "")
            check(byStatus.isEmpty, "and filters by status")
            // A binder nobody has written in lately still lists its notes, however busy the others are.
            let quiet = BinderRecord(name: "Quiet binder", colorIndex: 2)
            Store.shared.insert(quiet)
            let old = NoteItem(text: "# Archive index\n\nWhere last year's files went.")
            old.binderID = quiet.id
            old.updatedAt = Date(timeIntervalSinceNow: -400 * 86_400)
            Store.shared.insert(old)
            Store.shared.save()
            let inQuiet = list((try? await MCPServer.call("list_notes", ["binder": "quiet BINDER", "limit": 1], knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller))) ?? "")
            check(inQuiet.count == 1 && inQuiet.first?["title"] as? String == "Archive index", "list_notes lists a quiet binder's notes: \(inQuiet.count)")
            let meetingsIn = list((try? await MCPServer.call("list_meetings", ["binder": harbor.name, "limit": 1], knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller))) ?? "")
            check(meetingsIn.count == 1 && meetingsIn.first?["binder"] as? String == harbor.name, "list_meetings lists a binder's meetings")
            var refused = 0
            for tool in ["list_notes", "list_meetings"] {
                do { _ = try await MCPServer.call(tool, ["binder": "No such binder"], knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller)) }
                catch { refused += 1 }
            }
            check(refused == 2, "a binder that doesn't exist is an error, rather than every binder's notes and meetings")

            let navigation = HubNavigation()
            navigation.binderID = harbor.id
            navigation.selection = .binder
            navigation.pendingBinderTab = .notes
            navigation.pendingNoteID = note.id
            let hosting = NSHostingView(rootView: HubView()
                .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
                .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
                .modelContainer(Store.shared.container))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            hosting.wantsLayer = true
            window.contentView = hosting
            window.orderFrontRegardless()
            window.makeKey()
            try? await Task.sleep(for: .milliseconds(1200))
            let folder = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            capture(hosting, name: "tags-note", directory: folder)

            navigation.selection = .home
            navigation.switcher = .open
            try? await Task.sleep(for: .milliseconds(700))
            for character in "#pric" {
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: String(character),
                                                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0) { window.sendEvent(event) }
            }
            try? await Task.sleep(for: .milliseconds(500))
            capture(hosting, name: "tags-switcher", directory: folder)
            if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                            isARepeat: false, keyCode: 36) { window.sendEvent(enter) }
            try? await Task.sleep(for: .milliseconds(600))
            check(navigation.selection == .binder && navigation.binderID == harbor.id && navigation.switcher == nil,
                  "typing #pric in ⌘O and Return opens the tagged note")

            navigation.selection = .today
            try? await Task.sleep(for: .milliseconds(900))
            capture(hosting, name: "tags-today", directory: folder)
            window.close()
            print(failures == 0 ? "TAGS_OK" : "TAGS_FAILED: \(failures)")
            return failures == 0 ? 0 : 1
        }

        if let directory = value("--selftest-outline") {
            // The outline: jumping to a heading in a long note, and folding a section of rendered notes.
            var failures = 0
            func check(_ passed: Bool, _ label: String) {
                print("\(passed ? "PASS" : "FAIL"): \(label)")
                if !passed { failures += 1 }
            }
            let sections = (1...12).map { "## Section \($0)\n" + String(repeating: "A line of notes about part \($0).\n", count: 6) }
            var text = "# A long note\n\n" + sections.joined(separator: "\n")
            let model = MarkdownEditorModel()
            let hosting = NSHostingView(rootView: MarkdownNoteEditorPreview(text: Binding(get: { text }, set: { text = $0 }), model: model).frame(width: 640, height: 320))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            hosting.wantsLayer = true
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(700))
            let headings = MarkdownOutline.headings(in: text)
            check(headings.count == 13 && headings.last?.title == "Section 12", "the outline lists the note's headings: \(headings.count)")
            if let last = headings.last {
                model.jump(to: last.location)
                try? await Task.sleep(for: .milliseconds(300))
                func textViews(in view: NSView) -> [MarkdownTextView] { (view as? MarkdownTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
                let textView = textViews(in: hosting).first
                check(textView?.selectedRange().location == last.location && (textView?.enclosingScrollView?.contentView.bounds.minY ?? 0) > 200,
                      "choosing a heading puts the cursor there and scrolls it into view")
            }
            let folder = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            capture(hosting, name: "outline-editor", directory: folder)
            window.close()
            let summary = "# Review\n## Summary\nShip on the 28th.\n## Decisions\n- Annual plans at 15% off\n- No free tier change\n## Action items\n- [ ] Send the checklist"
            let shown = MarkdownBlocks.visibleLines(summary, folded: [3]).map(\.line)
            check(shown == ["# Review", "## Summary", "Ship on the 28th.", "## Decisions", "## Action items", "- [ ] Send the checklist"],
                  "folding a section hides its lines and nothing else")
            print(failures == 0 ? "OUTLINE_OK" : "OUTLINE_FAILED: \(failures)")
            return failures == 0 ? 0 : 1
        }

        if let directory = value("--selftest-history") {
            // Version history in a throwaway data folder: keeping, not over-keeping, a teammate's change, restoring, deleting.
            guard AppPaths.isDemo else {
                print("ERROR: set BINDERS_DATA_DIR to an empty folder; this writes notes and their versions there")
                return 1
            }
            var failures = 0
            func check(_ passed: Bool, _ label: String) {
                print("\(passed ? "PASS" : "FAIL"): \(label)")
                if !passed { failures += 1 }
            }
            let note = NoteItem(text: "# Launch plan\n\nFirst draft: ship on the 28th.")
            Store.shared.insert(note)
            let first = note.text
            note.text = "# Launch plan\n\nSecond draft: ship on the 28th, pricing page first."
            NoteHistory.changed(note.id, previous: first)
            check(NoteHistory.versions(of: note.id).map(\.text) == [first], "the first edit keeps the note as it was")
            let second = note.text
            note.text += "\n- [ ] Tell support"
            NoteHistory.changed(note.id, previous: second)
            check(NoteHistory.versions(of: note.id).count == 1, "the next keystrokes don't keep another straight away")
            NoteHistory.willChange(note, to: "# Launch plan\n\nA teammate's rewrite.", always: true)
            let before = note.text
            note.text = "# Launch plan\n\nA teammate's rewrite."
            check(NoteHistory.versions(of: note.id).first?.text == before, "a teammate's change keeps a version first, however recent the last")
            if let oldest = NoteHistory.versions(of: note.id).last {
                NoteHistory.restore(oldest, to: note)
                check(note.text == first && NoteHistory.versions(of: note.id).first?.text == "# Launch plan\n\nA teammate's rewrite.",
                      "restoring puts it back and keeps what was there as a version")
            }
            let hosting = NSHostingView(rootView: NoteHistorySheet(note: note))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            hosting.wantsLayer = true
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(800))
            let folder = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            capture(hosting, name: "history", directory: folder)
            window.close()
            Store.shared.delete(note)
            check(NoteHistory.versions(of: note.id).isEmpty, "deleting the note deletes its versions")
            print(failures == 0 ? "HISTORY_OK" : "HISTORY_FAILED: \(failures)")
            return failures == 0 ? 0 : 1
        }

        if args.contains("--selftest-folders") {
            // Folders inside binders: making, moving, templates, Tidy into Folders; the pages drawn into a folder, if given.
            return await foldersSelfTest(drawingTo: value("--selftest-folders").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }
        if args.contains("--selftest-folders-mcp") {
            return await foldersMCPSelfTest()
        }
        if args.contains("--selftest-folders-team") {
            return await foldersTeamSelfTest()
        }

        if args.contains("--selftest-templates") {
            // Note templates in a throwaway data folder: the built-in ones, filling one in, saving your own, replacing one.
            guard AppPaths.isDemo else {
                print("ERROR: set BINDERS_DATA_DIR to an empty folder; this writes templates there")
                return 1
            }
            var failures = 0
            func check(_ passed: Bool, _ label: String) {
                print("\(passed ? "PASS" : "FAIL"): \(label)")
                if !passed { failures += 1 }
            }
            let binder = BinderRecord(name: "Research", colorIndex: 1)
            Store.shared.insert(binder)
            check(TemplateStore.all.map(\.name) == NoteTemplate.builtIn.map(\.name), "the built-in templates are there: \(TemplateStore.all.map(\.name))")
            let reading = TemplateStore.all.first { $0.name == "Reading notes" }
            let note = TemplateStore.newNote(from: reading, in: binder)
            let long = Date().formatted(date: .complete, time: .omitted)
            check(note.text.hasPrefix("# Reading notes:") && note.text.contains("Read \(long)") && note.binderID == binder.id && !note.text.contains("{{"),
                  "a note from a template has the day filled in and lands in its binder")
            note.text = "# Paper review\n\n## Main claim\n{{date}} in {{binder}}"
            let saved = TemplateStore.save(note)
            check(saved.map { FileManager.default.fileExists(atPath: $0.path) } == true && TemplateStore.all.contains { $0.name == "Paper review" },
                  "a note saved as a template is offered next time")
            check(TemplateStore.newNote(from: TemplateStore.all.first { $0.name == "Paper review" }, in: binder).text.contains("in Research"),
                  "and your own templates are filled in too")
            try? "# My week\n".write(to: TemplateStore.folder.appendingPathComponent("Weekly review.md"), atomically: true, encoding: .utf8)
            check(TemplateStore.all.filter { $0.name == "Weekly review" }.map(\.body) == ["# My week\n"], "yours replaces a built-in of the same name")
            print(failures == 0 ? "TEMPLATES_OK" : "TEMPLATES_FAILED: \(failures)")
            return failures == 0 ? 0 : 1
        }

        if let directory = value("--selftest-today") {
            // The Today page on the demo data, and its daily note, made on the first keystroke.
            guard AppPaths.isDemo else {
                print("ERROR: set BINDERS_DATA_DIR to an empty folder; this seeds fictional data there")
                return 1
            }
            let controller = DictationController()
            guard await DemoData.seed(knowledge: controller.knowledge) else { return 1 }
            let navigation = HubNavigation()
            navigation.selection = .today
            let hosting = NSHostingView(rootView: HubView()
                .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
                .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
                .modelContainer(Store.shared.container))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            hosting.wantsLayer = true
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1200))
            let folder = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            capture(hosting, name: "today", directory: folder)
            func textViews(in view: NSView) -> [MarkdownTextView] { (view as? MarkdownTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
            let title = TodayView.dailyTitle(for: Date())
            func daily() -> NoteItem? { ((try? Store.shared.context.fetch(FetchDescriptor<NoteItem>())) ?? []).first { $0.title == title } }
            let before = daily()
            if let editor = textViews(in: hosting).first {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                editor.insertText("Called the venue: the room is booked.", replacementRange: editor.selectedRange())
            }
            // The next keystrokes, straight after, before that save is read back, go into the same note.
            if let editor = textViews(in: hosting).first {
                editor.insertText(" Catering next.", replacementRange: editor.selectedRange())
            }
            try? await Task.sleep(for: .milliseconds(500))
            let made = daily()
            let passed = before == nil && made?.text.contains("Called the venue") == true && made?.binderID == Store.shared.defaultBinder().id
            print("\(passed ? "PASS" : "FAIL"): the day's note is made on the first keystroke, titled \(title), in General")
            let dated = ((try? Store.shared.context.fetch(FetchDescriptor<NoteItem>())) ?? []).filter { $0.title == title }
            let once = dated.count == 1 && made?.text.contains("booked. Catering next.") == true
            print("\(once ? "PASS" : "FAIL"): and only once: the next keystrokes go into it (\(dated.count) notes titled \(title))")
            capture(hosting, name: "today-written", directory: folder)
            window.close()
            return passed && once ? 0 : 1
        }

        if let directory = value("--selftest-links") {
            // [[Links]] and "Mentioned in" on the demo data: resolving, suggesting, finding mentions, clicking, completing.
            return await linksSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if let directory = value("--selftest-switcher") {
            // The quick switcher driven by keystrokes on the demo data, in a window that never shows.
            return await switcherSelfTest(directory: URL(fileURLWithPath: directory))
        }

        if let directory = value("--selftest-demo-shots") {
            // Product screenshots from fictional data in a throwaway folder (BINDERS_DATA_DIR), never the real store.
            let controller = DictationController()
            guard await DemoData.seed(knowledge: controller.knowledge) else { return 1 }
            await renderDemoShots(to: URL(fileURLWithPath: directory), controller: controller)
            if args.contains("--ask") {
                // Real answers from the real pipeline, over the fictional data: embed, search, ask the local model.
                await controller.knowledge.indexNow()
                for (index, question) in DemoData.questions.enumerated() {
                    let started = Date()
                    let answer = await controller.knowledge.ask(question)
                    print("QUESTION: \(question)")
                    print("ANSWER (\(ms(since: started)) ms): \(answer.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
                    for source in answer.sources.prefix(4) { print("  SOURCE [\(source.kind.rawValue)] \(source.title) · \(source.metaLine)") }
                    await render(KnowledgeAnswerView(answer: answer).padding(20), size: NSSize(width: 720, height: 460),
                                 name: "demo-answer-\(index + 1)", directory: URL(fileURLWithPath: directory))
                }
            }
            return 0
        }

        if let directory = value("--selftest-snapshot") {
            await renderSnapshots(to: URL(fileURLWithPath: directory))
            return 0
        }

        if let directory = value("--selftest-editor-shot") {
            // The note editor with a sample note, rendered offscreen: nothing is read from or written to the store.
            let sample = #"""
# Launch checklist

Everything that has to be true before **Harbor** ships on the 28th. See [the plan](https://example.com), and forget ~~the old date~~.

## Before Friday
- [x] Confirm the annual discount with finance
- [ ] Send Jonas the final launch checklist
- [ ] Loop in support on the last two onboarding emails
  - [ ] Draft the reply template

## Notes
1. Pricing page copy is final
2. The comparison table still needs a *second* pass
- Beta list is at 412 people

> Launch date stays the 28th. A slip is decided on Monday, not before.

Run the import test with `make import-test`:

```bash
make import-test ROWS=50000
open reports/import.html
```
"""#
            await render(MarkdownNoteEditor(text: .constant(sample), fontSize: 15, placeholder: "Write, or hold fn to dictate.")
                .frame(width: 760, height: 720).background(Color(nsColor: .textBackgroundColor)),
                         size: NSSize(width: 760, height: 720), name: "editor", directory: URL(fileURLWithPath: directory))
            // Editing the second paragraph: its markup shows, everything else stays rendered.
            await render(MarkdownNoteEditor(text: .constant(sample), fontSize: 15, placeholder: "Write, or hold fn to dictate.")
                .frame(width: 760, height: 720).background(Color(nsColor: .textBackgroundColor)),
                         size: NSSize(width: 760, height: 720), name: "editor-focused", directory: URL(fileURLWithPath: directory)) { root in
                func find(_ view: NSView) -> MarkdownTextView? {
                    (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first
                }
                guard let editor = find(root) else { return }
                editor.window?.makeFirstResponder(editor)
                editor.setSelectedRange(NSRange(location: (sample as NSString).range(of: "Harbor").location, length: 0))
            }
            print("EDITOR_SHOT_DONE")
            return 0
        }

        if args.contains("--selftest-instances") {
            // Which running copies of Binders would keep the app from starting (MCP servers and self-tests don't).
            let own = ProcessInfo.processInfo.processIdentifier
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "") where app.processIdentifier != own {
                print("pid \(app.processIdentifier): \(AppDelegate.isAppInstance(app.processIdentifier) ? "the app" : "not the app (MCP server or self-test)")")
            }
            print("INSTANCES_DONE")
            return 0
        }

        if let path = value("--selftest-team-locate") {
            // What Join would do with a folder, without joining: for helping a teammate who can't join.
            do {
                print("TEAM_SPACE: \(try TeamSyncService.locateTeamSpace(near: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)).path)")
                return 0
            } catch {
                print("NO_TEAM_SPACE: \(error.localizedDescription)")
                return 1
            }
        }

        if args.contains("--selftest-team-database-off") {
            // The team database held back behind its default (lane RF1): off, then on. A folder gets Settings → Team drawn both ways.
            return await teamDatabaseOffSelfTest(drawingTo: value("--selftest-team-database-off").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }

        if args.contains("--selftest-hub-signin") {
            // Settings → Team signs in to a hub: a stand-in hub, then a real one when BINDERS_TEST_HUB is set.
            return await hubSignInSelfTest(drawingTo: value("--selftest-hub-signin").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }

        if args.contains("--selftest-hub-sync") {
            // Linked notes and folders both ways with a running hub, offline included (scripts/hub-sync-test.sh).
            return await hubSyncSelfTest()
        }

        if args.contains("--selftest-hub-agents") {
            // Agents and binders linked to a hub: this Mac's server, setting a tool up, and a real hub when BINDERS_TEST_HUB is set.
            return await hubAgentsSelfTest()
        }

        if args.contains("--selftest-hub-history") {
            // A linked note's history from a running hub (scripts/hub-history-test.sh); a folder after it draws the sheet.
            return await hubHistorySelfTest(drawingTo: value("--selftest-hub-history").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }

        if args.contains("--selftest-hub-link") {
            // Linking a binder to a hub's project: a stand-in hub, then a real one when BINDERS_TEST_HUB is set.
            return await hubLinkSelfTest(drawingTo: value("--selftest-hub-link").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }

        if args.contains("--selftest-hub-move") {
            // Move to a Hub: a team database's binders to a stand-in hub, then off the team database.
            return await hubMoveSelfTest(drawingTo: value("--selftest-hub-move").flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) })
        }

        if args.contains("--selftest-hub-board") {
            // A linked binder's board through the hub: a stand-in hub, then a real one when BINDERS_TEST_HUB is set.
            return await hubBoardSelfTest()
        }

        if let step = value("--selftest-join-copies-mac") {
            // One of the other Macs of `--selftest-teamdb-join-copies` (lane DB9), started by it in a folder of its own.
            return await joinCopiesMac(step)
        }

        if let flag = args.first(where: { $0.hasPrefix("--selftest-teamdb") }) {
            // The team database against a throwaway Postgres of its own, in a throwaway BINDERS_DATA_DIR
            // (SelfTestTeamDatabase.swift); its default on, as it's held back from 0.10.0 behind it (TeamDatabaseFeature).
            AppDefaults.store.set(true, forKey: TeamDatabaseFeature.key)
            // A folder after the flag: where `-team` draws Settings → Team (lane DB7).
            teamDrawings = value(flag).flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) }
            return await teamDatabaseSelfTest(flag)
        }

        if args.contains("--selftest-team") {
            return await teamSelfTest(keepFolder: args.contains("--keep"))
        }

        if args.contains("--selftest-wispr-import") {
            do {
                let summary = try WisprImporter.importAll()
                AppDefaults.store.set(true, forKey: "importedFromWispr")
                print("WISPR_IMPORTED: \(summary.words) words, \(summary.snippets) snippets, \(summary.skipped) skipped")
                return 0
            } catch {
                print("ERROR: \(error.localizedDescription)")
                return 1
            }
        }

        if args.contains("--selftest-wispr") {
            do {
                let preview = try WisprImporter.preview()
                print("WISPR_IMPORTABLE: \(preview.words) words, \(preview.snippets) snippets")
                return 0
            } catch {
                print("ERROR: \(error.localizedDescription)")
                return 1
            }
        }

        print("Usage: --selftest-audio <file> | --selftest-text <text> | --selftest-command <instruction> | --selftest-meeting <file> | --selftest-snapshot <dir> | --selftest-align <ref> <candidate> | --selftest-notes <meeting id> | --selftest-rescue <meeting id> --file <recording> | --selftest-team | --selftest-wispr")
        return 2
    }

    /// Two teammates with their own stores sharing one folder, without touching the real data.
    @MainActor
    private static func teamSelfTest(keepFolder: Bool) async -> Int32 {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("binders-team-\(UUID().uuidString.prefix(8))")
        let folder = root.appendingPathComponent("Team")
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? TeamSyncService.prepareTeamFolder(folder)
        defer { if !keepFolder { try? fileManager.removeItem(at: root) } }

        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        func member(_ name: String) -> (store: Store, team: TeamSyncService) {
            let store = Store(url: root.appendingPathComponent("\(name).store"))
            let team = TeamSyncService(flowBar: nil, store: store, stateURL: root.appendingPathComponent("\(name)-sync.json"))
            team.identityOverride = (folder, TeamAuthor(id: "id-\(name)", name: name))
            team.deletionGrace = 0
            team.idAssignmentAge = 0
            return (store, team)
        }
        func notes(_ store: Store) -> [NoteItem] { (try? store.context.fetch(FetchDescriptor<NoteItem>())) ?? [] }
        func meetings(_ store: Store) -> [MeetingRecord] { (try? store.context.fetch(FetchDescriptor<MeetingRecord>())) ?? [] }

        // Joining finds the team space near the folder picked: the folder the shared one sits in, or one inside it.
        func located(_ picked: URL) -> String? { (try? TeamSyncService.locateTeamSpace(near: picked))?.resolvingSymlinksInPath().path }
        let space = folder.resolvingSymlinksInPath().path
        check(located(folder) == space, "joining the team folder itself")
        check(located(root) == space, "joining the folder it sits in, like the top of a OneDrive")
        check(located(folder.appendingPathComponent(TeamFiles.notesFolder)) == space
              && located(folder.appendingPathComponent(TeamFiles.dataFolder).appendingPathComponent("members")) == space, "joining a folder inside it")
        // A file arriving in the team folder is noticed within a couple of seconds; Finder's .DS_Store isn't.
        var noticed = 0
        let watcher = FolderWatcher(url: folder, latency: 0.3) { noticed += 1 }
        // FSEvents also reports the folders this test made a moment ago; let those pass.
        try? await Task.sleep(for: .milliseconds(1200))
        noticed = 0
        try? Data().write(to: folder.appendingPathComponent(TeamFiles.notesFolder).appendingPathComponent(".DS_Store"))
        try? await Task.sleep(for: .milliseconds(900))
        let afterFinder = noticed
        try? "# From a teammate\n".write(to: folder.appendingPathComponent(TeamFiles.notesFolder).appendingPathComponent("From a teammate.md"),
                                           atomically: true, encoding: .utf8)
        for _ in 0..<30 where noticed == afterFinder { try? await Task.sleep(for: .milliseconds(100)) }
        check(watcher != nil && afterFinder == 0 && noticed > 0, "a teammate's file is noticed as it arrives, and Finder's .DS_Store isn't")
        try? fileManager.removeItem(at: folder.appendingPathComponent(TeamFiles.notesFolder).appendingPathComponent("From a teammate.md"))
        try? fileManager.removeItem(at: folder.appendingPathComponent(TeamFiles.notesFolder).appendingPathComponent(".DS_Store"))
        _ = watcher

        let elsewhere = root.appendingPathComponent("Elsewhere")
        try? fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        do {
            _ = try TeamSyncService.locateTeamSpace(near: elsewhere)
            check(false, "a folder with no team space near it is refused")
        } catch {
            check(error.localizedDescription.contains("Add shortcut to My files"), "a folder with no team space near it is refused, with what to do")
        }

        func files() -> [String: Date] {
            var result: [String: Date] = [:]
            let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
            while let url = enumerator?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory != true else { continue }
                result[String(url.resolvingSymlinksInPath().path.dropFirst(folder.resolvingSymlinksInPath().path.count + 1))] = values?.contentModificationDate
            }
            return result
        }
        func syncBoth(_ first: TeamSyncService, _ second: TeamSyncService) async {
            await first.syncNow()
            await second.syncNow()
        }

        let maya = member("Maya")
        let dana = member("Dana")

        // Maya shares a meeting and a note and keeps another note private.
        let meeting = MeetingRecord(title: "Pricing sync", appName: "Zoom", templateID: "general")
        meeting.status = "ready"
        meeting.duration = 600
        meeting.summary = "## Decisions\n- Launch at $49\n\n## Action items\n- [ ] You — send the pricing deck to Jonas\n- [ ] Jonas — review the deck"
        meeting.attendees = ["Dana"]
        meeting.speakerNames = ["Speaker 1": "Erin"]
        meeting.sharedWithTeam = true
        maya.store.insert(meeting)
        maya.store.replaceSegments(for: meeting.id, with: [
            TranscriptSegment(channel: .microphone, start: 1, end: 3, text: "Let's launch at forty nine dollars."),
            TranscriptSegment(channel: .system, start: 4, end: 6, text: "Agreed, Samyr owns the beta list.", speaker: "Speaker 1"),
        ])
        let checklist = NoteItem(text: "Launch checklist\n- Landing page")
        checklist.sharedWithTeam = true
        maya.store.insert(checklist)
        maya.store.insert(NoteItem(text: "Private thoughts about hiring"))

        await maya.team.syncNow()
        var listing = files()
        check(maya.team.status.error == nil, "Maya synced without errors \(maya.team.status.error ?? "")")
        check(listing.keys.contains { $0.hasPrefix("Meetings/") && $0.hasSuffix("Pricing sync.md") }, "meeting Markdown written")
        check(listing.keys.contains("_binders/meetings/\(meeting.id.uuidString).json"), "meeting data written")
        check(listing.keys.contains("Notes/Launch checklist.md"), "shared note written")
        check(!listing.keys.contains { $0.localizedCaseInsensitiveContains("private") }, "private note stays private")

        // Dana receives them.
        await dana.team.syncNow()
        let danaMeeting = meetings(dana.store).first
        check(danaMeeting?.isTeamCopy == true && danaMeeting?.teamAuthorName == "Maya", "Dana has Maya's meeting, attributed to Maya")
        // Maya's "You" is Maya on Dana's Mac, in her to-dos and in the notes she reads.
        let danaTodos = TaskCollector.collect(meetings: danaMeeting.map { [$0] } ?? [], notes: [], openMeeting: { _ in }, openNote: { _ in })
        check(danaTodos.first { $0.text == "send the pricing deck to Jonas" }?.owner == "Maya"
              && danaTodos.first { $0.text == "review the deck" }?.owner == "Jonas"
              && TeamSyncService.shown(danaMeeting?.summary ?? "", by: danaMeeting?.teamAuthorName).contains("- [ ] Maya — send the pricing deck"),
              "a teammate's \"You\" to-dos are theirs, not yours")
        let danaSegments = dana.store.segments(for: meeting.id)
        check(danaSegments.count == 2, "transcript arrived (\(danaSegments.count) segments)")
        let blocks = TranscriptFormatter.blocks(danaSegments, names: danaMeeting?.speakerNames ?? [:])
        check(blocks.map(\.speaker) == ["Maya", "Erin"], "speakers read Maya and Erin for Dana (\(blocks.map(\.speaker)))")
        check(notes(dana.store).count == 1 && notes(dana.store).first?.text == checklist.text, "Dana has the shared note only")
        print("ANNOUNCED: \(dana.team.lastAnnouncements)")

        // Dana edits the shared note.
        notes(dana.store).first?.text += "\n- Pricing page"
        dana.store.save()
        await syncBoth(dana.team, maya.team)
        check(checklist.text.hasSuffix("- Pricing page"), "Dana's edit reached Maya")

        // Properties travel too: Maya sets them, Dana sees them and changes one, Maya sees that.
        checklist.properties = NoteProperties(status: "Draft", owner: "Maya", due: Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: Date())))
        maya.store.save()
        await syncBoth(maya.team, dana.team)
        let danaCopy = notes(dana.store).first
        check(danaCopy?.status == "Draft" && danaCopy?.owner == "Maya" && danaCopy?.dueAt == checklist.dueAt, "a note's properties reach a teammate")
        danaCopy?.status = "Done"
        dana.store.save()
        await syncBoth(dana.team, maya.team)
        check(checklist.status == "Done" && checklist.owner == "Maya", "and a teammate's change to them comes back")

        // Someone adds a note in Obsidian.
        try? "---\ntags: [hiring]\n---\n# Hiring plan\nTwo engineers by March".write(to: folder.appendingPathComponent("Notes/Hiring plan.md"), atomically: true, encoding: .utf8)
        await syncBoth(maya.team, dana.team)
        check(notes(maya.store).contains { $0.text.hasPrefix("# Hiring plan") && $0.isTeamCopy }, "Obsidian note reached Maya")
        check(notes(dana.store).contains { $0.text.hasPrefix("# Hiring plan") }, "Obsidian note reached Dana")
        let hiringFile = (try? String(contentsOf: folder.appendingPathComponent("Notes/Hiring plan.md"), encoding: .utf8)) ?? ""
        check(hiringFile.hasPrefix("---\nbinders_id: \"\(TeamFiles.stableID(forPath: "Notes/Hiring plan.md"))\"\ntags: [hiring]\n---\n"),
              "Obsidian note got a path-derived Binders id and kept its tags")
        notes(dana.store).first { $0.text.hasPrefix("# Hiring plan") }?.text += "\nOne designer"
        dana.store.save()
        await syncBoth(dana.team, maya.team)
        let editedHiring = (try? String(contentsOf: folder.appendingPathComponent("Notes/Hiring plan.md"), encoding: .utf8)) ?? ""
        check(editedHiring.contains("tags: [hiring]") && notes(maya.store).contains { $0.text.hasSuffix("One designer") },
              "edits keep Obsidian properties and reach Maya")

        // Both edit the checklist before syncing.
        checklist.text += "\n- Maya's line"
        maya.store.save()
        let danaChecklist = notes(dana.store).first { $0.id == checklist.id }
        danaChecklist?.text += "\n- Dana's line"
        dana.store.save()
        await syncBoth(maya.team, dana.team)
        check(danaChecklist?.text.contains("Maya's line") == true && danaChecklist?.text.contains("Dana's line") == false,
              "conflict keeps the version synced first")
        check(notes(dana.store).contains { !$0.sharedWithTeam && $0.text.contains("Dana's line") }, "conflict saves Dana's edit as a private note")
        print("ANNOUNCED: \(dana.team.lastAnnouncements)")

        // A note file that can't be read (still downloading, half-written) isn't a deletion.
        let checklistURL = folder.appendingPathComponent("Notes/Launch checklist.md")
        let checklistData = (try? Data(contentsOf: checklistURL)) ?? Data()
        try? Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: checklistURL)
        await syncBoth(maya.team, dana.team)
        check(checklist.sharedWithTeam && notes(dana.store).contains { $0.id == checklist.id }, "unreadable note file keeps the note on both Macs")
        try? checklistData.write(to: checklistURL)

        // A file that briefly disappears only counts as deleted after the grace period.
        dana.team.deletionGrace = 120
        let parked = root.appendingPathComponent("parked.md")
        try? fileManager.moveItem(at: checklistURL, to: parked)
        await dana.team.syncNow()
        check(notes(dana.store).contains { $0.id == checklist.id }, "briefly missing note file waits out the grace period")
        try? fileManager.moveItem(at: parked, to: checklistURL)
        await dana.team.syncNow()
        dana.team.deletionGrace = 0

        // Sync-provider conflict copies never override anything.
        let meetingJSON = folder.appendingPathComponent("_binders/meetings/\(meeting.id.uuidString).json")
        let meetingCopy = meetingJSON.deletingLastPathComponent().appendingPathComponent("\(meeting.id.uuidString) (conflicted copy).json")
        if let data = try? Data(contentsOf: meetingJSON), var stale = try? TeamCoding.decoder().decode(TeamMeetingFile.self, from: data) {
            stale.summary = "Stale copy"
            try? TeamCoding.encoder().encode(stale).write(to: meetingCopy)
        }
        let checklistText = String(data: checklistData, encoding: .utf8) ?? ""
        try? checklistText.replacingOccurrences(of: "- Landing page", with: "- Landing page (old)")
            .write(to: folder.appendingPathComponent("Notes/Launch checklist (conflicted copy).md"), atomically: true, encoding: .utf8)
        await syncBoth(maya.team, dana.team)
        await syncBoth(maya.team, dana.team)
        check(!meeting.summary.contains("Stale") && danaMeeting?.summary.contains("Stale") == false, "conflicted meeting copy is ignored")
        check(!checklist.text.contains("(old)") && danaChecklist?.text.contains("(old)") == false, "conflicted note copy doesn't replace the note")
        let copyID = TeamFiles.stableID(forPath: "Notes/Launch checklist (conflicted copy).md")
        check(notes(maya.store).contains { $0.id.uuidString == copyID } && notes(dana.store).contains { $0.id.uuidString == copyID },
              "conflicted note copy becomes its own note on both Macs")
        try? fileManager.removeItem(at: meetingCopy)

        // Maya renames the meeting and updates the notes.
        meeting.title = "Pricing and launch sync"
        meeting.summary += "\n- Ship on Friday"
        maya.store.save()
        await syncBoth(maya.team, dana.team)
        check(danaMeeting?.title == "Pricing and launch sync" && danaMeeting?.summary.contains("Ship on Friday") == true, "meeting edits reached Dana")
        check(dana.store.segments(for: meeting.id).count == 2, "re-applied meeting still has its 2 transcript segments")
        listing = files()
        check(listing.keys.filter { $0.hasPrefix("Meetings/") }.count == 1, "renamed meeting replaced its Markdown file")

        // Nothing changed: no file is rewritten.
        await syncBoth(maya.team, dana.team)
        check(files() == listing, "a sync with no changes writes nothing")

        // Maya stops sharing the meeting; Dana deletes the Obsidian note.
        meeting.sharedWithTeam = false
        maya.store.save()
        if let hiring = notes(dana.store).first(where: { $0.text.hasPrefix("# Hiring plan") }) { dana.store.delete(hiring) }
        await syncBoth(maya.team, dana.team)
        await maya.team.syncNow()
        check(meetings(dana.store).isEmpty, "unshared meeting removed from Dana's Mac")
        check(meetings(maya.store).count == 1, "Maya keeps the unshared meeting")
        check(!notes(maya.store).contains { $0.text.hasPrefix("# Hiring plan") }, "deleted note removed from Maya's Mac")
        check(!files().keys.contains { $0.hasPrefix("Meetings/") || $0 == "Notes/Hiring plan.md" }, "their files left the team folder")

        // Dana's sync state is lost: nothing deleted comes back and nothing is duplicated.
        let danaNoteCount = notes(dana.store).count
        let beforeReset = files()
        try? fileManager.removeItem(at: root.appendingPathComponent("Dana-sync.json"))
        let danaAgain = TeamSyncService(flowBar: nil, store: dana.store, stateURL: root.appendingPathComponent("Dana-sync.json"))
        danaAgain.identityOverride = (folder, TeamAuthor(id: "id-Dana", name: "Dana"))
        danaAgain.deletionGrace = 0
        danaAgain.idAssignmentAge = 0
        await danaAgain.syncNow()
        check(notes(dana.store).count == danaNoteCount && files() == beforeReset, "lost sync state brings nothing back and duplicates nothing")

        // A conversation Maya's iPhone heard stays on her Mac, even marked shared by mistake.
        let overheard = MeetingRecord(title: "Hallway chat about pricing", appName: "iPhone", templateID: "conversation")
        overheard.kind = MeetingRecord.conversationKind
        overheard.status = "ready"
        overheard.summary = "## Summary\nA quick chat about pricing."
        overheard.sharedWithTeam = true
        maya.store.insert(overheard)
        await maya.team.syncNow()
        await danaAgain.syncNow()
        check(!files().keys.contains { $0.contains(overheard.id.uuidString) || $0.localizedCaseInsensitiveContains("Hallway chat") }
              && !meetings(dana.store).contains { $0.id == overheard.id }, "a conversation the iPhone heard never reaches the team folder")

        // An agent's note stays the agent's on a teammate's Mac: labelled there, its correction steering nothing.
        let agentsNote = NoteItem(text: "Launch date\n\nWrong: launch is May 3\nRight: launch is June 9\n#correction")
        agentsNote.sharedWithTeam = true
        agentsNote.madeBy = "Claude Code · app"
        maya.store.insert(agentsNote)
        await maya.team.syncNow()
        await danaAgain.syncNow()
        let danaAgents = notes(dana.store).first { $0.id == agentsNote.id }
        check(danaAgents?.madeBy == "Claude Code · app", "an agent's note reaches a teammate as the agent's: \(danaAgents?.madeBy ?? "unmarked")")
        agentsNote.madeBy = nil
        maya.store.save()
        await maya.team.syncNow()
        await danaAgain.syncNow()
        check(danaAgents != nil && notes(dana.store).first { $0.id == agentsNote.id }?.madeBy == nil, "and once Maya makes it hers, it's hers there too")

        // An agent adds to Maya's shared note while Dana edits it: the version Maya keeps aside in the conflict is still the
        // agent's edit, so answers leave it out and it's labelled until she makes it hers.
        let rota = NoteItem(text: "Booth rota\n- Sam on Monday")
        rota.sharedWithTeam = true
        maya.store.insert(rota)
        await maya.team.syncNow()
        await danaAgain.syncNow()
        let agentEdited = Date(timeIntervalSinceNow: -60)
        rota.text += "\n- Venue opens at 8"
        rota.markEdited(by: "Claude Code", at: agentEdited)
        maya.store.save()
        let danaRota = notes(dana.store).first { $0.id == rota.id }
        danaRota?.text += "\n- Dana on Tuesday"
        dana.store.save()
        await danaAgain.syncNow()
        await maya.team.syncNow()
        let keptAside = notes(maya.store).first { $0.id != rota.id && !$0.sharedWithTeam && $0.text.contains("Venue opens at 8") }
        check(danaRota != nil && rota.text.hasSuffix("- Dana on Tuesday") && keptAside?.editedBy == "Claude Code"
              && keptAside?.editedAt.map { abs($0.timeIntervalSince(agentEdited)) < 0.01 } == true
              && keptAside.map { maya.store.agentMarks()[$0.id.uuidString]?.editedBy == "Claude Code" } == true,
              "a conflict on a note an agent edited keeps the agent's edit marked on the copy kept aside: \(keptAside?.editedBy ?? "unmarked")")
        check(rota.editedBy == "Claude Code", "and on the shared note, which may still hold earlier words of the agent's")

        // An agent's edit to Maya's shared note reaches Dana as the agent's: labelled there, and left out of Ask, its words
        // never arriving as Maya's. Once Maya makes it hers, it's hers on Dana's Mac too.
        let plan = NoteItem(text: "Booth plan\n- Tables by the door")
        plan.sharedWithTeam = true
        maya.store.insert(plan)
        await maya.team.syncNow()
        await danaAgain.syncNow()
        let agentChanged = Date(timeIntervalSinceNow: -120)
        plan.text += "\n- Banner on the left wall"
        plan.markEdited(by: "Codex", at: agentChanged)
        maya.store.save()
        await maya.team.syncNow()
        await danaAgain.syncNow()
        let danaPlan = notes(dana.store).first { $0.id == plan.id }
        check(danaPlan?.text.hasSuffix("- Banner on the left wall") == true && danaPlan?.editedBy == "Codex"
              && danaPlan?.editedAt.map { abs($0.timeIntervalSince(agentChanged)) < 1 } == true
              && dana.store.agentMarks()[plan.id.uuidString]?.editedBy == "Codex",
              "an agent's edit to a shared note reaches a teammate as the agent's, which Ask there leaves out: \(danaPlan?.editedBy ?? "unmarked")")
        let planFile = files().keys.first { $0.hasPrefix("Notes/Booth plan") }
            .flatMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) } ?? ""
        check(planFile.contains("binders_edited_by: \"Codex\"") && planFile.contains("binders_edited_at: "),
              "the edit's mark is in the note's file, which a Binders that doesn't know it keeps as it is")
        await syncBoth(maya.team, danaAgain)
        await syncBoth(maya.team, danaAgain)
        let marked = files()
        await syncBoth(maya.team, danaAgain)
        check(files() == marked, "a note with an agent's edit marked syncs once, then writes nothing more")
        plan.makeMine()
        maya.store.save()
        await maya.team.syncNow()
        await danaAgain.syncNow()
        check(danaPlan?.editedBy == nil && danaPlan?.editedAt == nil && dana.store.agentMarks()[plan.id.uuidString] == nil,
              "once Maya makes it hers, it's hers on Dana's Mac too")

        // A note an agent edited that synced before edits were marked in the team folder (its sync hash had no mark):
        // updating writes nothing for the mark alone, and a teammate's change since is taken, not kept aside as Maya's.
        let menu = NoteItem(text: "Lunch order\n- Soup for Sam")
        menu.sharedWithTeam = true
        maya.store.insert(menu)
        await maya.team.syncNow()
        await danaAgain.syncNow()
        menu.editedBy = "Codex"
        menu.editedAt = Date(timeIntervalSinceNow: -300)
        maya.store.save()
        let beforeUpdate = files()
        await maya.team.syncNow()
        check(files() == beforeUpdate, "a note synced before edits were marked isn't written again for its mark alone")
        let danaMenu = notes(dana.store).first { $0.id == menu.id }
        danaMenu?.text += "\n- Salad for Dana"
        dana.store.save()
        await danaAgain.syncNow()
        let asideBefore = notes(maya.store).filter { !$0.sharedWithTeam && $0.text.hasPrefix("Lunch order") }.count
        await maya.team.syncNow()
        let asideAfter = notes(maya.store).filter { !$0.sharedWithTeam && $0.text.hasPrefix("Lunch order") }.count
        check(menu.text.hasSuffix("- Salad for Dana") && asideAfter == asideBefore && menu.editedBy == "Codex",
              "and a teammate's change since is taken with no copy kept aside, the agent's edit still marked: \(asideAfter - asideBefore) kept aside")

        // A note made from what Maya said to herself stays on her Mac wherever it goes: moved into a shared binder, its
        // binder deleted into a shared General, its binder shared after Delete All took away the moment it was made from,
        // and even marked shared by mistake. One from before the mark is found by its moment while History still has it.
        let launch = BinderRecord(name: "Launch", colorIndex: 1)
        launch.sharedWithTeam = true
        maya.store.insert(launch)
        let errands = BinderRecord(name: "Errands", colorIndex: 3)
        maya.store.insert(errands)
        let said = NoteItem(text: "# Book the dentist\n\nRemind me to book the dentist for Thursday.")
        said.binderID = errands.id
        said.staysUnshared = true
        maya.store.insert(said)
        maya.store.move(said, to: launch)
        check(said.binderID == launch.id && !said.sharedWithTeam, "moved into a shared binder, a note made from what you said stays unshared")
        let older = NoteItem(text: "# Call the venue\n\nRemind me to call the venue about the booth.")
        older.binderID = errands.id
        maya.store.insert(older)
        maya.store.insert(TranscriptRecord(id: older.id, mode: "moment", rawText: "remind me to call the venue about the booth", finalText: "Call the venue",
                                           appName: "iPhone", bundleID: nil, category: nil, duration: 3, asrMillis: 0, llmMillis: 0, engine: "parakeet-v2",
                                           llmModel: nil, usedLLM: false, fallbackReason: nil, audioFileName: nil, status: "answered"))
        maya.store.markMomentNotes()
        // Settings → Delete All takes the moments away (here without the recordings, which this test doesn't own).
        try? maya.store.context.delete(model: TranscriptRecord.self)
        maya.store.save()
        maya.team.setShared(errands, true)
        check(older.staysUnshared && !older.sharedWithTeam, "one from before the mark is marked, and stays unshared when its binder is shared after Delete All")
        let general = maya.store.defaultBinder()
        maya.team.setShared(general, true)
        maya.store.deleteBinder(errands, movingItemsTo: general)
        check(older.binderID == general.id && !older.sharedWithTeam, "its binder deleted, it moves into a shared General and stays unshared")
        said.sharedWithTeam = true
        maya.store.save()
        await maya.team.syncNow()
        await danaAgain.syncNow()
        check(!said.sharedWithTeam && !files().keys.contains { $0.contains("Book the dentist") || $0.contains("Call the venue") }
              && !notes(dana.store).contains { $0.id == said.id || $0.id == older.id },
              "team sync never sends one, even marked shared by mistake, and unshares it")

        print("TEAM_FOLDER: \(folder.path)")
        for path in files().keys.sorted() { print("  \(path)") }
        if let markdown = try? String(contentsOf: folder.appendingPathComponent("Notes/Launch checklist.md"), encoding: .utf8) {
            print("----- Notes/Launch checklist.md -----\n\(markdown)")
        }
        print(failures == 0 ? "TEAM_SELFTEST: all passed" : "TEAM_SELFTEST: \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    @MainActor
    static func printFormatted(raw: String, context: AppContext, vocabulary: [VocabularyTerm]? = nil) async {
        let start = Date()
        let result = await TextFormatter.format(raw: raw, context: context, vocabulary: vocabulary)
        print("FORMAT_MS: \(ms(since: start))")
        print("USED_LLM: \(result.usedLLM)\(result.fallbackReason.map { " (fallback: \($0))" } ?? "")")
        print("PRESS_ENTER: \(result.pressEnter)")
        print("FINAL: \(result.text)")
    }

    /// Two agents and you on a board, through the same tools Claude uses, in a throwaway folder (BINDERS_DATA_DIR).
    @MainActor
    private static func boardSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let write = MCPServer.writeInApp(controller: controller)
        let agentA = BoardActor(name: "Agent A", kind: .agent), agentB = BoardActor(name: "Agent B", kind: .agent)
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:] }
        func list(_ text: String) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? [] }

        let launch = BinderRecord(name: "Launch", colorIndex: 2)
        Store.shared.insert(launch)
        let created = await call("create_task", ["title": "Write the release notes", "binder": "Launch", "column": "ready"], as: agentA)
        guard let id = object(created.text)["id"] as? String, let card = controller.board.card(UUID(uuidString: id)!) else {
            print("BOARD_FAILED: couldn't create a card: \(created.text)")
            return 1
        }
        check(card.column == .ready && card.binderID == launch.id, "an agent puts a card in Launch's Ready column")
        check(list((await call("list_tasks", ["binder": "Launch", "column": "ready"], as: agentB)).text).count == 1, "list_tasks finds it")

        check((await call("claim_task", ["id": id], as: agentA)).ok && card.column == .inProgress && card.assignee == "Agent A",
              "Agent A claims it and it moves to In progress")
        let stolen = await call("claim_task", ["id": id], as: agentB)
        check(!stolen.ok && stolen.text.contains("Agent A"), "Agent B can't claim it: \(stolen.text)")
        check(!(await call("update_task", ["id": id, "column": "review"], as: agentB)).ok, "nor move it")

        let leaseBefore = card.claimExpiresAt ?? .distantPast
        try? await Task.sleep(for: .milliseconds(20))
        let reported = await call("update_task", ["id": id, "progress": "Drafted the notes", "links": "https://example.com/pr/12"], as: agentA)
        check(reported.ok && card.links == ["https://example.com/pr/12"] && (card.claimExpiresAt ?? .distantPast) > leaseBefore,
              "a progress report adds the link and renews the claim")

        check((await call("ask_on_task", ["id": id, "question": "Should the notes mention the pricing change?"], as: agentA)).ok && card.column == .blocked,
              "asking moves it to Blocked")
        controller.board.sweep(now: Date().addingTimeInterval(3 * BoardRules.lease))
        check(card.column == .blocked && card.assignee == "Agent A", "a question nobody answers for an hour and a half keeps the card waiting for Agent A")
        check((await call("comment_task", ["id": id, "text": "Yes, one line."], as: .you)).ok && card.column == .inProgress,
              "your answer (as from the phone) sends it back to In progress")
        let fresh = (card.claimExpiresAt ?? .distantPast).timeIntervalSinceNow
        check(fresh > BoardRules.lease - 60 && fresh <= BoardRules.lease, "the answer gives Agent A a fresh 30 minutes")

        let finish = await call("update_task", ["id": id, "column": "done"], as: agentA)
        check(!finish.ok && finish.text.localizedCaseInsensitiveContains("review"), "Agent A can't move it to Done: \(finish.text)")
        check((await call("complete_task", ["id": id, "summary": "Notes are in the PR."], as: agentA)).ok && card.column == .review,
              "complete_task hands it over for review")
        let sentBack = await call("update_task", ["id": id, "column": "in_progress"], as: .you)
        let lease = (card.claimExpiresAt ?? .distantPast).timeIntervalSinceNow
        check(sentBack.ok && card.column == .inProgress && card.assignee == "Agent A" && lease > BoardRules.lease - 60 && lease <= BoardRules.lease
              && controller.board.timeline(card.id).last?.text == "Sent back to Agent A.",
              "sending it back from Review gives it to Agent A again, for 30 minutes")
        check(list((await call("list_tasks", ["mine": true], as: agentA)).text).count == 1, "and Agent A finds it with `mine`")
        check((await call("complete_task", ["id": id, "summary": "Pricing line added."], as: agentA)).ok && card.column == .review,
              "Agent A hands it over again")
        check((await call("update_task", ["id": id, "column": "done"], as: .you)).ok && card.column == .done, "you approve it: Done")
        check(list((await call("list_tasks", ["binder": "Launch"], as: agentA)).text).isEmpty, "Done cards drop out of list_tasks")

        let timeline = object((await call("get_task", ["id": id], as: agentA)).text)["timeline"] as? [[String: Any]] ?? []
        let kinds = timeline.compactMap { $0["kind"] as? String }
        check(kinds == ["created", "claimed", "progress", "question", "answer", "completed", "moved", "completed", "moved"],
              "the timeline tells the story: \(kinds)")

        // A board's saves don't send the knowledge index over the whole library again; a save that changes a note does.
        let updated = ModelContext.NotificationKey.updatedIdentifiers.rawValue, inserted = ModelContext.NotificationKey.insertedIdentifiers.rawValue
        let events = controller.board.timeline(card.id).map(\.persistentModelID)
        check(TaskCard.onlyBoards([updated: [card.persistentModelID], inserted: events]), "a board's save doesn't start the index")
        check(!TaskCard.onlyBoards([updated: [card.persistentModelID, launch.persistentModelID]]), "a save that changes anything else does")
        check(!TaskCard.onlyBoards(nil) && !TaskCard.onlyBoards([:]), "and so does a save that doesn't say what changed")

        // You can take a card over from an agent, and the agent can't take it back.
        let third = object((await call("create_task", ["title": "Tidy the changelog", "binder": "Launch", "column": "ready"], as: .you)).text)["id"] as? String ?? ""
        _ = await call("claim_task", ["id": third], as: agentA)
        let taken = await call("claim_task", ["id": third], as: .you)
        if let tidy = UUID(uuidString: third).flatMap(controller.board.card) {
            check(taken.ok && tidy.assignee == BoardActor.you.name && !tidy.assigneeIsAgent && tidy.claimExpiresAt == nil
                  && controller.board.timeline(tidy.id).last?.text == "Took it over from Agent A.", "you take a card over from Agent A: \(taken.text)")
            check(!(await call("update_task", ["id": third, "column": "review"], as: agentA)).ok, "and Agent A can't move it any more")
            let late = await call("update_task", ["id": third, "progress": "Sorted the 0.8 entries"], as: agentA)
            check(late.ok && late.text.contains("The user has it now"), "a report from Agent A tells it the card is yours now: \(late.text)")
        } else {
            check(false, "a card to take over")
        }
        // An agent can't put another agent's card on hold with a question.
        let fourth = object((await call("create_task", ["title": "Check the screenshots", "binder": "Launch", "column": "ready"], as: .you)).text)["id"] as? String ?? ""
        _ = await call("claim_task", ["id": fourth], as: agentA)
        let meddling = await call("ask_on_task", ["id": fourth, "question": "Shall I take this over?"], as: agentB)
        check(!meddling.ok && UUID(uuidString: fourth).flatMap(controller.board.card)?.column == .inProgress,
              "Agent B can't ask about Agent A's card and block it: \(meddling.text)")

        // Who a card is meant for, apart from who has it: yours to decide, an agent's only to suggest.
        let release = object((await call("create_task", ["title": "Draft the release email", "binder": "Launch", "column": "ready", "for": "Pennant"],
                                          as: .you)).text)["id"] as? String ?? ""
        let forPennant = list((await call("list_tasks", ["for": "pennant"], as: agentA)).text)
        check(forPennant.count == 1 && forPennant.first?["meant_for"] as? String == "Pennant" && forPennant.first?["meant_for_confirmed"] as? Bool == true,
              "a card you meant for Pennant is listed for Pennant, and confirmed")
        let changelog = object((await call("create_task", ["title": "Write the changelog", "binder": "Launch", "for": "Codex"], as: agentA)).text)["id"] as? String ?? ""
        let suggested = list((await call("list_tasks", ["for": "Codex"], as: agentA)).text).first
        check(suggested?["meant_for_confirmed"] as? Bool == false, "an agent's choice of who a card is for is only a suggestion")
        _ = await call("update_task", ["id": changelog, "for": "Codex"], as: .you)
        let confirmed = list((await call("list_tasks", ["for": "Codex"], as: agentA)).text).first
        check(confirmed?["meant_for_confirmed"] as? Bool == true, "and you confirm it")
        let recent = list((await call("list_tasks", ["since": AutomationPayload.iso(Date().addingTimeInterval(-60))], as: agentA)).text)
        check(recent.contains { ($0["id"] as? String) == release }, "since finds the cards changed in the last minute")
        check(!(await call("list_tasks", ["since": "yesterday"], as: agentA)).ok, "since needs a time")
        // A host that pins its name (BINDERS_AGENT in its configuration) is named first, whatever the agent says.
        setenv("BINDERS_AGENT", "Claude Code", 1)
        _ = await call("claim_task", ["id": release, "agent": "Pennant"], as: agentA)
        unsetenv("BINDERS_AGENT")
        check(UUID(uuidString: release).flatMap(controller.board.card)?.assignee == "Claude Code · Pennant",
              "an agent in Claude Code can't pass itself off as Pennant")
        // Your choice of who a card is for stands: an agent can only say what it thinks.
        let venue = object((await call("create_task", ["title": "Choose the venue", "binder": "Launch", "column": "ready", "for": "Pennant"],
                                        as: .you)).text)["id"] as? String ?? ""
        let overruled = await call("update_task", ["id": venue, "for": "Codex"], as: agentA)
        _ = await call("update_task", ["id": venue, "for": ""], as: agentA)
        let venueCard = UUID(uuidString: venue).flatMap(controller.board.card)
        check(overruled.text.contains("The user chose who it's for") && venueCard?.meantFor == "Pennant" && venueCard?.meantForByAgent == false,
              "an agent can't change or clear who you meant a card for: \(overruled.text)")
        // And no agent acts as you, whatever it calls itself.
        _ = await call("claim_task", ["id": venue], as: .you)
        let posing = await call("update_task", ["id": venue, "column": "done", "agent": "You"], as: agentA)
        check(venueCard?.assignee == BoardActor.you.name && venueCard?.column == .inProgress,
              "an agent that calls itself You can't finish the card you hold: \(posing.text)")
        // A host with a pinned name finds what's meant for it with for "me".
        let deploy = object((await call("create_task", ["title": "Check the deploy", "binder": "Launch", "column": "ready", "for": "Claude Code"],
                                         as: .you)).text)["id"] as? String ?? ""
        setenv("BINDERS_AGENT", "Claude Code", 1)
        let forMe = list((await call("list_tasks", ["for": "me"], as: agentA)).text).compactMap { $0["id"] as? String }
        unsetenv("BINDERS_AGENT")
        check(forMe.contains(deploy) && !forMe.contains(venue), "for \"me\" lists the cards meant for the host's pinned name")
        // Once Agent A has gone quiet, before the sweep comes round, the card is let go first: asking about it doesn't hand
        // Agent A a hold with no end.
        if let screenshots = UUID(uuidString: fourth).flatMap(controller.board.card) {
            screenshots.claimExpiresAt = Date().addingTimeInterval(-1)
            let asked = await call("ask_on_task", ["id": fourth, "question": "Which devices should the screenshots show?"], as: agentB)
            let kinds = controller.board.timeline(screenshots.id).suffix(2).map(\.kind)
            check(asked.ok && screenshots.column == .blocked && screenshots.assignee == nil && kinds == [.lapsed, .question],
                  "asking about a card whose agent went quiet lets it go first: \(kinds)")
        }
        // A card left in Review by an earlier version keeps no lease, so no one reads a time that means nothing.
        if let older = UUID(uuidString: third).flatMap(controller.board.card) {
            older.state = CardState(column: .review, assignee: agentA.name, assigneeIsAgent: true, claimExpires: Date().addingTimeInterval(-600))
            controller.board.sweep()
            check(older.claimExpiresAt == nil && older.assignee == agentA.name && older.column == .review, "the sweep clears an old lease in Review")
            let listed = list((await call("list_tasks", ["binder": "Launch", "column": "review"], as: agentB)).text).first { ($0["id"] as? String) == third }
            check(listed?["claim_expires"] as? String == "", "list_tasks gives no end time for a card waiting in Review")
        }

        // An agent that goes quiet loses the card.
        let second = object((await call("create_task", ["title": "Check the import tool", "binder": "Launch", "column": "ready"], as: .you)).text)["id"] as? String ?? ""
        _ = await call("claim_task", ["id": second, "agent": "Claude Code · repo"], as: agentB)
        let quiet = controller.board.card(UUID(uuidString: second)!)!
        check(quiet.assignee == "Claude Code · repo", "an agent names itself with `agent`")
        check(list((await call("list_tasks", ["mine": true, "agent": "Claude Code · repo"], as: agentB)).text).count == 1, "and finds its own cards with `mine`")
        quiet.claimExpiresAt = Date().addingTimeInterval(-1)
        controller.board.sweep()
        check(quiet.column == .ready && quiet.assignee == nil && controller.board.timeline(quiet.id).last?.kind == .lapsed,
              "after its lease lapses, the card is back in Ready")

        // A binder can let agents finish.
        launch.agentsMayFinish = true
        _ = await call("claim_task", ["id": second], as: agentA)
        check((await call("complete_task", ["id": second, "summary": "Import works up to 50k rows."], as: agentA)).ok && quiet.column == .done,
              "where agents may finish, complete_task goes straight to Done")
        let fifth = object((await call("create_task", ["title": "Write the FAQ", "binder": "Launch", "column": "ready"], as: .you)).text)["id"] as? String ?? ""
        _ = await call("claim_task", ["id": fifth], as: agentA)
        let finished = await call("update_task", ["id": fifth, "column": "done", "progress": "Published"], as: agentA)
        check(finished.ok && !finished.text.contains("hold") && !finished.text.contains("has it now"),
              "an agent that finishes its own card isn't told it lost it: \(finished.text)")
        check(!(await call("claim_task", ["id": UUID().uuidString], as: agentA)).ok, "an unknown card is refused")

        // To-dos become cards and stay linked: a card that's done ticks its to-do off where it lives.
        let prep = NoteItem(text: "Launch prep\n\n- [ ] Draft the launch email\n- [ ] Book the venue")
        prep.binderID = launch.id
        Store.shared.insert(prep)
        let todos = list((await call("list_todos", [:], as: agentA)).text)
        guard let email = todos.first(where: { ($0["task"] as? String) == "Draft the launch email" })?["id"] as? String else {
            print("BOARD_FAILED: list_todos doesn't have the note's to-do")
            return 1
        }
        let fromTodo = await call("create_task", ["todo": email, "column": "ready"], as: agentA)
        let farmed = controller.board.card(forTodo: email)
        check(fromTodo.ok && farmed?.title == "Draft the launch email" && farmed?.binderID == launch.id && farmed?.column == .ready,
              "create_task turns a to-do into a card in its binder: \(fromTodo.text)")
        let again = await call("create_task", ["todo": email], as: agentB)
        let sameTodo = ((try? Store.shared.context.fetch(FetchDescriptor<TaskCard>())) ?? []).filter { $0.sourceRef == email }
        check(again.ok && object(again.text)["id"] as? String == farmed?.id.uuidString && sameTodo.count == 1,
              "the same to-do doesn't get a second card: \(again.text)")
        let listed = list((await call("list_todos", [:], as: agentA)).text).first { ($0["id"] as? String) == email }
        check(listed?["card_id"] as? String == farmed?.id.uuidString && listed?["card_column"] as? String == "ready", "list_todos says it's on the board")
        let entries = TaskCollector.collect(meetings: [], notes: [prep], openMeeting: { _ in }, openNote: { _ in })
        check(entries.contains { $0.ref == email }, "the to-do lists name a to-do the way list_todos does")
        if let farmed {
            check((try? controller.board.move(farmed, to: .done, by: .you)) != nil
                  && prep.text.contains("- [x] Draft the launch email") && prep.text.contains("- [ ] Book the venue"),
                  "finishing the card ticks its to-do off in the note, and only that one")
            check((try? controller.board.move(farmed, to: .ready, by: .you)) != nil && prep.text.contains("- [ ] Draft the launch email"),
                  "taking the card out of Done opens the to-do again")
        }
        let promise = controller.commitments.addSpoken("send Dana the pricing sheet").commitment
        promise.binderID = launch.id
        if let item = Todos.find(promise.id.uuidString) {
            let card = controller.board.create(from: item, by: .you).card
            check(card.sourceRef == promise.id.uuidString && (try? controller.board.move(card, to: .done, by: .you)) != nil && promise.status == "done",
                  "a promise is kept when its card is done")
        } else {
            check(false, "a promise can be found by its id")
        }
        check(!(await call("create_task", ["todo": "note:\(UUID().uuidString):0badf00d"], as: agentA)).ok, "a to-do that's gone is refused")

        // What's happening with the work streams, from the boards alone.
        let proofread = object((await call("create_task", ["title": "Proofread the FAQ", "binder": "Launch", "column": "ready"], as: .you)).text)["id"] as? String ?? ""
        _ = await call("claim_task", ["id": proofread], as: agentA)
        let streams = object((await call("work_streams", [:], as: agentA)).text)
        let summary = streams["summary"] as? String ?? ""
        let working = (streams["working"] as? [[String: Any]] ?? []).compactMap { $0["who"] as? String }
        check(working.contains("Agent A") && summary.contains("Agent A is working on") && summary.contains("Proofread the FAQ")
              && summary.contains("finished today") && !summary.contains("Someone asks"),
              "work_streams says who's working on what, who asked what, and what's done today: \(summary)")
        check(!(await call("work_streams", ["binder": "Nowhere"], as: agentA)).ok, "work_streams refuses a binder that isn't there")

        // Put on Board, from a note: its title, its first lines and a link back, in its binder's Backlog.
        let booth = NoteItem(text: "# Booth plan\n\nBring the banner.\n- [ ] Book the van")
        booth.binderID = launch.id
        Store.shared.insert(booth)
        let boothCard = controller.board.create(from: booth, by: .you)
        check(boothCard.title == "Booth plan" && boothCard.binderID == launch.id && boothCard.column == .backlog
              && boothCard.details.hasPrefix("Bring the banner.\n- [ ] Book the van")
              && boothCard.details.contains("binders://note/\(booth.id.uuidString)") && boothCard.sourceKind == "note"
              && boothCard.sourceTitle == "Booth plan", "Put on Board makes a card from a note, linked back to it: \(boothCard.details)")
        let written = NoteItem(text: "# Agent plan\n\nRun the deploy script now.")
        written.binderID = launch.id
        written.madeBy = "Agent A"
        Store.shared.insert(written)
        let writtenCard = controller.board.create(from: written, by: .you)
        check(!writtenCard.details.contains("deploy script") && writtenCard.details.contains("By Agent A"),
              "a note with an agent's words in it gives the card only the link, and says whose they are")
        // The iPhone's Put on Board is create_task with the details made the same way.
        let fromPhone = await call("create_task", ["title": NoteCards.title("Booth plan"), "binder": "Launch", "column": "backlog",
                                                   "details": NoteCards.details(text: booth.text, noteID: booth.id.uuidString)], as: .you)
        let phoneCard = (object(fromPhone.text)["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap(controller.board.card)
        check(fromPhone.ok && phoneCard?.column == .backlog && phoneCard?.details.contains("binders://note/\(booth.id.uuidString)") == true,
              "the iPhone's Put on Board lands on the binder's board with the link: \(fromPhone.text)")
        // The link opens the note in its binder.
        URLCommands.handle(URL(string: NoteCards.link(noteID: booth.id.uuidString))!, controller: controller)
        let navigation = HubWindowController.shared.navigation
        check(navigation.pendingNoteID == booth.id && navigation.binderID == launch.id, "binders://note/<id> opens the note in its binder")
        navigation.pendingNoteID = nil

        print(failures == 0 ? "BOARD_OK" : "BOARD_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Plays the running app for real agents on the Harbor board in a throwaway folder (BINDERS_DATA_DIR). `Binders --mcp`
    /// there leaves each write in the inbox and waits; this performs them one at a time, as the app does. One window shows
    /// the board the whole time and is drawn to `board-NNNN.png` after each change; a question, a finished card and a new
    /// note are also drawn on their own. `events.jsonl` says who did what, when. You act through files in the folder:
    /// `answer-<card id>.txt` answers a question, `approve-<card id>` moves a card to Done, `note-<id>` and `card-<id>`
    /// draw that note or card on their own, `stop` ends it.
    @MainActor
    private static func boardServe(to directory: URL, empty: Bool, size: NSSize, keep: Bool) async -> Int32 {
        let controller = DictationController()
        // `--keep` opens a folder from an earlier run as it is, to draw more of it.
        let seeded = keep ? true : await DemoData.seed(knowledge: controller.knowledge)
        guard seeded, let harbor = Store.shared.binders().first(where: { $0.name == DemoData.binderName }) else { return 1 }
        if empty { controller.board.cards(in: harbor.id).forEach { controller.board.delete($0) } }
        let manager = FileManager.default, inbox = InboxCommands.directory
        try? manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = Date()
        let events = directory.appendingPathComponent("events.jsonl")
        manager.createFile(atPath: events.path, contents: Data())
        let log = try? FileHandle(forWritingTo: events)

        func environment<V: View>(_ view: V) -> some View {
            view.environment(controller).environment(controller.meetings).environment(controller.knowledge)
                .environment(controller.team).environment(controller.capture).environment(controller.commitments)
                .environment(AppSettings.shared).modelContainer(Store.shared.container)
        }
        let navigation = HubNavigation()
        navigation.binderID = harbor.id
        navigation.selection = .binder
        navigation.pendingBinderTab = .board
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: environment(HubView().environment(navigation)))
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500))

        // Layer drawing leaves the sidebar's list out, and the sidebar doesn't change during a run: draw the window once
        // through each view's own drawing, which gets the sidebar right (and not the rest), to put it back afterwards.
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("sidebar.png"))
        }
        func splitViews(_ view: NSView) -> [NSSplitView] { (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splitViews) }
        if let sidebar = splitViews(hosting).first?.arrangedSubviews.first { print("SIDEBAR_WIDTH: \(Int(sidebar.frame.width))") }

        var frame = 0
        func draw() async {
            try? await Task.sleep(for: .milliseconds(250))
            frame += 1
            capture(hosting, name: String(format: "board-%04d", frame), directory: directory)
        }
        func say(_ line: String) {
            print("\(Date().formatted(date: .omitted, time: .standard)) \(line)")
            fflush(stdout)
        }
        func record(_ fields: [String: Any]) {
            var entry = fields
            entry["ms"] = Int(Date().timeIntervalSince(started) * 1000)
            entry["frame"] = frame
            if let data = try? JSONSerialization.data(withJSONObject: entry) { log?.write(data + Data("\n".utf8)) }
        }
        func asYou(_ tool: String, _ arguments: [String: Any]) async {
            do {
                let reply = try await MCPServer.call(tool, arguments, knowledge: controller.knowledge,
                                                     write: MCPServer.writeInApp(controller: controller), actor: .you)
                say("You: \(tool) \(arguments["id"] ?? "") → \(reply)")
                record(["who": "You", "action": tool, "card": arguments["id"] ?? "", "ok": true, "text": arguments["text"] ?? ""])
            } catch {
                say("You: \(tool) refused → \((error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription)")
            }
        }
        await draw()
        record(["who": "", "action": "start"])
        say("SERVING: \(inbox.path)")
        let suffix = Inbox.requestFile("")
        while !manager.fileExists(atPath: directory.appendingPathComponent("stop").path) {
            var changed = false, closeUps: [(name: String, view: AnyView, size: NSSize)] = []
            let requests = ((try? manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasSuffix(suffix) && Inbox.isValidName(String($0.lastPathComponent.dropLast(suffix.count))) }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            for url in requests {
                let name = String(url.lastPathComponent.dropLast(suffix.count))
                guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(InboxRequest.self, from: data) else { continue }
                let request = InboxCommands.fromAgent(decoded)
                let result = await InboxCommands.perform(request, controller: controller)
                try? JSONEncoder().encode(result).write(to: inbox.appendingPathComponent(Inbox.resultFile(name)), options: .atomic)
                try? manager.removeItem(at: url)
                let who = request.fields["actor"] ?? ""
                say("\(who.isEmpty ? "?" : who): \(request.action) \(request.fields["id"] ?? request.fields["title"] ?? "") → "
                    + (result.ok ? result.message : "REFUSED \(result.error ?? "")")
                    + (request.action == "ask_on_task" ? " QUESTION: \(request.fields["text"] ?? "")" : ""))
                changed = true
                record(["who": who, "action": request.action, "card": request.fields["id"] ?? "", "ok": result.ok,
                        "text": result.ok ? result.message : (result.error ?? ""), "made": result.id ?? "",
                        "question": request.action == "ask_on_task" ? (request.fields["text"] ?? "") : ""])
                let tag = String(format: "%04d", frame + 1)
                if result.ok, ["ask_on_task", "complete_task"].contains(request.action),
                   let id = UUID(uuidString: request.fields["id"] ?? ""), let card = controller.board.card(id) {
                    closeUps.append(("card-\(tag)-\(request.action)", AnyView(environment(CardDetailView(card: card)).environment(HubNavigation())), NSSize(width: CardLayout.defaultWidth, height: CardLayout.defaultHeight)))
                }
                if result.ok, request.action == "add_note", let id = result.id.flatMap(UUID.init(uuidString:)) {
                    let notes = HubNavigation()
                    notes.binderID = harbor.id
                    notes.selection = .binder
                    notes.pendingBinderTab = .notes
                    notes.pendingNoteID = id
                    closeUps.append(("note-\(tag)", AnyView(environment(HubView().environment(notes))), size))
                }
            }
            for file in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                let path = directory.appendingPathComponent(file)
                if file.hasPrefix("answer-"), file.hasSuffix(".txt"), let text = try? String(contentsOf: path, encoding: .utf8) {
                    await asYou("comment_task", ["id": String(file.dropFirst(7).dropLast(4)), "text": text.trimmed])
                } else if file.hasPrefix("approve-") {
                    await asYou("update_task", ["id": String(file.dropFirst(8)), "column": "done"])
                } else if file.hasPrefix("note-"), let id = UUID(uuidString: String(file.dropFirst(5))) {
                    let notes = HubNavigation()
                    notes.binderID = harbor.id
                    notes.selection = .binder
                    notes.pendingBinderTab = .notes
                    notes.pendingNoteID = id
                    closeUps.append(("note-\(id.uuidString.prefix(8))", AnyView(environment(HubView().environment(notes))), size))
                } else if file.hasPrefix("card-"), let id = UUID(uuidString: String(file.dropFirst(5))), let card = controller.board.card(id) {
                    closeUps.append(("card-\(id.uuidString.prefix(8))", AnyView(environment(CardDetailView(card: card)).environment(HubNavigation())), NSSize(width: CardLayout.defaultWidth, height: CardLayout.defaultHeight)))
                } else { continue }
                try? manager.removeItem(at: path)
                changed = true
            }
            controller.board.sweep()
            if changed { await draw() }
            for closeUp in closeUps { await render(closeUp.view, size: closeUp.size, name: closeUp.name, directory: directory.appendingPathComponent("close-ups")) }
            try? await Task.sleep(for: .milliseconds(150))
        }
        window.close()
        say("STOPPED after \(frame) frames")
        return 0
    }

    /// For developing the iPhone app: the fictional demo data behind a real phone link, a pairing link on standard output
    /// (with 127.0.0.1 first, for the Simulator), and commands on standard input: "todo <text>", "note <text>", "pair".
    /// It offers made-up addresses, as screenshots are taken against it; `--real-network` offers this Mac's own, for a
    /// real iPhone on this network (Tailscale is never asked here).
    @MainActor
    private static func linkServe() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this seeds fictional data there")
            return 1
        }
        let controller = DictationController()
        guard await DemoData.seed(knowledge: controller.knowledge) else { return 1 }
        // Spare ports, so it runs alongside the real app's phone link.
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: AppPaths.support.appendingPathComponent("link-devices.json"))
        if CommandLine.arguments.contains("--real-network") { server.networkForTests = nil }
        controller.link = server
        server.start()
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        guard server.status == .listening else {
            print("ERROR: \(server.status)")
            return 1
        }
        func printPairing() async {
            guard var pairing = await server.beginPairing(), let port = server.boundPairingPort else { return }
            pairing.addresses.insert("127.0.0.1:\(port)", at: 0)
            print("PAIR_URL: \(pairing.url.absoluteString)")
            fflush(stdout)
        }
        // Killed rather than ended by closing standard input (the UI tests' runner stops it so): the run's device keys
        // still leave the Keychain.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let stops = [SIGTERM, SIGINT].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { server.stop() }
                exit(0)
            }
            source.resume()
            return source
        }
        defer { stops.forEach { $0.cancel() } }
        print("SERVING on port \(server.boundPort ?? 0)")
        await printPairing()
        let lines = AsyncStream<String> { continuation in
            Thread.detachNewThread {
                while let line = readLine() { continuation.yield(line) }
                continuation.finish()
            }
        }
        for await line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "pair" {
                await printPairing()
            } else if text.hasPrefix("todo-in "), let bar = text.firstIndex(of: "|") {
                // "todo-in Harbor launch|call Sam": a to-do in a named binder.
                let binder = String(text[text.index(text.startIndex, offsetBy: 8)..<bar])
                let result = await InboxCommands.perform(InboxRequest(action: "add_todo", fields: ["text": String(text[text.index(after: bar)...]), "binder": binder]), controller: controller)
                print("TODO: \(result.ok ? result.message : result.error ?? "failed")")
            } else if text.hasPrefix("todo ") {
                let result = await InboxCommands.perform(InboxRequest(action: "add_todo", fields: ["text": String(text.dropFirst(5))]), controller: controller)
                print("TODO: \(result.message)")
            } else if text.hasPrefix("note ") {
                let result = await InboxCommands.perform(InboxRequest(action: "add_note", fields: ["text": String(text.dropFirst(5))]), controller: controller)
                print("NOTE: \(result.message)")
            } else if text.hasPrefix("ask "), let bar = text.firstIndex(of: "|") {
                // "ask Fix the import|Which staging database?": an agent takes the card that starts so and asks you.
                let title = String(text[text.index(text.startIndex, offsetBy: 4)..<bar])
                if let card = controller.board.cards(in: nil).first(where: { $0.title.hasPrefix(title) }) {
                    let agent = ["id": card.id.uuidString, "actor": "Claude Code · harbor-web", "actor_kind": BoardActor.Kind.agent.rawValue]
                    _ = await InboxCommands.perform(InboxRequest(action: "claim_task", fields: agent), controller: controller)
                    let question = agent.merging(["text": String(text[text.index(after: bar)...])]) { a, _ in a }
                    let result = await InboxCommands.perform(InboxRequest(action: "ask_on_task", fields: question), controller: controller)
                    print("ASKED: \(result.ok ? card.id.uuidString : result.error ?? "failed")")
                } else {
                    print("ASKED: no card starting “\(title)”")
                }
            } else if text.hasPrefix("card ") {
                // "card Fix the import": where that card is, who has it, and for how long.
                let title = String(text.dropFirst(5))
                if let card = controller.board.cards(in: nil).first(where: { $0.title.hasPrefix(title) }) {
                    let minutes = card.claimExpiresAt.map { "\(Int(($0.timeIntervalSinceNow / 60).rounded()))" } ?? "none"
                    let last = controller.board.timeline(card.id).last
                    print("CARD: column=\(card.column.rawValue) assignee=\(card.assignee ?? "") lease=\(minutes) last=\(last?.kindRaw ?? ""):\(last?.author ?? ""):\(last?.text ?? "")")
                } else {
                    print("CARD: none")
                }
            } else if text == "agents" {
                // Agents for the iPhone's Agents screen: two that check the board themselves, a conversation with each, and a
                // local model as the Manager, answered by a stand-in.
                let binders = Store.shared.binders()
                guard let first = binders.first else { print("AGENTS: no binders"); continue }
                let registry = AgentRegistry.shared
                let claude = AgentProfile(name: "Claude Code · app", wake: .board)
                let pennant = AgentProfile(name: "Pennant", wake: .board, binders: [binders.last?.id ?? first.id])
                registry.upsert(claude)
                registry.upsert(pennant)
                registry.upsert(AgentProfile(name: "Manager", wake: .localModel(LocalModelWake(model: "stand-in")), manager: true), isManager: true)
                // And Claude Code for chats (lane AC1), a stand-in that writes as it goes, then answers in Markdown.
                let bin = AppPaths.support.appendingPathComponent("bin"), repository = AppPaths.support.appendingPathComponent("repo")
                try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
                let fake = bin.appendingPathComponent("claude")
                try? """
                    #!/bin/sh
                    cat > /dev/null
                    prev=""
                    for a in "$@"; do if [ "$prev" = "--worktree" ]; then mkdir -p ".claude/worktrees/$a"; fi; prev="$a"; done
                    cat <<'JSON'
                    {"type":"assistant","message":{"content":[{"type":"text","text":"Looking at **BoardColumnsView** now…"}]}}
                    JSON
                    sleep 4
                    cat <<'JSON'
                    {"type":"result","result":"Found it. The board clips because:\\n\\n- each column is at least **260 pt** wide\\n- six columns need `1,560 pt`\\n\\n1. Fold Done into a strip\\n2. Let columns shrink to 200 pt\\n\\n```\\nlet minimum: CGFloat = 200\\n```"}
                    JSON
                    """.write(to: fake, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
                registry.upsert(AgentProfile(name: "Claude Code · live", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "auto", executable: fake.path)),
                                             preset: "claude-code"))
                let board = controller.board
                let agent = BoardActor(name: claude.name, kind: .agent)
                let working = board.create(title: "Why does the board clip at 1100 pt?", details: "On my 14-inch screen the last column is cut off.", binderID: first.id, by: .you)
                board.give(working, to: claude.name, by: .you)
                try? board.claim(working, by: agent)
                _ = board.comment(working, text: "Looking at BoardColumnsView now. The minimum column width is 260 pt, so six columns need 1,560 pt.", by: agent)
                let asked = board.create(title: "Update the download link", binderID: first.id, by: .you)
                board.give(asked, to: claude.name, by: .you)
                try? board.claim(asked, by: agent)
                _ = try? board.ask(asked, question: "Should the link point at 0.12.0 or the latest release?", by: agent)
                // A card the stand-in Claude Code worked on, with Binders' log of its run, for the terminal (lane AC2).
                let live = BoardActor(name: "Claude Code · live", kind: .agent)
                let folded = board.create(title: "Fold Done into a narrow strip", details: "Done takes a full column on a 14-inch screen.", binderID: first.id, by: .you)
                board.give(folded, to: live.name, by: .you)
                try? board.claim(folded, by: live)
                _ = board.comment(folded, text: "Keep the count on the strip.", by: .you)
                let logs = AgentPlaces.logs
                try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                let log = logs.appendingPathComponent("\(folded.id.uuidString.prefix(8).lowercased())-20261029T090000.jsonl")
                try? ([
                    #"{"type":"system","subtype":"init","session_id":"s1"}"#,
                    #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"p1","name":"TodoWrite","input":{"todos":[{"content":"Read the board","status":"completed"},{"content":"Fold Done","activeForm":"Folding Done","status":"in_progress"},{"content":"Run the tests","status":"pending"}]}}]}}"#,
                    #"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"On it. I'll fold **Done** into a narrow strip that keeps its count."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/repo/Binders/Board/BoardColumnsView.swift"}}]}}"#,
                    #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"..."}]}}"#,
                    #"{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/repo/Binders/Board/BoardColumnsView.swift","old_string":"a\n.frame(minWidth: 260)\nb","new_string":"a\n.frame(minWidth: column == .done ? 120 : 260)\n.animation(.snappy, value: folded)\nb"}}]}}"#,
                    #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}"#,
                    #"{"type":"assistant","message":{"id":"m4","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"swift test --filter BoardTests"}}]}}"#,
                    #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"Test Suite 'BoardTests' started\nExecuted 24 tests, with 0 failures"}]}}"#,
                    #"{"type":"assistant","message":{"id":"m5","content":[{"type":"text","text":"Done folds to 120 pt and keeps its count. Tests pass."}]}}"#,
                    #"{"type":"result","subtype":"success","is_error":false,"duration_ms":192000,"total_cost_usd":0.42,"result":"Done folds to 120 pt and keeps its count."}"#,
                ].joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
                board.woke(folded, agent: live.name, text: "Started Claude Code in \(repository.path)/.claude/worktrees/fold-done (acceptEdits, ready). To look in: claude --resume 3f2a3c55-1111-4222-8333-944455556666 there.", log: log)
                let manager = controller.manager
                manager.localPump = {
                    let waiting = (try? FileManager.default.contentsOfDirectory(atPath: InboxCommands.directory.path)) ?? []
                    for file in waiting where file.hasSuffix(".request.json") {
                        await InboxCommands.apply(named: String(file.dropLast(".request.json".count)), controller: controller)
                    }
                }
                manager.localModel = { _, _ in
                    ScriptedModel { _, _, user in
                        user.contains("tidy") || user.contains("Tidy")
                            ? #"{"action":"reply","tool":"","arguments":[],"reply":"Done: nothing needed moving."}"#
                            : #"{"action":"reply","tool":"","arguments":[],"reply":"Two cards need you: Claude Code asks which release the download link points at, and the board clipping is in progress."}"#
                    }
                }
                Store.shared.save()
                print("AGENTS: \(registry.agents.map(\.name).joined(separator: ", "))")
            } else if text == "hellos" {
                // How many times the phone has connected: one per launch, and none for a quick trip to the background.
                print("HELLOS: \(server.hellos)")
            } else if text == "conversations" {
                // What the phone's All-day capture sent, as the Mac wrote it up.
                let kind = MeetingRecord.conversationKind
                for record in (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.kind == kind }))) ?? [] {
                    let lines = Store.shared.segments(for: record.id).map { "  [\(TranscriptFormatter.timestamp($0.start))] \(record.speakerNames[$0.speaker] ?? $0.speaker): \($0.text)" }
                    print("CONVERSATION: \(record.title) · \(record.status) · \(Store.shared.binder(record.binderID)?.name ?? "?") · \(record.appName ?? "") · shared=\(record.sharedWithTeam)")
                    print(lines.joined(separator: "\n"))
                    print(record.summary)
                }
            } else if text == "quit" {
                break
            }
            fflush(stdout)
        }
        server.stop()
        return 0
    }

    /// Plays an iPhone against the phone link, in a throwaway folder (BINDERS_DATA_DIR) on spare ports: pairs once, proves
    /// which device it is, uses the tools, hears about changes, and is shut out by a wrong key and by being removed.
    @MainActor
    private static func linkSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes and to-dos")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let devicesURL = FileManager.default.temporaryDirectory.appendingPathComponent("link-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: devicesURL) }
        let server = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: devicesURL)
        server.start()
        for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
        check(server.status == .listening, "the Mac is listening")
        guard let port = server.boundPort, let pairing = await server.beginPairing(), let pairingPort = server.boundPairingPort else {
            print("LINK_FAILED: couldn't start")
            return 1
        }
        check(!pairing.addresses.isEmpty && LinkPairing(url: pairing.url) == pairing, "the QR code carries addresses and survives the round trip")
        var local = pairing
        local.addresses = ["127.0.0.1:\(pairingPort)"]

        do {
            let paired = try await LinkClient.pair(local, deviceName: "Test iPhone")
            check(server.devices.map(\.name) == ["Test iPhone"], "paired, and the Mac keeps the device")
            // Its key is in the Keychain, never in the data folder, so nothing that reads the folder can connect as it.
            let listed = (try? Data(contentsOf: devicesURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            check(listed.count == 1 && listed.allSatisfy { $0["key"] == nil } && listed.first?["name"] as? String == "Test iPhone"
                  && LinkServer.storedKey(for: paired.device) == paired.key.withUnsafeBytes({ Data($0) }),
                  "its key is kept in the Keychain, and link-devices.json says only who's paired: \(listed.first.map { $0.keys.sorted() } ?? [])")
            try? await Task.sleep(for: .milliseconds(600))
            check(server.pairing == nil, "pairing closes after one use")
            let reused = try? await LinkClient.pair(local, deviceName: "Someone else")
            check(reused == nil, "the same code can't pair a second device")

            let phone = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            try await phone.connect()
            let early = try? await phone.request("tools/list")
            check(early == nil, "nothing works before the device proves which one it is")
            try await phone.hello(device: paired.device, key: paired.key, name: "Test iPhone")
            check(server.connectedDevices.contains(paired.device), "the Mac shows the device as connected")
            let tools = try await phone.request("tools/list") as? [String: Any]
            check((tools?["tools"] as? [Any])?.count == MCPServer.tools.count, "the phone gets the same tools as MCP")
            _ = try await phone.callTool("add_todo", ["text": "Call Sam tomorrow at 3 pm"])
            let todos = try await phone.callTool("list_todos")
            check(todos.localizedCaseInsensitiveContains("call sam"), "a to-do added from the phone is on the board")
            // Dictation from the phone is cleaned up here, the way the Mac cleans its own.
            let formatted = try await phone.request("binders/format", ["text": "um so send it by friday actually make that thursday"]) as? [String: Any]
            let cleaned = formatted?["text"] as? String ?? ""
            check(!cleaned.isEmpty && !cleaned.lowercased().contains("um ") && cleaned.lowercased().contains("thursday") && !cleaned.lowercased().contains("friday"),
                  "the Mac cleans up the phone's dictation: “\(cleaned)”")
            // And keeps it with its own dictations, once, however many times it's sent.
            let dictationID = UUID().uuidString
            for _ in 0..<2 {
                _ = try await phone.request("binders/dictation", ["id": dictationID, "text": "Send it by Thursday.", "raw": "um so send it by thursday",
                                                                  "app": "iPhone keyboard", "date": "2026-10-13T09:30:00Z"])
            }
            let recent = try await phone.callTool("recent_dictations")
            let kept = ((try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>())) ?? []).filter { $0.id.uuidString == dictationID }
            check(kept.count == 1 && kept.first?.appName == "iPhone keyboard" && kept.first?.rawText == "um so send it by thursday"
                  && recent.contains("Send it by Thursday."), "a dictation made on the phone is kept on the Mac, once: \(kept.count)")

            let heard = LinkEvents()
            phone.onNotification { heard.add($0) }
            _ = try await phone.request("binders/subscribe")
            Store.shared.insert(NoteItem(text: "Link test note\n\n- [ ] check the phone"))
            for _ in 0..<30 where heard.kinds.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            check(heard.kinds.contains("notes") && heard.kinds.contains("todos"), "the phone hears that notes changed: \(heard.kinds.sorted())")

            // A phone that lists nothing in its hello is iPhone 2.0: it's sent nothing new. One that lists more gets it.
            check(server.phoneFeatures == [LinkFeatures.firstPhone], "a phone that lists nothing reads what iPhone 2.0 reads")
            let modern = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            try await modern.connect()
            try await modern.hello(device: paired.device, key: paired.key, name: "Test iPhone",
                                   features: LinkFeatures.thisPhone + [LinkFeatures.notification("binders/test")])
            let modernHeard = LinkEvents()
            modern.onNotification { modernHeard.add($0) }
            _ = try await modern.request("binders/subscribe")
            check(server.phoneFeatures.contains { $0.contains(LinkFeatures.notification("binders/test")) }, "the Mac keeps what each phone reads")
            let before = heard.count
            server.notify("binders/test", ["kinds": ["test"]])
            for _ in 0..<30 where modernHeard.count == 0 { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(300))
            check(modernHeard.count == 1 && heard.count == before, "a new notification goes only to the phone that reads it")
            let hello = try await modern.hello(device: paired.device, key: paired.key, name: "Test iPhone")
            check((hello["features"] as? [String] ?? []).contains(LinkFeatures.warm), "the Mac says it warms its model for the phone")
            check((try? await modern.request(LinkFeatures.warmMethod, timeout: 5)) != nil, "and answers binders/warm at once")
            // The heartbeat's footing: how long the Mac has been quiet, and a word when a request goes unanswered.
            try? await Task.sleep(for: .milliseconds(1100))
            check(modern.quietFor >= 1, "the phone knows how long the Mac has been quiet")
            let timeouts = LinkEvents()
            modern.onTimeout { timeouts.add([:]) }
            server.stalls = true
            let stalled = try? await modern.request("ping", timeout: 1)
            server.stalls = false
            check(stalled == nil && timeouts.count == 1, "a request the Mac doesn't answer times out, and the phone is told")
            check((try? await modern.request("ping", timeout: 3)) != nil, "and a Mac that wakes answers again")
            modern.close()
            // A Mac that takes the connection and then says nothing is given up on in the phone's handshake time, rather
            // than leaving the phone "Connecting…" for minutes.
            let silent = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            try await silent.connect()
            server.stalls = true
            let helloStarted = Date()
            let unanswered = try? await silent.hello(device: paired.device, key: paired.key, name: "Test iPhone", timeout: 1)
            server.stalls = false
            check(unanswered == nil && Date().timeIntervalSince(helloStarted) < 3, "a hello the Mac doesn't answer gives up in its time")
            silent.close()

            let intruder = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: SymmetricKey(size: .bits256))
            let intruded = (try? await intruder.connect(timeout: 3)) != nil
            check(!intruded, "a wrong key can't connect")
            intruder.close()

            server.revoke(paired.device)
            try? await Task.sleep(for: .milliseconds(300))
            let afterRemoval = try? await phone.callTool("list_binders")
            check(afterRemoval == nil, "a removed device is disconnected at once")
            let again = LinkClient(host: "127.0.0.1", port: port, identity: paired.device.uuidString, key: paired.key)
            let reconnected = (try? await again.connect(timeout: 3)) != nil
            check(!reconnected, "and can't connect again")
            again.close()
            check(LinkServer.storedKey(for: paired.device) == nil, "and its key is gone from the Keychain")

            await checkKeysMove(check, controller: controller)

            // In a throwaway folder, a run's devices leave the Keychain when the link stops, so the self-tests leave nothing.
            if var second = await server.beginPairing(), let secondPort = server.boundPairingPort {
                second.addresses = ["127.0.0.1:\(secondPort)"]
                let other = try await LinkClient.pair(second, deviceName: "Second iPhone")
                let kept = LinkServer.storedKey(for: other.device) != nil
                server.stop()
                check(kept && LinkServer.storedKey(for: other.device) == nil, "in a throwaway folder, the devices' keys leave the Keychain when the link stops")
            } else {
                check(false, "pairing opens a second time")
            }
        } catch {
            check(false, "the conversation failed: \(error.localizedDescription)")
        }
        server.stop()
        // Where a phone can reach the Mac: the addresses, in the hello and as notices, and the parallel dial.
        await linkAddressesSelfTest(check, controller: controller)
        print(failures == 0 ? "LINK_OK" : "LINK_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// A devices file from before 0.8.1, with the keys in it: they move to the Keychain without anyone pairing again, and
    /// the file is written without them. After that a key put into the file never gets in, and a device whose key the
    /// Keychain doesn't have (a data folder from another Mac) stays listed in the file but can't connect.
    @MainActor
    private static func checkKeysMove(_ check: (Bool, String) -> Void, controller: DictationController) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("link-devices-before-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func entries() -> [[String: Any]] {
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        }
        func listening(_ server: LinkServer) async -> UInt16? {
            server.start()
            for _ in 0..<50 where server.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
            return server.boundPort
        }
        /// Whether a phone with this key gets past hello.
        func connects(_ device: UUID, _ key: SymmetricKey, port: UInt16) async -> Bool {
            let phone = LinkClient(host: "127.0.0.1", port: port, identity: device.uuidString, key: key)
            defer { phone.close() }
            guard (try? await phone.connect(timeout: 3)) != nil else { return false }
            return (try? await phone.hello(device: device, key: key, name: "Old iPhone", timeout: 3)) != nil
        }
        /// A device as builds before 0.8.1 wrote it, key and all.
        struct Before: Codable {
            let id: UUID
            var name: String
            var key: Data
            var pairedAt: Date
            var lastSeen: Date?
        }
        let old = UUID(), oldKey = SymmetricKey(size: .bits256)
        let oldData = oldKey.withUnsafeBytes { Data($0) }
        try? JSONEncoder().encode([Before(id: old, name: "Old iPhone", key: oldData, pairedAt: Date().addingTimeInterval(-86_400), lastSeen: nil)])
            .write(to: url)
        let moved = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: url)
        check(moved.devices.map(\.name) == ["Old iPhone"] && LinkServer.storedKey(for: old) == oldData
              && entries().count == 1 && entries().allSatisfy { $0["key"] == nil },
              "a devices file from before moves its keys to the Keychain, keeps the device, and is written again without them")
        var still = false
        if let port = await listening(moved) { still = await connects(old, oldKey, port: port) }
        check(still, "and that iPhone still connects, with no pairing again")

        // Put into the file afterwards: a device with a key of its own, and one whose key this Mac's Keychain doesn't have.
        let planted = UUID(), plantedKey = SymmetricKey(size: .bits256), copied = UUID()
        var written = entries()
        written.append(["id": planted.uuidString, "name": "Not an iPhone", "key": plantedKey.withUnsafeBytes { Data($0) }.base64EncodedString(), "pairedAt": 0])
        written.append(["id": copied.uuidString, "name": "Copied iPhone", "pairedAt": 0])
        try? JSONSerialization.data(withJSONObject: written).write(to: url)
        let later = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: url)
        let kept = entries()
        check(later.devices.map(\.name) == ["Old iPhone"] && LinkServer.storedKey(for: planted) == nil && kept.count == 3 && kept.allSatisfy { $0["key"] == nil },
              "a key put into the file after they moved isn't taken, and leaves the file; the others stay listed: \(later.devices.map(\.name))")
        if let port = await listening(later) {
            let intruded = await connects(planted, plantedKey, port: port)
            let oldOne = await connects(old, oldKey, port: port)
            check(!intruded && oldOne, "so a device put in the file can't connect, while the iPhone paired before can")
        } else {
            check(false, "the link starts again")
        }
        // The Keychain's "moved" mark can't be read at launch (locked, or access denied): a key the Keychain holds for a
        // device in the file says the move happened, so a key put into the file still isn't taken.
        Keychain.write("", for: later.movedName)
        let plantedAgain = UUID(), plantedAgainKey = SymmetricKey(size: .bits256)
        written = entries()
        written.append(["id": plantedAgain.uuidString, "name": "Not an iPhone either",
                        "key": plantedAgainKey.withUnsafeBytes { Data($0) }.base64EncodedString(), "pairedAt": 0])
        try? JSONSerialization.data(withJSONObject: written).write(to: url)
        let unmarked = LinkServer(controller: controller, port: 0, pairingPort: 0, devicesURL: url)
        check(unmarked.devices.map(\.name) == ["Old iPhone"] && LinkServer.storedKey(for: plantedAgain) == nil && entries().allSatisfy { $0["key"] == nil },
              "with the mark unreadable, a key the Keychain holds for a paired device still keeps a key put into the file out: \(unmarked.devices.map(\.name))")
        if let port = await listening(unmarked) {
            let intruded = await connects(plantedAgain, plantedAgainKey, port: port)
            check(!intruded, "and that device can't connect")
        } else {
            check(false, "the link starts again")
        }
        later.revoke(old)
        check(LinkServer.storedKey(for: old) == nil && entries().count == 2, "removing a device deletes its key from the Keychain")
        check(later.devicesToPairAgain.map(\.name) == ["Not an iPhone", "Copied iPhone"],
              "the ones without a key are listed to pair again or remove: \(later.devicesToPairAgain.map(\.name))")
        later.revoke(copied)
        check(entries().count == 1 && later.devicesToPairAgain.map(\.name) == ["Not an iPhone"], "and Remove takes one off the file")
        unmarked.stop()
        later.stop()
        moved.stop()
    }

    /// Ticks checklist items in a meeting's notes, a note's digest and a note the way MCP's set_todo_status does, in a
    /// throwaway folder (BINDERS_DATA_DIR) only.
    @MainActor
    private static func boardTasksSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes and meetings")
            return 1
        }
        let controller = DictationController()
        let store = Store.shared
        let meeting = MeetingRecord(title: "Launch review", appName: "Zoom", templateID: AppSettings.shared.meetingTemplateID)
        meeting.summary = "## Action items\n- [ ] Maya — send the deck\n- [ ] Noah — book the room"
        meeting.status = "ready"
        store.insert(meeting)
        let note = NoteItem(text: "Plan\n\n- [ ] call Sam\n- [x] order stickers")
        note.digest = "# Plan\n\n## To-dos\n- [ ] Call Sam about the launch"
        store.insert(note)

        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        func set(_ reference: BoardTaskReference, _ status: String) async -> InboxResult {
            await InboxCommands.perform(InboxRequest(action: "set_todo_status", fields: ["id": reference.string, "status": status]), controller: controller)
        }
        let deck = BoardTaskReference(place: .meeting, id: meeting.id, text: "send the deck")
        let ticked = await set(deck, "done")
        check(ticked.ok && meeting.summary.contains("- [x] Maya — send the deck") && meeting.summary.contains("- [ ] Noah — book the room"),
              "meeting action item ticked, the other left alone")
        check(await set(deck, "open").ok && meeting.summary.contains("- [ ] Maya — send the deck"), "and reopened")
        let digest = await set(BoardTaskReference(place: .digest, id: note.id, text: "Call Sam about the launch"), "done")
        check(digest.ok && note.digest.contains("- [x] Call Sam about the launch") && note.text.contains("- [ ] call Sam"), "digest to-do ticked, note untouched")
        let before = note.updatedAt
        let body = await set(BoardTaskReference(place: .note, id: note.id, text: "call Sam"), "done")
        check(body.ok && note.text.contains("- [x] call Sam") && note.updatedAt > before, "note checkbox ticked and the note marked as edited")
        check(!(await set(BoardTaskReference(place: .note, id: note.id, text: "order stickers"), "dismissed")).ok, "checklist items can't be dismissed")
        check(!(await set(BoardTaskReference(place: .note, id: note.id, text: "something never written"), "done")).ok, "a changed or missing item is refused")
        check(!(await set(BoardTaskReference(place: .meeting, id: UUID(), text: "send the deck"), "done")).ok, "an unknown meeting is refused")
        print(failures == 0 ? "BOARD_TASKS_OK" : "BOARD_TASKS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Links between notes, meetings, binders and people, on the fictional demo data, in windows that never show.
    @MainActor
    private static func linksSelfTest(directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this seeds fictional data there")
            return 1
        }
        let controller = DictationController()
        guard await DemoData.seed(knowledge: controller.knowledge) else { return 1 }
        await controller.knowledge.indexNow()
        await LinkTargets.refreshEntities(controller.knowledge)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        guard let harbor = Store.shared.binders().first(where: { $0.name == DemoData.binderName }) else { return 1 }

        // What a title means.
        if case .meeting = LinkTargets.resolve("launch readiness REVIEW") { check(true, "a link finds a meeting by its title, whatever the case") }
        else { check(false, "a link finds a meeting by its title, whatever the case") }
        if case .binder = LinkTargets.resolve("Harbor launch") { check(true, "and a binder by its name") } else { check(false, "and a binder by its name") }
        if case .entity = LinkTargets.resolve("Tomás Ferreira") { check(true, "and a person from the knowledge graph") } else { check(false, "and a person from the knowledge graph") }
        check(LinkTargets.resolve("An idea nobody wrote down") == nil && !LinkTargets.exists("An idea nobody wrote down") && LinkTargets.exists("Harbor launch"),
              "a link to nothing yet is known as one")
        check(LinkTargets.suggestions(for: "launch r").first == "Launch readiness review", "typing after [[ suggests the best match first")

        // Mentions, linked and not.
        let note = NoteItem(text: "# Launch follow-ups\n\nFrom the launch readiness review: see [[Pricing page walkthrough]] for the table.")
        note.binderID = harbor.id
        Store.shared.insert(note)
        let notes = (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>())) ?? []
        let meetings = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        let toWalkthrough = MentionsPanel.mentions(of: "Pricing page walkthrough", excluding: nil, notes: notes, meetings: meetings)
        check(toWalkthrough.contains { $0.id == note.id && $0.linked }, "a note that links to a meeting is listed on it")
        let toReview = MentionsPanel.mentions(of: "Launch readiness review", excluding: nil, notes: notes, meetings: meetings)
        check(toReview.contains { $0.id == note.id && !$0.linked }, "a note that only names it is listed as not linked yet")
        if let linked = WikiLinks.linkingFirstMention(of: "Launch readiness review", in: note.text) { note.text = linked }
        check(MentionsPanel.mentions(of: "Launch readiness review", excluding: nil, notes: notes, meetings: meetings).contains { $0.id == note.id && $0.linked },
              "Link makes it a link")

        // A link to nothing yet makes the note.
        let navigation = HubNavigation()
        LinkTargets.open("An idea nobody wrote down", from: harbor.id, in: navigation)
        let made = ((try? Store.shared.context.fetch(FetchDescriptor<NoteItem>())) ?? []).first { $0.title == "An idea nobody wrote down" }
        check(made != nil && made?.binderID == harbor.id && navigation.pendingNoteID == made?.id && navigation.selection == .binder,
              "clicking a link to nothing makes a note of that name and opens it")

        // A heading or block in a note: the note, opened there. Never a note named "…#Heading".
        func allNotes() -> [NoteItem] { (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>())) ?? [] }
        let plan = NoteItem(text: "# Rollout plan\n\nIntro.\n\n" + String(repeating: "A line to scroll past.\n", count: 60)
                            + "\n## Risks: what could slip\n\nVendor is late. ^vendor\n")
        plan.binderID = harbor.id
        Store.shared.insert(plan)
        if case .note(let found) = LinkTargets.resolve("rollout PLAN#Risks what could slip"), found.id == plan.id { check(true, "a link to a heading finds its note") }
        else { check(false, "a link to a heading finds its note") }
        check(LinkTargets.exists("Rollout plan#Anything") && LinkTargets.exists("#Anything"), "and isn't shown as a link to nothing")
        let toHeading = HubNavigation()
        LinkTargets.open("Rollout plan#Risks what could slip", from: harbor.id, in: toHeading)
        check(toHeading.pendingNoteID == plan.id && toHeading.pendingNotePlace == "Risks what could slip", "opening it opens the note at the heading")
        let toBlock = HubNavigation()
        LinkTargets.open("Rollout plan#^vendor", from: harbor.id, in: toBlock)
        check(toBlock.pendingNoteID == plan.id && toBlock.pendingNotePlace == "^vendor", "and a block at the block")
        let toTitle = HubNavigation()
        LinkTargets.open("Rollout plan", from: harbor.id, in: toTitle)
        check(toTitle.pendingNoteID == plan.id && toTitle.pendingNotePlace == nil, "a plain link opens the note at the top")
        LinkTargets.open("A plan nobody wrote#Budget", from: harbor.id, in: HubNavigation())
        check(allNotes().contains { $0.title == "A plan nobody wrote" } && !allNotes().contains { $0.title.contains("#Budget") },
              "a link to a heading in a note that doesn't exist makes the note, named without the heading")
        let counted = allNotes().count
        LinkTargets.open("#Risks", from: harbor.id, in: HubNavigation())
        check(allNotes().count == counted, "a link to a heading in the same note makes nothing")

        // Files: opened, never made into notes.
        let missingFile = HubNavigation()
        LinkTargets.open("minutes.pdf", from: harbor.id, in: missingFile)
        check(allNotes().count == counted && missingFile.pendingNoteID == nil, "a link to a missing file makes no note")
        check(!LinkTargets.exists("minutes.pdf"), "and shows as missing")
        try? FileManager.default.createDirectory(at: Attachments.folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Attachments.folder.appendingPathComponent("agenda.pdf").path, contents: Data("%PDF-1.4".utf8))
        check(LinkTargets.exists("agenda.pdf") && LinkTargets.exists("folder/agenda.pdf"), "a link to a file in the attachments is found, wherever Obsidian kept it")

        // The editor: a click on a link opens it; [[ completes to a title and closes the link.
        var opened: [String] = []
        let links = NoteLinks(suggestions: { LinkTargets.suggestions(for: $0) }, exists: { LinkTargets.exists($0) }, open: { opened.append($0) })
        var text = note.text
        let hosting = NSHostingView(rootView: MarkdownNoteEditor(text: Binding(get: { text }, set: { text = $0 }), links: links).frame(width: 700, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(600))
        func textViews(in view: NSView) -> [MarkdownTextView] { (view as? MarkdownTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
        if let textView = textViews(in: hosting).first, let layout = textView.layoutManager, let container = textView.textContainer {
            let label = (textView.string as NSString).range(of: "Pricing page walkthrough")
            var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: label, actualCharacterRange: nil), in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let point = textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            if let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                textView.mouseDown(with: click)
            }
            check(opened == ["Pricing page walkthrough"], "clicking a link in the editor opens it: \(opened)")
            capture(hosting, name: "links-editor", directory: directory)

            textView.string = "Notes from [[Laun"
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            var index = -1
            let partial = textView.rangeForUserCompletion
            let offered = textView.completions(forPartialWordRange: partial, indexOfSelectedItem: &index) ?? []
            check(offered.contains("Launch readiness review") && offered.allSatisfy { $0.localizedCaseInsensitiveContains("laun") },
                  "after [[, the editor offers the titles that match: \(offered.prefix(3))")
            textView.insertCompletion("Launch readiness review", forPartialWordRange: partial, movement: NSReturnTextMovement, isFinal: true)
            check(textView.string == "Notes from [[Launch readiness review]]", "choosing one finishes the link: \(textView.string)")

            // A link to a heading in the same note goes to it.
            textView.string = "# Plan\n\nSee [[#Risks]] below.\n\n" + String(repeating: "Filler.\n", count: 40) + "## Risks\n\nVendor is late."
            textView.restyle()
            window.makeFirstResponder(nil)
            let link = (textView.string as NSString).range(of: "#Risks]]")
            var spot = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: link.location + 1, length: 4), actualCharacterRange: nil), in: container)
            spot.origin.x += textView.textContainerOrigin.x
            spot.origin.y += textView.textContainerOrigin.y
            let linkPoint = textView.convert(NSPoint(x: spot.midX, y: spot.midY), to: nil)
            if let click = NSEvent.mouseEvent(with: .leftMouseDown, location: linkPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                textView.mouseDown(with: click)
            }
            check(textView.selectedRange().location == (textView.string as NSString).range(of: "## Risks").location && opened == ["Pricing page walkthrough"],
                  "clicking a link to a heading in the same note goes there: \(textView.selectedRange().location)")
        } else {
            check(false, "the editor renders")
        }
        window.close()

        // "Mentioned in" on the meeting, as the window shows it.
        let hub = HubNavigation()
        hub.binderID = harbor.id
        hub.selection = .binder
        hub.pendingBinderTab = .meetings
        hub.pendingMeetingID = meetings.first { $0.title == DemoData.meetingTitle }?.id
        await render(HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(hub).environment(AppSettings.shared)
            .modelContainer(Store.shared.container), size: NSSize(width: 1300, height: 900), name: "links-meeting", directory: directory)
        // And on a note: the launch review's action items name the launch checklist.
        hub.pendingBinderTab = .notes
        hub.pendingNoteID = notes.first { $0.title == "Launch checklist" }?.id
        await render(HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(hub).environment(AppSettings.shared)
            .modelContainer(Store.shared.container), size: NSSize(width: 1300, height: 900), name: "links-note", directory: directory)
        // A note opened from a link to its heading has the cursor there.
        let opening = HubNavigation()
        opening.binderID = harbor.id
        opening.selection = .binder
        opening.pendingBinderTab = .notes
        opening.pendingNoteID = plan.id
        opening.pendingNotePlace = "Risks what could slip"
        let hubHosting = NSHostingView(rootView: HubView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(opening).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        let hubWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        hubWindow.isReleasedWhenClosed = false
        hubWindow.alphaValue = 0
        hubWindow.contentView = hubHosting
        hubWindow.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500))
        let planEditor = textViews(in: hubHosting).first { $0.string.hasPrefix("# Rollout plan") }
        let heading = (plan.text as NSString).range(of: "## Risks").location
        check(planEditor?.selectedRange().location == heading && (planEditor?.enclosingScrollView?.contentView.bounds.minY ?? 0) > 100,
              "a note opened from a link to its heading has the cursor at the heading, scrolled to it: \(planEditor?.selectedRange().location ?? -1)")
        capture(hubHosting, name: "links-heading", directory: directory)
        hubWindow.close()

        // A new title: the links to the old one follow it, once the cursor leaves the first line.
        let faq = NoteItem(text: "# Pricing FAQ\n\nSee [[Pricing FAQ#Refunds]] below.\n\n## Refunds\n\nWithin 30 days.")
        let sales = NoteItem(text: "# Sales notes\n\nAsk about [[Pricing FAQ]], [[pricing faq|the FAQ]] and [[Pricing FAQ#Refunds]]. Not `[[Pricing FAQ]]`.")
        for item in [faq, sales] {
            item.binderID = harbor.id
            Store.shared.insert(item)
        }
        let review = meetings.first { $0.title == DemoData.meetingTitle }
        review?.userNotes += "\n\nFollow up on [[Pricing FAQ]]."
        let card = TaskCard(title: "Answer refund questions", binderID: harbor.id)
        card.details = "Use [[Pricing FAQ#Refunds]]."
        Store.shared.insert(card)
        var renames: [LinkRename] = []
        let faqHosting = NSHostingView(rootView: MarkdownNoteEditor(text: Binding(get: { faq.text }, set: { faq.text = $0 }),
                                                                    links: LinkTargets.forNote(faq) { renames.append($0) })
            .frame(width: 700, height: 300))
        let faqWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        faqWindow.isReleasedWhenClosed = false
        faqWindow.alphaValue = 0
        faqWindow.contentView = faqHosting
        faqWindow.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(600))
        if let editor = textViews(in: faqHosting).first {
            faqWindow.makeFirstResponder(editor)
            func type(_ words: String, atEndOfLine line: String) {
                let range = (editor.string as NSString).range(of: line)
                editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
                editor.insertText(words, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            // Undo steps end with each event, as when a person types and clicks; this test sends none of its own.
            func leaveTitle() async {
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
                try? await Task.sleep(for: .milliseconds(100))
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                try? await Task.sleep(for: .milliseconds(300))
            }
            type(" for buyers", atEndOfLine: "# Pricing FAQ")
            try? await Task.sleep(for: .milliseconds(500))
            check(sales.text.contains("[[Pricing FAQ]],"), "typing a new title changes no links while the cursor is still on it")
            await leaveTitle()
            check(sales.text == "# Sales notes\n\nAsk about [[Pricing FAQ for buyers]], [[Pricing FAQ for buyers|the FAQ]] and [[Pricing FAQ for buyers#Refunds]]. Not `[[Pricing FAQ]]`.",
                  "leaving the title points the links at it, keeping what they show and their headings: \(sales.text)")
            check(review?.userNotes.contains("[[Pricing FAQ for buyers]]") == true && card.details == "Use [[Pricing FAQ for buyers#Refunds]].",
                  "in meeting notes and on cards too")
            check(editor.string.contains("See [[Pricing FAQ for buyers#Refunds]] below."), "and in the note itself")
            check(renames.count == 1 && renames.first?.summary == "Updated 5 links in 1 note, 1 meeting and 1 card", "it says what it changed: \(renames.map(\.summary))")
            if case .note(let found) = LinkTargets.resolve("Pricing FAQ for buyers#Refunds"), found.id == faq.id { check(true, "the links still reach the note") }
            else { check(false, "the links still reach the note") }

            editor.ownUndoManager.undo()
            check(sales.text.contains("Ask about [[Pricing FAQ]], [[pricing faq|the FAQ]]") && card.details == "Use [[Pricing FAQ#Refunds]]."
                  && editor.string.contains("See [[Pricing FAQ#Refunds]]") && MarkdownSyntax.noteTitle(editor.string) == "Pricing FAQ for buyers",
                  "one undo puts every link back, and leaves the title: \(editor.string.prefix(30))")
            editor.ownUndoManager.redo()
            check(sales.text.contains("[[Pricing FAQ for buyers|the FAQ]]") && editor.string.contains("See [[Pricing FAQ for buyers#Refunds]]"), "redo points them at it again")

            // A title cleared on the way to a new one: the links go from the last title to the next.
            let titleLine = (editor.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
            editor.setSelectedRange(NSRange(location: 2, length: titleLine.length - 3))
            editor.deleteBackward(nil)
            await leaveTitle()
            check(sales.text.contains("[[Pricing FAQ for buyers]],"), "an empty title changes nothing")
            type("Refund FAQ", atEndOfLine: "# ")
            await leaveTitle()
            check(sales.text.contains("Ask about [[Refund FAQ]], [[Refund FAQ|the FAQ]]"), "the next title does: \(sales.text)")

            // Closing the window with a new title still on the first line.
            type(" v2", atEndOfLine: "# Refund FAQ")
            faqWindow.close()
            check(sales.text.contains("Ask about [[Refund FAQ v2]]") && faq.text.contains("See [[Refund FAQ v2#Refunds]]"), "closing the note with a new title points the links at it")
        } else {
            check(false, "the note's editor renders")
        }
        faqWindow.close()

        // Nothing changes while something else goes by the old name, or for a title that can't go in a link.
        let reviewLink = NoteItem(text: "# Prep\n\nRead [[\(DemoData.meetingTitle)]] first.")
        reviewLink.binderID = harbor.id
        Store.shared.insert(reviewLink)
        check(LinkTargets.renameLinks(from: DemoData.meetingTitle, to: "Launch review v2") == nil && reviewLink.text.contains("[[\(DemoData.meetingTitle)]]"),
              "links stay while something else still has the old name")
        check(LinkTargets.renameLinks(from: "Refund FAQ v2", to: "Refunds [draft]") == nil, "a title with brackets changes no links")

        // Through MCP, and for binders and meetings.
        let result = await InboxCommands.perform(InboxRequest(action: "update_note", fields: ["id": faq.id.uuidString, "find": "# Refund FAQ v2", "replace": "# Refund policy"]),
                                                 controller: controller)
        check(result.ok && sales.text.contains("Ask about [[Refund policy]]") && faq.text.contains("See [[Refund policy#Refunds]]")
              && result.message.contains("Links that follow the new title: 6 links in 2 notes, 1 meeting and 1 card"), "an agent's new title moves the links too: \(result.message)")
        let side = BinderRecord(name: "Side project")
        Store.shared.insert(side)
        let sideNote = NoteItem(text: "# Ideas\n\nFor [[Side project]].")
        sideNote.binderID = side.id
        Store.shared.insert(sideNote)
        side.name = "Side quest"
        LinkTargets.renameLinks(from: "Side project", to: side.name)
        check(sideNote.text.contains("[[Side quest]]"), "renaming a binder moves the links to it")
        if let review {
            review.title = "Launch readiness review, final"
            LinkTargets.renameLinks(from: DemoData.meetingTitle, to: review.title)
            check(reviewLink.text.contains("[[Launch readiness review, final]]"), "and renaming a meeting")
        }

        print(failures == 0 ? "LINKS_OK" : "LINKS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Opens the quick switcher and types into it, on the fictional demo data, checking where Return goes.
    @MainActor
    private static func switcherSelfTest(directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this seeds fictional data there")
            return 1
        }
        let controller = DictationController()
        guard await DemoData.seed(knowledge: controller.knowledge) else { return 1 }
        await controller.knowledge.indexNow()
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let navigation = HubNavigation()
        let hosting = NSHostingView(rootView: HubView()
            .environment(controller)
            .environment(controller.meetings)
            .environment(controller.knowledge)
            .environment(controller.team)
            .environment(controller.capture)
            .environment(controller.commitments)
            .environment(navigation)
            .environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 780), styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        window.makeKey()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func key(_ characters: String, code: UInt16 = 0) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            window.sendEvent(event)
        }
        func type(_ text: String) async {
            for character in text { key(String(character)) }
            try? await Task.sleep(for: .milliseconds(400))
        }
        func open(_ mode: SwitcherMode) async {
            navigation.switcher = mode
            try? await Task.sleep(for: .milliseconds(700))
        }
        let returnKey = ("\r", UInt16(36)), downKey = (String(UnicodeScalar(0xF701)!), UInt16(125)), escapeKey = ("\u{1b}", UInt16(53))
        try? await Task.sleep(for: .milliseconds(800))

        let harbor = Store.shared.binders().first { $0.name == DemoData.binderName }
        await open(.open)
        capture(hosting, name: "switcher-recent", directory: directory)
        await type("launch rev")
        capture(hosting, name: "switcher-launch", directory: directory)
        key(returnKey.0, code: returnKey.1)
        try? await Task.sleep(for: .milliseconds(600))
        check(navigation.switcher == nil && navigation.selection == .binder && navigation.binderID == harbor?.id,
              "typing “launch rev” and Return opens the launch review in Harbor launch")

        await open(.commands)
        await type("sett ai")
        capture(hosting, name: "switcher-commands", directory: directory)
        key(returnKey.0, code: returnKey.1)
        try? await Task.sleep(for: .milliseconds(600))
        check(navigation.switcher == nil && navigation.selection == .settings, "⌘P, “sett ai” and Return opens Settings")

        await open(.open)
        await type("pricing")
        key(downKey.0, code: downKey.1)
        try? await Task.sleep(for: .milliseconds(300))
        capture(hosting, name: "switcher-down", directory: directory)
        key(escapeKey.0, code: escapeKey.1)
        try? await Task.sleep(for: .milliseconds(300))
        check(navigation.switcher == nil, "Esc closes it")

        // People open their page in Knowledge.
        await open(.open)
        await type("jonas")
        key(returnKey.0, code: returnKey.1)
        try? await Task.sleep(for: .milliseconds(600))
        check(navigation.selection == .knowledge, "a person opens in Knowledge")
        window.close()
        print(failures == 0 ? "SWITCHER_OK" : "SWITCHER_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Renders every Hub page and the Flow bar states to PNGs, for visual checks without screen recording access.
    @MainActor
    private static func renderDemoShots(to directory: URL, controller: DictationController) async {
        let size = NSSize(width: 1120, height: 760)
        let binders = Store.shared.binders()
        let harbor = binders.first { $0.name == DemoData.binderName } ?? Store.shared.defaultBinder()
        let meetings = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        let review = meetings.first { $0.title == DemoData.meetingTitle }

        func hub(_ configure: (HubNavigation) -> Void) -> some View {
            let navigation = HubNavigation()
            navigation.binderID = harbor.id
            configure(navigation)
            return HubView()
                .environment(controller)
                .environment(controller.meetings)
                .environment(controller.knowledge)
                .environment(controller.team)
                .environment(controller.capture)
                .environment(controller.commitments)
                .environment(navigation)
                .environment(AppSettings.shared)
                .modelContainer(Store.shared.container)
                .defaultAppStorage(throwawayDefaults)
        }
        await render(hub { $0.selection = .home }, size: size, name: "demo-home", directory: directory)
        await render(hub { $0.selection = .binder }, size: size, name: "demo-binder", directory: directory)
        await render(hub { $0.selection = .binder; $0.pendingBinderTab = .meetings; $0.pendingMeetingID = review?.id },
                     size: size, name: "demo-meeting", directory: directory)
        let notes = (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>())) ?? []
        let digested = notes.first { $0.binderID == harbor.id && !$0.digest.isEmpty }
        await render(hub { $0.selection = .binder; $0.pendingBinderTab = .notes; $0.pendingNoteID = digested?.id },
                     size: size, name: "demo-note", directory: directory)
        // Wide enough for all six columns, and short, as the site shows the board as a strip.
        await render(hub { $0.selection = .binder; $0.pendingBinderTab = .board }, size: NSSize(width: 2080, height: 600), name: "demo-board", directory: directory)
        if let blocked = controller.board.cards(in: harbor.id).first(where: { $0.column == .blocked }) {
            await render(CardDetailView(card: blocked).environment(controller).environment(HubNavigation()).modelContainer(Store.shared.container),
                         size: NSSize(width: CardLayout.defaultWidth, height: CardLayout.defaultHeight), name: "demo-card", directory: directory)
        }
        // Adding to-dos to the board: the launch's open to-dos without a card, two of them ticked.
        let carded = Set(controller.board.cards(in: harbor.id).compactMap(\.sourceRef))
        let waiting = TaskCollector.collect(meetings: meetings.filter { $0.binderID == harbor.id }, notes: notes.filter { $0.binderID == harbor.id },
                                            commitments: Store.shared.commitments().filter { $0.binderID == harbor.id },
                                            openMeeting: { _ in }, openNote: { _ in })
            .filter { !$0.done && !carded.contains($0.ref) }
        await render(TodoPickerSheet(binder: harbor, todos: waiting, chosen: Set(waiting.prefix(2).map(\.ref)))
                        .environment(controller).modelContainer(Store.shared.container),
                     size: NSSize(width: 560, height: 640), name: "demo-add-todos", directory: directory)
        await render(hub { $0.selection = .writing }, size: size, name: "demo-writing", directory: directory)
        await render(hub { $0.selection = .knowledge }, size: size, name: "demo-knowledge", directory: directory)
        for page in [SettingsPage.general, .shortcuts, .dictation, .ai, .writing, .automations, .mcp, .phone] {
            // The iPhone page with the link on and a pairing code showing, when run with `-phoneLink YES`.
            if page == .phone, AppSettings.shared.phoneLink {
                controller.link.start()
                for _ in 0..<30 where controller.link.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
                await controller.link.beginPairing()
            }
            await render(hub { $0.selection = .settings; $0.pendingSettingsPage = page }, size: size, name: "demo-settings-\(page.rawValue)", directory: directory)
            if page == .phone { controller.link.stop() }
        }

        for (suffix, section) in [("home", HubSection.home), ("binder", .binder), ("writing", .writing), ("knowledge", .knowledge)] {
            let navigation = HubNavigation()
            navigation.binderID = harbor.id
            navigation.selection = section
            await render(HubSidebar()
                .environment(controller)
                .environment(navigation)
                .environment(AppSettings.shared)
                .modelContainer(Store.shared.container)
                .frame(width: 230),
                size: NSSize(width: 230, height: 760), name: "demo-sidebar-\(suffix)", directory: directory)
        }

        await render(KnowledgeGraphView(selectedEntityID: .constant(nil)).environment(controller.knowledge).padding(16),
                     size: NSSize(width: 1000, height: 640), name: "demo-graph", directory: directory)

        let model = FlowBarModel()
        let actions = FlowBarActions(stop: {}, cancel: {}, openMeeting: {}, stopMeeting: {}, acceptPrompt: {}, dismissPrompt: {})
        let states: [(String, NSSize, (FlowBarModel) -> Void)] = [
            ("demo-flow-recording", FlowBarController.size, {
                $0.display = .recording
                $0.preview = "I'll send you the final launch checklist by Friday"
                $0.levels = (0..<30).map { Float(0.012 + 0.085 * abs(sin(Double($0) * 0.55)) * abs(cos(Double($0) * 0.21))) }
            }),
            ("demo-flow-processing", FlowBarController.size, { $0.display = .processing; $0.mode = .dictation; $0.handsFree = false }),
            ("demo-flow-promise", FlowBarController.size, { $0.display = .toast; $0.toastText = "Promise noted: Send Jonas the final launch checklist · Friday"; $0.toastSymbol = "hand.raised" }),
            ("demo-flow-meeting", NSSize(width: 300, height: 50), { $0.display = .meeting; $0.meetingStartedAt = Date().addingTimeInterval(-1_634) }),
        ]
        for (name, size, configure) in states {
            configure(model)
            await render(FlowBarView(model: model, actions: actions).background(Color.clear), size: size, name: name, directory: directory)
        }
    }

    @MainActor
    private static func renderSnapshots(to directory: URL) async {
        let controller = DictationController()
        let navigation = HubNavigation()
        navigation.binderID = Store.shared.defaultBinder().id
        for section in HubSection.allCases {
            navigation.selection = section
            await render(HubView()
                .environment(controller)
                .environment(controller.meetings)
                .environment(controller.knowledge)
                .environment(controller.team)
                .environment(controller.capture)
            .environment(controller.commitments)
                .environment(navigation)
                .environment(AppSettings.shared)
                .modelContainer(Store.shared.container),
                size: NSSize(width: 1020, height: 720), name: "hub-\(section.rawValue)", directory: directory)
        }

        await render(HubSidebar()
            .environment(controller)
            .environment(navigation)
            .environment(AppSettings.shared)
            .modelContainer(Store.shared.container)
            .frame(width: 230),
            size: NSSize(width: 230, height: 640), name: "hub-sidebar", directory: directory)

        await render(KnowledgeGraphView(selectedEntityID: .constant(nil)).environment(controller.knowledge).padding(16),
                     size: NSSize(width: 900, height: 600), name: "knowledge-graph-live", directory: directory)

        let model = FlowBarModel()
        let actions = FlowBarActions(stop: {}, cancel: {}, openMeeting: {}, stopMeeting: {}, acceptPrompt: {}, dismissPrompt: {})
        let states: [(String, NSSize, (FlowBarModel) -> Void)] = [
            ("flow-recording", FlowBarController.size, {
                $0.display = .recording
                $0.preview = "I think we should meet at three tomorrow and bring the slides"
                $0.levels = (0..<30).map { Float(0.01 + 0.08 * abs(sin(Double($0) * 0.6))) }
            }),
            ("flow-handsfree-command", FlowBarController.size, { $0.display = .recording; $0.mode = .command; $0.handsFree = true; $0.preview = "" }),
            ("flow-processing", FlowBarController.size, { $0.display = .processing; $0.mode = .dictation; $0.handsFree = false }),
            ("flow-toast", FlowBarController.size, { $0.display = .toast; $0.toastText = "Added “Binders” to your dictionary"; $0.toastSymbol = "book.closed" }),
            ("flow-meeting", NSSize(width: 300, height: 50), { $0.display = .meeting; $0.meetingStartedAt = Date().addingTimeInterval(-754) }),
            ("flow-prompt", NSSize(width: 540, height: 56), { $0.display = .prompt; $0.promptText = "Zoom is using your mic" }),
        ]
        for (name, size, configure) in states {
            configure(model)
            await render(FlowBarView(model: model, actions: actions).background(Color(white: 0.55)), size: size, name: name, directory: directory)
        }
    }

    @MainActor
    private static func render<Content: View>(_ view: Content, size: NSSize, name: String, directory: URL,
                                              prepare: ((NSView) -> Void)? = nil) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        if let prepare {
            try? await Task.sleep(for: .milliseconds(300))
            prepare(hosting)
        }
        try? await Task.sleep(for: .milliseconds(1200))
        capture(hosting, name: name, directory: directory)
        captureScrollContents(hosting, name: name, directory: directory)
        window.close()
    }

    @MainActor
    static func capture(_ view: NSView, name: String, directory: URL) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let layer = view.layer,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("\(name).png"))
        print("SNAPSHOT: \(name).png")
        fflush(stdout)
    }

    /// Layer rendering skips scroll view tiles, so render each scroll view's document separately.
    @MainActor
    static func captureScrollContents(_ root: NSView, name: String, directory: URL) {
        var scrollViews: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { scrollViews.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        for (index, scroll) in scrollViews.enumerated() {
            guard let document = scroll.documentView, document.bounds.height > 20 else { continue }
            let area = NSRect(x: 0, y: 0, width: document.bounds.width, height: min(document.bounds.height, 2600))
            guard let rep = document.bitmapImageRepForCachingDisplay(in: area) else { continue }
            document.cacheDisplay(in: area, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name)-scroll\(index).png"))
            print("SNAPSHOT: \(name)-scroll\(index).png (\(Int(document.bounds.width))x\(Int(document.bounds.height)))")
        }
    }

    /// Preferences for what a test run's views remember, such as the Settings part last opened: the app's own store,
    /// which in a test run is a file in the throwaway folder (AppDefaults), so a run doesn't change them for the real app
    /// or for other runs.
    @MainActor
    static var throwawayDefaults: UserDefaults { AppDefaults.store }

    static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}

/// Collects the kinds in `binders/changed` notifications, which arrive on the link's queue.
private final class LinkEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Set<String>()
    private var received = 0

    func add(_ message: [String: Any]) {
        let kinds = ((message["params"] as? [String: Any])?["kinds"] as? [String]) ?? []
        lock.withLock {
            collected.formUnion(kinds)
            received += 1
        }
    }

    var kinds: Set<String> { lock.withLock { collected } }
    /// How many notifications arrived.
    var count: Int { lock.withLock { received } }
}

/// A note editor with its toolbar, driven by a model the test holds, for the outline check.
private struct MarkdownNoteEditorPreview: View {
    @Binding var text: String
    let model: MarkdownEditorModel

    var body: some View {
        VStack(spacing: 0) {
            MarkdownToolbar(model: model, showsMarkup: .constant(false), headings: MarkdownOutline.headings(in: text))
            MarkdownEditor(text: $text, model: model)
        }
    }
}
