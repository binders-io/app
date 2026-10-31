import AppKit
import Observation
import SwiftUI
import BindersKit

// Lane DS9: the Distill list beside the note, in place of the review sheet: one row per item, in the note's order, as
// they're read; accept places one on the board as Place on Board does, dismiss leaves it out for good, both with Undo. The
// rows are the note's proposals still waiting, and while you read the note, the items the model has written so far.

/// One row of the Distill list: an item of a proposal still waiting, or one being read (`record` nil until the proposal is
/// made).
struct DistillListRow: Identifiable, Equatable {
    var item: DistillItem
    var record: UUID?
    /// Distill Again's offer for a card already on the board (a brief to bring up to date, a card to close), shown as a row
    /// whose item is the card: accepting takes it, dismissing lets it be.
    var offer: DistillUpdate? = nil
    var id: UUID { item.id }
    /// Still being read: it can be looked at, and Return or Delete on it is kept for when the reading is done.
    var live: Bool { record == nil }
}

/// A note's Distill list, shared by every place the note shows: what's selected, hovered and open for editing, what was just
/// placed (with Undo), the items readings in the background found that you haven't looked at, and the cards in flight.
@MainActor
@Observable
final class DistillListModel {
    let note: UUID
    var selected: UUID?
    var hovered: UUID?
    var editing: UUID?
    /// "Placed on Web · Undo", for a while after accepting.
    var placed: [Placed] = []
    /// Items a reading in the background found, not yet looked at: the button's and the Work bar's count.
    var newItems: Set<UUID> = []
    /// "Up to date", on the button for a moment, after a click when nothing changed since the last reading.
    var upToDateUntil: Date?
    /// Return or Delete on a row still being read: done once its proposal is made.
    var pendingAccept: [UUID: BoardColumn] = [:]
    var pendingDismiss: Set<UUID> = []
    /// The column each item goes to, as you chose it while editing: Ready unless you said Backlog.
    var columns: [UUID: BoardColumn] = [:]
    /// When each item of the reading you're watching was found, for its lines' glow.
    var found: [UUID: Date] = [:]
    /// Cards flying from the note into the list (or the button), each setting off a moment after the one before.
    var launches: [Launch] = []
    /// When the reading you're watching started, for the light that sweeps down the part being read.
    var readingSince: Date?
    /// Bumped to ask the list to take the keyboard, when it's opened with Distill.
    var focusRequest = 0
    @ObservationIgnored private var flights = DistillFlights()
    @ObservationIgnored private var seenLive: Set<UUID> = []
    /// Whether a flight's landing is left to the clock (the self-tests draw frames with it held still).
    @ObservationIgnored var landsOnItsOwn = true

    struct Launch: Identifiable, Equatable {
        var id: UUID
        var title: String
        var color: Color
        var start: Date
    }

    struct Placed: Identifiable, Equatable {
        var id = UUID()
        var line: String
        var cards: [UUID]
        var record: UUID
        var items: [UUID]
    }

    init(note: UUID) {
        self.note = note
    }

    // MARK: The rows

