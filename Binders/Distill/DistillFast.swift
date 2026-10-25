import Foundation
import BindersKit

// Lane DS8: Distill reads fast. What the views read as a note is read (`live`), who each item is for after the proposal
// (`suggestLater`), briefs written for the cards kept (`DistillBriefJob`), and the Distill model loaded when a note with
// Distill on is opened (`warm(for:)`). The rules are BindersKit's (`DistillLines`, `DistillKeep`, `DistillBriefs`).

/// A note's items as it's read: each one as soon as the model has written it, in the note's order, then the proposal's.
struct DistillLive: Equatable {
    enum Phase: Equatable {
        case reading, done, failed, stopped
    }

    var phase: Phase
    var items: [DistillItem]
    /// The parts it's read in, and how many are done.
    var parts: Int
    var partsDone: Int
}

/// Gathers a reading's items as its parts' replies come, each part's partial items replaced by its whole reading once
/// it's done; an item keeps its id while it's read, for the views.
@MainActor
final class DistillLiveBuilder {
    let note: UUID
    let format: DistillFormat
    var parts = 0
    private var byPart: [Int: [DistillReading.Item]] = [:]
    private var finished: Set<Int> = []
    private var ids: [String: UUID] = [:]

    init(note: UUID, format: DistillFormat) {
        self.note = note
        self.format = format
    }

    var done: Int { finished.count }

    /// A part's items: whether anything changed. Partial items never replace a part's whole reading, or more of them.
    func set(_ items: [DistillReading.Item], part: Int, final: Bool) -> Bool {
        guard !finished.contains(part) else { return false }
        if !final, (byPart[part]?.count ?? 0) >= items.count { return false }
        byPart[part] = items
        if final { finished.insert(part) }
        return true
    }

    /// Every part's items so far, in the parts' order.
    var items: [DistillItem] {
        byPart.keys.sorted().flatMap { part in
            (byPart[part] ?? []).enumerated().map { index, item in
                let key = "\(part)-\(index)"
                let id = ids[key] ?? UUID()
                ids[key] = id
                return DistillItem(id: id, title: item.title, brief: item.brief, doneWhen: item.doneWhen, section: item.section, quote: item.quote,
                                   size: item.size, hint: item.hint, briefPending: item.briefPending ? true : nil)
            }
        }
    }
}

extension DistillService {
    /// The most items the decision model is asked about after one reading, and for how long in all.
    static let suggestAtMost = 25
    static let suggestSeconds: TimeInterval = 90

    /// Who each item is for, where the reader didn't say (`suggestWho`), asked after the proposal is made so the review
    /// opens at once: each suggestion goes into the proposal as it comes, for an item still meant for no one that you
    /// didn't leave so, and into an open review (`suggestedRevision`). At most `suggestAtMost` items, `suggestSeconds`.
    func suggestLater(_ record: DistillRecord, binder: UUID?) {
        let asked = Array(record.items.filter { $0.meantFor == nil && $0.meantForHow != "you" && $0.card == nil && !$0.dropped }.prefix(Self.suggestAtMost))
        guard !asked.isEmpty, controller?.router != nil else { return }
        suggesting.insert(record.id)
        let started = Date()
        suggestTasks[record.id] = Task { [weak self] in
            for item in asked {
                guard let self, !Task.isCancelled, Date().timeIntervalSince(started) < Self.suggestSeconds else { break }
                var one = [item]
                guard await self.suggestWho(&one, binder: binder) > 0, let who = one.first?.meantFor else { continue }
                self.suggested(who, how: one.first?.meantForHow ?? "model", item: item.id, distill: record.id, note: record.note)
            }
            guard let self else { return }
            self.suggesting.remove(record.id)
            self.suggestTasks[record.id] = nil
            self.suggestedRevision += 1
        }
    }

    /// One suggestion, into the proposal as kept, unless the item was given someone, placed or dropped meanwhile.
    private func suggested(_ who: String, how: String, item: UUID, distill: UUID, note: UUID) {
        guard var record = store.distill(distill, of: note), let index = record.items.firstIndex(where: { $0.id == item }) else { return }
        let current = record.items[index]
        guard current.meantFor == nil, current.meantForHow != "you", current.card == nil, !current.dropped else { return }
        record.items[index].meantFor = who
        record.items[index].meantForHow = how
        store.save(record)
        suggestedRevision += 1
    }

    /// Until the decision model is done with a distill's items (the self-tests).
    func suggestionsDone(_ distill: UUID) async {
        await suggestTasks[distill]?.value
    }

    // MARK: Warming the Distill model

    /// Lane DS8: a note with Distill on was opened (its Work bar showed): the Distill model loads in the background, so the
    /// first reading doesn't wait for it, when nothing is being recorded or dictated, it's a model running in Binders that
    /// isn't loaded, and it fits beside the models in memory without freeing one (the dictation model stays,
    /// `MLXRuntime.warm`). Never for a note without Distill. Dictating stops it (`cancelWarm`).
    func warm(for note: NoteItem) {
        guard note.distill, warming == nil, !busy(), let client = model(), client.place == .inApp else { return }
        let id = note.id
        warming = Task { [weak self] in
            let loaded = await client.warmBeside()
            guard let self else { return }
            self.warming = nil
            if loaded, !Task.isCancelled { self.warmedFor.append(id) }
        }
    }

