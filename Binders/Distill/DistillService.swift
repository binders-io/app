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
    /// How many items the reading has found so far (lane DS7): the parts before, and the whole items of the reply coming.
    private(set) var readingItems: [UUID: Int] = [:]
    /// Lane DS8: each note's items as they're read, one by one, in the note's order, then the proposal's; for the views
    /// (DS9's live list). Kept until the next reading.
    private(set) var live: [UUID: DistillLive] = [:]
    /// Lane DS9: notes read quietly, in the background (`refresh`): no sweep, no flying cards, no word on the Work bar.
    private(set) var quietReading: Set<UUID> = []
    /// Lane DS9: the model being loaded before a reading can start, by its name, for "Loading Qwen3.8-27B…".
    private(set) var loadingModel: [UUID: String] = [:]
    /// Lane DS9: the lines of the part being read now, for the light that sweeps down them in the note.
    private(set) var readingLines: [UUID: DistillLines] = [:]
    /// Lane DS9: the note's text as the last reading of it read it, for telling whether what you typed since is worth a
    /// reading in the background.
    @ObservationIgnored var lastRead: [UUID: String] = [:]
    /// Lane DS9: the model readings in the background ask, in the background lane so they never hold up dictation or Ask.
    /// The self-tests give a stand-in.
    @ObservationIgnored var backgroundModel: @MainActor () -> LLMClient? = { AppSettings.shared.makeDistillClient(lane: .later) }
    /// Lane DS9: readings while you write (`DistillBackgroundReader`), and each note's Distill list (`DistillListModel`).
    @ObservationIgnored lazy var background = DistillBackgroundReader(service: self)
    @ObservationIgnored var lists: [UUID: DistillListModel] = [:]
    /// How Distill asks its model, when a self-test says (`readingFormat`).
    @ObservationIgnored var format: DistillFormat?
    /// Lane DS8: distills whose items are still being given someone by the decision model (`suggestLater`), and a count
    /// bumped as its suggestions arrive, for the open review.
    var suggesting: Set<UUID> = []
    var suggestedRevision = 0
    @ObservationIgnored var suggestTasks: [UUID: Task<Void, Never>] = [:]
    /// Lane DS8: the language model briefs are written with (`DistillBriefs`), in the background lane; the self-tests give
    /// a stand-in.
    @ObservationIgnored var briefModel: @MainActor () -> LLMClient? = { AppSettings.shared.makeDistillClient(lane: .later) }
    /// Cards whose brief is being written before they go to an agent: the agent's name (lane DS8).
    var writingBrief: [UUID: String] = [:]
    @ObservationIgnored var briefQueue: Task<Void, Never>?
    @ObservationIgnored var briefsWaiting: [DistillBriefJob] = []
    /// The warm-up of the Distill model under way (lane DS8), and the self-tests' word on whether it ran.
    @ObservationIgnored var warming: Task<Void, Never>?
    @ObservationIgnored var warmedFor: [UUID] = []
    /// Whether something is recorded or dictated now, in place of the controller's own word: the self-tests say.
    @ObservationIgnored var busyOverride: (() -> Bool)?
    /// Notes whose reading you stopped, while it winds down.
    private(set) var stopping: Set<UUID> = []
    @ObservationIgnored private var stopFlags: [UUID: DistillStopFlag] = [:]
    /// A reading that took long or was cut short: how long, with which model, and a quicker one for Distill (lane DS7).
    var slow: [UUID: DistillSlowReading] = [:]
    /// How long a reply may take (`StreamPace`): Distill's, unless a self-test gives its own.
    @ObservationIgnored var pace: StreamPace = .distill
    /// How often "9 items so far" is counted again as the reply grows, in seconds.
    @ObservationIgnored var progressEvery: TimeInterval = 0.5
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
        // Lane DS8: briefs still to be written when Binders quit.
        resumeBriefs()
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
        /// No section changed since it was last read (lane DS8, `refresh`).
        case unchanged
        /// You stopped the reading before it found anything (lane DS7).
        case stopped(String)
        /// The model's replies had no list of work items in them, even asked again (lane DS2).
        case noList(String)
        var errorDescription: String? {
            switch self {
            case .off: "Distill is off for this note. Turn it on with Distill This Note, in the note's menu."
            case .noModel: "Choose a language model in Settings → AI to distill notes, or Distill with one of your agents."
            case .reading: "Binders is reading this note already."
            case .empty(let why): why
            case .noList(let why): why
            case .stopped(let why): why
            case .notForAgents(let why): why
            case .noAgent: "That agent isn't one of yours that takes this binder's cards."
            case .gone: "That note isn't in your binders any more."
            case .nothingToPlace: "Tick the items to place first."
            // Store.refusedMessage's words.
            case .library: "Binders can't save right now: its library didn't open."
            case .unchanged: "Nothing changed in the note since it was last read."
            }
        }
    }

    /// Binders' model reads the note and proposes work items. Nothing reaches the board. A note distilled before is
    /// compared with its earlier items by section (Distill again). `ranBy`: you, or an agent asking over MCP
    /// (distill_note). A note longer than the model reads well is read in parts, sized from the model's context where
    /// Binders knows it, and a reply with no list is asked once more (`DistillRun`).
    /// Lane DS8: asked as `readingFormat` says (v2: numbered lines, short replies); only the sections that changed since
    /// they were last read whole go to the model, the rest taken from what was kept (`DistillKeep`); parts are asked at once
    /// where the model's server allows; each item shows in `live` as it's written; who each is for is suggested by the
    /// decision model after the proposal is made, never holding it up (`suggestLater`). `quietly` (`refresh`): nothing is
    /// said on the Work bar, and nothing is read when no section changed.
    /// Lane DS9: `full` reads every section again, whatever was kept (Distill Again from the Distill list); `client`, a
    /// model other than `model()` (the background lane's, for `refresh`). A reading you start pauses one in the background.
    @discardableResult
    func distill(_ note: NoteItem, ranBy: BoardActor = .you, quietly: Bool = false, full: Bool = false,
                 client given: LLMClient? = nil) async -> Result<DistillRecord, Problem> {
        guard Store.shared.canSave else { return .failure(.library) }
        guard note.distill else { return .failure(.off) }
        guard !reading.contains(note.id) else { return .failure(.reading) }
        if !quietly { background.foregroundStarted() }
        guard let client = given ?? model() else {
            if !quietly { problems[note.id] = Problem.noModel.errorDescription }
            return .failure(.noModel)
        }
        MarkdownEditor.flushAll()
        let id = note.id
        // What it reads is kept as a version, marked once the proposal is made.
        let text = note.text
        let sections = DistillSections.sections(of: text)
        let format = readingFormat
        let who = takers(for: note.binderID)
        let key = DistillKeep.Key(format: format, model: client.model, takers: who.fingerprint)
        let split = DistillKeep.split(sections, kept: full ? [] : store.file(for: id).readings ?? [], key: key)
        if quietly, split.read.isEmpty { return .failure(.unchanged) }
        reading.insert(id)
        if quietly { quietReading.insert(id) } else { list(for: id).readingStarted() }
        lastRead[id] = text
        if !quietly {
            problems[id] = nil
            said[id] = nil
            replyStart[id] = nil
            slow[id] = nil
        }
        let flag = DistillStopFlag()
        stopFlags[id] = flag
        let liveReading = DistillLiveBuilder(note: id, format: format)
        live[id] = DistillLive(phase: .reading, items: [], parts: 0, partsDone: 0)
        defer {
            reading.remove(id)
            quietReading.remove(id)
            readingLines[id] = nil
            loadingModel[id] = nil
            readingPart[id] = nil
            readingItems[id] = nil
            stopping.remove(id)
            stopFlags[id] = nil
            if live[id]?.phase == .reading { live[id]?.phase = .done }
        }
        // A slow model's parts are smaller, sized from how fast it was measured to write (lane DS7).
        let place = client.place, model = client.model
        // Lane DS9: a model in Binders not yet in memory loads first, which the list and the Work bar say.
        if place == .inApp, await client.residency() == nil { loadingModel[id] = Self.shortName(model) }
        let budget = DistillBudget.forContext(await client.contextTokens(), format: format).paced(DistillSpeeds.speed(of: model), place: place, format: format)
        let pace = pace
        let gate = DistillProgressGate(every: progressEvery)
        let heard = DistillFirstWords()
        let started = Date()
        var outcome: DistillRun.Outcome?
        if !split.read.isEmpty {
            do {
                outcome = try await DistillRun.read(title: note.title, text: text, budget: budget, who: who, format: format,
                                                    concurrent: client.concurrentAsks, only: split.kept.isEmpty ? nil : split.read,
                                                    onPart: { [weak self] part in
                                                        await MainActor.run { self?.partRead(part, of: id, builder: liveReading) }
                                                    }) { [weak self] ask in
                    await MainActor.run {
                        if ask.parts > 1 { self?.readingPart[id] = ReadingPart(part: ask.part, of: ask.parts) }
                        if let lines = ask.lines { self?.readingLines[id] = lines }
                        if ask.part > 1 || ask.attempt > 1 { self?.loadingModel[id] = nil }
                        liveReading.parts = max(liveReading.parts, ask.parts)
                        self?.readingItems[id] = max(self?.readingItems[id] ?? 0, ask.itemsBefore)
                    }
                    let prompt = ask.system.count + ask.user.count
                    do {
                        let reply = try await Self.asked(client, ask, held: Self.holdsToSchema, pace: pace, stop: flag) { text in
                            if heard.first() { Task { @MainActor in self?.loadingModel[id] = nil } }
                            guard gate.due() else { return }
                            // The items written so far, as they come (lane DS8): parsed off the main actor, shown on it.
                            let partial = ask.read(text).items
                            Task { @MainActor in
                                guard let self, self.reading.contains(id) else { return }
                                self.partialRead(partial, part: ask.part, of: id, builder: liveReading)
                            }
                        }
                        if let timing = reply.timing { DistillSpeeds.record(model: model, prompt: prompt, timing: timing, tokens: reply.tokens) }
                        return reply.text
                    } catch let stopped as StreamStopped {
                        DistillSpeeds.record(model: model, prompt: prompt, timing: stopped.timing)
                        throw stopped
                    }
                }
            } catch {
                let why = "Couldn't read the note: \(error.localizedDescription)"
                if !quietly { problems[id] = why }
                live[id]?.phase = .failed
                return .failure(.empty(why))
            }
        }
        if !quietly, let outcome {
            slow[id] = slowReading(seconds: Date().timeIntervalSince(started), cutShort: outcome.cutShort && !outcome.stopped, model: model, place: place)
        }
        guard note.modelContext != nil, !note.isDeleted else { return .failure(.gone) }
        // What was read whole is kept by section, for the next reading to read only what changed.
        if let outcome {
            let fresh = DistillKeep.readings(from: outcome, sections: split.read, key: key)
            store.update(id) { $0.readings = DistillKeep.kept($0.readings, adding: fresh, sections: sections) }
        }
        var read: DistillReading.Result
        if split.kept.isEmpty, let outcome {
            read = outcome.result
        } else {
            let reused = DistillKeep.result(split.kept)
            let new = outcome?.result ?? .empty
            read = DistillParts.merge([reused, new], headings: sections.compactMap(\.heading), limit: DistillPrompt.maxItems + reused.items.count)
            read.cutOff = new.cutOff
            read.noList = false
        }
        guard !read.items.isEmpty else {
            live[id]?.phase = .done
            guard let outcome else {
                // Nothing changed, and nothing was found before either.
                if !quietly { said[id] = "Nothing new to propose: no section changed since it was last read." }
                return .failure(.unchanged)
            }
            if outcome.stopped {
                let why = "You stopped the reading before the model finished an item. Distill again when you're ready."
                if !quietly { problems[id] = why }
                live[id]?.phase = .stopped
                return .failure(.stopped(why))
            }
            if outcome.noList {
                let why = outcome.noListWords(model: client.model, agents: !agentChoices(for: note).isEmpty)
                if !quietly {
                    problems[id] = why
                    replyStart[id] = outcome.firstLines
                }
                return .failure(.noList(why))
            }
            // Cut short with nothing whole yet: why, rather than "no work".
            let why = outcome.cutShort ? outcome.partsNote ?? "The reading was cut short." : ["The model found no work in this note.", outcome.partsNote].compactMap { $0 }.joined(separator: " ")
            if !quietly { problems[id] = why }
            return .failure(.empty(why))
        }
        var items = read.items(sections: sections)
        // Lane DS9: each item keeps the id it had while it was read, so the Distill list's row stays the same row.
        Self.keepIDs(of: liveReading.items, in: &items)
        readersPicks(read, into: &items, binder: note.binderID)
        let readNote = [outcome?.partsNote, read.note].compactMap { $0 }.joined(separator: " ")
        let record = propose(items, for: note, text: text, sections: sections, ranBy: ranBy, readBy: client.model, readByAgent: false,
                             parts: outcome.map { $0.inParts ? $0.parts.count : nil } ?? nil, readNote: readNote.isEmpty ? nil : readNote)
        live[id] = DistillLive(phase: .done, items: record.items, parts: liveReading.parts, partsDone: liveReading.parts)
        if !quietly {
            if !readNote.isEmpty { problems[id] = readNote }
            if record.items.isEmpty, record.updates.isEmpty { said[id] = "Nothing new to propose: everything in it is on the board or proposed already." }
        }
        // Who each item is for, where the reader didn't say: after the proposal, so it never holds up the review.
        suggestLater(record, binder: note.binderID)
        return .success(record)
    }

    /// Lane DS8: reads only the sections of `note` that changed since they were last read whole, without opening the
    /// review or saying anything on the Work bar, and proposes what's new in them (DS9's live list calls it while you
    /// write). `.unchanged` when no section changed: no model is asked. Lane DS9: `background`, with the background lane's
    /// model (`backgroundModel`).
    @discardableResult
    func refresh(note: NoteItem, background: Bool = false) async -> Result<DistillRecord, Problem> {
        guard background else { return await distill(note, quietly: true) }
        guard let client = backgroundModel() else { return .failure(.noModel) }
        return await distill(note, quietly: true, client: client)
    }

    /// "Qwen3.8-27B" for "mlx-community/Qwen3.8-27B-4bit": a model's name as the list says it loads.
    static func shortName(_ model: String) -> String {
        if let known = MLXModels.known.first(where: { $0.id == model })?.name { return known }
        let last = model.components(separatedBy: "/").last ?? model
        return last.replacingOccurrences(of: #"-(4|6|8)bit$"#, with: "", options: .regularExpression)
    }

    /// The ids the live list gave items as they were read, carried to the proposal's items of the same title, their waits
    /// following (lane DS9).
    static func keepIDs(of live: [DistillItem], in items: inout [DistillItem]) {
        func key(_ title: String) -> String { title.lowercased().filter { $0.isLetter || $0.isNumber } }
        var byTitle: [String: [UUID]] = [:]
        for item in live { byTitle[key(item.title), default: []].append(item.id) }
        var moved: [UUID: UUID] = [:]
        for index in items.indices {
            let k = key(items[index].title)
            guard var ids = byTitle[k], !ids.isEmpty else { continue }
            let id = ids.removeFirst()
            byTitle[k] = ids
            moved[items[index].id] = id
            items[index].id = id
        }
        guard !moved.isEmpty else { return }
        for index in items.indices { items[index].waitsFor = items[index].waitsFor.map { moved[$0] ?? $0 } }
    }

    /// Lane DS8: whether any section of `note` changed since it was last read whole, the way it would be read now (the
    /// model, the format, who can take work). Cheap: no model is asked.
    func hasChangedSections(note: NoteItem) -> Bool {
        guard note.distill, let client = model() else { return false }
        let key = DistillKeep.Key(format: readingFormat, model: client.model, takers: takers(for: note.binderID).fingerprint)
        return DistillKeep.hasChanged(note.text, kept: store.file(for: note.id).readings, key: key)
    }

    /// How Distill asks its model (lane DS8): the self-tests' choice, else `distillFormat` in the app's defaults (v2 when
    /// it isn't set).
    var readingFormat: DistillFormat { format ?? DistillFormat(setting: AppDefaults.store.string(forKey: "distillFormat")) }

    /// A part's items so far, as its reply comes: shown at once, in the note's order.
    private func partialRead(_ items: [DistillReading.Item], part: Int, of note: UUID, builder: DistillLiveBuilder) {
        guard builder.set(items, part: part, final: false) else { return }
        publish(builder, note: note)
    }

    /// A part done: its items as read, in place of what came while it was written.
    private func partRead(_ part: DistillRun.PartOutcome, of note: UUID, builder: DistillLiveBuilder) {
        builder.parts = max(builder.parts, part.count)
        _ = builder.set(part.read?.items ?? [], part: part.number, final: true)
        publish(builder, note: note)
    }

    private func publish(_ builder: DistillLiveBuilder, note: UUID) {
        let items = builder.items
        live[note] = DistillLive(phase: .reading, items: items, parts: builder.parts, partsDone: builder.done)
        readingItems[note] = max(readingItems[note] ?? 0, items.count)
        // Lane DS9: each new item glows in the note and flies into the Distill list (not for a reading in the background).
        list(for: note).liveItems(items, quiet: quietReading.contains(note))
    }

    /// Stops the reading of a note (Cancel on the Work bar, lane DS7): the reply coming now stops, its whole items and the
    /// parts read before are kept and proposed, and the parts after aren't read.
    func stopReading(_ note: UUID) {
        guard let flag = stopFlags[note] else { return }
        flag.raise()
        stopping.insert(note)
    }

    /// What the Work bar says while a note is read: "Reading part 2 of 5 · 9 items so far" (lane DS7).
    func readingLine(_ note: UUID) -> String {
        if stopping.contains(note) { return "Stopping: keeping what's read…" }
        if let loading = loadingModel[note] { return "Loading \(loading)…" }
        let part = readingPart[note]
        return DistillRun.readingLine(part: part?.part ?? 1, of: part?.of ?? 1, items: readingItems[note] ?? 0)
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

    /// The same, saying whether the reply was held to the schema, and why not, for the bench. The model may take as long
    /// as it keeps writing (`pace`, lane DS7): a reply that stops, or that you stop with `stop`, throws `StreamStopped` with
    /// what it wrote, which the reading keeps up to its last whole item. `onText`: the reply so far, as it grows.
    nonisolated static func asked(_ client: LLMClient, _ ask: DistillRun.Ask, held: Bool, pace: StreamPace = .distill, stop: DistillStopFlag? = nil,
                                  onText: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SchemaReply {
        if let stop, stop.isSet { throw StreamStopped(why: .stopped, pace: pace, text: "", timing: StreamTiming(firstWords: nil, lastWords: nil, characters: 0, total: 0)) }
        let stopped: @Sendable () -> Bool = { stop?.isSet ?? false }
        do {
            guard held else {
                var reply = try await client.paced(system: ask.system, user: ask.user, maxTokens: ask.maxTokens, temperature: 0.2, pace: pace,
                                                   schema: nil, stopWhen: ask.stopWhen, stopped: stopped, onText: onText)
                reply.why = "asked without the schema"
                return reply
            }
            // Lane DS8: what every part shares comes first, so a model in Binders reads it once; v2's items are short.
            let schema = ReplySchema(name: DistillSchema.name, bounded: ask.schema(bounded: true), portable: ask.schema(bounded: false),
                                     answerTokens: ask.replyTokens, stopWhenNotHeld: ask.stopWhen, userPrefix: ask.prefix.isEmpty ? nil : ask.prefix,
                                     itemTokens: ask.format == .v2 ? ask.format.tokensPerItem : nil)
            let reply = try await client.paced(system: ask.system, user: ask.user, maxTokens: ask.maxTokens, temperature: 0.2, pace: pace,
                                               schema: schema, stopWhen: ask.stopWhenHeld, stopped: stopped, onText: onText)
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

    /// Who each item is meant for as the reader said (lane AS1, `DistillMeantFor.reader`): a name it gave that is someone
    /// an item can be meant for here (`named`), else you for "person"; "agent", "either" and a name that's no one here are
    /// left for the decision model (`suggestWho`).
    func readersPicks(_ read: DistillReading.Result, into items: inout [DistillItem], binder: UUID?) {
        for (index, item) in read.items.enumerated() where items.indices.contains(index) {
            switch DistillMeantFor.reader(hint: item.hint, name: item.forName, resolve: { named($0, binder: binder) }) {
            case .you:
                items[index].meantFor = BoardActor.you.name
                items[index].meantForHow = "reader"
            case .named(let who):
                // One of your agents, or one of the team's people.
                items[index].meantFor = who
                items[index].meantForHow = "reader"
            case .ask:
                break
            }
        }
    }

    /// Who can take work in a binder, as the reader is told (lane AS1): your agents that take its cards, by name with what
    /// each is for and its kinds of work, and the team's people. `DistillTakers.none` with neither, and the reader is asked
    /// as before.
    func takers(for binder: UUID?) -> DistillTakers {
        let agents = AgentRegistry.shared.agents.filter { $0.isEnabled && $0.takesCards(from: binder) }
        return DistillTakers(agents: agents.map(DistillTakers.Agent.init), people: teamPeople(in: binder))
    }

    /// The agents that take a binder's cards with no What it's for of your typing: Distill can only guess what to give
    /// them, which the review sheet says.
    func withoutPurpose(in binder: UUID?) -> [String] {
        AgentRegistry.shared.agents.filter { $0.isEnabled && $0.takesCards(from: binder) && !$0.hasOwnPurpose }.map(\.name)
    }

    /// Who each item is meant for, where the reader didn't say: the decision model's pick among your agents that take the
    /// binder's cards, by what each is for, at its suggestion band; you, when it's as sure that no agent fits ("nobody",
    /// for you to do yourself); else no one, as when it's unsure or there's no decision model. The model reads the item's
    /// title and the start of its brief (`DistillWhoState`, lane AS1). It doesn't choose among people, who have no What
    /// it's for: a teammate comes from the reader's `for`, or from you in the review. An item you chose No one yet for is
    /// left as you chose. Returns how many it filled in.
    @discardableResult
    func suggestWho(_ items: inout [DistillItem], binder: UUID?) async -> Int {
        guard let router = controller?.router else { return 0 }
        let library = router.gather()
        let binderID = binder ?? Store.shared.defaultBinder().id
        var filled = 0
        for index in items.indices where items[index].meantFor == nil && items[index].meantForHow != "you" {
            let state = DistillWhoState.state(title: items[index].title, brief: items[index].brief)
            guard let answer = await router.ask(state, binder: false, agent: true, library: library) else { continue }
            let outcome = router.agentOutcome(kind: .card, named: [], answer: answer, binder: binderID, agentFit: false)
            if let pick = outcome.pick {
                items[index].meantFor = pick.name
                items[index].meantForHow = "model"
                filled += 1
            } else if RouterRules.saysNobody(answer.agentAnswer, bands: answer.bands) {
                items[index].meantFor = BoardActor.you.name
                items[index].meantForHow = "model"
                filled += 1
            }
        }
        return filled
    }

    /// Suggest Who Again, in the review sheet (lane AS1): the decision model asked once more, with today's agents, for the
    /// items still to review that are meant for no one and that you didn't leave so. Returns the items with who it
    /// suggested, and how many.
    func suggestAgain(_ items: [DistillItem], binder: UUID?) async -> (items: [DistillItem], filled: Int) {
        var items = items
        let filled = await suggestWho(&items, binder: binder)
        return (items, filled)
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
            // Lane DS9: one you dismissed from the Distill list counts too, so it's never proposed again.
            distill.items.filter { $0.dropped || distill.status != .dismissed || $0.card != nil }.map { item -> DistillAgain.Earlier in
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
                                details: DistillCards.requestDetails(noteText: note.text, note: note.id, agentWords: words, who: takers(for: note.binderID)),
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
        let read = DistillReading.read(itemsJSON, headings: sections.compactMap(\.heading), names: takers(for: note.binderID).others)
        guard !read.items.isEmpty else {
            return .failure(.empty(read.noList ? "items must be a list of work items, each with at least a title." : "No item had a title."))
        }
        var items = read.items(sections: sections)
        readersPicks(read, into: &items, binder: note.binderID)
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