    /// The rows, in the note's order: every item still waiting in the note's proposals, and while you read it, the items
    /// written so far. Sections in the note's order; within one, as read.
    func rows(_ service: DistillService, text: String) -> [DistillListRow] {
        let file = DistillStore.shared.file(for: note)
        var rows: [DistillListRow] = []
        var known: Set<UUID> = []
        for record in file.distills where record.status == .proposed {
            for item in record.items where item.card == nil && !item.dropped && known.insert(item.id).inserted {
                rows.append(DistillListRow(item: item, record: record.id))
            }
            for update in record.openUpdates where known.insert(update.id).inserted {
                let title = service.board?.card(update.card)?.title ?? "A card that's gone"
                let item = DistillItem(id: update.id, title: title, brief: update.brief, doneWhen: update.doneWhen, section: update.section, quote: update.quote)
                rows.append(DistillListRow(item: item, record: record.id, offer: update))
            }
        }
        if let live = service.live[note], live.phase == .reading, !service.quietReading.contains(note) {
            for item in live.items where !isRepeat(item, in: file) && known.insert(item.id).inserted { rows.append(DistillListRow(item: item, record: nil)) }
        }
        rows.removeAll { pendingDismiss.contains($0.id) }
        let headings = DistillSections.sections(of: text).map(\.heading)
        func place(_ section: String?) -> Int {
            guard let section else { return 0 }
            return headings.firstIndex { $0 == section }.map { $0 + 1 } ?? Int.max / 2
        }
        return rows.enumerated().sorted { a, b in
            let pa = place(a.element.item.section), pb = place(b.element.item.section)
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Keys

    /// The keys the list answers to.
    enum Key { case up, down, accept, acceptAll, dismiss, edit, escape }

    /// What a key does: the selection moves, a row opens to edit, or items are accepted or dismissed (which the caller does,
    /// with its Undo). After accepting or dismissing, the row below (or above) is selected. Nil: the key isn't the list's.
    enum KeyOutcome: Equatable { case handled, accept([UUID]), dismiss([UUID]) }

    func key(_ key: Key, rows: [DistillListRow]) -> KeyOutcome? {
        if editing != nil {
            guard key == .escape else { return nil }
            editing = nil
            return .handled
        }
        let index = selected.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = index.flatMap { rows.indices.contains($0 + 1) ? rows[$0 + 1].id : rows.indices.contains($0 - 1) ? rows[$0 - 1].id : nil }
        switch key {
        case .down:
            guard !rows.isEmpty else { return nil }
            selected = rows[min(rows.count - 1, (index ?? -1) + 1)].id
            return .handled
        case .up:
            guard !rows.isEmpty else { return nil }
            selected = rows[max(0, (index ?? rows.count) - 1)].id
            return .handled
        case .acceptAll:
            guard !rows.isEmpty else { return nil }
            selected = nil
            return .accept(rows.map(\.id))
        case .accept:
            guard let index else { return nil }
            selected = next
            return .accept([rows[index].id])
        case .dismiss:
            guard let index else { return nil }
            selected = next
            return .dismiss([rows[index].id])
        case .edit:
            guard let index, !rows[index].live, rows[index].offer == nil else { return nil }
            editing = rows[index].id
            return .handled
        case .escape:
            guard selected != nil else { return nil }
            selected = nil
            return .handled
        }
    }

    /// An item being read that an earlier reading already gave, by any reader (on the board, waiting, or dismissed), the
    /// same or in other words (`DistillAgain.alike`): Distill Again leaves it out once the reading is done, so it never
    /// shows, nor flies.
    func isRepeat(_ item: DistillItem, in file: DistillFile? = nil) -> Bool {
        let file = file ?? DistillStore.shared.file(for: note)
        return file.distills.contains { record in
            record.items.contains { other in
                other.id != item.id && ((other.section == item.section && DistillAgain.similarity(other.title, item.title) >= 0.99)
                    || DistillAgain.alike((item.title, item.brief, item.quote), (other.title, other.brief, other.quote)))
            }
        }
    }

    // MARK: Found as it's read

    /// The items written so far of a reading you're watching: each new one glows in the note and sets off as a card, a
    /// moment after the one before.
    func liveItems(_ items: [DistillItem], quiet: Bool, now given: Date? = nil) {
        let now = given ?? DistillMotion.now()
        let file = DistillStore.shared.file(for: note)
        for item in items where seenLive.insert(item.id).inserted {
            guard !quiet, !isRepeat(item, in: file) else { continue }
            found[item.id] = now
            let start = flights.start(at: now)
            launches.append(Launch(id: item.id, title: item.title, color: Self.color(for: item), start: start))
            guard landsOnItsOwn else { continue }
            let landing = start.timeIntervalSince(now) + DistillFlights.duration
            let id = item.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(landing))
                self?.landed(id)
            }
        }
    }

    /// A card is in its row: it goes, and the row shows.
    func landed(_ id: UUID) {
        launches.removeAll { $0.id == id }
    }

    /// Whether the item's card is still flying, so its row waits to show.
    func inFlight(_ id: UUID) -> Bool { launches.contains { $0.id == id } }

