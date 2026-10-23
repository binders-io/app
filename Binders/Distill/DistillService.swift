import Foundation
import Observation
import SwiftData
import BindersKit

/// Distill on this Mac: a note with Distill on is read into work items (by Binders' model in Settings → AI, or by one of
/// your agents through propose_work_items), a person reviews them and places them on the board, and the note follows
/// their progress. Every card it places is meant for whoever was picked, by you; cards wait for each other as placed, and
/// an agent can't take one until what it waits for is Done (BoardRules). When a section changes after its cards were made,
/// the cards say so and the agents holding them are told; an agent's change waits for a person to look first. Nothing
/// reaches the board before Place on Board, except an agent's own placing in a binder that allows it.
@MainActor
@Observable
final class DistillService {
    /// The app's, for what changes notes without a controller at hand (note history). Nil in `Binders --mcp`.
    static weak var shared: DistillService?

    @ObservationIgnored weak var controller: DictationController?
    let store = DistillStore.shared
    /// The language model that reads notes: the one in Settings → AI. The self-tests give a stand-in.
    /// The model Distill reads with: the one chosen for Distill in Settings → AI, else the language model (lane DS3).
    @ObservationIgnored var model: @MainActor () -> LLMClient? = { AppSettings.shared.makeDistillClient(lane: .now) }
    /// Notes being read by the model now.
    private(set) var reading: Set<UUID> = []
    /// For a long note read in parts (lane DS2): the part being read now, and how many there are, for the Work bar.
    private(set) var readingPart: [UUID: ReadingPart] = [:]
    struct ReadingPart: Equatable {
        var part: Int
        var of: Int
    }
    /// Why the last reading of a note made no proposal, in words for the Work bar.
    var problems: [UUID: String] = [:]
    /// What the model wrote first, its thinking left out, when the last reading of a note found no list in its replies:
    /// for the Work bar and the alert, so you can see why.
    var replyStart: [UUID: String] = [:]
    /// What the last reading of a note found, when that's worth a word on the Work bar: nothing new.
    var said: [UUID: String] = [:]
    /// How long your typing settles before the sections it changed are looked at.
    @ObservationIgnored var settleDelay: Duration = .seconds(45)
    @ObservationIgnored var settling: [UUID: Task<Void, Never>] = [:]
    /// What each Distill note's cards stood at, for the notifications (`Seen`).
    @ObservationIgnored var seen: [UUID: Seen] = [:]
    /// A Distill note's cards as the notifications follow them: its counts, its cards that were your turn, and those that
    /// waited on you in Blocked with only a reason.
    struct Seen {
        var counts: DistillProgress.Counts
        var yourTurn: Set<UUID>
        var blocked: Set<UUID>
    }
    /// The team's people an item can be meant for, in place of `teamPeople(in:)`: the self-tests give their own.
    @ObservationIgnored var teamPeopleOverride: (@MainActor (UUID?) -> [String])?
    @ObservationIgnored private var boardWatcher: SaveWatcher?
    /// Bumped when the board or a distill changes, for the Work bars and lists.
    var boardRevision = 0
    /// For the self-tests: notifications that would have been posted, as their titles.
    @ObservationIgnored var posted: [String] = []

    init(controller: DictationController) {
        self.controller = controller
        Self.shared = self
    }

    var board: BoardService? { controller?.board }

    /// Follows the board for the Work bars and the notifications, and catches up on sections changed while Binders was
    /// closed.
    func start() {
        boardWatcher = SaveWatcher(kinds: ["TaskCard", "TaskEvent"]) { [weak self] in self?.boardChanged() }
        forgetDeletedNotes()
        for note in DistillBoard.notes(in: nil) { seen[note.id] = watch(note.id) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            // Lane DS6: notes with cards made with Put on Board from their sections too, Distill on or not.
            for note in DistillBoard.workNotes(in: nil) where note.distill || DistillBoard.followsSections(note.id) {
                self.checkSections(of: note, by: note.distill ? NoteHistory.index(of: note.id, note: note).current?.by ?? .you : .you)
            }
        }
    }

