import Foundation
import Network
import SwiftUI
import SwiftData
import BindersKit
import MLXGuidedGeneration
import MLXLMCommon

extension SelfTest {
    /// Distill's reply held to its JSON schema (lane DS3), in a throwaway folder (BINDERS_DATA_DIR) with stand-in model
    /// servers on the loopback address and stand-in tokenizers: no model is loaded. Ollama gets the schema as `format`, an
    /// OpenAI-compatible server as `response_format` (json_schema, strict), their properties in the prompt's order; a server
    /// that turns it down is asked again without it, once, and from then on; a too-long error still reads as one; the
    /// object's items are read and proposed, and `{"items": []}` is still "no work"; xgrammar compiles the schema and holds a
    /// reply to it, a token at a time, on a small vocabulary; MLX's guide compiles a schema once and reuses it after, and
    /// says why when it can't be set up.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill-schema -notesShowMarkdown NO
    @MainActor
    static func distillSchemaSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes and distills")
            return 1
        }
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let spec = DistillBench.specs.first { $0.name == "Checkout redesign" }!
        let headings = DistillSections.sections(of: spec.text).compactMap(\.heading)
        let reply = DistillBench.schemaReply
        func ask(parts: Int = 1) -> DistillRun.Ask {
            DistillRun.Ask(user: DistillPrompt.user(title: "Checkout redesign", sections: headings, text: spec.text), maxTokens: 5_000,
                           replyTokens: 3_000, part: 1, parts: parts, attempt: 1, headings: headings)
        }
        /// The schema's fields, in the body as it was sent, go in the prompt's order.
        func ordered(_ body: String) -> Bool {
            guard let start = body.range(of: #""format":"#) ?? body.range(of: #""schema":"#) else { return false }
            let schema = body[start.upperBound...]
            let positions = ["\"title\"", "\"brief\"", "\"done_when\"", "\"section\"", "\"waits_for\"", "\"size\"", "\"for\""]
                .compactMap { schema.range(of: $0)?.lowerBound }
            return positions.count == 7 && positions == positions.sorted()
        }
        func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }

        // MARK: Ollama: format
        guard let ollama = SchemaModelServer(reply: reply), let ollamaPort = await ollama.start() else {
            run.check(false, "a stand-in Ollama starts")
            return 1
        }
        let ollamaClient = OllamaClient(baseURL: URL(string: "http://127.0.0.1:\(ollamaPort)")!, model: "stand-in")
        do {
            let answer = try await DistillService.asked(LanedClient(inner: ollamaClient, lane: .now, interrupts: false), ask(), held: true)
            let sent = ollama.requests.last
            let format = object(sent?.body["format"])
            run.check(answer.held && answer.text == reply, "Ollama's reply is held to the schema, through the model's lane")
            run.check(format["type"] as? String == "object" && object(object(format["properties"])["items"])["maxItems"] as? Int == DistillPrompt.maxItems,
                      "Ollama is sent the schema as format, with its counts")
            let section = object(object(object(object(object(format["properties"])["items"])["items"])["properties"])["section"])
            run.check(section["enum"] as? [String] == headings + [""], "its sections are the note's headings and the opening: \(section["enum"] ?? "-")")
            run.check(ordered(sent?.raw ?? ""), "the fields go in the prompt's order, as the grammar writes them")
            run.check(sent?.body["think"] as? Bool == false && sent?.body["stream"] as? Bool == true, "thinking is still off, and the reply streams")
        } catch {
            run.check(false, "Ollama answers: \(error.localizedDescription)")
        }
        do {
            let plain = try await DistillService.asked(ollamaClient, ask(), held: false)
            run.check(!plain.held && ollama.requests.last?.body["format"] == nil, "with --constrained off, no format is sent")
        } catch {
            run.check(false, "Ollama answers without the schema: \(error.localizedDescription)")
        }
        ollama.stop()

        // An Ollama too old for a schema in format.
        guard let old = SchemaModelServer(reply: "[]", mode: .refusesSchema), let oldPort = await old.start() else {
            run.check(false, "a stand-in old Ollama starts")
            return 1
        }
        let oldClient = OllamaClient(baseURL: URL(string: "http://127.0.0.1:\(oldPort)")!, model: "stand-in")
        do {
            let first = try await DistillService.asked(oldClient, ask(), held: true)
            run.check(!first.held && first.text == "[]" && old.requests.count == 2 && old.requests[1].body["format"] == nil,
                      "an Ollama that turns format down is asked once more without it: \(old.requests.count) requests")
            run.check(first.why?.contains("turned the schema down") == true, "and the bench is told why: \(first.why ?? "-")")
            let second = try await DistillService.asked(oldClient, ask(), held: true)
            run.check(!second.held && old.requests.count == 3 && old.requests[2].body["format"] == nil, "and from then on is asked without it")
        } catch {
            run.check(false, "the old Ollama answers: \(error.localizedDescription)")
        }
        old.stop()

        // MARK: OpenAI-compatible: response_format
        guard let server = SchemaModelServer(reply: reply), let port = await server.start() else {
            run.check(false, "a stand-in OpenAI-compatible server starts")
            return 1
        }
        let openAI = OpenAICompatibleClient(baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!, model: "stand-in", apiKey: nil)
        do {
            let answer = try await DistillService.asked(openAI, ask(parts: 3), held: true)
            let sent = server.requests.last
            let format = object(sent?.body["response_format"])
            let named = object(format["json_schema"])
            let schema = object(named["schema"])
            run.check(answer.held && answer.text == reply, "the server's reply is held to the schema")
            run.check(format["type"] as? String == "json_schema" && named["name"] as? String == DistillSchema.name && named["strict"] as? Bool == true,
                      "it's sent response_format: json_schema, named \(DistillSchema.name), strict")
            run.check(schema["type"] as? String == "object" && !(sent?.raw.contains("maxItems") ?? true) && !(sent?.raw.contains("minimum") ?? true),
                      "in its portable form, without counts")
            run.check(ordered(sent?.raw ?? ""), "its fields in the prompt's order")
            run.check(sent?.raw.contains(#""anyOf""#) == true, "read in parts, a wait may name another part's item by its title")
            run.check(object(sent?.body["chat_template_kwargs"])["enable_thinking"] as? Bool == false, "thinking is still off")
        } catch {
            run.check(false, "the server answers: \(error.localizedDescription)")
        }
        server.stop()

        guard let refusing = SchemaModelServer(reply: reply, mode: .refusesSchema), let refusingPort = await refusing.start() else {
            run.check(false, "a stand-in server that turns response_format down starts")
            return 1
        }
        let refusingClient = OpenAICompatibleClient(baseURL: URL(string: "http://127.0.0.1:\(refusingPort)/v1")!, model: "stand-in", apiKey: nil)
        do {
            let first = try await DistillService.asked(refusingClient, ask(), held: true)
            run.check(!first.held && first.text == reply && refusing.requests.count == 2 && refusing.requests[1].body["response_format"] == nil,
                      "a server that turns response_format down with a 400 is asked once more without it: \(refusing.requests.count) requests")
            _ = try await DistillService.asked(refusingClient, ask(), held: true)
            run.check(refusing.requests.count == 3 && refusing.requests[2].body["response_format"] == nil, "and remembered: asked without it from then on")
        } catch {
            run.check(false, "the refusing server answers: \(error.localizedDescription)")
        }
        refusing.stop()

        guard let fussy = SchemaModelServer(reply: reply, mode: .refusesThinkingSwitch), let fussyPort = await fussy.start() else {
            run.check(false, "a stand-in server that turns the thinking switch down starts")
            return 1
        }
        do {
            let fussyClient = OpenAICompatibleClient(baseURL: URL(string: "http://127.0.0.1:\(fussyPort)/v1")!, model: "stand-in", apiKey: nil)
            let answer = try await DistillService.asked(fussyClient, ask(), held: true)
            run.check(answer.held && fussy.requests.count == 2 && fussy.requests[1].body["chat_template_kwargs"] == nil && fussy.requests[1].body["response_format"] != nil,
                      "a server that turns the thinking switch down keeps the schema")
        } catch {
            run.check(false, "the fussy server answers: \(error.localizedDescription)")
        }
        fussy.stop()

        guard let small = SchemaModelServer(reply: reply, mode: .tooLong), let smallPort = await small.start() else {
            run.check(false, "a stand-in server with a small context starts")
            return 1
        }
        do {
            let smallClient = OpenAICompatibleClient(baseURL: URL(string: "http://127.0.0.1:\(smallPort)/v1")!, model: "stand-in", apiKey: nil)
            _ = try await DistillService.asked(smallClient, ask(), held: true)
            run.check(false, "a prompt too long for the server is said to be")
        } catch let tooLong as DistillRun.TooLong {
            run.check(tooLong.contextTokens == 6_144 && small.requests.count == 1, "a too-long error is still read as one, not as the schema turned down")
        } catch {
            run.check(false, "a too-long error reads as one: \(error.localizedDescription)")
        }
        small.stop()

        // MARK: Distilling a note with a held reply
        let store = Store.shared
        let service = controller.distill
        service.start()
        service.settleDelay = .seconds(600)
        let folder = AppPaths.support
        let standIns = RouterStandIns()
        standIns.byChoice[.tev1] = RouterStandIn()
        controller.router.models = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("distill-schema-measures.json")),
                                                  fingerprints: FolderFingerprints(url: folder.appendingPathComponent("distill-schema-fingerprints.json")),
                                                  makeBackend: { standIns.make($0) })
        controller.router.budget = .seconds(1)
        let binder = BinderRecord(name: "Shop", colorIndex: 2)
        store.insert(binder)
        func note(_ text: String) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = binder.id
            store.insert(note)
            service.setDistill(true, for: note)
            return note
        }
        guard let shop = SchemaModelServer(reply: reply), let shopPort = await shop.start() else {
            run.check(false, "a stand-in Ollama for distilling starts")
            return 1
        }
        let shopClient = OllamaClient(baseURL: URL(string: "http://127.0.0.1:\(shopPort)")!, model: "stand-in")
        service.model = { shopClient }
        let checkout = note(spec.text)
        if case .success(let record) = await service.distill(checkout) {
            run.check(record.items.map(\.title) == ["Combine checkout into one page", "Ship behind a flag to 10% of visitors", "Decide on 100%"],
                      "the object's items are proposed: \(record.items.map(\.title))")
            run.check(record.items.map(\.section) == ["Payment form", "Rollout", "Rollout"], "in their sections")
            run.check(record.items[1].waitsFor == [record.items[0].id], "with their waits")
            let chats = shop.requests.filter { !($0.body["messages"] as? [Any] ?? []).isEmpty }
            run.check(chats.count == 1 && chats[0].body["format"] != nil, "asked once, held to the schema: \(chats.count)")
        } else {
            run.check(false, "a note is distilled from a held reply: \(service.problems[checkout.id] ?? "")")
        }
        shop.stop()

        guard let nothing = SchemaModelServer(reply: #"{"items": []}"#), let nothingPort = await nothing.start() else {
            run.check(false, "a stand-in Ollama that finds nothing starts")
            return 1
        }
        let nothingClient = OllamaClient(baseURL: URL(string: "http://127.0.0.1:\(nothingPort)")!, model: "stand-in")
        service.model = { nothingClient }
        let names = note(DistillBench.specs.first { $0.gold.isEmpty }!.text)
        var noWork = false
        if case .failure(.empty(let why)) = await service.distill(names) { noWork = why == "The model found no work in this note." }
        run.check(noWork && nothing.requests.filter { !($0.body["messages"] as? [Any] ?? []).isEmpty }.count == 1,
                  "{\"items\": []} is still “The model found no work in this note.”, asked once")
        nothing.stop()

        // MARK: xgrammar holds a reply to the schema
        let vocabulary = SchemaToyTokenizer.vocabulary
        let eos = Int32(vocabulary.count - 1)
        do {
            let grammarTokenizer = try GrammarTokenizer(vocab: vocabulary, vocabType: .raw, eosTokenId: eos)
            func holds(_ text: String, schema: String) -> Bool {
                guard let constraint = try? GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: schema) else { return false }
                for character in text.unicodeScalars {
                    guard let id = vocabulary.firstIndex(of: String(character)), (try? constraint.commitToken(Int32(id))) != nil else { return false }
                }
                return (try? constraint.commitToken(eos))?.isTerminated == true
            }
            let schema = DistillSchema.json(headings: headings)
            let compact = reply.replacingOccurrences(of: "\n", with: " ")
            run.check(holds(compact, schema: schema), "xgrammar compiles the schema and accepts a reply that fits it")
            run.check(!holds(compact.replacingOccurrences(of: "\"Rollout\"", with: "\"Launch\""), schema: schema), "a section that isn't a heading is refused")
            run.check(!holds(compact.replacingOccurrences(of: "\"medium\"", with: "\"huge\""), schema: schema), "a size that isn't small, medium or large is refused")
            run.check(!holds("Here are the items: " + compact, schema: schema), "prose before the JSON is refused")
            run.check(!holds(#"{"items": [{"title": "A"}]}"#, schema: schema), "an item missing its fields is refused")
            run.check(!holds(compact.replacingOccurrences(of: #""quote": "Ship behind a flag to 10% of visitors", "#, with: ""), schema: schema),
                      "an item without the note's words (quote, lane DS4) is refused")
            run.check(holds(#"{"items": []}"#, schema: schema), "an empty list is allowed")
            run.check(!holds(compact.replacingOccurrences(of: "\"waits_for\": [2]", with: "\"waits_for\": [26]"), schema: schema), "a wait past the 25th item is refused")
            let inParts = compact.replacingOccurrences(of: "\"waits_for\": [2]", with: "\"waits_for\": [2, \"Show a live order summary\"]")
            run.check(holds(inParts, schema: DistillSchema.json(headings: headings, waitsByTitle: true)), "read in parts, a wait by title is allowed")
            run.check(!holds(inParts, schema: schema), "read whole, it isn't")
            run.check(holds(compact, schema: DistillSchema.json(headings: headings, bounded: false)), "the portable form compiles too")
            let odd = ["Say \"hello\"", #"C:\temp"#, "Ünïcödé"]
            let oddReply = #"{"items": [{"title": "A", "brief": "", "done_when": "", "section": "C:\\temp", "quote": "", "waits_for": [], "size": "small", "for": "agent"}]}"#
            run.check(holds(oddReply, schema: DistillSchema.json(headings: odd)), "a heading with quotes and backslashes is matched as written")
            run.check(holds(#"{"items": [{"title": "A", "brief": "", "done_when": "", "section": "", "quote": "", "waits_for": [], "size": "small", "for": "person"}]}"#,
                            schema: DistillSchema.json(headings: [])), "a note with no headings: every item in the opening")
        } catch {
            run.check(false, "xgrammar reads a small vocabulary: \(error)")
        }

        // MARK: MLX's guide
        let toy = SchemaToyTokenizer()
        let directory = folder.appendingPathComponent("Models/toy", isDirectory: true)
        let guides = MLXGuides()
        /// Writes `text` a character at a time, as a model would, skipping what the matcher wrote itself (fast-forward).
        func writes(_ text: String, _ constraint: GrammarConstraint) -> Bool {
            let characters = text.unicodeScalars.map(String.init)
            var index = 0
            while index < characters.count {
                guard let id = vocabulary.firstIndex(of: characters[index]), let result = try? constraint.commitToken(Int32(id)) else { return false }
                index += 1
                for forced in result.tokens {
                    guard index < characters.count, vocabulary[Int(forced)] == characters[index] else { return false }
                    index += 1
                }
            }
            return (try? constraint.commitToken(eos))?.isTerminated == true
        }
        do {
            let schema = DistillSchema.json(headings: headings)
            let compact = reply.replacingOccurrences(of: "\n", with: " ")
            let first = try guides.prepare(directory: directory, tokenizer: toy, schema: schema)
            run.check(first.vocabSize == vocabulary.count && first.reserve > 0, "the guide reads the model's vocabulary: \(first.vocabSize) tokens, \(first.reserve) to close")
            run.check(writes(compact, first.constraint), "its matcher holds a reply to the schema")
            let busy = try guides.prepare(directory: directory, tokenizer: toy, schema: schema)
            run.check(guides.compiles == 2 && busy.constraint !== first.constraint, "a grammar in use isn't handed out twice")
            guides.keep(first.constraint, schema: schema, directory: directory)
            let again = try guides.prepare(directory: directory, tokenizer: toy, schema: schema)
            run.check(guides.compiles == 2 && again.constraint === first.constraint, "a schema asked for again reuses the grammar kept: \(guides.compiles) compiled")
            run.check(writes(compact, again.constraint), "wound back to its start, it holds the next reply too")
            _ = try guides.prepare(directory: directory, tokenizer: toy, schema: DistillSchema.json(headings: ["Another"]))
            run.check(guides.compiles == 3, "another note's schema is compiled for it")
            guides.keep(again.constraint, schema: schema, directory: directory.appendingPathComponent("other"))
            _ = try guides.prepare(directory: directory, tokenizer: toy, schema: schema)
            run.check(guides.compiles == 4, "a grammar is kept only for the model it was made for")
        } catch {
            run.check(false, "the guide is set up on a small vocabulary: \(MLXGuides.words(error))")
        }
        do {
            _ = try guides.prepare(directory: directory, tokenizer: toy, schema: #"{"type": 42}"#)
            run.check(false, "a schema xgrammar can't read is turned down")
        } catch {
            run.check(MLXGuides.words(error).hasPrefix("xgrammar"), "a schema it can't read says why, for the log: \(MLXGuides.words(error).prefix(80))")
        }
        guides.forget()

        // MARK: A real model's tokenizer
        // `--tokenizer <model folder>`: its tokenizer files only (tokenizer.json, its config and chat template), never its
        // weights, so a model's own vocabulary is checked without running it.
        if let index = CommandLine.arguments.firstIndex(of: "--tokenizer"), CommandLine.arguments.indices.contains(index + 1) {
            await checkTokenizer(URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true), reply: reply, headings: headings, run: run)
        }

        // MARK: Two models in memory, where they fit
        let gigabyte: Int64 = 1_073_741_824
        let gemma = 15 * gigabyte + gigabyte / 2, qwen = 16 * gigabyte
        run.check(MLXRuntime.fits(qwen, beside: [gemma], memory: UInt64(64 * gigabyte)), "on a 64 GB Mac, Distill's 16 GB model stays beside a 15.5 GB language model")
        run.check(!MLXRuntime.fits(qwen, beside: [gemma], memory: UInt64(48 * gigabyte)), "on a 48 GB Mac they take turns")
        run.check(!MLXRuntime.fits(gigabyte, beside: [gigabyte, gigabyte], memory: UInt64(128 * gigabyte)), "never more than two at once")
        run.check(MLXRuntime.fits(qwen, beside: [], memory: UInt64(32 * gigabyte)) && !MLXRuntime.fits(qwen, beside: [gemma], memory: UInt64(32 * gigabyte)),
                  "on a 32 GB Mac either loads alone, freeing the other")

        // MARK: Distill's own model
        let settings = AppSettings.shared
        let saved = (settings.distillModelSource, settings.distillModel, settings.llmProvider, settings.ollamaModel)
        defer {
            settings.distillModelSource = saved.0
            settings.distillModel = saved.1
            settings.llmProvider = saved.2
            settings.ollamaModel = saved.3
        }
        settings.llmProvider = .ollama
        settings.ollamaModel = "gemma4:26b"
        settings.distillModelSource = .same
        run.check(settings.makeDistillClient()?.model == "gemma4:26b" && settings.distillModelName == "gemma4:26b", "by default Distill reads with the language model")
        settings.distillModelSource = .ollama
        settings.distillModel = "qwen3:32b"
        run.check(settings.makeDistillClient()?.model == "qwen3:32b" && settings.makeLLMClient()?.model == "gemma4:26b",
                  "a model for Distill is Distill's only: the language model stays")
        settings.distillModelSource = .mlx
        settings.distillModel = MLXModels.distillSuggestion.id
        run.check(settings.makeDistillClient()?.model == MLXModels.distillSuggestion.id && settings.distillModelName == "Qwen3.8-27B-4bit",
                  "an MLX model for Distill: \(settings.distillModelName)")
        // `--draw <folder>`: the Settings section, with the language model's and with Qwen chosen.
        if let index = CommandLine.arguments.firstIndex(of: "--draw"), CommandLine.arguments.indices.contains(index + 1) {
            let out = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            let size = NSSize(width: 760, height: 260)
            _ = await drawnAlone(Form { DistillModelSection() }.formStyle(.grouped), controller: controller, name: "distill-model-qwen", size: size, directory: out)
            settings.distillModelSource = .same
            _ = await drawnAlone(Form { DistillModelSection() }.formStyle(.grouped), controller: controller, name: "distill-model-same", size: size, directory: out)
            settings.distillModelSource = .mlx
        }
        settings.distillModel = "  "
        run.check(settings.makeDistillClient()?.model == "gemma4:26b", "with no name, Distill keeps the language model")
        run.check(MLXModels.known.contains { $0.id == "mlx-community/Qwen3.8-27B-4bit" && $0.gigabytes == 16.1 }
                  && !MLXModels.suggestions.contains { $0.id == MLXModels.distillSuggestion.id },
                  "Qwen 3.8 27B is suggested for Distill, with its size, and not as the language model")

        print("DONE: \(run.failures == 0 ? "all passed" : "\(run.failures) failed")")
        return run.failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// A model's own tokenizer from its folder: xgrammar reads its vocabulary, Distill's schema compiles on it, the
    /// reply as the tokenizer splits it is held, and its chat template with thinking off ends where the answer starts.
    @MainActor
    static func checkTokenizer(_ folder: URL, reply: String, headings: [String], run: DistillTestRun) async {
        let name = folder.lastPathComponent
        let tokenizer: any MLXLMCommon.Tokenizer
        do {
            tokenizer = try await TransformersTokenizerLoader().load(from: folder)
        } catch {
            run.check(false, "\(name)'s tokenizer loads: \(error.localizedDescription)")
            return
        }
        let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
        print("TOKENIZER: \(name): \(vocabulary.vocab.count) tokens, \(vocabulary.vocabType), end of turn \(tokenizer.eosToken ?? "none") (\(tokenizer.eosTokenId.map(String.init) ?? "-"))")
        run.check(vocabulary.vocab.count > 1_000 && tokenizer.eosTokenId != nil, "\(name): xgrammar reads its vocabulary and its end token")
        let schema = DistillSchema.json(headings: headings)
        do {
            let grammarTokenizer = try GrammarTokenizer(vocab: vocabulary.vocab, vocabType: vocabulary.vocabType, eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
            let started = Date()
            let constraint = try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: schema)
            let compiled = Date().timeIntervalSince(started)
            var accepted = true
            for token in tokenizer.encode(text: reply.replacingOccurrences(of: "\n", with: " "), addSpecialTokens: false) where accepted {
                accepted = (try? constraint.commitToken(Int32(token))) != nil
            }
            let ended = accepted && (try? constraint.commitToken(Int32(tokenizer.eosTokenId ?? 0)))?.isTerminated == true
            run.check(ended, String(format: "\(name): Distill's schema compiles on it (%.2f s) and holds a reply as it splits it, to its end token", compiled))
            let partsStarted = Date()
            _ = try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: DistillSchema.json(headings: headings, waitsByTitle: true))
            let inParts = Date().timeIntervalSince(partsStarted)
            run.check(compiled < 10 && inParts < 10, String(format: "\(name): it compiles in seconds, not minutes (%.2f s whole, %.2f s in parts, a debug build)", compiled, inParts))
            let refused = try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: schema)
            var tookProse = true
            for token in tokenizer.encode(text: "Here are the work items:", addSpecialTokens: false) where tookProse {
                tookProse = (try? refused.commitToken(Int32(token))) != nil
            }
            run.check(!tookProse, "\(name): prose before the JSON is refused")
        } catch {
            run.check(false, "\(name): xgrammar sets up on it: \(MLXGuides.words(error))")
        }
        let guides = MLXGuides()
        do {
            let prepared = try guides.prepare(directory: folder, tokenizer: tokenizer, schema: schema)
            run.check(prepared.vocabSize == vocabulary.vocab.count && prepared.reserve > 0, "\(name): MLX's guide is set up on it, \(prepared.reserve) tokens to close")
        } catch {
            run.check(false, "\(name): MLX's guide is set up on it: \(MLXGuides.words(error))")
        }
        guides.forget()
        // Thinking off, as Binders asks: the template should open the answer, not a thought.
        if let tokens = try? tokenizer.applyChatTemplate(messages: [["role": "system", "content": "S"], ["role": "user", "content": "U"]], tools: nil,
                                                         additionalContext: ["enable_thinking": false]) {
            let text = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
            let tail = String(text.suffix(60)).replacingOccurrences(of: "\n", with: "\\n")
            print("TEMPLATE: \(name), thinking off, ends: \(tail)")
            let opensThought = text.hasSuffix("<think>\n") || text.hasSuffix("<|channel>thought\n")
            run.check(!opensThought, "\(name): with enable_thinking false its template doesn't open a thought for the model to write in")
        } else {
            run.check(false, "\(name): its chat template renders")
        }
    }
}

extension DistillBench {
    /// A held reply for the checkout spec, as the schema has it: an object whose items have every field.
    static let schemaReply = """
        {"items": [
        {"title": "Combine checkout into one page", "brief": "Address, delivery and card together.", "done_when": "Checkout is one page.", "section": "Payment form", "quote": "Put address, delivery and card on one page", "waits_for": [], "size": "medium", "for": "agent"},
        {"title": "Ship behind a flag to 10% of visitors", "brief": "Once the form is done.", "done_when": "10% see it.", "section": "Rollout", "quote": "Ship behind a flag to 10% of visitors", "waits_for": [1], "size": "small", "for": "agent"},
        {"title": "Decide on 100%", "brief": "Compare abandonment, then decide.", "done_when": "Decided.", "section": "Rollout", "quote": "decide on 100%", "waits_for": [2], "size": "small", "for": "person"}
        ]}
        """
}

/// A tokenizer of single characters (printable ASCII, a few letters with accents, newline and tab) and an end token,
/// standing in for a model's to set up xgrammar without one.
struct SchemaToyTokenizer: MLXLMCommon.Tokenizer {
    static let vocabulary: [String] = (0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) } + ["Ü", "ï", "ö", "é", "\n", "\t", "</s>"]

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.unicodeScalars.compactMap { Self.vocabulary.firstIndex(of: String($0)) } }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.compactMap { Self.vocabulary.indices.contains($0) ? Self.vocabulary[$0] : nil }.joined() }
    func convertTokenToId(_ token: String) -> Int? { Self.vocabulary.firstIndex(of: token) }
    func convertIdToToken(_ id: Int) -> String? { Self.vocabulary.indices.contains(id) ? Self.vocabulary[id] : nil }
    var bosToken: String? { nil }
    var eosToken: String? { "</s>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
}

/// A model server on the loopback address that answers Ollama's /api/chat and an OpenAI-compatible /v1/chat/completions in
/// one piece, keeping each request's body as it came; it can turn a schema down, or the thinking switch, or say the
/// prompt is too long for its context.
private final class SchemaModelServer: @unchecked Sendable {
    enum Mode: Sendable { case accepts, refusesSchema, refusesThinkingSwitch, tooLong }

    struct Request {
        var path: String
        var raw: String
        var body: [String: Any]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.binders.selftest.schema-server")
    private let lock = NSLock()
    private let reply: String
    private let mode: Mode
    private var received: [Request] = []
    var requests: [Request] { lock.withLock { received } }

    init?(reply: String, mode: Mode = .accepts) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        self.reply = reply
        self.mode = mode
    }

    func start() async -> UInt16? {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return await withCheckedContinuation { continuation in
            let once = SchemaOnce()
            listener.stateUpdateHandler = { [weak self] state in
                let port: UInt16?
                switch state {
                case .ready: port = self?.listener.port?.rawValue
                case .failed, .cancelled: port = nil
                default: return
                }
                if once.first() { continuation.resume(returning: port) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var data = data
            if let chunk { data.append(chunk) }
            if let request = Self.request(in: data) { return self.answer(request, on: connection) }
            if isComplete || error != nil { return connection.cancel() }
            self.read(connection, data)
        }
    }

    private static func request(in data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let length = lines.lazy.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        let raw = Data(body.prefix(length))
        return Request(path: path, raw: String(decoding: raw, as: UTF8.self),
                       body: (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:])
    }

    private func answer(_ request: Request, on connection: NWConnection) {
        lock.withLock { received.append(request) }
        let openAI = request.path.hasSuffix("/chat/completions")
        func send(_ status: String, _ body: String) {
            let text = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
        switch mode {
        case .refusesSchema where openAI && request.body["response_format"] != nil:
            return send("400 Bad Request", #"{"error":{"code":400,"message":"'response_format' of type 'json_schema' is not supported","type":"invalid_request_error"}}"#)
        case .refusesSchema where !openAI && request.body["format"] != nil:
            return send("400 Bad Request", #"{"error":"invalid format: expected \"json\" or a JSON schema"}"#)
        case .refusesThinkingSwitch where request.body["chat_template_kwargs"] != nil:
            return send("400 Bad Request", #"{"error":{"message":"Unrecognized request argument supplied: chat_template_kwargs"}}"#)
        case .tooLong:
            return send("400 Bad Request", #"{"error":{"code":400,"message":"the request exceeds the available context size, try increasing it","type":"exceed_context_size_error","n_prompt_tokens":4800,"n_ctx":6144}}"#)
        default:
            break
        }
        let object: [String: Any] = openAI
            ? ["choices": [["index": 0, "message": ["role": "assistant", "content": reply], "finish_reason": "stop"]]]
            : ["model": "stand-in", "message": ["role": "assistant", "content": reply], "done": true]
        send("200 OK", String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self))
    }
}

/// True the first time it's asked only.
private final class SchemaOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