    /// A new reading starts: what the last one found is old news.
    func readingStarted(now: Date? = nil) {
        readingSince = now ?? DistillMotion.now()
        seenLive = []
        found = [:]
        launches = []
        flights = DistillFlights()
    }

    /// Items a reading in the background found: counted as new until you look at the list.
    func found(_ ids: [UUID]) {
        newItems.formUnion(ids)
    }

    /// You looked at the list: nothing is new any more.
    func looked() {
        if !newItems.isEmpty { newItems = [] }
    }

    // MARK: Who it's for

    /// The colour of who an item is for, as its card wears it: your agents lavender, you the accent, a teammate teal, no
    /// one yet grey. While it's read, before anyone is picked, what the reader said it needs.
    static func color(for item: DistillItem) -> Color {
        if let who = item.meantFor {
            if who == BoardActor.you.name { return BindersTheme.accent }
            if AgentRegistry.shared.agent(named: who) != nil { return BindersTheme.agent }
            return BinderPalette.color(1)
        }
        switch item.hint {
        case .agent: return BindersTheme.agent
        case .person: return BindersTheme.accent
        default: return BindersTheme.muted
        }
    }

    static func nsColor(for item: DistillItem) -> NSColor { NSColor(color(for: item)) }

    /// "You", an agent's short name, a teammate's name, or "No one yet".
    static func who(_ item: DistillItem) -> String {
        guard let who = item.meantFor else { return "No one yet" }
        return who == BoardActor.you.name ? "You" : who.shortAgentName
    }

    // MARK: Accepting and dismissing

