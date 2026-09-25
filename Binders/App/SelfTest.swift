import AppKit
import ApplicationServices
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
                let vocabulary = Store.shared.vocabulary()
                var raw = ""
                for pass in 1...2 {
                    let start = Date()
                    raw = try await engine.transcribe(audio, language: settings.languageHint, vocabulary: vocabulary, boost: settings.vocabularyBoost)
                    print("ASR_MS_PASS\(pass): \(ms(since: start))")
                }
                print("RAW: \(raw)")
                await printFormatted(raw: raw, context: context)
                return 0
            } catch {
                print("ERROR: \(error.localizedDescription)")
                return 1
            }
        }

        if let raw = value("--selftest-text") {
            await printFormatted(raw: raw, context: context)
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

        if args.contains("--selftest-team") {
            return await teamSelfTest(keepFolder: args.contains("--keep"))
        }

        if args.contains("--selftest-wispr-import") {
            do {
                let summary = try WisprImporter.importAll()
                UserDefaults.standard.set(true, forKey: "importedFromWispr")
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
        meeting.summary = "## Decisions\n- Launch at $49"
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

        print("TEAM_FOLDER: \(folder.path)")
        for path in files().keys.sorted() { print("  \(path)") }
        if let markdown = try? String(contentsOf: folder.appendingPathComponent("Notes/Launch checklist.md"), encoding: .utf8) {
            print("----- Notes/Launch checklist.md -----\n\(markdown)")
        }
        print(failures == 0 ? "TEAM_SELFTEST: all passed" : "TEAM_SELFTEST: \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    @MainActor
    private static func printFormatted(raw: String, context: AppContext) async {
        let start = Date()
        let result = await TextFormatter.format(raw: raw, context: context)
        print("FORMAT_MS: \(ms(since: start))")
        print("USED_LLM: \(result.usedLLM)\(result.fallbackReason.map { " (fallback: \($0))" } ?? "")")
        print("PRESS_ENTER: \(result.pressEnter)")
        print("FINAL: \(result.text)")
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
        }
        await render(hub { $0.selection = .home }, size: size, name: "demo-home", directory: directory)
        await render(hub { $0.selection = .binder }, size: size, name: "demo-binder", directory: directory)
        await render(hub { $0.selection = .binder; $0.pendingBinderTab = .meetings; $0.pendingMeetingID = review?.id },
                     size: size, name: "demo-meeting", directory: directory)
        await render(hub { $0.selection = .writing }, size: size, name: "demo-writing", directory: directory)
        await render(hub { $0.selection = .knowledge }, size: size, name: "demo-knowledge", directory: directory)
        for page in [SettingsPage.general, .dictation, .ai, .writing, .automations, .mcp] {
            await render(hub { $0.selection = .settings; $0.pendingSettingsPage = page }, size: size, name: "demo-settings-\(page.rawValue)", directory: directory)
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
    private static func render<Content: View>(_ view: Content, size: NSSize, name: String, directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1200))
        capture(hosting, name: name, directory: directory)
        captureScrollContents(hosting, name: name, directory: directory)
        window.close()
    }

    @MainActor
    private static func capture(_ view: NSView, name: String, directory: URL) {
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
    private static func captureScrollContents(_ root: NSView, name: String, directory: URL) {
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

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