    /// Dictating, or a recording, started: a warm-up under way stops, quietly.
    func cancelWarm() {
        warming?.cancel()
        warming = nil
    }

    /// Whether something is being recorded or dictated now.
    func busy() -> Bool {
        if let busyOverride { return busyOverride() }
        guard let controller else { return true }
        if case .idle = controller.phase {} else { return true }
        return controller.meetings.isRecording || controller.allDay.inConversation
    }
}

// MARK: - Briefs written later

/// A card placed from a v2 item, waiting for its brief (lane DS8): what the ask is written from, and the agent it goes to
/// once it's written, when it goes to one.
struct DistillBriefJob: Equatable {
    var card: UUID
    var title: String
    var noteTitle: String
    var section: String?
    var lines: String
    var agent: String?
}

extension DistillService {
    /// How long one brief may take: its first words within 3 minutes (it waits behind other background work), a minute
    /// between words, 4 minutes in all. Past it, the card keeps its lines, and an agent's hand-off goes on without it.
    static let briefPace = StreamPace(firstWords: 180, idle: 60, ceiling: 240)

    /// The job for a card placed from `item`, when its brief is still the note's lines.
    func briefJob(_ item: DistillItem, card: TaskCard, noteTitle: String, agent: String?) -> DistillBriefJob {
        DistillBriefJob(card: card.id, title: card.title, noteTitle: noteTitle, section: item.section, lines: item.brief, agent: agent)
    }

    /// Writes the cards' briefs one after another, in the background lane, those an agent waits for first: never
    /// blocking the board or the review.
    func writeBriefs(_ jobs: [DistillBriefJob]) {
        guard !jobs.isEmpty else { return }
        for job in jobs where job.agent != nil {
            writingBrief[job.card] = job.agent
            controller?.agents.say(job.card, "Writing the brief for \(job.agent!)…")
        }
        // Those an agent waits for first, each group in the order placed.
        let all = briefsWaiting + jobs
        briefsWaiting = all.filter { $0.agent != nil } + all.filter { $0.agent == nil }
        guard briefQueue == nil else { return }
        briefQueue = Task { [weak self] in
            while let self, !self.briefsWaiting.isEmpty {
                let job = self.briefsWaiting.removeFirst()
                await self.writeBrief(job)
            }
            self?.briefQueue = nil
        }
    }

    /// Until every brief waiting is written (the self-tests).
    func briefsDone() async {
        while let queue = briefQueue { await queue.value }
    }

    /// One card's brief: asked, then put on the card unless you changed its description since it was placed; the card
    /// keeps the note's lines when the ask fails, with one quiet line on its history. Then the hand-off it waited for.
    private func writeBrief(_ job: DistillBriefJob) async {
        var written: (brief: String, doneWhen: String)?
        if let client = briefModel() {
            let user = DistillBriefs.user(title: job.title, noteTitle: job.noteTitle, section: job.section, lines: job.lines)
            let schema = Self.holdsToSchema ? ReplySchema(name: "brief", bounded: DistillBriefs.schema, portable: DistillBriefs.schema,
                                                          answerTokens: DistillBriefs.maxTokens) : nil
            if let reply = try? await client.paced(system: DistillBriefs.system, user: user, maxTokens: DistillBriefs.maxTokens, temperature: 0.2,
                                                   pace: Self.briefPace, schema: schema, stopWhen: { _ in false }) {
                written = DistillBriefs.read(reply.text)
            }
        }
        guard let board, let card = board.card(job.card) else {
            writingBrief[job.card] = nil
            return
        }
        var from = card.distilledFrom
        let unchanged = from?.briefFor == DistillSections.hash(card.details)
        if let written, unchanged {
            board.edit(card, details: DistillCards.updating(card.details, brief: written.brief, doneWhen: written.doneWhen), by: BoardService.binders)
        } else if written == nil, unchanged {
            board.note(card, text: "Binders' model couldn't write a brief for this card, so it keeps the note's lines it came from.")
        }
        from?.briefFor = nil
        from?.briefAgent = nil
        card.distilledFrom = from
        Store.shared.save()
        boardRevision += 1
        // The hand-off it waited for, as Place on Board would have made it.
        if let agent = job.agent {
            writingBrief[job.card] = nil
            controller?.agents.say(job.card, nil)
            if card.meantFor == nil, card.column != .done { board.assign(card, to: agent, by: .you) }
        }
    }

    /// Cards whose brief was still to be written when Binders last quit: written now, an agent's hand-off after it.
    func resumeBriefs() {
        guard let board else { return }
        var jobs: [DistillBriefJob] = []
        for note in DistillBoard.notes(in: nil) {
            for card in DistillBoard.cards(of: note.id) where card.distilledFrom?.briefFor != nil {
                let from = card.distilledFrom
                let item = from.flatMap { from in store.distill(from.distill, of: note.id)?.items.first { $0.id == from.item } }
                jobs.append(DistillBriefJob(card: card.id, title: card.title, noteTitle: note.title, section: from?.section,
                                            lines: item?.brief ?? from?.quote ?? card.title, agent: from?.briefAgent))
            }
        }
        writeBriefs(jobs)
    }
}