    /// Accept: each item placed on the board as Place on Board places it, in the column chosen for it (Ready unless you
    /// said Backlog), with "Placed on <board> · Undo". An item still being read is placed once its proposal is made.
    func accept(_ ids: [UUID], service: DistillService, undo: UndoManager?) {
        guard !ids.isEmpty, let note = Store.shared.note(note) else { return }
        let ids = settleOffers(ids, take: true, service: service)
        guard !ids.isEmpty else { return }
        let file = DistillStore.shared.file(for: note.id)
        var byRecord: [UUID: [UUID]] = [:]
        for id in ids {
            if let record = file.distills.first(where: { $0.status == .proposed && $0.items.contains { $0.id == id && $0.card == nil && !$0.dropped } }) {
                byRecord[record.id, default: []].append(id)
            } else if service.live[note.id]?.items.contains(where: { $0.id == id }) == true {
                pendingAccept[id] = columns[id] ?? .ready
            }
        }
        var cards: [UUID] = []
        var placedItems: [UUID] = []
        var records: [UUID] = []
        var columnsUsed: Set<BoardColumn> = []
        for (recordID, items) in byRecord {
            guard let record = DistillStore.shared.distill(recordID, of: note.id) else { continue }
            // One placing per column, so each card goes where you chose.
            let groups = Dictionary(grouping: items) { columns[$0] ?? .ready }
            for (column, group) in groups {
                let current = DistillStore.shared.distill(recordID, of: note.id) ?? record
                let made = service.place(current, items: Set(group), column: column)
                cards += made.map(\.id)
                if !made.isEmpty { columnsUsed.insert(column) }
            }
            placedItems += items
            records.append(recordID)
        }
        guard !cards.isEmpty else { return }
        let board = Store.shared.binder(note.binderID)?.name ?? "the board"
        let count = cards.count == 1 ? "" : " \(cards.count)"
        let column = columnsUsed == [.backlog] ? ", in Backlog" : ""
        let entry = Placed(line: "Placed\(count) on \(board)\(column)", cards: cards, record: records.first!, items: placedItems)
        placed.append(entry)
        let id = entry.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.placed.removeAll { $0.id == id }
        }
        undo?.registerUndo(withTarget: Store.shared) { [weak self, weak service] _ in
            MainActor.assumeIsolated {
                guard let self, let service else { return }
                self.unplace(entry, service: service)
            }
        }
        undo?.setActionName(cards.count == 1 ? "Accept Item" : "Accept Items")
    }

    /// Distill Again's offers among `ids`, taken (the card's brief brought up to date, or the card closed) or let be, as the
    /// review sheet's do; the other ids, returned.
    private func settleOffers(_ ids: [UUID], take: Bool, service: DistillService) -> [UUID] {
        var rest: [UUID] = []
        let file = DistillStore.shared.file(for: note)
        for id in ids {
            guard let record = file.distills.first(where: { $0.updates.contains { $0.id == id && $0.taken == nil } }),
                  let update = record.updates.first(where: { $0.id == id }) else {
                rest.append(id)
                continue
            }
            if take { service.take(update, of: record) } else { service.leave(update, of: record) }
        }
        return rest
    }

    /// Undo of Accept: the cards it made leave the board, and their items wait in the list again.
    func unplace(_ entry: Placed, service: DistillService) {
        guard let board = service.board else { return }
        for id in entry.cards { if let card = board.card(id) { board.delete(card) } }
        let ids = Set(entry.items)
        DistillStore.shared.update(note) { file in
            for index in file.distills.indices {
                var changed = false
                for item in file.distills[index].items.indices where ids.contains(file.distills[index].items[item].id) {
                    file.distills[index].items[item].card = nil
                    changed = true
                }
                if changed { file.distills[index].status = .proposed }
            }
        }
        placed.removeAll { $0.id == entry.id }
        service.boardRevision += 1
    }

    /// Dismiss: left out quietly, and never proposed again (Distill Again counts it as read). An item still being read is
    /// left out once its proposal is made.
    func dismiss(_ ids: [UUID], service: DistillService, undo: UndoManager?) {
        let ids = settleOffers(ids, take: false, service: service)
        guard !ids.isEmpty else { return }
        var undone: [(record: UUID, item: UUID, waits: [(UUID, [UUID])])] = []
        for id in ids {
            guard let recordID = DistillStore.shared.file(for: note).distills.first(where: { $0.items.contains { $0.id == id } })?.id,
                  var record = DistillStore.shared.distill(recordID, of: note), let index = record.items.firstIndex(where: { $0.id == id }) else {
                pendingDismiss.insert(id)
                continue
            }
            let waits = record.items.filter { $0.waitsFor.contains(id) }.map { ($0.id, $0.waitsFor) }
            record.items[index].dropped = true
            for position in record.items.indices { record.items[position].waitsFor.removeAll { $0 == id } }
            DistillService.finishIfReviewed(&record)
            DistillStore.shared.save(record)
            undone.append((recordID, id, waits))
        }
        service.boardRevision += 1
        guard !undone.isEmpty else { return }
        undo?.registerUndo(withTarget: Store.shared) { [weak self, weak service] _ in
            MainActor.assumeIsolated {
                guard let self, let service else { return }
                for entry in undone {
                    guard var record = DistillStore.shared.distill(entry.record, of: self.note) else { continue }
                    if let index = record.items.firstIndex(where: { $0.id == entry.item }) { record.items[index].dropped = false }
                    for (waiter, waits) in entry.waits { if let index = record.items.firstIndex(where: { $0.id == waiter }) { record.items[index].waitsFor = waits } }
                    record.status = .proposed
                    DistillStore.shared.save(record)
                }
                service.boardRevision += 1
            }
        }
        undo?.setActionName(ids.count == 1 ? "Dismiss Item" : "Dismiss Items")
    }

    /// The reading's proposal is made: Return and Delete pressed on its rows while it was read are done now.
    func proposalMade(service: DistillService, undo: UndoManager?) {
        let file = DistillStore.shared.file(for: note)
        let all = Set(file.distills.flatMap(\.items).map(\.id))
        let accepting = pendingAccept.filter { all.contains($0.key) }
        for (id, column) in accepting { columns[id] = column }
        pendingAccept = pendingAccept.filter { !all.contains($0.key) }
        if !accepting.isEmpty { accept(Array(accepting.keys), service: service, undo: undo) }
        let dismissing = pendingDismiss.filter { all.contains($0) }
        pendingDismiss.subtract(dismissing)
        if !dismissing.isEmpty { dismiss(Array(dismissing), service: service, undo: undo) }
        // The live list's leftovers that never made it into the proposal: forgotten.
        if service.live[note]?.phase != .reading { pendingAccept = [:]; pendingDismiss = [] }
    }

    // MARK: Editing

    /// An item changed in the list (its title, who, size), kept in its proposal.
    func edit(_ id: UUID, _ change: (inout DistillItem) -> Void) {
        guard let recordID = DistillStore.shared.file(for: note).distills.first(where: { $0.items.contains { $0.id == id } })?.id,
              var record = DistillStore.shared.distill(recordID, of: note), let index = record.items.firstIndex(where: { $0.id == id }) else { return }
        change(&record.items[index])
        DistillStore.shared.save(record)
    }

    /// The record an item is in, and its place there.
    private func locate(_ id: UUID) -> (record: DistillRecord, index: Int)? {
        guard let record = DistillStore.shared.file(for: note).distills.first(where: { $0.status == .proposed && $0.items.contains { $0.id == id } }),
              let index = record.items.firstIndex(where: { $0.id == id }) else { return nil }
        return (record, index)
    }

    /// Split: a copy of the item below it, to divide the work between the two, as the review sheet's.
    func split(_ id: UUID) {
        guard let found = locate(id) else { return }
        var record = found.record
        let index = found.index
        var copy = record.items[index]
        copy.id = UUID()
        copy.title += " (part 2)"
        record.items.insert(copy, at: index + 1)
        DistillStore.shared.save(record)
        selected = copy.id
    }

    /// Merge with the next row of the same proposal: its brief and done when after this one's, its waits added, and what
    /// waited for it waiting for this one, as the review sheet's.
    func merge(_ id: UUID, with next: UUID) {
        guard let found = locate(id), let other = found.record.items.firstIndex(where: { $0.id == next }) else { return }
        var record = found.record
        let index = found.index
        let gone = record.items[other]
        var item = record.items[index]
        item.brief = [item.brief, gone.brief].filter { !$0.isEmpty }.joined(separator: "\n\n")
        item.doneWhen = [item.doneWhen, gone.doneWhen].filter { !$0.isEmpty }.joined(separator: " ")
        item.waitsFor = Array(Set(item.waitsFor + gone.waitsFor).subtracting([item.id, gone.id]))
        record.items[index] = item
        for position in record.items.indices where record.items[position].waitsFor.contains(gone.id) {
            record.items[position].waitsFor = Array(Set(record.items[position].waitsFor.map { $0 == gone.id ? item.id : $0 }).subtracting([record.items[position].id]))
        }
        record.items.remove(at: other)
        DistillStore.shared.save(record)
    }

    /// Move Up and Move Down: swapped with the row next to it, when that's of the same proposal and section.
    func move(_ id: UUID, with other: UUID) {
        guard let found = locate(id), let next = found.record.items.firstIndex(where: { $0.id == other }) else { return }
        var record = found.record
        let index = found.index
        record.items.swapAt(index, next)
        DistillStore.shared.save(record)
    }

    /// The row the one at `id` can merge with or swap with in the list, `offset` rows on: of the same proposal, and for a
    /// swap, the same section.
    func neighbour(of id: UUID, offset: Int, in rows: [DistillListRow], sameSection: Bool) -> UUID? {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + offset) else { return nil }
        let row = rows[index], other = rows[index + offset]
        guard !row.live, row.offer == nil, other.offer == nil, other.record == row.record, !sameSection || other.item.section == row.item.section else { return nil }
        return other.id
    }
}

