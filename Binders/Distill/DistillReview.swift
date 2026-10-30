import AppKit
import SwiftUI
import BindersKit

/// The review sheet: every proposed item editable (title, brief, done when, section, what it waits for, size, who it's
/// meant for), with merge, split, drop and reorder; then Place on Board, in Ready or Backlog, for the ticked items only.
/// Nothing reaches the board before it. Distill again's offers sit below: briefs to bring up to date with a section that
/// changed, and cards to close whose section is gone.
struct DistillReviewSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var distill: DistillRecord
    let note: NoteItem
    /// The items placed with Place on Board.
    @State private var chosen: Set<UUID>
    @State private var column: BoardColumn = .ready
    /// Distill again's offers to take.
    @State private var taking: Set<UUID> = []
    @State private var placedLine: String?
    /// Suggest Who Again is asking the decision model (lane AS1), and what it found.
    @State private var suggesting = false
    @State private var suggestedLine: String?

    init(distill: DistillRecord, note: NoteItem) {
        _distill = State(initialValue: distill)
        _chosen = State(initialValue: Set(distill.waiting.map(\.id)))
        self.note = note
    }

    /// The items still to review, in their order.
    private var open: [Int] { distill.items.indices.filter { distill.items[$0].card == nil && !distill.items[$0].dropped } }
    private var offers: [DistillUpdate] { distill.updates.filter { $0.taken == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if open.isEmpty, offers.isEmpty {
                        Text(placedLine ?? "Everything in this proposal is on the board or left out.").foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(Array(open.enumerated()), id: \.element) { position, index in
                        // It may wait for any other item still in play: one to place, or one on the board already.
                        DistillItemEditor(item: $distill.items[index], number: position + 1, note: note.id, chosen: chosenBinding(distill.items[index].id),
                                          others: distill.items.indices.filter { $0 != index && !distill.items[$0].dropped }.map { distill.items[$0] },
                                          sections: DistillSections.sections(of: note.text).compactMap(\.heading),
                                          people: people(for: distill.items[index]),
                                          pickedBy: DistillMeantFor.pickedLine(how: distill.items[index].meantForHow, meantFor: distill.items[index].meantFor,
                                                                               readBy: distill.readBy, readByAgent: distill.readByAgent),
                                          wouldCircle: { wouldCircle(distill.items[index].id, with: $0) },
                                          actions: actions(for: index, position: position))
                    }
                    if !offers.isEmpty { offersList }
                    let placed = distill.items.filter { $0.card != nil }
                    if !placed.isEmpty {
                        Text(placed.count == 1 ? "1 item is on the board already." : "\(placed.count) items are on the board already.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 860, height: 640)
        .pageGround()
        .onDisappear { controller.distill.save(distill) }
        // Lane DS8: who the decision model suggests comes after the sheet opens, into the items still meant for no one.
        .onChange(of: controller.distill.suggestedRevision) { takeSuggestions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Work items from “\(note.title)”").font(BindersTheme.cardTitle).lineLimit(1)
                Spacer()
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction).help("Close it: the proposal waits on the Work bar.")
            }
            Text("Read by \(distill.readByLine) \(distill.at.formatted(.relative(presentation: .named)))\(Self.partsLine(distill)). Nothing goes on the board until you place it; change anything first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let why = distill.readNote ?? controller.distill.problems[note.id] {
                StatusLabel(why, .waiting).font(.caption)
            }
            if distill.readByAgent {
                Label("\(distill.readBy)'s words: read them before they become cards' briefs.", systemImage: BindersTheme.agentSymbol)
                    .font(.caption)
                    .foregroundStyle(BindersTheme.agent)
            }
            whoLines
        }
        .padding(16)
    }

    /// The open items meant for no one that you didn't leave so: what Suggest Who Again asks about.
    private var unassigned: [Int] { open.filter { distill.items[$0].meantFor == nil && distill.items[$0].meantForHow != "you" } }

    /// Lane AS1: agents Distill can only guess about, with the way to Settings → Agents; and Suggest Who Again for the
    /// items meant for no one.
    @ViewBuilder private var whoLines: some View {
        if let line = DistillMeantFor.noPurposeLine(controller.distill.withoutPurpose(in: note.binderID)) {
            HStack(spacing: 6) {
                StatusLabel(line, .waiting).font(.caption)
                Button("Open Settings → Agents") {
                    // The proposal waits on the Work bar, as with Not Now.
                    controller.distill.save(distill)
                    dismiss()
                    HubWindowController.shared.navigation.pendingSettingsPage = .agents
                    HubWindowController.shared.show(section: .settings)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        let suggesting = suggesting || controller.distill.suggesting.contains(distill.id)
        if !unassigned.isEmpty || suggesting || suggestedLine != nil {
            HStack(spacing: 8) {
                if !unassigned.isEmpty || suggesting {
                    Button("Suggest Who Again") { suggestAgain() }
                        .controlSize(.small)
                        .disabled(suggesting)
                        .help("Ask the decision model again, with your agents as they are now, who the items meant for no one are for. What you chose stays.")
                }
                if suggesting {
                    ProgressView().controlSize(.small)
                    Text("Asking the decision model…").font(.caption).foregroundStyle(.secondary)
                } else if let suggestedLine {
                    Text(suggestedLine).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Suggest Who Again: the decision model asked for the open items meant for no one; what it suggests fills only those
    /// still meant for no one when it answers, so nothing you chose meanwhile changes.
    private func suggestAgain() {
        let asked = unassigned.map { distill.items[$0] }
        guard !asked.isEmpty else { return }
        suggesting = true
        suggestedLine = nil
        Task {
            let result = await controller.distill.suggestAgain(asked, binder: note.binderID)
            var filled = 0
            for item in result.items where item.meantFor != nil {
                guard let index = distill.items.firstIndex(where: { $0.id == item.id }),
                      distill.items[index].meantFor == nil, distill.items[index].meantForHow != "you" else { continue }
                distill.items[index].meantFor = item.meantFor
                distill.items[index].meantForHow = item.meantForHow
                filled += 1
            }
            suggesting = false
            suggestedLine = Self.suggestedLine(filled: filled, asked: asked.count)
        }
    }

    /// The decision model's suggestions made after the proposal (lane DS8, `DistillService.suggestLater`), as kept: each
    /// into an item here still meant for no one that you didn't leave so.
    private func takeSuggestions() {
        guard let stored = DistillStore.shared.distill(distill.id, of: note.id) else { return }
        for item in stored.items where item.meantFor != nil {
            guard let index = distill.items.firstIndex(where: { $0.id == item.id }), distill.items[index].meantFor == nil,
                  distill.items[index].meantForHow != "you" else { continue }
            distill.items[index].meantFor = item.meantFor
            distill.items[index].meantForHow = item.meantForHow
        }
    }

    /// What Suggest Who Again found, in a sentence.
    static func suggestedLine(filled: Int, asked: Int) -> String {
        if filled == 0 {
            return "The decision model had no suggestion: it wasn't sure, or isn't set up in Settings → AI. Choose who in For."
        }
        let items = filled == 1 ? "1 item" : "\(filled) items"
        return filled == asked ? "Suggested who for \(items)." : "Suggested who for \(items) of \(asked); choose who for the rest in For."
    }

    /// ", in 4 parts, as the note is long": how a long note was read (lane DS2); nothing for one read whole.
    static func partsLine(_ distill: DistillRecord) -> String {
        guard let parts = distill.parts, parts > 1 else { return "" }
        return ", in \(parts) parts, as the note is long"
    }

    /// Distill again's offers: a brief to update, a card to close.
    private var offersList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cards already on the board").font(.callout.weight(.semibold)).foregroundStyle(.sectionInk).padding(.top, 8)
            ForEach(offers) { update in
                let card = controller.board.card(update.card)
                HStack(alignment: .top, spacing: 10) {
                    Toggle("", isOn: Binding(get: { taking.contains(update.id) }, set: { if $0 { taking.insert(update.id) } else { taking.remove(update.id) } }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card?.title ?? "A card that's gone").font(.callout.weight(.medium))
                        switch update.kind {
                        case .brief:
                            Text("Its section, \(update.section ?? DistillSections.openingTitle), changed. Update its brief to:").font(.caption).foregroundStyle(.secondary)
                            Text(update.brief.isEmpty ? "(no brief)" : update.brief).font(.caption).padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(BindersTheme.surface))
                        case .close:
                            Text("Its section, \(update.section ?? DistillSections.openingTitle), is gone from the note. Close the card (it goes to Done, counted as closed).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        let placing = open.map { distill.items[$0] }.filter { chosen.contains($0.id) }
        let warnings = loseWaits(placing)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(warnings, id: \.self) { warning in StatusLabel(warning, .waiting).font(.caption) }
            if let placedLine { StatusLabel(placedLine, .done).font(.callout) }
            HStack {
                Picker("Place in", selection: $column) {
                    Text("Ready").tag(BoardColumn.ready)
                    Text("Backlog").tag(BoardColumn.backlog)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Ready hands each card to the agent it's meant for, once what it waits for is done. Backlog keeps them for later.")
                Spacer()
                Button("Put Aside", role: .destructive) {
                    // Kept as put aside: the sheet saves its copy as it closes.
                    distill.status = .dismissed
                    controller.distill.save(distill)
                    dismiss()
                }
                .help("Leave the rest of this proposal out. What's on the board stays.")
                Button(placeTitle(placing.count)) { place(placing) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(placing.isEmpty && taking.isEmpty)
            }
        }
        .padding(12)
    }

    private func placeTitle(_ count: Int) -> String {
        let changes = taking.count
        switch (count, changes) {
        case (0, 0): return "Place on Board"
        case (_, 0): return count == 1 ? "Place 1 on Board" : "Place \(count) on Board"
        case (0, _): return changes == 1 ? "Apply 1 Change" : "Apply \(changes) Changes"
        default: return "Place \(count) and Apply \(changes)"
        }
    }

    private func place(_ placing: [DistillItem]) {
        controller.distill.save(distill)
        for update in offers where taking.contains(update.id) { controller.distill.take(update, of: distill) }
        for update in offers where !taking.contains(update.id) && !placing.isEmpty { controller.distill.leave(update, of: distill) }
        let cards = controller.distill.place(distill, items: Set(placing.map(\.id)), column: column)
        distill = DistillStore.shared.distill(distill.id, of: note.id) ?? distill
        chosen = Set(distill.waiting.map(\.id))
        taking = []
        let binder = Store.shared.binder(note.binderID)?.name ?? "the"
        placedLine = cards.isEmpty ? "Done." : "Placed \(cards.count == 1 ? "1 card" : "\(cards.count) cards") on the \(binder) board, in \(column.title)."
        if distill.waiting.isEmpty, offers.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
        }
    }

    /// Waits on items not placed now and not on the board from before: left out, which the sheet says before you place.
    private func loseWaits(_ placing: [DistillItem]) -> [String] {
        let placingIDs = Set(placing.map(\.id))
        let onBoard = Set(DistillStore.shared.file(for: note.id).distills.flatMap(\.items).filter { $0.card != nil }.map(\.id))
        return placing.compactMap { item in
            let lost = item.waitsFor.filter { !placingIDs.contains($0) && !onBoard.contains($0) }
            guard let first = lost.first, let other = distill.items.first(where: { $0.id == first }) else { return nil }
            return "“\(item.title)” waits for “\(other.title)”, which you're not placing now: that wait is left out."
        }
    }

    private func chosenBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { chosen.contains(id) }, set: { if $0 { chosen.insert(id) } else { chosen.remove(id) } })
    }

    /// Who an item can be meant for: your agents that take the binder's cards, you, or no one; the team's people too: the
    /// team folder's members for a binder shared through it (`DistillService.people(for:)`, as a name in
    /// `for` is matched); and whoever it's meant for now, if that's someone else.
    private func people(for item: DistillItem) -> [String] {
        var names = controller.distill.people(for: note.binderID)
        if let current = item.meantFor, !names.contains(current) { names.append(current) }
        return names
    }

    /// Whether `item` waiting for these would put an item in a circle.
    private func wouldCircle(_ item: UUID, with waits: [UUID]) -> Bool {
        let graph = Dictionary(distill.items.map { ($0.id.uuidString, $0.waitsFor.map(\.uuidString)) }, uniquingKeysWith: { a, _ in a })
        return CardWaits.makesCycle(card: item.uuidString, waitsFor: waits.map(\.uuidString), graph: graph)
    }

    // MARK: Merge, split, drop, reorder

    private func actions(for index: Int, position: Int) -> DistillItemEditor.Actions {
        DistillItemEditor.Actions(
            up: position > 0 ? { move(index, to: open[position - 1]) } : nil,
            down: position + 1 < open.count ? { move(index, to: open[position + 1]) } : nil,
            split: { split(index) },
            mergeWithNext: position + 1 < open.count ? { merge(index, with: open[position + 1]) } : nil,
            drop: { drop(index) })
    }

    private func move(_ index: Int, to other: Int) {
        distill.items.swapAt(index, other)
    }

    /// A copy of the item below it, to divide the work between the two.
    private func split(_ index: Int) {
        var copy = distill.items[index]
        copy.id = UUID()
        copy.title += " (part 2)"
        distill.items.insert(copy, at: index + 1)
        chosen.insert(copy.id)
    }

    /// The next item folded into this one: its brief and done when after this one's, what it waits for added, and what
    /// waited for it waiting for this one.
    private func merge(_ index: Int, with next: Int) {
        let other = distill.items[next]
        var item = distill.items[index]
        item.brief = [item.brief, other.brief].filter { !$0.isEmpty }.joined(separator: "\n\n")
        item.doneWhen = [item.doneWhen, other.doneWhen].filter { !$0.isEmpty }.joined(separator: " ")
        item.waitsFor = Array(Set(item.waitsFor + other.waitsFor).subtracting([item.id, other.id]))
        distill.items[index] = item
        for position in distill.items.indices where distill.items[position].waitsFor.contains(other.id) {
            distill.items[position].waitsFor = Array(Set(distill.items[position].waitsFor.map { $0 == other.id ? item.id : $0 })
                .subtracting([distill.items[position].id]))
        }
        distill.items.remove(at: next)
        chosen.remove(other.id)
    }

    /// Left out: nothing waits for it any more.
    private func drop(_ index: Int) {
        let id = distill.items[index].id
        distill.items[index].dropped = true
        chosen.remove(id)
        for position in distill.items.indices { distill.items[position].waitsFor.removeAll { $0 == id } }
    }
}

/// One proposed item, every part of it editable.
struct DistillItemEditor: View {
    struct Actions {
        var up: (() -> Void)?
        var down: (() -> Void)?
        var split: () -> Void
        var mergeWithNext: (() -> Void)?
        var drop: () -> Void
    }

    @Environment(DictationController.self) private var controller
    @Binding var item: DistillItem
    let number: Int
    /// The note it's read from, for the link to its section.
    let note: UUID
    @Binding var chosen: Bool
    /// The other items it could wait for.
    let others: [DistillItem]
    let sections: [String]
    let people: [String]
    /// Who picked who it's for, in a few words (`DistillMeantFor.pickedLine`), or nil.
    var pickedBy: String? = nil
    let wouldCircle: ([UUID]) -> Bool
    let actions: Actions

    /// Where the item's section link goes: its heading in the note, the link its card will carry back
    /// (`DistillLinks.section`), or the note's top for its opening.
    static func sectionLink(note: UUID, section: String?) -> URL? {
        URL(string: DistillLinks.section(note: note, heading: section))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $chosen).labelsHidden().toggleStyle(.checkbox).help("Place this one with Place on Board")
            Text("\(number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                TextField("What to do", text: $item.title).textFieldStyle(.plain).font(.body.weight(.semibold))
                TextField("Brief: what and why", text: $item.brief, axis: .vertical).lineLimit(1...5).textFieldStyle(.plain).font(.callout)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Done when").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("what anyone can check", text: $item.doneWhen, axis: .vertical).lineLimit(1...3).textFieldStyle(.plain).font(.callout)
                }
                HStack(spacing: 8) {
                    Picker("Section", selection: $item.section) {
                        Text(DistillSections.openingTitle).tag(String?.none)
                        ForEach(sections, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .frame(maxWidth: 230)
                    // Its heading in the note, as the placed card's link back goes.
                    Button {
                        if let url = Self.sectionLink(note: note, section: item.section) { URLCommands.handle(url, controller: controller) }
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .themedLink()
                    .help(item.section.map { "Show the “\($0)” section in the note" } ?? "Show the note's opening")
                    .accessibilityLabel(item.section.map { "Show the \($0) section in the note" } ?? "Show the note's opening")
                    Menu {
                        ForEach(others) { other in
                            let waiting = item.waitsFor.contains(other.id)
                            Button {
                                if waiting { item.waitsFor.removeAll { $0 == other.id } } else { item.waitsFor.append(other.id) }
                            } label: {
                                Label(other.title + (other.card != nil ? " (on the board)" : ""), systemImage: waiting ? "checkmark" : "circle")
                            }
                            .disabled(!waiting && wouldCircle(item.waitsFor + [other.id]))
                        }
                    } label: {
                        Text(waitsLabel).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: 240)
                    .help("The items this one waits for: an agent can't take its card until theirs are done. One that would wait for itself can't be chosen.")
                    Picker("Size", selection: $item.size) {
                        Text("No size").tag(DistillItem.Size?.none)
                        ForEach(DistillItem.Size.allCases, id: \.self) { Text($0.title).tag(DistillItem.Size?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("For", selection: Binding(get: { item.meantFor ?? "" }, set: {
                        item.meantFor = $0.isEmpty ? nil : $0
                        item.meantForHow = "you"
                    })) {
                        Text("No one yet").tag("")
                        ForEach(people, id: \.self) { Text($0 == BoardActor.you.name ? "You" : $0).tag($0) }
                    }
                    .frame(maxWidth: 200)
                    if let pickedBy {
                        Text(pickedBy).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .controlSize(.small)
            }
            VStack(spacing: 2) {
                Button { actions.up?() } label: { Image(systemName: "chevron.up") }.disabled(actions.up == nil).help("Move up")
                Button { actions.down?() } label: { Image(systemName: "chevron.down") }.disabled(actions.down == nil).help("Move down")
                Menu {
                    Button("Split", action: actions.split)
                    Button("Merge with Next") { actions.mergeWithNext?() }.disabled(actions.mergeWithNext == nil)
                    Divider()
                    Button("Drop", role: .destructive, action: actions.drop)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Split, merge or drop it")
            }
            .buttonStyle(.borderless)
            .quietControl()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(BindersTheme.surface).opacity(chosen ? 1 : 0.5))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(BindersTheme.line))
    }

    private var waitsLabel: String {
        let titles = others.filter { item.waitsFor.contains($0.id) }.map(\.title)
        guard !titles.isEmpty else { return "Waits for nothing" }
        return "Waits for " + titles.prefix(2).map { "“\($0)”" }.joined(separator: ", ") + (titles.count > 2 ? " +\(titles.count - 2)" : "")
    }
}