    /// The distills of notes that are gone (deleted and not put back before the app quit), as their history goes.
    private func forgetDeletedNotes() {
        guard !Store.shared.isFallback, let notes = try? Store.shared.context.fetch(FetchDescriptor<NoteItem>()) else { return }
        let kept = Set(notes.map(\.id))
        for file in (try? FileManager.default.contentsOfDirectory(at: DistillStore.folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !kept.contains(id) else { continue }
            store.forget(id)
        }
    }

    // MARK: Turning it on

    /// The cards placed from the note that aren't Done (or closed): Stop Distilling asks first while there are any.
    func openCards(of note: NoteItem) -> [TaskCard] {
        DistillBoard.cards(of: note.id).filter { $0.column != .done && $0.distilledFrom?.closed == nil }
    }

    /// Distill on or off. On, its history starts being kept for good, and who wrote its text now is noted; off, its cards
    /// stay on the board as they are.
    func setDistill(_ on: Bool, for note: NoteItem) {
        guard note.distill != on, Store.shared.allowsSave() else { return }
        note.distill = on
        note.updatedAt = Date()
        Store.shared.save()
        if on {
            var index = NoteHistory.index(of: note.id, note: note)
            index.stamp(note.text, by: index.current?.by ?? .you, at: Date())
            NoteHistory.save(index, for: note.id)
            seen[note.id] = watch(note.id)
        }
        controller?.team.scheduleSync(after: 0.5)
        boardRevision += 1
    }

    // MARK: Distilling

    enum Problem: LocalizedError, Equatable, Sendable {
        case off, noModel, reading, empty(String), notForAgents(String), noAgent, gone, nothingToPlace, library
        /// The model's replies had no list of work items in them, even asked again (lane DS2).
        case noList(String)
        var errorDescription: String? {
            switch self {
            case .off: "Distill is off for this note. Turn it on with Distill This Note, in the note's menu."
            case .noModel: "Choose a language model in Settings → AI to distill notes, or Distill with one of your agents."
            case .reading: "Binders is reading this note already."
            case .empty(let why): why
            case .noList(let why): why
            case .notForAgents(let why): why
            case .noAgent: "That agent isn't one of yours that takes this binder's cards."
            case .gone: "That note isn't in your binders any more."
            case .nothingToPlace: "Tick the items to place first."
            // Store.refusedMessage's words.
            case .library: "Binders can't save right now: its library didn't open."
            }
        }
    }

    /// Binders' model reads the note and proposes work items: who each is meant for is suggested by the decision model.
    /// Nothing reaches the board. A note distilled before is compared with its earlier items by section (Distill again).
    /// `ranBy`: you, or an agent asking over MCP (distill_note). A note longer than the model reads well is read in parts,
    /// sized from the model's context where Binders knows it, and a reply with no list is asked once more (`DistillRun`).
    @discardableResult
    func distill(_ note: NoteItem, ranBy: BoardActor = .you) async -> Result<DistillRecord, Problem> {
        guard Store.shared.canSave else { return .failure(.library) }
        guard note.distill else { return .failure(.off) }
        guard !reading.contains(note.id) else { return .failure(.reading) }
        guard let client = model() else {
            problems[note.id] = Problem.noModel.errorDescription
            return .failure(.noModel)
        }
        MarkdownEditor.flushAll()
        let id = note.id
        reading.insert(id)
        problems[id] = nil
        said[id] = nil
        replyStart[id] = nil
        defer {
            reading.remove(id)
            readingPart[id] = nil
        }
        // What it reads is kept as a version, marked once the proposal is made.
        let text = note.text
        let sections = DistillSections.sections(of: text)
        let budget = DistillBudget.forContext(await client.contextTokens())
        let outcome: DistillRun.Outcome
        do {
            outcome = try await DistillRun.read(title: note.title, text: text, budget: budget) { [weak self] ask in
                if ask.parts > 1 { await MainActor.run { self?.readingPart[id] = ReadingPart(part: ask.part, of: ask.parts) } }
                return try await Self.ask(client, ask)
            }
        } catch {
            let why = "Couldn't read the note: \(error.localizedDescription)"
            problems[id] = why
            return .failure(.empty(why))
        }
        guard note.modelContext != nil, !note.isDeleted else { return .failure(.gone) }
        let read = outcome.result
        guard !read.items.isEmpty else {
            if outcome.noList {
                let why = outcome.noListWords(model: client.model, agents: !agentChoices(for: note).isEmpty)
                problems[id] = why
                replyStart[id] = outcome.firstLines
                return .failure(.noList(why))
            }
            let why = ["The model found no work in this note.", outcome.partsNote].compactMap { $0 }.joined(separator: " ")
            problems[id] = why
            return .failure(.empty(why))
        }
        var items = read.items(sections: sections)
        for (index, item) in read.items.enumerated() {
            if item.hint == .person {
                items[index].meantFor = BoardActor.you.name
                items[index].meantForHow = "reader"
            } else if let who = named(item.forName, binder: note.binderID) {
                items[index].meantFor = who
                items[index].meantForHow = "reader"
            }
        }
        await suggestWho(&items, binder: note.binderID)
        let readNote = [outcome.partsNote, read.note].compactMap { $0 }.joined(separator: " ")
        let record = propose(items, for: note, text: text, sections: sections, ranBy: ranBy, readBy: client.model, readByAgent: false,
                             parts: outcome.inParts ? outcome.parts.count : nil, readNote: readNote.isEmpty ? nil : readNote)
        if !readNote.isEmpty { problems[id] = readNote }
        if record.items.isEmpty, record.updates.isEmpty { said[id] = "Nothing new to propose: everything in it is on the board or proposed already." }
        return .success(record)
    }

    /// Whether Distill holds the model's reply to its JSON schema (`DistillSchema`, lane DS3) where the model allows it.
    /// On unless `defaults write io.binders.mac distillHeldToSchema -bool NO`, for comparing (the bench has
    /// `--constrained off`).
    nonisolated static var holdsToSchema: Bool {
        AppDefaults.store.object(forKey: "distillHeldToSchema") as? Bool ?? true
    }

    /// One question of a reading, to the model in Settings → AI: a server's "too long for my context" becomes
    /// `DistillRun.TooLong`, so the reading starts again in smaller parts; a reply that was only thinking, or empty, reads as a
    /// reply with no list, so it's asked once more. `held`: the reply is held to the note's JSON schema where the model
    /// allows it (lane DS3).
    nonisolated static func ask(_ client: LLMClient, _ ask: DistillRun.Ask, held: Bool = holdsToSchema) async throws -> String {
        try await asked(client, ask, held: held).text
    }

    /// The same, saying whether the reply was held to the schema, and why not, for the bench.
    nonisolated static func asked(_ client: LLMClient, _ ask: DistillRun.Ask, held: Bool) async throws -> SchemaReply {
        do {
            guard held else {
                let text = try await client.stream(system: DistillPrompt.system, user: ask.user, maxTokens: ask.maxTokens, temperature: 0.2,
                                                   timeout: 300, stopWhen: ask.stopWhen)
                return SchemaReply(text: text, held: false, why: "asked without the schema")
            }
            let schema = ReplySchema(name: DistillSchema.name, bounded: ask.schema(bounded: true), portable: ask.schema(bounded: false),
                                     answerTokens: ask.replyTokens, stopWhenNotHeld: ask.stopWhen)
            let reply = try await client.stream(system: DistillPrompt.system, user: ask.user, maxTokens: ask.maxTokens, temperature: 0.2,
                                                timeout: 300, schema: schema, stopWhen: ask.stopWhenHeld, onText: { _ in })
            if !reply.held, let why = reply.why { Log.llm.notice("Distill asked \(client.model, privacy: .public) without its schema: \(why, privacy: .public)") }
            return reply
        } catch LLMError.http(let code, let body) where (400..<600).contains(code) && DistillBudget.isTooLong(body) {
            throw DistillRun.TooLong(contextTokens: DistillBudget.context(fromError: body))
        } catch LLMError.onlyThinking {
            return SchemaReply(text: "<think>…</think>", held: false, why: "only thinking")
        } catch LLMError.emptyResponse {
            return SchemaReply(text: "", held: false, why: "an empty reply")
        }
    }

    /// Your agents that could read the note instead, as the alert offers them: those that take its binder's cards, unless
    /// the note never goes to an agent (a teammate's, or one made from what you said).
    func agentChoices(for note: NoteItem) -> [AgentProfile] {
        guard !note.isTeamCopy, !note.staysUnshared else { return [] }
        return AgentRegistry.shared.agents.filter { $0.isEnabled && $0.takesCards(from: note.binderID) }
    }

    /// Who each item is meant for, where the reader didn't say: the decision model's pick among your agents that take the
    /// binder's cards, by what each is for, at its suggestion band; you, when it's as sure that no agent fits ("nobody",
    /// for you to do yourself); else no one, as when it's unsure or there's no decision model. The model doesn't choose
    /// among people, who have no What it's for: a teammate comes from the reader's `for`, or from you in the review.
    func suggestWho(_ items: inout [DistillItem], binder: UUID?) async {
        guard let router = controller?.router else { return }
        let library = router.gather()
        let binderID = binder ?? Store.shared.defaultBinder().id
        for index in items.indices where items[index].meantFor == nil {
            let state = items[index].title
            guard let answer = await router.ask(state, binder: false, agent: true, library: library) else { continue }
            let outcome = router.agentOutcome(kind: .card, named: [], answer: answer, binder: binderID, agentFit: false)
            if let pick = outcome.pick {
                items[index].meantFor = pick.name
                items[index].meantForHow = "model"
            } else if RouterRules.saysNobody(answer.agentAnswer, bands: answer.bands) {
                items[index].meantFor = BoardActor.you.name
                items[index].meantForHow = "model"
            }
        }
    }

    // MARK: Who it's for

    /// Who an item can be meant for in a binder: your agents that take its cards, you, and the team's people
    /// (`teamPeople(in:)`), as the review sheet's For list offers them.
    func people(for binder: UUID?) -> [String] {
        var names = AgentRegistry.shared.agents.filter { $0.isEnabled && $0.takesCards(from: binder) }.map(\.name)
        names.append(BoardActor.you.name)
        for name in teamPeople(in: binder) where !names.contains(name) { names.append(name) }
        return names
    }

    /// The team's people for a binder: on a board shared through the team database, teammates' agents that take its cards
    /// (with their owners) and teammates (lane DB2); for a binder shared through the team folder, the folder's members
    /// other than you.
    func teamPeople(in binder: UUID?) -> [String] {
        if let teamPeopleOverride { return teamPeopleOverride(binder) }
        var names: [String] = []
        if let team = TeamBoard.current, team.covers(binder) {
            names += team.teammatesAgents(taking: binder).map { team.directory.name(of: $0) }
            names += team.directory.teammates.map(\.name)
        }
        if let folder = controller?.team, folder.isConfigured, let shared = Store.shared.binder(binder), shared.sharedWithTeam || shared.isTeamCopy {
            names += folder.status.members.filter { $0.id != folder.me.id }.map(\.name)
        }
        return names
    }

    /// The one the reader named in `for`, when an item can be meant for them here: one of your agents that takes the
    /// binder's cards, by its name, else one of the team's people (`DistillWho.match`). Nil for anyone else.
    func named(_ name: String?, binder: UUID?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if let agent = AgentRegistry.shared.agent(named: name), agent.takesCards(from: binder) { return agent.name }
        return DistillWho.match(name, among: people(for: binder).filter { $0 != BoardActor.you.name })
    }

    /// Keeps a proposal: the version read is marked, and, for a note distilled before, only what's new or changed is
    /// proposed, with updates for cards whose section changed and closes for cards whose section is gone.
    @discardableResult
    private func propose(_ items: [DistillItem], for note: NoteItem, text: String, sections: [DistillSections.Section], ranBy: BoardActor,
                         readBy: String, readByAgent: Bool, version: String? = nil, requestCard: UUID? = nil, parts: Int? = nil,
                         readNote: String? = nil) -> DistillRecord {
        let id = UUID()
        let file = store.file(for: note.id)
        let earlier = file.distills.flatMap { distill in
            distill.items.filter { !$0.dropped && (distill.status != .dismissed || $0.card != nil) }.map { item -> DistillAgain.Earlier in
                let card = item.card.flatMap { board?.card($0) }
                // A card whose brief was brought up to date carries its section's newer version.
                let hash = card?.distilledFrom?.sectionHash ?? item.sectionHash
                return DistillAgain.Earlier(item: item.id, title: item.title, section: item.section, sectionHash: hash,
                                            card: card?.id, finished: card.map { $0.column == .done } ?? false)
            }
        }
        var record = DistillRecord(id: id, note: note.id, ranBy: ranBy.name, ranByAgent: ranBy.isAgent, readBy: readBy, readByAgent: readByAgent,
                                   version: version ?? NoteHistory.markRead(note, by: id), items: items, requestCard: requestCard,
                                   parts: parts, readNote: readNote)
        if !earlier.isEmpty {
            if readBy == ranBy.name, requestCard == nil {
                // Someone's own proposal (an agent's propose_work_items): what it proposes, never an item made before.
                record.items = DistillAgain.additions(read: items, earlier: earlier).items
            } else {
                // The note read again: the new and the changed, by section.
                let plan = DistillAgain.plan(read: items, earlier: earlier, sections: sections)
                record.items = plan.items
                record.updates = plan.updates + plan.closes
            }
            record.after = file.distills.last?.id
        }
        if version != nil { NoteHistory.markVersion(version!, of: note, by: id) }
        // Nothing to review: it doesn't wait on the Work bar, though History still says it read the note.
        if record.items.isEmpty, record.updates.isEmpty { record.status = .placed }
        store.save(record)
        boardRevision += 1
        return record
    }

    /// "Distill with…": a card in the note's binder asking the agent to read the note and call propose_work_items with
    /// the card's id, meant for it by you and given to it (Give to's path: its hourly cap, its receipt). A teammate's note,
    /// and one made from what you said, never go to an agent this way.
    func distill(_ note: NoteItem, with agent: AgentProfile) -> Result<TaskCard, Problem> {
        guard Store.shared.allowsSave() else { return .failure(.library) }
        guard note.distill else { return .failure(.off) }
        guard let board else { return .failure(.gone) }
        if note.isTeamCopy {
            return .failure(.notForAgents("A teammate's note doesn't go to an agent. Distill it with Binders' model instead."))
        }
        if note.staysUnshared {
            return .failure(.notForAgents("This note was made from what you said, so it doesn't go to an agent. Distill it with Binders' model instead."))
        }
        guard agent.isEnabled, agent.takesCards(from: note.binderID) else { return .failure(.noAgent) }
        MarkdownEditor.flushAll()
        let distill = UUID()
        let version = NoteHistory.markRead(note, by: distill)
        let words = note.agentMark.noteLine
        let card = board.create(title: DistillCards.requestTitle(note.title),
                                details: DistillCards.requestDetails(noteText: note.text, note: note.id, agentWords: words),
                                binderID: note.binderID, column: .ready, source: ("note", note.id.uuidString, note.title), by: .you)
        card.distilledFrom = DistilledFrom(note: note.id, distill: distill, item: distill, version: version, request: true)
        Store.shared.save()
        board.give(card, to: agent.name, by: .you)
        // An agent reads it now: what Binders' model last failed at is no longer the news.
        problems[note.id] = nil
        replyStart[note.id] = nil
        return .success(card)
    }

    /// An agent's proposal (propose_work_items): its items as it wrote them, read as the model's are, kept as a proposal
    /// for you to review. Placed at once only when the binder's Agents may place work items is on: as Place on Board does,
    /// in Ready, each meant for whoever it picked, waiting as proposed, so agents take them in order as their own start
    /// switches allow (lane DB2). `card`: the card that asked it to distill the note, when it answers one.
    func propose(itemsJSON: String, for note: NoteItem, by actor: BoardActor, card request: TaskCard? = nil) async -> Result<(DistillRecord, [TaskCard]), Problem> {
        guard Store.shared.canSave else { return .failure(.library) }
        guard note.distill else { return .failure(.off) }
        let text = note.text
        let sections = DistillSections.sections(of: text)
        let read = DistillReading.read(itemsJSON, headings: sections.compactMap(\.heading))
        guard !read.items.isEmpty else {
            return .failure(.empty(read.noList ? "items must be a list of work items, each with at least a title." : "No item had a title."))
        }
        var items = read.items(sections: sections)
        for (index, item) in read.items.enumerated() {
            if item.hint == .person {
                items[index].meantFor = BoardActor.you.name
                items[index].meantForHow = "reader"
            } else if let who = named(item.forName, binder: note.binderID) {
                // One of your agents, or one of the team's people.
                items[index].meantFor = who
                items[index].meantForHow = "reader"
            }
        }
        await suggestWho(&items, binder: note.binderID)
        let from = request?.distilledFrom
        var record = propose(items, for: note, text: text, sections: sections, ranBy: actor, readBy: actor.name, readByAgent: actor.isAgent,
                             version: from?.version, requestCard: request?.id)
        if let request, let board {
            let count = record.items.count
            board.note(request, text: count == 0 && record.updates.isEmpty
                       ? "\(actor.name) proposed nothing new: everything in “\(note.title)” is on the board or proposed already."
                       : "\(actor.name) proposed \(count == 1 ? "1 work item" : "\(count) work items"). They wait for your review in “\(note.title)”.")
        }
        guard actor.isAgent, Store.shared.binder(note.binderID)?.agentsMayPlace == true, !record.waiting.isEmpty else { return .success((record, [])) }
        let placed = place(record, items: Set(record.waiting.map(\.id)), column: .ready, by: actor, agentPlaced: true)
        record = store.distill(record.id, of: note.id) ?? record
        return .success((record, placed))
    }
}