extension DistillService {
    /// The note's Distill list (lane DS9), made the first time it's asked for.
    func list(for note: UUID) -> DistillListModel {
        if let list = lists[note] { return list }
        let list = DistillListModel(note: note)
        lists[note] = list
        return list
    }
}

// MARK: - Distill, from the button, the menu and the list

/// What the Distill button, the Note menu's Distill (⇧⌘D) and the list do.
@MainActor
enum DistillActions {
    /// Posted to open a note's Distill list wherever the note shows, with its "note" (and "popout" for its own window).
    static let show = Notification.Name("BindersDistillListShow")
    /// Posted by the Note menu's Distill: the note in front does what its Distill button does.
    static let fromMenu = Notification.Name("BindersDistillFromMenu")
    /// How long "Up to date" stays on the button.
    static let upToDateFor: TimeInterval = 2.5

    /// The Distill button: the list opens with whatever is known, at once. A note never distilled has Distill turned on and
    /// is read (no separate step); one read before is read again only where it changed, and when nothing did, the list
    /// shows what was kept without asking the model ("Up to date"). A reading in the background of the same note gives way.
    static func press(_ note: NoteItem, controller: DictationController, popout: Bool = false) {
        let service = controller.distill
        let list = service.list(for: note.id)
        open(note.id, popout: popout)
        list.focusRequest += 1
        list.looked()
        if service.reading.contains(note.id), !service.quietReading.contains(note.id) { return }
        guard Store.shared.canSave else { return }
        if !note.distill {
            service.setDistill(true, for: note)
            start(note, controller: controller)
            return
        }
        if service.quietReading.contains(note.id) {
            service.stopReading(note.id)
            Task {
                await service.background.settle()
                start(note, controller: controller)
            }
            return
        }
        // Read before by Binders' model, or by an agent that answered "Distill with…": its sections count as read too.
        let readBefore = DistillStore.shared.file(for: note.id).distills.contains { !$0.readByAgent || $0.requestCard != nil }
        if readBefore, service.model() != nil, !service.hasChangedSections(note: note) {
            list.upToDateUntil = Date().addingTimeInterval(upToDateFor)
            service.said[note.id] = nil
            return
        }
        start(note, controller: controller)
    }

