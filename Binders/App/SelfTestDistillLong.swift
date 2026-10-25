import Foundation
import SwiftData
import BindersKit

extension SelfTest {
    /// Distill on a long note (lane DS2), in a throwaway folder (BINDERS_DATA_DIR) with stand-in language models and the
    /// router's stand-in decision model: a note of about 60,000 characters read in parts, each with every heading, the
    /// items made one in the note's order with their waits across parts; a model that answers with no list the first time,
    /// and is asked once more; one that always answers in prose, for a short note and a long one; one that thinks first,
    /// and one that only thinks; a server that says the note is too long for its context; a part with no list.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill-long -notesShowMarkdown NO
    @MainActor
    static func distillLongSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes and distills")
            return 1
        }
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let store = Store.shared
        let service = controller.distill
        // v1's prompts and sizes, as this test was written for (lane DS8 made v2 the default; `--selftest-distill-fast` has it).
        service.format = .v1
        let registry = AgentRegistry.shared
        if registry.paused { registry.setPaused(false) }
        service.start()
        service.settleDelay = .seconds(600)
        let folder = AppPaths.support
        // The decision model is a stand-in that knows none of these titles: no one is suggested for them.
        let standIns = RouterStandIns()
        standIns.byChoice[.tev1] = RouterStandIn()
        controller.router.models = DecisionModels(choice: .tev1, measures: DecisionMeasureStore(url: folder.appendingPathComponent("distill-long-measures.json")),
                                                  fingerprints: FolderFingerprints(url: folder.appendingPathComponent("distill-long-fingerprints.json")),
                                                  makeBackend: { standIns.make($0) })
        controller.router.budget = .seconds(1)
        let scribe = AgentProfile(name: "Scribe", wake: .board, purpose: "writes and edits documents")
        run.check(registry.upsert(scribe) == nil, "Scribe is saved")
        let binder = BinderRecord(name: "Programme", colorIndex: 3)
        store.insert(binder)
        let long = DistillBench.longStatus
        func note(_ text: String) -> NoteItem {
            let note = NoteItem(text: text)
            note.binderID = binder.id
            store.insert(note)
            service.setDistill(true, for: note)
            return note
        }
        func title(_ gold: DistillBench.Gold) -> String { gold.words.joined(separator: " ").capitalized }
        let parts = DistillParts.plan(long.text, capacity: DistillBudget.unknown)

        // MARK: A long note, read in parts
        run.check(long.text.count >= 58_000 && long.text.count <= 62_000, "the note is about 60,000 characters: \(long.text.count)")
        let status = note(long.text)
        let reader = DistillLongStandIn(spec: long, way: .list)
        reader.peek = { await MainActor.run { service.readingPart[status.id].map { "\($0.part) of \($0.of)" } } }
        service.model = { reader }
        guard case .success(let record) = await service.distill(status) else {
            run.check(false, "the long note is distilled: \(service.problems[status.id] ?? "")")
            return 1
        }
        let asks = reader.asks
        run.check(parts.count >= 5 && asks.count == parts.count, "the model read it in \(parts.count) parts, once each: asked \(asks.count) times")
        run.check(asks.map(\.part) == (1...parts.count).map { "\($0) of \(parts.count)" }, "the Work bar said which part it was reading: \(asks.map { $0.part ?? "-" })")
        run.check(service.readingPart[status.id] == nil && !service.reading.contains(status.id), "and stops saying it once done")
        // With who can take work in the binder (Scribe, you), as Distill tells the reader (lane AS1).
        let instructions = DistillPrompt.system(who: service.takers(for: binder.id))
        run.check(instructions.contains("\"Scribe\", an AI agent") && asks.allSatisfy { $0.system == instructions }, "each part has the whole instructions")
        let everyHeading = DistillPrompt.headingsLine(DistillSections.sections(of: long.text).compactMap(\.heading))
        run.check(asks.allSatisfy { $0.user.contains(everyHeading) }, "and the whole list of headings")
        run.check(asks.allSatisfy { $0.user.count <= DistillBudget.unknown + 4_000 }, "no part's question is longer than a part and its framing: \(asks.map(\.user.count).max() ?? 0)")
        run.check(asks.allSatisfy { $0.maxTokens == DistillPrompt.maxTokens + DistillBudget.thinkingRoom }, "each may write a whole list, with room to think first")
        run.check(asks.last?.user.contains("## Checkout: Rollout") == true, "the note's end is read: before, it was cut at 36,000 characters")
        // Lane DS8: no part hears the items found before it, so parts can be asked at once.
        run.check(!asks.contains { $0.user.contains("Work items from the parts before") }, "no part hears the items found before it")
        run.check(record.parts == parts.count, "the distill says it read the note in \(parts.count) parts: \(record.parts ?? 0)")
        run.check(DistillReviewSheet.partsLine(record) == ", in \(parts.count) parts, as the note is long", "the review sheet says so: \(DistillReviewSheet.partsLine(record))")
        run.check(record.items.map(\.title) == long.gold.map(title), "its 23 items, in the note's order: \(record.items.count)")
        let titles = Dictionary(record.items.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let flag = record.items.first { $0.title == "Flag 10%" }
        run.check(Set(flag?.waitsFor.compactMap { titles[$0] } ?? []) == ["One Page Form", "Retry Keep Typed Details", "Log Failure Reason", "Order Summary Total"],
                  "the rollout, read last, waits for items parts before it, by title and by heading: \(flag?.waitsFor.compactMap { titles[$0] } ?? [])")
        run.check(record.items.last?.meantFor == "You" && record.items.last?.waitsFor == [flag?.id].compactMap { $0 }, "the decision on 100% is yours and waits for the rollout")
        run.check(record.items.allSatisfy { $0.section != nil && $0.sectionHash == DistillSections.section($0.section, in: long.text)?.hash },
                  "each item has its section and that section's version")
        run.check(record.readNote == nil && service.problems[status.id] == nil, "nothing was left out: \(record.readNote ?? "")")
        run.check(controller.board.cards(in: binder.id).isEmpty, "nothing is on the board before Place on Board")

        // MARK: No list the first time: asked once more
        let booth = DistillBench.specs.first { $0.name == "Summit booth" }!
        let second = note(booth.text)
        let once = DistillLongStandIn(spec: booth, way: .proseFirst)
        service.model = { once }
        if case .success(let again) = await service.distill(second) {
            run.check(once.asks.count == 2, "a reply with no list is asked once more: \(once.asks.count)")
            run.check(once.asks.last?.user.hasSuffix(DistillPrompt.reminder) == true, "with a short reminder at the end to reply with only the JSON list")
            run.check(again.items.count == booth.gold.count && again.parts == nil, "the second reply's 8 items are proposed, read whole: \(again.items.count)")
            run.check(service.problems[second.id] == nil && service.replyStart[second.id] == nil, "and nothing is said against it")
        } else {
            run.check(false, "a reply with no list the first time is asked again and read: \(service.problems[second.id] ?? "")")
        }

        // MARK: Prose every time
        let short = note(booth.text.replacingOccurrences(of: "# Summit booth", with: "# Summit booth again"))
        let prose = DistillLongStandIn(spec: booth, way: .prose)
        service.model = { prose }
        let before = DistillStore.shared.file(for: short.id).distills.count
        if case .failure(.noList(let why)) = await service.distill(short) {
            run.check(prose.asks.count == 2, "asked twice, then no more: \(prose.asks.count)")
            run.check(why == "The model answered without a list of work items, even when asked again. Try again, or choose another model in Settings → AI, or Distill with one of your agents.",
                      "it says what happened in plain words: \(why)")
            run.check(service.problems[short.id] == why, "on the Work bar too")
            run.check(service.replyStart[short.id] == "## Status summary The projects are mostly on track. Checkout is in review. …",
                      "with the first lines the model wrote: \(service.replyStart[short.id] ?? "none")")
            run.check(service.agentChoices(for: short).map(\.name) == ["Scribe"], "the alert offers Distill with Scribe")
            if case .success = service.distill(short, with: scribe) {
                run.check(service.problems[short.id] == nil && service.replyStart[short.id] == nil, "and once Scribe has it, the Work bar's words go")
            } else {
                run.check(false, "Distill with Scribe from the alert")
            }
        } else {
            run.check(false, "prose every time is no list, said in plain words")
        }
        run.check(DistillStore.shared.file(for: short.id).distills.count == before, "and no proposal is made")
        let longProse = note(long.text.replacingOccurrences(of: "# Spring programme status", with: "# Spring programme status, copy"))
        let prosy = DistillLongStandIn(spec: long, way: .prose)
        service.model = { prosy }
        if case .failure(.noList(let why)) = await service.distill(longProse) {
            run.check(prosy.asks.count == parts.count * 2, "a long note: each part asked twice: \(prosy.asks.count)")
            run.check(why == "The model answered without a list of work items for each of the \(parts.count) parts of this note, even when asked again, so the note may be too long for stand-in. Distill it with one of your agents instead, or choose another model in Settings → AI.",
                      "it says the note may be too long for this model, and offers an agent: \(why)")
            run.check(service.replyStart[longProse.id] != nil, "and shows what the model wrote")
        } else {
            run.check(false, "a long note with prose every time is no list, said in plain words")
        }

        // MARK: Thinking
        let thinker = DistillLongStandIn(spec: booth, way: .thinking)
        service.model = { thinker }
        let thought = note(booth.text.replacingOccurrences(of: "# Summit booth", with: "# Summit booth, thought through"))
        if case .success(let read) = await service.distill(thought) {
            run.check(thinker.asks.count == 1 && read.items.count == booth.gold.count, "a reply that thinks first is read once, its list after the thought: \(read.items.count)")
            run.check(!read.items.contains { $0.title.contains("Draft") }, "nothing from the thought is an item")
            run.check(thinker.asks.allSatisfy { !$0.stopsEarly }, "drafts repeated in the thought didn't stop the reply")
        } else {
            run.check(false, "a reply that thinks first is read: \(service.problems[thought.id] ?? "")")
        }
        let onlyThinks = DistillLongStandIn(spec: booth, way: .onlyThinking)
        service.model = { onlyThinks }
        let pondered = note(booth.text.replacingOccurrences(of: "# Summit booth", with: "# Summit booth, pondered"))
        if case .failure(.noList(let why)) = await service.distill(pondered) {
            run.check(onlyThinks.asks.count == 2 && why.hasPrefix("stand-in spent its whole reply thinking and never wrote the list, even when asked again."),
                      "a model that only thinks is said so: \(why)")
            run.check(service.replyStart[pondered.id] == nil, "its thinking isn't shown as what it wrote")
        } else {
            run.check(false, "a model that only thinks is no list")
        }

        // MARK: A server that says the note is too long for it
        let tight = DistillLongStandIn(spec: long, way: .tooLongOver(9_000))
        service.model = { tight }
        let refused = note(long.text.replacingOccurrences(of: "# Spring programme status", with: "# Spring programme status, small model"))
        if case .success(let small) = await service.distill(refused) {
            run.check((small.parts ?? 0) > parts.count, "read again in smaller parts, sized from the context it gave: \(small.parts ?? 0)")
            run.check(small.items.count == long.gold.count, "with every item: \(small.items.count)")
        } else {
            run.check(false, "a note too long for the server is read in smaller parts: \(service.problems[refused.id] ?? "")")
        }

        // MARK: One part with no list
        // The part with the booth's work in it.
        let boothPart = parts.first { $0.pieces.contains { $0.heading == "Booth: Stand" } }?.number ?? 2
        let gap = DistillLongStandIn(spec: long, way: .proseInPart(boothPart))
        service.model = { gap }
        let partly = note(long.text.replacingOccurrences(of: "# Spring programme status", with: "# Spring programme status, partly"))
        if case .success(let some) = await service.distill(partly) {
            let said = some.readNote ?? ""
            run.check(!some.items.isEmpty && some.items.count < long.gold.count && !some.items.contains { $0.section == "Booth: Stand" },
                      "the other parts' items are proposed: \(some.items.count)")
            run.check(said.hasPrefix("Part \(boothPart) of \(parts.count) (“") && said.contains("had no list of work items, even when asked again, so its work isn't here."),
                      "the review says which part gave none: \(said)")
            run.check(service.problems[partly.id] == said, "as the Work bar does")
        } else {
            run.check(false, "a part with no list leaves the rest proposed")
        }

        // MARK: Context from the model folder
        let model = folder.appendingPathComponent("Models/stand-in", isDirectory: true)
        try? FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try? #"{"model_type": "gemma4", "text_config": {"max_position_embeddings": 262144}}"#.write(to: model.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        run.check(MLXClient.contextTokens(in: model) == 262_144, "an MLX model's context is read from its config.json")
        run.check(DistillBudget.forContext(MLXClient.contextTokens(in: model)).partCharacters == DistillBudget.readsWell,
                  "and a part is then what reads well, not the whole context")

        // Lane DS8: a long note with v2's stand-in.
        await distillFastLongChecks(run, binder: binder)
        print("DONE: \(run.failures == 0 ? "all passed" : "\(run.failures) failed")")
        return run.failures == 0 ? 0 : 1
    }
}

