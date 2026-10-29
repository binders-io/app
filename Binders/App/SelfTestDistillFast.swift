import Foundation
import SwiftData
import BindersKit

/// Lane DS8: Distill reads fast, with stand-in models speaking v2 (numbered lines, items that name their lines): run at
/// the end of `--selftest-distill`, `--selftest-distill-long` and `--selftest-distill-slow`, in their throwaway folders.
extension SelfTest {
    /// Items published one by one as they're written; the quote, section and first brief taken from the lines; the
    /// proposal made before the decision model suggests anyone; briefs written once the cards are placed, before an
    /// agent's hand-off; a description you changed never written over; a brief that fails leaves the lines and one quiet
    /// line; Distill Again sending only the changed section; the warm-up of the Distill model; what each format writes.
    @MainActor
    static func distillFastChecks(_ run: DistillTestRun, router: RouterStandIn) async {
        let controller = run.controller
        let service = controller.distill
        let board = controller.board
        let store = Store.shared
        service.format = .v2
        service.progressEvery = 0
        defer { service.format = nil }
        let shop = BinderRecord(name: "Shop", colorIndex: 4)
        store.insert(shop)
        let spec = DistillBench.specs.first { $0.name == "Checkout redesign" }!
        let note = NoteItem(text: spec.text)
        note.binderID = shop.id
        store.insert(note)
        service.setDistill(true, for: note)
        func title(_ gold: DistillBench.Gold) -> String { gold.words.joined(separator: " ").capitalized }
        // Courier keeps each wake's card in a file of its own, as several of its cards wake at once here.
        let courier = AgentProfile(name: "Courier", wake: .command(command: #"cat > "courier-$BINDERS_CARD.json""#, folder: run.folder.path),
                                   wakesPerHour: 60, purpose: "the shop's checkout pages")
        run.check(AgentRegistry.shared.upsert(courier) == nil, "v2: Courier is saved")
        // The decision model: the agent's items are Courier's, and slow, so waiting for it would show.
        for gold in spec.gold where !gold.person { router.set(title(gold), agent: ["Courier": 0.98]) }
        router.delay = .milliseconds(250)
        defer { router.delay = .zero }

        // MARK: Read with v2, its items shown as they come
        let reader = DistillV2StandIn(spec: spec)
        let seen = FastSeen()
        let noteID = note.id
        reader.peek = {
            try? await Task.sleep(for: .milliseconds(40))
            let live = await MainActor.run { service.live[noteID] }
            seen.add(live?.items.count ?? 0, first: live?.items.first?.id)
        }
        service.model = { reader }
        let started = Date()
        guard case .success(var record) = await service.distill(note) else {
            run.check(false, "v2: the note is distilled: \(service.problems[note.id] ?? "")")
            return
        }
        let took = Date().timeIntervalSince(started)
        run.check(reader.asks.count == 1, "v2: one ask for a note that fits: \(reader.asks.count)")
        let ask = reader.asks.first
        run.check(ask?.system == DistillPrompt.system(who: service.takers(for: shop.id), format: .v2), "v2: with v2's instructions")
        run.check(ask?.user.contains("1| We're rebuilding checkout") == true && ask?.user.contains("## Payment form") == true,
                  "v2: the note goes as numbered lines, its headings as they are")
        run.check(ask.map { $0.prefix != nil && $0.user.hasPrefix($0.prefix!) } == true, "v2: the start every part shares comes first, for the model to keep")
        run.check(ask?.schema?.contains(#""lines":"#) == true && ask?.schema?.contains("quote") == false, "v2: held to v2's schema")
        run.check(record.items.count == spec.gold.count, "v2: every item is proposed: \(record.items.count)")
        run.check(record.items.map(\.section) == spec.gold.map(\.section), "v2: each in its section, from its lines")
        run.check(record.items.allSatisfy { $0.quote.map(note.text.contains) == true }, "v2: each quote is the note's own words, so its mark is exact")
        run.check(record.items.allSatisfy { $0.briefPending == true && !$0.brief.isEmpty && note.text.contains($0.brief.components(separatedBy: "\n")[0]) },
                  "v2: each brief is its lines, until a brief is written for its card")
        let counts = seen.counts
        run.check(counts.first == 1 && counts == counts.sorted() && Set(counts).count >= spec.gold.count - 1,
                  "v2: the items are published one by one as they're written: \(counts)")
        run.check(seen.firstIDs.count == 1, "v2: an item keeps its id while it's read")
        run.check(service.live[note.id]?.phase == .done && service.live[note.id]?.items.map(\.id) == record.items.map(\.id),
                  "v2: then the proposal's items, done")
        run.check(service.readingLine(note.id) == "Reading the note…" && service.readingItems[note.id] == nil, "v2: the Work bar stops counting once done")
        run.check(took < 2.5 && service.suggesting.contains(record.id) && record.items.allSatisfy { $0.meantForHow != "model" },
                  "v2: the proposal is ready before the decision model has suggested anyone (\(String(format: "%.1f", took)) s)")
        let suggestStarted = Date()
        await service.suggestionsDone(record.id)
        let suggestTook = Date().timeIntervalSince(suggestStarted)
        record = DistillStore.shared.distill(record.id, of: note.id) ?? record
        run.check(record.items.filter { $0.meantFor == "Courier" && $0.meantForHow == "model" }.count == spec.gold.filter { !$0.person }.count,
                  "v2: its suggestions arrive into the proposal after it: \(String(format: "%.1f", suggestTook)) s for \(spec.gold.count - 1) items")
        run.check(record.items.last?.meantFor == "You" && record.items.last?.meantForHow == "reader", "v2: the reader's \"person\" is you, as before")

        // What each format writes, with the stand-in: the measure the bench takes with a real model.
        let v2Tokens = DistillBench.estimatedTokens(reader.replies.joined())
        let v1Tokens = DistillBench.estimatedTokens(DistillModelStandIn.first)
        print(String(format: "MEASURE: stand-in output, v1 %d tokens an item (its checkout reply), v2 %d (estimated, 4 characters a token); asks a reading: v1 1, v2 %d",
                     v1Tokens / 8, v2Tokens / max(1, record.items.count), reader.asks.count))
        run.check(v2Tokens / max(1, record.items.count) <= DistillFormat.v2.tokensPerItem, "v2: about 30 tokens an item or fewer: \(v2Tokens / max(1, record.items.count))")

        // MARK: Briefs written once the cards are placed, before an agent's hand-off
        let writer = BriefStandIn()
        service.briefModel = { writer }
        let failing = title(spec.gold[4])
        writer.failFor = [failing]
        let cards = service.place(record, items: Set(record.items.map(\.id)), column: .ready)
        run.check(cards.count == spec.gold.count, "v2: every item is placed: \(cards.count)")
        guard cards.count == spec.gold.count else { return }
        let form = cards[0], decision = cards[7], failed = cards[4]
        run.check(writer.asks.isEmpty, "v2: placing doesn't wait for a brief")
        run.check(form.details.hasPrefix("From “Checkout redesign” › Payment form:\n> One page instead of three"),
                  "v2: until its brief is written, the card carries the note's lines: \(form.details.prefix(80))")
        run.check(form.meantFor == nil && service.writingBrief[form.id] == "Courier" && controller.agents.outcomes[form.id]?.message == "Writing the brief for Courier…",
                  "v2: an agent's card waits for its brief, saying so")
        run.check(decision.meantFor == "You", "v2: yours is yours at once; its brief comes in the background")
        // You change the decision card's description before its brief is written.
        board.edit(decision, details: "My own words for this.", by: .you)
        await service.briefsDone()
        let order = writer.asks.map(\.title)
        run.check(writer.asks.count == cards.count, "v2: a brief asked for each card, one after another: \(writer.asks.count)")
        run.check(order.last == title(spec.gold[7]), "v2: the agents' cards first, yours after: \(order.last ?? "")")
        run.check(form.details.hasPrefix("Brief for One Page Form.\n\n**Done when:** One Page Form is done.\n\nDistilled from [Checkout redesign]"),
                  "v2: the brief and done when are written on the card: \(form.details.prefix(90))")
        run.check(form.meantFor == "Courier" && form.distilledFrom?.briefFor == nil && service.writingBrief[form.id] == nil, "v2: then it goes to Courier")
        let woke = run.folder.appendingPathComponent("courier-\(form.id.uuidString).json")
        var wake: [String: Any] = [:]
        for _ in 0..<100 where wake.isEmpty {
            wake = run.object((try? String(contentsOf: woke, encoding: .utf8)) ?? "")
            if wake.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        }
        run.check((wake["details"] as? String)?.hasPrefix("Brief for One Page Form.") == true, "v2: Courier's wake carries the brief, written before it left")
        run.check(decision.details == "My own words for this.", "v2: a description you changed is never written over")
        run.check(failed.details.hasPrefix("From “Checkout redesign”") && failed.meantFor == "Courier",
                  "v2: a brief that fails leaves the lines, and the hand-off goes on")
        run.check(board.timeline(failed.id).filter { $0.text.contains("couldn't write a brief") }.count == 1, "v2: with one quiet line on its history")

        // MARK: Distill Again reads only what changed
        run.check(!service.hasChangedSections(note: note), "v2: nothing changed: no section to read")
        let asksBefore = reader.asks.count
        if case .failure(.unchanged) = await service.refresh(note: note) {
            run.check(reader.asks.count == asksBefore, "v2: a refresh with nothing changed asks nothing")
        } else {
            run.check(false, "v2: a refresh with nothing changed asks nothing")
        }
        let before = note.text
        note.text = before.replacingOccurrences(of: "Show the items, the delivery cost and the total", with: "Show the items, the delivery cost, the tax and the total")
        NoteHistory.changed(note.id, previous: before, by: .you)
        run.check(service.hasChangedSections(note: note), "v2: a section changed")
        guard case .success(let again) = await service.distill(note) else {
            run.check(false, "v2: Distill Again reads the changed section")
            return
        }
        let last = reader.asks.last?.user ?? ""
        run.check(reader.asks.count == asksBefore + 1 && last.contains("## Order summary") && !last.contains("## Payment form")
                  && last.contains("the rest of the note was read before"), "v2: Distill Again sends only the changed section")
        let first = reader.asks.first?.user.count ?? 0
        // What's captured already is listed on top of the note's lines: the note itself is what's measured.
        let captured = last.components(separatedBy: "\n").first { $0.hasPrefix("Already captured from this note") }
        run.check(captured != nil, "v2: Distill Again lists what's captured already: \(captured?.prefix(120) ?? "nothing")")
        let sent = last.count - (captured.map { $0.count + 2 } ?? 0)
        print("MEASURE: Distill Again sent \(sent) characters of the note in 1 ask (\(last.count) with what's captured); the first reading sent \(first)")
        run.check(sent * 2 < first, "v2: far less than the whole note: \(sent) of \(first) characters")
        run.check(again.items.isEmpty && again.updates.contains { $0.kind == .brief && $0.card == cards[5].id },
                  "v2: the summary's card is offered its section as it is now, nothing proposed twice")

        // MARK: The Distill model is loaded when a note with Distill on is opened
        let warm = WarmStandIn()
        service.model = { warm }
        service.busyOverride = { true }
        service.warm(for: note)
        try? await Task.sleep(for: .milliseconds(100))
        run.check(warm.warms == 0, "warm-up: not while you're dictating")
        service.busyOverride = { false }
        let plain = NoteItem(text: "# Not distilled\n\nNothing.")
        plain.binderID = shop.id
        store.insert(plain)
        service.warm(for: plain)
        try? await Task.sleep(for: .milliseconds(100))
        run.check(warm.warms == 0, "warm-up: never for a note without Distill")
        service.warm(for: note)
        try? await Task.sleep(for: .milliseconds(200))
        run.check(warm.warms == 1 && service.warmedFor.last == note.id, "warm-up: the Distill model loads when its note opens")
        warm.inApp = false
        service.warm(for: note)
        try? await Task.sleep(for: .milliseconds(100))
        run.check(warm.warms == 1, "warm-up: only for a model running in Binders")
        warm.inApp = true
        warm.slow = true
        service.warm(for: note)
        try? await Task.sleep(for: .milliseconds(50))
        controller.distill.cancelWarm()
        try? await Task.sleep(for: .milliseconds(400))
        run.check(warm.cancelled == 1 && service.warming == nil, "warm-up: dictating stops it, quietly")
        service.busyOverride = nil
    }

    /// A long note with v2: parts asked two at a time where the server allows, back in the note's order, each with the
    /// same start and nothing of the others; then Distill Again reading only the part with the changed section.
    @MainActor
    static func distillFastLongChecks(_ run: DistillTestRun, binder: BinderRecord) async {
        let service = run.controller.distill
        service.format = .v2
        defer { service.format = .v1 }
        let spec = DistillBench.long(characters: 40_000)
        let note = NoteItem(text: spec.text)
        note.binderID = binder.id
        Store.shared.insert(note)
        service.setDistill(true, for: note)
        let reader = DistillV2StandIn(spec: spec)
        reader.concurrent = 2
        reader.slowFirst = true
        service.model = { reader }
        guard case .success(let record) = await service.distill(note) else {
            run.check(false, "v2, long: the note is distilled: \(service.problems[note.id] ?? "")")
            return
        }
        let asks = reader.asks
        let parts = DistillParts.plan(spec.text, capacity: DistillBudget.forContext(nil, format: .v2).capacity(header: 0)).count
        run.check(asks.count >= 3, "v2, long: read in parts: \(asks.count)")
        run.check(reader.most == 2, "v2, long: two parts asked at once, as the server allows: \(reader.most)")
        func title(_ gold: DistillBench.Gold) -> String { gold.words.joined(separator: " ").capitalized }
        run.check(record.items.map(\.title) == spec.gold.map(title), "v2, long: the items in the note's order, the slow first part's first: \(record.items.count) of \(spec.gold.count)")
        let prefix = asks.first?.prefix ?? "-"
        run.check(asks.allSatisfy { $0.prefix == prefix && $0.user.hasPrefix(prefix) }, "v2, long: every part starts the same, for the model to keep")
        run.check(!asks.contains { $0.user.contains("Work items from the parts before") }, "v2, long: no part hears the others")
        run.check(service.live[note.id]?.items.count == record.items.count, "v2, long: the live list ends with the proposal")
        // What keeping the shared start saves, with the stand-in's prompts: tokens read with and without it.
        let whole = asks.map { ($0.system.count + $0.user.count) / 4 }.reduce(0, +)
        let kept = whole - (asks.count - 1) * ((asks.first?.system.count ?? 0) + prefix.count) / 4
        print("MEASURE: a \(spec.text.count)-character note in \(asks.count) parts: about \(whole) tokens of question read without keeping the start, \(kept) with it (estimated; \(parts) parts planned)")
        // Distill Again: one section changes.
        let before = note.text
        note.text = before.replacingOccurrences(of: "Order 300 stickers and 100 tote bags", with: "Order 400 stickers and 100 tote bags")
        NoteHistory.changed(note.id, previous: before, by: .you)
        let count = reader.asks.count
        _ = await service.distill(note)
        let again = reader.asks.dropFirst(count)
        run.check(again.count == 1 && again.first?.user.contains("## Booth: Swag") == true
                  && again.first?.user.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.count == 1,
                  "v2, long: Distill Again asks once, with only the changed section: \(again.count) asks")
        print("MEASURE: Distill Again on the long note sent \(again.first?.user.count ?? 0) characters; the first reading \(asks.map(\.user.count).reduce(0, +))")
    }

    /// A slow model in Binders with v2: bigger parts in the same two minutes, v2's shorter answer, and the stall rule.
    @MainActor
    static func distillFastSlowChecks(_ run: DistillTestRun, binder: BinderRecord) async {
        let service = run.controller.distill
        service.format = .v2
        defer { service.format = .v1 }
        DistillSpeeds.forget()
        let spec = DistillBench.long(characters: 20_000)
        func note() -> NoteItem {
            let note = NoteItem(text: spec.text + "\n\n<!-- \(UUID().uuidString) -->")
            note.binderID = binder.id
            Store.shared.insert(note)
            service.setDistill(true, for: note)
            return note
        }
        let paced = DistillBudget.forContext(nil, format: .v2).paced(nil, place: .inApp, format: .v2)
        let v1 = DistillBudget.forContext(nil).paced(nil, place: .inApp)
        let reader = DistillV2StandIn(spec: spec)
        reader.inApp = true
        service.model = { reader }
        let first = note()
        _ = await service.distill(first)
        let v1Parts = DistillParts.plan(first.text, capacity: v1.partCharacters).count
        run.check(paced.partCharacters == 12_000 && reader.asks.count < v1Parts,
                  "v2, slow: a model in Binders not measured yet reads in parts of 12,000 characters: \(reader.asks.count) parts, v1 \(v1Parts)")
        run.check(reader.asks.allSatisfy { $0.maxTokens == paced.streamTokens } && paced.replyTokens <= DistillFormat.v2.maxTokens,
                  "v2, slow: each may write v2's shorter answer: \(paced.replyTokens) tokens")
        // A stall in the second part: its whole items kept, the reading goes on, and it's read again next time.
        let staller = DistillV2StandIn(spec: spec)
        staller.inApp = true
        staller.stallInPart = 2
        service.model = { staller }
        let stalled = note()
        guard case .success(let record) = await service.distill(stalled) else {
            run.check(false, "v2, slow: a stall keeps what was written")
            return
        }
        run.check(record.readNote?.contains("was cut short: the model stopped writing for") == true && !record.items.isEmpty,
                  "v2, slow: the stalled part is noted, its whole items kept: \(record.readNote ?? "")")
        run.check(service.hasChangedSections(note: stalled), "v2, slow: the part cut short is read again next time")
        let reread = DistillV2StandIn(spec: spec)
        reread.inApp = true
        service.model = { reread }
        _ = await service.distill(stalled)
        run.check(reread.asks.count == 1, "v2, slow: and only it: \(reread.asks.count) asks")
    }
}

/// What a stand-in saw of the live list, from its own task.
final class FastSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var _counts: [Int] = []
    private var _ids: Set<UUID> = []
    var counts: [Int] { lock.withLock { _counts } }
    var firstIDs: Set<UUID> { lock.withLock { _ids } }
    func add(_ count: Int, first: UUID?) {
        lock.withLock {
            _counts.append(count)
            if let first { _ids.insert(first) }
        }
    }
}

/// Stands in for the language model speaking v2 (lane DS8): reads the part's numbered lines from the question and
/// answers with the bench's careful reply (`DistillBench.standInReply`), an item at a time. It can be a server that
/// answers two at a time, take longer over its first part, run in Binders, or stall in a part.
final class DistillV2StandIn: LLMClient, @unchecked Sendable {
    struct Asked {
        var system: String
        var user: String
        var prefix: String?
        var schema: String?
        var maxTokens: Int
    }

    let spec: DistillBench.Spec
    var concurrent = 1
    var slowFirst = false
    var inApp = false
    var stallInPart: Int?
    /// Lane DS9: an item for every line of the part, so any section a test adds has work in it.
    var everyLine = false
    var peek: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var _asks: [Asked] = []
    private var _replies: [String] = []
    private var running = 0
    private var _most = 0

    init(spec: DistillBench.Spec) { self.spec = spec }

    var model: String { "v2-stand-in" }
    var place: ModelPlace { inApp ? .inApp : .elsewhere }
    var concurrentAsks: Int { concurrent }
    var asks: [Asked] { lock.withLock { _asks } }
    var replies: [String] { lock.withLock { _replies } }
    var most: Int { lock.withLock { _most } }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout) { _ in false }
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await answer(system: system, user: user, prefix: nil, schema: nil, maxTokens: maxTokens, onText: { _ in })
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval, schema: ReplySchema,
                stopWhen: @escaping @Sendable (String) -> Bool, onText: @escaping @Sendable (String) -> Void) async throws -> SchemaReply {
        let text = try await answer(system: system, user: user, prefix: schema.userPrefix, schema: schema.bounded, maxTokens: maxTokens, onText: onText)
        return SchemaReply(text: text, held: true, why: nil)
    }

    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}

    private func answer(system: String, user: String, prefix: String?, schema: String?, maxTokens: Int,
                        onText: @escaping @Sendable (String) -> Void) async throws -> String {
        lock.withLock {
            _asks.append(Asked(system: system, user: user, prefix: prefix, schema: schema, maxTokens: maxTokens))
            running += 1
            _most = max(_most, running)
        }
        defer { lock.withLock { running -= 1 } }
        let part = Self.part(user)
        // The part's own lines, numbered as they were: the text after its framing, the numbers taken off.
        let body = user.dropFirst(prefix?.count ?? 0).components(separatedBy: "\n")
        let start = body.firstIndex { $0.hasPrefix("#") || $0.hasPrefix("1| ") } ?? 0
        let raw = body[start...].map { $0.replacingOccurrences(of: #"^\d+\| "#, with: "", options: .regularExpression) }.joined(separator: "\n")
        let ask = DistillRun.Ask(user: user, maxTokens: maxTokens, replyTokens: maxTokens, part: part, parts: 1, attempt: 1, format: .v2, lines: DistillLines(raw))
        let reply = everyLine ? Self.lineReply(ask.lines ?? DistillLines(raw)) : DistillBench.standInReply(ask, spec: spec)
        lock.withLock { _replies.append(reply) }
        let items = Self.items(reply)
        if slowFirst, part == 1 { try await Task.sleep(for: .milliseconds(300)) }
        var text = #"{"items":["#
        for (index, item) in items.enumerated() {
            if stallInPart == part, index == 2 {
                text += #",{"title":"Half"#
                onText(text)
                try await Task.sleep(for: .seconds(3_600))
            }
            text += (index > 0 ? "," : "") + item
            onText(text)
            await peek?()
            try await Task.sleep(for: .milliseconds(10))
        }
        text += "]}"
        onText(text)
        return text
    }

    /// An item for each numbered line, its title the line's first words (lane DS9).
    static func lineReply(_ lines: DistillLines) -> String {
        let items = lines.numbered.map { line -> String in
            let words = line.text.replacingOccurrences(of: #"^[-*\s]+"#, with: "", options: .regularExpression).split(separator: " ").prefix(5).joined(separator: " ")
            let title = words.replacingOccurrences(of: "\"", with: "'")
            return #"{"title":"\#(title)","lines":[\#(line.id)],"for":"agent","size":"small"}"#
        }
        return #"{"items":[\#(items.joined(separator: ","))]}"#
    }

    /// Which part a question is: "This is part 2 of 5", else 1.
    static func part(_ user: String) -> Int {
        guard let range = user.range(of: #"This is part \d+ of"#, options: .regularExpression) else { return 1 }
        return Int(user[range].components(separatedBy: " ")[3]) ?? 1
    }

    /// The reply's items, each as written.
    static func items(_ reply: String) -> [String] {
        guard let open = reply.range(of: #"{"items":["#), reply.hasSuffix("]}") else { return [] }
        let list = String(reply[open.upperBound..<reply.index(reply.endIndex, offsetBy: -2)])
        guard !list.isEmpty else { return [] }
        return list.components(separatedBy: "},{").enumerated().map { index, piece in
            var item = piece
            if index > 0 { item = "{" + item }
            if !item.hasSuffix("}") { item += "}" }
            return item
        }
    }
}

/// Stands in for the model that writes a card's brief once it's placed: "Brief for <title>.", or nothing for the titles
/// it's told to fail on.
final class BriefStandIn: LLMClient, @unchecked Sendable {
    struct Asked {
        var title: String
        var user: String
    }

    private let lock = NSLock()
    private var _asks: [Asked] = []
    var failFor: Set<String> = []
    var asks: [Asked] { lock.withLock { _asks } }
    var model: String { "brief-stand-in" }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String {
        try await stream(system: system, user: user, maxTokens: maxTokens, temperature: temperature, timeout: timeout) { _ in false }
    }

    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String {
        let title = user.components(separatedBy: "\n").first { $0.hasPrefix("Item: ") }.map { String($0.dropFirst(6)) } ?? ""
        lock.withLock { _asks.append(Asked(title: title, user: user)) }
        try await Task.sleep(for: .milliseconds(20))
        if failFor.contains(title) { throw LLMError.emptyResponse }
        return #"{"brief": "Brief for \#(title).", "done_when": "\#(title) is done."}"#
    }

    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}
}

/// Stands in for a model running in Binders, for the warm-up: counts its loads, and can take long enough to be stopped.
final class WarmStandIn: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _warms = 0, _cancelled = 0
    var inApp = true
    var slow = false
    var warms: Int { lock.withLock { _warms } }
    var cancelled: Int { lock.withLock { _cancelled } }
    var model: String { "warm-stand-in" }
    var place: ModelPlace { inApp ? .inApp : .elsewhere }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String { "[]" }
    func stream(system: String, user: String, maxTokens: Int, temperature: Double, timeout: TimeInterval,
                stopWhen: @escaping @Sendable (String) -> Bool) async throws -> String { "[]" }
    func listModels() async throws -> [String] { [model] }
    func warmUp() async {}

    func warmBeside() async -> Bool {
        if slow {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                lock.withLock { _cancelled += 1 }
                return false
            }
        }
        lock.withLock { _warms += 1 }
        return true
    }
}