    /// Reads the note (`full`: every section again, Distill Again), its items showing in the list as they come. A problem
    /// is said on the Work bar and in the list, never in a sheet.
    static func start(_ note: NoteItem, controller: DictationController, full: Bool = false) {
        MarkdownEditor.flushAll()
        let service = controller.distill
        service.list(for: note.id).readingStarted()
        Task {
            let result = await service.distill(note, full: full)
            let list = service.list(for: note.id)
            if case .success = result { list.proposalMade(service: service, undo: nil) }
            if case .failure(.unchanged) = result { list.upToDateUntil = Date().addingTimeInterval(upToDateFor) }
        }
    }

    static func open(_ note: UUID, popout: Bool = false) {
        NotificationCenter.default.post(name: show, object: nil, userInfo: ["note": note, "popout": popout])
    }

    /// "Up to date · read 2 minutes ago": what the list says when nothing changed since its last reading, by Binders'
    /// model or by an agent that read the whole note ("read by Scribe 2 minutes ago").
    static func upToDateLine(_ note: UUID, now: Date = Date()) -> String? {
        guard let last = DistillStore.shared.file(for: note).distills.last(where: { !$0.readByAgent || $0.requestCard != nil }) else { return nil }
        let by = last.readByAgent ? " by \(last.readBy.shortAgentName)" : ""
        return "Up to date · read\(by) \(WorkBar.ago(last.at, now: now))"
    }
}

extension DistillListModel {
    /// What the note's editor lights of the list: the rows' lines (while it shows, or a reading you started runs), the
    /// selected and hovered rows, the part being read, and what was just found.
    func editorDistill(service: DistillService, rows: [DistillListRow], stage: DistillStage, accent: NSColor, reduceMotion: Bool,
                       listShown: Bool, select: @escaping (UUID) -> Void) -> EditorDistill {
        let foreground = service.reading.contains(note) && !service.quietReading.contains(note)
        let spots = listShown || foreground ? rows.map { row in
            EditorDistill.Spot(id: row.id, quote: row.item.quote, source: row.item.briefPending == true || row.live ? row.item.brief : nil,
                               section: row.item.section, color: Self.nsColor(for: row.item))
        } : []
        return EditorDistill(spots: spots, selected: listShown ? selected : nil, hovered: listShown ? hovered : nil,
                             reading: foreground ? service.readingLines[note] : nil, readingSince: foreground ? readingSince : nil,
                             found: foreground ? found : [:], accent: accent, reduceMotion: reduceMotion, stage: stage, select: select)
    }
}