/// Stands in for the language model on Distill's long-note checks: answers each question from the spec's gold items for
/// the sections in it (their words as titles), the way it's told to, and keeps what it was asked.
final class DistillLongStandIn: LLMClient, @unchecked Sendable {
    enum Way {
        /// A list every time.
        case list
        /// Prose the first time, then a list.
        case proseFirst
        case prose
        /// A thought with draft items in it, repeated, then the list.
        case thinking
        case onlyThinking
        /// Prose for the part with this number.
        case proseInPart(Int)
        /// A llama.cpp server's "too long" for a question longer than this.
        case tooLongOver(Int)
    }

    struct Asked {
        var system: String
        var user: String
        var maxTokens: Int
        /// What the Work bar said it was reading, when asked.
        var part: String?
        /// Whether its stop would have ended the reply early.
        var stopsEarly: Bool
    }

    let spec: DistillBench.Spec
    let way: Way
    var context: Int?
    var peek: (@Sendable () async -> String?)?
    private let lock = NSLock()
    private var _asks: [Asked] = []
    var asks: [Asked] { lock.withLock { _asks } }

    init(spec: DistillBench.Spec, way: Way) {
        self.spec = spec
        self.way = way
    }

    var model: String { "stand-in" }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout) { _ in false }
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        let part = await peek?()
        let reply = try answer(user)
        lock.withLock { _asks.append(Asked(system: system, user: user, maxTokens: maxTokens, part: part, stopsEarly: stopWhen(reply))) }
        return reply
    }

    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}
    func contextTokens() async -> Int? { context }

    static let prose = "## Status summary\nThe projects are mostly on track.\nCheckout is in review.\nThe booth is booked."

    private func answer(_ user: String) throws -> String {
        switch way {
        case .list: return list(user)
        case .proseFirst: return user.hasSuffix(DistillPrompt.reminder) ? list(user) : Self.prose
        case .prose: return Self.prose
        case .thinking:
            let draft = String(repeating: "\"title\": \"Draft item\",\n", count: 4)
            return "<|channel>thought\nLet me draft the items first: [{\"title\": \"Draft item\"}]\n\(draft)<channel|>" + list(user)
        case .onlyThinking: return "<|channel>thought\nThere is a lot in this note. Let me go through it section by section, starting with"
        case .proseInPart(let number): return user.contains("This is part \(number) of") ? Self.prose : list(user)
        case .tooLongOver(let limit):
            if user.count > limit {
                throw LLMError.http(400, #"{"error":{"code":400,"message":"the request exceeds the available context size, try increasing it","type":"exceed_context_size_error","n_prompt_tokens":4800,"n_ctx":6144}}"#)
            }
            return list(user)
        }
    }

    /// The gold items of the sections in the question, as a careful model would list them: waits by title, and the
    /// rollout's on the retry section by its heading.
    private func list(_ user: String) -> String {
        let inPart = Set(user.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) })
        func title(_ gold: DistillBench.Gold) -> String { gold.words.joined(separator: " ").capitalized }
        let items: [[String: Any]] = spec.gold.compactMap { gold in
            guard let section = gold.section, inPart.contains(section) else { return nil }
            var item: [String: Any] = ["title": title(gold), "brief": gold.words.joined(separator: ", "), "section": section,
                                       "for": gold.person ? "person" : "agent"]
            if section == "Checkout: Rollout", gold.waits.count == 3 {
                item["waits_for"] = [title(spec.gold[gold.waits[0]]), "Checkout: Retry after a failed payment", title(spec.gold[gold.waits[2]])]
            } else if !gold.waits.isEmpty {
                item["waits_for"] = gold.waits.map { title(spec.gold[$0]) }
            }
            return item
        }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted])) ?? Data("[]".utf8), as: UTF8.self)
    }
}
