import AppKit
import SwiftData
import SwiftUI
import BindersKit

/// A binder's board: its cards in six columns, dragged between them by you, picked up by agents over MCP. With Group by
/// Note on (lane DS5), each column shows each note's cards together under a header; ⌘-click, ⇧-click, ⌘A and a group's
/// Select All choose several cards, which the bar over the columns acts on at once.
struct BoardView: View {
    @Environment(DictationController.self) private var controller
    @Environment(HubNavigation.self) private var navigation
    @Environment(\.undoManager) private var undoManager
    @Environment(\.binderTint) private var binderTint
    @Bindable var binder: BinderRecord
    @Query private var cards: [TaskCard]
    /// The binder's notes, for Group by Note's titles: read once with the cards, so drawing the board doesn't fetch each
    /// note again on every hover or drag.
    @Query private var notes: [NoteItem]
    @State private var drafting: BoardColumn?
    @State private var draft = ""
    @State private var target: BoardColumn?
    @State private var problem: String?
    /// Folded columns you opened: they stay open until you fold them again.
    @State private var opened: Set<BoardColumn> = []
    /// Group by Note, remembered for each binder's board (lane DS5).
    @AppStorage private var groupByNote: Bool
    @State private var selection = BoardSelection()
    /// Groups you folded, by column and note.
    @State private var foldedGroups: Set<String> = []
    /// What the last action on several cards did, with its Undo.
    @State private var said: Said?
    @State private var deleting: [UUID] = []
    @State private var giving: Giving?
    /// What's being dragged, for the slot in the column it's over: one title, or "3 cards".
    @State private var draggingTitles: [String] = []
    /// The cards being dragged, lifted where they sit while their preview follows the pointer.
    @State private var draggingIDs: Set<UUID> = []
    /// The column a card just landed in, for a short answer there.
    @State private var dropFlash: BoardColumn?
    /// Giving cards to a teammate's agent, waiting for your yes (lane DB2), and the cards.
    @State private var asking: TeamConsent?
    @State private var askingFor: [UUID] = []
    @FocusState private var focused: Bool
    @FocusState private var draftFocused: Bool
    /// For self-tests: the layout the board last drew, and the width it had for it.
    nonisolated(unsafe) static var lastLayout: (layout: BoardLayout, width: Double)?
    /// For self-tests: what the board last showed (lane DS5): the cards selected, and each column's groups with Group by Note on.
    nonisolated(unsafe) static var lastShown: (selection: Set<UUID>, groups: [BoardColumn: [BoardGroups.Group]]?)?
    /// For the board-groups self-test: each card and group header named for FitProbe, to click.
    nonisolated(unsafe) static var probesCards = false
    /// For the window-fit self-test: cards to select as the board opens.
    nonisolated(unsafe) static var selectOnOpen: Set<UUID>?

    /// What an action on several cards said, and whether Undo can put it back.
    struct Said: Equatable {
        let id = UUID()
        let line: String
        let undoable: Bool
    }

    /// Cards to give an agent, waiting for the one question.
    struct Giving: Equatable {
        let ids: [UUID]
        let name: String
    }

    /// For self-tests: what the board shows now.
    private static func record(_ selected: Set<UUID>, _ grouping: Grouping?) {
        lastShown = (selected, grouping.map { model in Dictionary(uniqueKeysWithValues: BoardColumn.allCases.map { ($0, model.groups(in: $0)) }) })
    }

    /// Group by Note's key in the app's defaults, for a binder's board.
    static func groupKey(_ binderID: UUID) -> String { "boardGroupByNote." + binderID.uuidString }

    init(binder: BinderRecord) {
        self.binder = binder
        let id = binder.id
        _cards = Query(filter: #Predicate<TaskCard> { $0.binderID == id }, sort: [SortDescriptor(\TaskCard.position, order: .reverse)])
        _notes = Query(filter: #Predicate<NoteItem> { $0.binderID == id })
        _groupByNote = AppStorage(wrappedValue: false, Self.groupKey(id), store: AppDefaults.store)
    }

    var body: some View {
        let noteTitles = Self.noteTitles(notes)
        let grouping = groupByNote ? Self.grouping(cards, titles: noteTitles) : nil
        let byColumn = Dictionary(grouping: cards, by: { $0.column })
        let _ = Self.record(selection.ids, grouping)
        VStack(alignment: .leading, spacing: 0) {
            // On one row while it fits; short of room, the switches go under the words, then under each other.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    hint
                    Spacer()
                    AddTodosButton(binder: binder)
                    groupSwitch
                    switches
                }
                VStack(alignment: .leading, spacing: 8) {
                    // Under the switches, the words wrap rather than ask for the whole row (lane DS5).
                    hint.modifier(IdealWidthCap(cap: 320))
                    HStack(spacing: 12) {
                        AddTodosButton(binder: binder)
                        groupSwitch
                        Spacer(minLength: 0)
                        switches
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    // Under the switches, the words wrap rather than ask for the whole row (lane DS5).
                    hint.modifier(IdealWidthCap(cap: 320))
                    HStack(spacing: 12) {
                        AddTodosButton(binder: binder)
                        groupSwitch
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        switches
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    // Under the switches, the words wrap rather than ask for the whole row (lane DS5).
                    hint.modifier(IdealWidthCap(cap: 320))
                    AddTodosButton(binder: binder)
                    groupSwitch
                    switches
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 11)
            .background(BindersTheme.ground)
            .overlay(alignment: .bottom) { Divider().opacity(0.55) }
            if binder.agentsMayPlace {
                // What the switch gives up, said where it's on (lane DS1).
                Label("Agents place their work items from Distill straight onto this board, in Ready, without your review: their words are the briefs, and the agents they pick start on them as those agents' switches allow.",
                      systemImage: BindersTheme.agentSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
            // Shared through a team database that's off or out of reach: what waits, what's kept, and what to do (lane DB8).
            TeamReachLine(binderID: binder.id)
            // Several selected (lane DS5): what to do with them all, and what stays as it is.
            if selection.count > 1 {
                let chosen = selectedCards
                SeveralCardsBar(heading: BoardBulkWords.selected(chosen.count), titles: chosen.map(\.title), rules: rules(for: chosen),
                                clear: { withAnimation(BoardDesign.settle) { selection.clear() } }) {
                    severalButtons(chosen, inMenu: false)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let said { saidLine(said) }
            // Columns narrow to fit the window, down to a width a card still reads at. Short of that, Done and then Backlog
            // fold to strips with their counts, so Ready, In progress, and Blocked and Review, the ones waiting on you,
            // show without scrolling sideways.
            GeometryReader { geometry in
                let width = geometry.size.width
                let layout = BoardLayout.fit(width: width, opened: opened)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: layout.spacing) {
                        ForEach(BoardColumn.allCases, id: \.self) { column in
                            if layout.folded.contains(column) {
                                strip(column)
                            } else {
                                // One you opened shows how to fold it again while there's no room for it.
                                let foldable = opened.contains(column)
                                    && BoardLayout.fit(width: width, opened: opened.subtracting([column])).folded.contains(column)
                                self.column(column, width: layout.columnWidth, foldable: foldable, grouping: grouping,
                                            items: byColumn[column] ?? [], noteTitles: noteTitles)
                            }
                        }
                    }
                    .padding(.horizontal, layout.margin)
                    .padding(.bottom, 20)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .onAppear { Self.lastLayout = (layout, width) }
                .onChange(of: layout) { Self.lastLayout = (layout, width) }
            }
            // The board takes the keys once you choose a card on it: ⌘A selects every card, Esc clears, ⌫ deletes, asking.
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onCommand(#selector(NSText.selectAll(_:))) { selectEverything() }
            .onExitCommand { withAnimation(BoardDesign.settle) { selection.clear() } }
            .onDeleteCommand { if !selection.isEmpty { deleting = selectedCards.map(\.id) } }
        }
        // Fill the space the binder gives the board, and no more, so the header above stays put.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Couldn't do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .confirmationDialog(deleteQuestion, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), titleVisibility: .visible) {
            Button(deleting.count == 1 ? "Delete Card" : "Delete \(deleting.count) Cards", role: .destructive) {
                let going = cards(deleting)
                deleting = []
                act(BoardBulk.delete(going, board: controller.board, undoManager: undoManager))
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            let going = cards(deleting)
            Text(BoardBulkWords.deleteMessage(going.count, shared: going.filter { BoardBulk.sharedWithTeam($0, board: controller.board) }.count))
        }
        .confirmationDialog(giving.map { BoardBulkWords.giveQuestion($0.ids.count, to: $0.name) } ?? "",
                            isPresented: Binding(get: { giving != nil }, set: { if !$0 { giving = nil } }), titleVisibility: .visible, presenting: giving) { give in
            Button("Give to \(give.name)") {
                giving = nil
                act(BoardBulk.assign(cards(give.ids), to: .agent(give.name), board: controller.board, undoManager: undoManager))
            }
            Button("Cancel", role: .cancel) {}
        } message: { give in
            Text(BoardBulkWords.giveMessage(give.ids.count, to: give.name))
        }
        .teamConsent($asking) { consent in
            // The yes for a teammate's agent is the one question.
            controller.teamBoard.agree(to: consent.agent)
            act(BoardBulk.assign(cards(askingFor), to: .agent(consent.name), board: controller.board, undoManager: undoManager))
        }
        .onAppear(perform: takePendingSelection)
        .onChange(of: navigation.pendingBoardSelection) { takePendingSelection() }
        // A card that's gone, or moved to another board, leaves the selection.
        .onChange(of: cards.map(\.id)) { _, now in
            withAnimation(BoardDesign.settle) { selection.keep(Set(now)) }
        }
        // Column counts roll once the board has drawn what it first read.
        .settlesAfterAppearing()
        // What the runs Binders started say they're doing, on their cards.
        .followingAgentDoing()
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Drag to move")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Image(systemName: BindersTheme.agentSymbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(BindersTheme.agent)
                .accessibilityHidden(true)
            Text("Agents pick up Ready cards")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drag cards between columns. Agents pick up Ready cards through Binders' MCP server.")
    }

    /// Group by Note (lane DS5), remembered for this board.
    private var groupSwitch: some View {
        Toggle(isOn: $groupByNote) {
            Label("Group by Note", systemImage: "square.stack.3d.down.right")
        }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
            .help("Show each note's cards together in every column, under the note's title and how its work is going. Remembered for this board.")
    }

    @ViewBuilder
    private var switches: some View {
        Toggle("Agents finish cards", isOn: $binder.agentsMayFinish)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("When this is off, an agent's finished card goes to Review for you to check.")
        Toggle("Agents place items", isOn: $binder.agentsMayPlace)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Off: an agent's work items from Distill wait for you to review and place them. On: it places them itself, in Ready, meant for the agents it picked, which start on them as their own switches allow, without you reading them first.")
            .fitProbe("board.header.last")
    }

    private func column(_ column: BoardColumn, width: CGFloat, foldable: Bool, grouping: Grouping?, items allItems: [TaskCard],
                        noteTitles: [UUID: String]) -> some View {
        var items = allItems
        let count = items.count
        if column == .done { items = Array(items.prefix(30)) }
        // With Group by Note on: each note's cards under its header, in the board's order of notes; Done keeps to 30 cards.
        let groups = grouping.map { Self.shown($0.groups(in: column), cards: $0.byID, limit: column == .done ? 30 : nil) }
        let order = groups.map { list in list.filter { !foldedGroups.contains(foldKey(column, $0.group)) }.flatMap { $0.cards.map(\.id) } } ?? items.map(\.id)
        let accent = BoardDesign.accent(column)
        let dropTint = binderTint?.fill ?? BindersTheme.accent
        let targeted = target == column
        let flashing = dropFlash == column
        // Not grouped: a card that belongs to a note says so, with the note's title, so the way back is visible here too.
        let showNote = grouping == nil
        return VStack(alignment: .leading, spacing: 8) {
            columnHeader(column, count: count, foldable: foldable, accent: accent)
            if drafting == column {
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                    TextField("What needs doing?", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .focused($draftFocused)
                        .onSubmit { create(in: column) }
                        .onExitCommand { drafting = nil; draftFocused = false }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(BindersTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(accent.opacity(0.55)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ScrollView(.vertical) {
                LazyVStack(spacing: BoardDesign.cardGap) {
                    if targeted {
                        BoardDropSlot(column: column, titles: draggingTitles)
                    }
                    if let groups {
                        ForEach(groups) { entry in
                            let key = foldKey(column, entry.group)
                            let open: (() -> Void)? = entry.group.note.map { note in { Self.openNote(note) } }
                            BoardGroupHeader(group: entry.group, folded: foldedGroups.contains(key),
                                             toggle: {
                                                 withAnimation(BoardDesign.drop) {
                                                     if foldedGroups.contains(key) { foldedGroups.remove(key) } else { foldedGroups.insert(key) }
                                                 }
                                             },
                                             selectAll: { selectGroup(entry.group.note) },
                                             openNote: open)
                                // A card dropped on a group goes in it, and into this column.
                                .dropDestination(for: String.self) { ids, _ in
                                    join(ids, group: entry.group, column: column)
                                    return true
                                }
                            if !foldedGroups.contains(key) {
                                ForEach(entry.cards) { card in
                                    tile(card, order: order, noteTitle: card.groupNote.flatMap { noteTitles[$0] } ?? card.sourceTitle,
                                         showNote: false)
                                }
                            }
                        }
                    } else {
                        ForEach(items) { card in
                            tile(card, order: order, noteTitle: card.groupNote.flatMap { noteTitles[$0] } ?? card.sourceTitle,
                                 showNote: showNote)
                        }
                    }
                    if items.isEmpty && drafting != column && !targeted {
                        BoardEmptyColumn(column: column)
                    }
                }
                .filing(order)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: BoardDesign.columnRadius, style: .continuous)
                .fill(BoardDesign.columnFill(column, targeted: targeted, tint: dropTint))
        }
        .overlay {
            RoundedRectangle(cornerRadius: BoardDesign.columnRadius, style: .continuous)
                .strokeBorder(BoardDesign.columnBorder(column, targeted: targeted, tint: dropTint), lineWidth: targeted ? 1.6 : 1)
        }
        .overlay {
            if flashing {
                RoundedRectangle(cornerRadius: BoardDesign.columnRadius, style: .continuous)
                    .strokeBorder(accent.opacity(0.9), lineWidth: 2)
                    .transition(.opacity)
            }
        }
        .shadow(color: targeted ? dropTint.opacity(0.22) : .clear, radius: 16, y: 4)
        .animation(BoardDesign.lift, value: targeted)
        .animation(BoardDesign.flash, value: flashing)
        .dropDestination(for: String.self) { ids, _ in
            move(ids, to: column)
            return true
        } isTargeted: { hovering in
            withAnimation(BoardDesign.settle) {
                target = hovering ? column : (target == column ? nil : target)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    /// A column's name and count, and its fold and add controls: a mark that says what the column means, then the words.
    private func columnHeader(_ column: BoardColumn, count: Int, foldable: Bool, accent: Color) -> some View {
        HStack(spacing: 6) {
            // A glyph in the column's colour, then its name: at 150 pt the name has to keep to one line.
            Image(systemName: BoardDesign.symbol(column))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(column.title)
                .font(.system(size: 15.5, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
            Text("\(count)")
                .font(BoardDesign.columnCount)
                .monospacedDigit()
                .foregroundStyle(accent)
                .rollingCount(count)
            Spacer(minLength: 2)
            if foldable {
                Button { withAnimation(BoardDesign.drop) { _ = opened.remove(column) } } label: {
                    Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .quietControl()
                .help("Fold \(column.title)")
            }
            if column != .done {
                Button {
                    withAnimation(BoardDesign.settle) {
                        drafting = column
                        draft = ""
                        draftFocused = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.borderless)
                .quietControl()
                .help("Add a card to \(column.title)")
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 1)
    }

    /// A card on the board: a click opens it; with ⌘ or ⇧ it's chosen instead (lane DS5). Dragged while it's one of several
    /// chosen, it takes them all.
    private func tile(_ card: TaskCard, order: [UUID], noteTitle: String? = nil, showNote: Bool = false) -> some View {
        let chosen = selection.count > 1 && selection.contains(card.id) ? selectedCards : [card]
        let titles = chosen.map(\.title)
        let ids = Set(chosen.map(\.id))
        return CardTile(card: card, selected: selection.contains(card.id), lifted: draggingIDs.contains(card.id),
                        noteTitle: noteTitle, showNote: showNote)
            .fitProbe(Self.probesCards ? "board.card." + card.id.uuidString : "")
            .onTapGesture { tapped(card, order: order) }
            // ⌘ and ⇧ as the click itself carries them, ahead of the plain click that opens the card.
            .highPriorityGesture(TapGesture().modifiers(.command).onEnded { choose(card, command: true, order: order) }
                .exclusively(before: TapGesture().modifiers(.shift).onEnded { choose(card, shift: true, order: order) }))
            // What the drop slot in the column says, and the lift of what's leaving.
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { value in
                guard abs(value.translation.width) + abs(value.translation.height) > 4 else { return }
                if draggingTitles != titles { draggingTitles = titles }
                if draggingIDs != ids {
                    withAnimation(BoardDesign.lift) { draggingIDs = ids }
                }
            }.onEnded { _ in
                withAnimation(BoardDesign.lift) {
                    draggingTitles = []
                    draggingIDs = []
                }
            })
            .draggable(dragged(card)) { BoardDragPreview(titles: titles, column: card.column) }
            .contextMenu { menu(for: card) }
            .transition(.filed)
    }

    /// Opens the note a group belongs to, from its header on the board.
    static func openNote(_ id: UUID) {
        guard let note = Store.shared.note(id) else { return }
        HubWindowController.shared.navigation.open(note: note)
        HubWindowController.shared.show()
    }

    @ViewBuilder
    private func menu(for card: TaskCard) -> some View {
        if selection.count > 1, selection.contains(card.id) {
            severalButtons(selectedCards, inMenu: true)
        } else {
            Menu("Move to") {
                MoveToBinderItems(current: card.binderID) { target in
                    do { try controller.router.move(card, to: target) } catch { problem = error.localizedDescription }
                }
            }
            // Lane DS5: into a note's group, or out of it; a card made from a note (by Distill, or with Put on Board, lane
            // DS6) stays in its note's.
            if card.noteMembership?.staysInGroup != true, card.distilledFrom?.request != true {
                Menu("Part of") {
                    PartOfItems(binderID: binder.id, current: card.groupNote, canTakeOut: card.groupNote != nil) { note in
                        act(BoardBulk.group([card], into: note, board: controller.board, undoManager: undoManager))
                    }
                }
            }
        }
    }

    /// The bar's buttons, and the same in a selected card's menu, for these cards.
    private func severalButtons(_ chosen: [TaskCard], inMenu: Bool) -> some View {
        let columns = Set(chosen.map(\.column)), notes = Set(chosen.map(\.groupNote))
        return SeveralCardsButtons(count: chosen.count, binderID: binder.id, column: columns.count == 1 ? columns.first : nil,
                                   group: notes.count == 1 ? notes.first ?? nil : nil, inMenu: inMenu,
                                   move: { column in act(BoardBulk.move(chosen, to: column, board: controller.board, undoManager: undoManager)) },
                                   assign: { choice in assign(chosen, choice) },
                                   putIn: { note in act(BoardBulk.group(chosen, into: note, board: controller.board, undoManager: undoManager)) },
                                   delete: { deleting = chosen.map(\.id) })
    }

    /// Assign to: an agent asks once ("Give 5 cards to Claude Code?"), a teammate's agent asks for your yes the first time;
    /// you, a teammate or anyone happen at once, with Undo.
    private func assign(_ chosen: [TaskCard], _ choice: AssignChoice) {
        switch choice {
        case .who(.agent(let name)):
            giving = Giving(ids: chosen.map(\.id), name: name)
        case .who(let who):
            act(BoardBulk.assign(chosen, to: who, board: controller.board, undoManager: undoManager))
        case .teammatesAgent(let agent):
            let consent = controller.teamBoard.consent(for: agent)
            if controller.teamBoard.agreed(to: agent) {
                giving = Giving(ids: chosen.map(\.id), name: consent.name)
            } else {
                askingFor = chosen.map(\.id)
                asking = consent
            }
        }
    }

    /// Says what an action on several cards did, with Undo, for a while; a card it took off the board leaves the selection.
    private func act(_ outcome: BoardBulk.Outcome) {
        let line = Said(line: outcome.line, undoable: outcome.undoable)
        withAnimation { said = line }
        selection.keep(Set(cards.map(\.id)).subtracting(outcome.changed.filter { controller.board.card($0) == nil }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if said == line { withAnimation { said = nil } }
        }
    }

    private func saidLine(_ said: Said) -> some View {
        HStack(spacing: 8) {
            Label(said.line, systemImage: "square.on.square")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if said.undoable {
                Button("Undo") {
                    undoManager?.undo()
                    withAnimation { self.said = nil }
                }
                .controlSize(.small)
                .help("Put them back as they were (⌘Z)")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .transition(.opacity)
    }

    /// What stays as it is when you act on these, a line each, as the several-notes panel says it.
    private func rules(for chosen: [TaskCard]) -> [String] {
        var rules: [String] = []
        let working = chosen.compactMap { BoardBulk.workingOn($0) }
        if working.count == 1, let who = working.first {
            rules.append("1 is being worked on by \(who): it doesn't move or change hands while they have it.")
        } else if working.count > 1 {
            rules.append("\(working.count) are being worked on: they don't move or change hands while someone has them.")
        }
        let distilled = chosen.filter { $0.noteMembership?.tie == .distilled }.count
        if distilled == 1 {
            rules.append("1 was made by Distill: it stays in its note's group.")
        } else if distilled > 1 {
            rules.append("\(distilled) were made by Distill: they stay in their notes' groups.")
        }
        // Lane DS6: made with Put on Board from a note.
        let put = chosen.filter { $0.noteMembership?.tie == .put }.count
        if put == 1 {
            rules.append("1 was put on the board from its note: it stays in that note's group.")
        } else if put > 1 {
            rules.append("\(put) were put on the board from their notes: they stay in their notes' groups.")
        }
        let shared = chosen.filter { BoardBulk.sharedWithTeam($0, board: controller.board) }.count
        if shared == 1 {
            rules.append("1 is on the team's board: deleting it deletes it for everyone.")
        } else if shared > 1 {
            rules.append("\(shared) are on the team's board: deleting them deletes them for everyone.")
        }
        return rules
    }

    private var deleteQuestion: String {
        let going = cards(deleting)
        return going.count == 1 ? "Delete “\(going[0].title)”?" : BoardBulkWords.deleteQuestion(going.count)
    }

    // MARK: Choosing cards (lane DS5)

    /// The chosen cards, in the board's order.
    private var selectedCards: [TaskCard] { cards.filter { selection.contains($0.id) } }

    private func cards(_ ids: [UUID]) -> [TaskCard] {
        let wanted = Set(ids)
        return cards.filter { wanted.contains($0.id) }
    }

    /// A click on a card: it opens in its own window and the choice clears.
    private func tapped(_ card: TaskCard, order: [UUID]) {
        draggingTitles = []
        draggingIDs = []
        let opened = withAnimation(BoardDesign.settle) {
            selection.click(card.id, command: false, shift: false, column: order)
        }
        if !opened { navigation.open(card: card) }
    }

    /// ⌘-click adds it or takes it away; ⇧-click adds the run from the last one clicked in its column.
    private func choose(_ card: TaskCard, command: Bool = false, shift: Bool = false, order: [UUID]) {
        withAnimation(BoardDesign.settle) {
            selection.click(card.id, command: command, shift: shift, column: order)
        }
        focused = true
    }

    /// ⌘A: every card on this board.
    private func selectEverything() {
        withAnimation(BoardDesign.settle) { selection.select(cards.map(\.id)) }
    }

    /// A group's Select All: its cards in every column of this board; with ⌘, as well as those already chosen.
    private func selectGroup(_ note: UUID?) {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        withAnimation(BoardDesign.settle) {
            selection.select(cards.filter { $0.groupNote == note }.map(\.id), adding: flags.contains(.command))
        }
        focused = true
    }

    /// Select on Board from a note's Work panel, or the window-fit self-test's: those of the cards on this board.
    private func takePendingSelection() {
        let pending = navigation.pendingBoardSelection ?? Self.selectOnOpen
        guard let pending else { return }
        navigation.pendingBoardSelection = nil
        Self.selectOnOpen = nil
        withAnimation(BoardDesign.settle) {
            selection.select(cards.map(\.id).filter { pending.contains($0) })
        }
        focused = true
    }

    /// What dragging a card carries: the card, or, when it's one of several chosen, all of them, their ids with commas.
    private func dragged(_ card: TaskCard) -> String {
        guard selection.count > 1, selection.contains(card.id) else { return card.id.uuidString }
        return selectedCards.map(\.id.uuidString).joined(separator: ",")
    }

    /// The cards a drop carries.
    private func dropped(_ ids: [String]) -> [TaskCard] {
        let wanted = ids.flatMap { $0.split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
        return wanted.compactMap { controller.board.card($0) }
    }

    /// Dropped on a group's header: into that note's group (on "Not from a note", out of its group), and into the column,
    /// as one change one Undo puts back.
    private func join(_ ids: [String], group: BoardGroups.Group, column: BoardColumn) {
        let moving = dropped(ids)
        guard !moving.isEmpty else { return }
        let note = group.note.flatMap { Store.shared.note($0) }
        guard group.note == nil || note != nil else { return problem = "That note isn't on this Mac, so cards can't go in its group." }
        draggingTitles = []
        draggingIDs = []
        withAnimation(BoardDesign.drop) {
            undoManager?.beginUndoGrouping()
            let grouped = BoardBulk.group(moving, into: note, board: controller.board, undoManager: undoManager)
            let off = moving.filter { $0.column != column }
            let moved = off.isEmpty ? nil : BoardBulk.move(off, to: column, board: controller.board, undoManager: undoManager)
            undoManager?.endUndoGrouping()
            let line = [grouped.changed.isEmpty && grouped.stays.isEmpty ? nil : grouped.line, moved?.line].compactMap { $0 }.joined(separator: " ")
            act(BoardBulk.Outcome(changed: grouped.changed + (moved?.changed ?? []), stays: grouped.stays + (moved?.stays ?? []),
                                  line: line.isEmpty ? (moved?.line ?? grouped.line) : line, undoable: grouped.undoable || moved?.undoable == true))
        }
        flash(column)
    }

    /// A short answer on a column where a card just landed.
    private func flash(_ column: BoardColumn) {
        withAnimation(BoardDesign.flash) { dropFlash = column }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            if dropFlash == column { withAnimation(BoardDesign.flash) { dropFlash = nil } }
        }
    }

    private func foldKey(_ column: BoardColumn, _ group: BoardGroups.Group) -> String { column.rawValue + "|" + group.id }

    // MARK: Grouping (lane DS5)

    /// The board's cards as Group by Note reads them, worked out once for every column.
    struct Grouping {
        let cards: [BoardGroups.Card]
        let titles: [UUID: String]
        let byID: [UUID: TaskCard]

        func groups(in column: BoardColumn) -> [BoardGroups.Group] { BoardGroups.groups(in: column, cards: cards, titles: titles) }
    }

    /// `cards` in the board's order. A note's title is the note's own, or the title its cards keep (`sourceTitle`) when it
    /// isn't on this Mac. Read once for the board's own drawing (`titles` comes from its notes), and on its own for a caller
    /// with just the cards, as the self-tests and the Work list do.
    static func grouping(_ cards: [TaskCard]) -> Grouping {
        var titles: [UUID: String] = [:]
        for card in cards {
            guard let note = card.noteMembership?.note, titles[note] == nil else { continue }
            titles[note] = Store.shared.note(note)?.title ?? card.sourceTitle ?? ""
        }
        return grouping(cards, titles: titles)
    }

    /// The same, with the notes' titles already at hand: drawing the board doesn't fetch each note again on every hover.
    static func grouping(_ cards: [TaskCard], titles: [UUID: String]) -> Grouping {
        let read = cards.map { card -> BoardGroups.Card in
            // The note's cards (lane DS6): Distill's, put in by hand, and made with Put on Board, before this build too.
            let member = card.noteMembership
            let note = member?.note
            return BoardGroups.Card(id: card.id, column: card.column, note: note, created: card.createdAt, closed: member?.from?.closed != nil)
        }
        var known = titles
        for card in cards {
            guard let note = card.noteMembership?.note, known[note] == nil else { continue }
            known[note] = card.sourceTitle ?? ""
        }
        return Grouping(cards: read, titles: known, byID: Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    /// The binder's notes by id, for Group by Note's titles.
    static func noteTitles(_ notes: [NoteItem]) -> [UUID: String] {
        Dictionary(notes.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// A group as a column shows it: its header and its cards.
    struct ShownGroup: Identifiable {
        let group: BoardGroups.Group
        let cards: [TaskCard]
        var id: String { group.id }
    }

    /// Each group with its cards, up to `limit` cards in all (Done shows its newest 30).
    static func shown(_ groups: [BoardGroups.Group], cards: [UUID: TaskCard], limit: Int?) -> [ShownGroup] {
        var left = limit ?? .max
        return groups.compactMap { group in
            guard left > 0 else { return nil }
            let shown = Array(group.cards.compactMap { cards[$0] }.prefix(left))
            left -= shown.count
            return shown.isEmpty ? nil : ShownGroup(group: group, cards: shown)
        }
    }

    /// A folded column: its count and its name on its side. A click opens it, and a card dropped on it moves there.
    private func strip(_ column: BoardColumn) -> some View {
        let count = cards.filter { $0.column == column }.count
        let accent = BoardDesign.accent(column)
        let dropTint = binderTint?.fill ?? BindersTheme.accent
        let targeted = target == column
        return Button {
            withAnimation(BoardDesign.drop) { _ = opened.insert(column) }
        } label: {
            VStack(spacing: 9) {
                Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(BoardDesign.columnCount)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(accent.opacity(0.14)))
                    .foregroundStyle(accent)
                    .rollingCount(count)
                Sideways {
                    Text(column.title)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .rotationEffect(.degrees(90))
                }
                Spacer(minLength: 0)
                BoardColumnMark(column: column, size: 18)
            }
            .padding(.vertical, 12)
            .frame(width: BoardLayout.stripWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: BoardDesign.columnRadius, style: .continuous)
                    .fill(BoardDesign.columnFill(column, targeted: targeted, tint: dropTint))
            }
            .overlay {
                RoundedRectangle(cornerRadius: BoardDesign.columnRadius, style: .continuous)
                    .strokeBorder(BoardDesign.columnBorder(column, targeted: targeted, tint: dropTint), lineWidth: targeted ? 1.6 : 1)
            }
            .shadow(color: targeted ? dropTint.opacity(0.22) : .clear, radius: 12, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(column.title)")
        .accessibilityLabel("\(column.title), \(count) \(count == 1 ? "card" : "cards")")
        .accessibilityHint("Opens the column")
        .animation(BoardDesign.lift, value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            move(ids, to: column)
            return true
        } isTargeted: { hovering in
            withAnimation(BoardDesign.settle) {
                target = hovering ? column : (target == column ? nil : target)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func create(in column: BoardColumn) {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        drafting = nil
        draftFocused = false
        guard !title.isEmpty, Store.shared.allowsSave() else { return }
        // Made at once; the agent whose work it is follows a moment later (CardRouter).
        withAnimation(BoardDesign.drop) {
            _ = controller.router.typedCard(title: title, binder: binder, column: column)
        }
        draft = ""
    }

    /// A card dropped on a column moves there; several dropped together move as Move to does, with what stayed and Undo.
    private func move(_ ids: [String], to column: BoardColumn) {
        let moving = dropped(ids)
        draggingTitles = []
        draggingIDs = []
        withAnimation(BoardDesign.drop) {
            if moving.count > 1 {
                act(BoardBulk.move(moving, to: column, board: controller.board, undoManager: undoManager))
            } else {
                for card in moving {
                    do { try controller.board.move(card, to: column, by: .you) } catch { problem = error.localizedDescription }
                }
            }
        }
        target = nil
        // A card someone is working on stays where it is: the column answers only if something landed.
        if moving.contains(where: { $0.column == column }) { flash(column) }
    }
}

/// Its content turned on its side, in the space it takes that way: a folded column's name.
private struct Sideways: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: size.height, height: size.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(subview.sizeThatFits(.unspecified)))
    }
}

/// A card on the board: its title, who has it, when it's due, and anything that needs you. Under the pointer it lifts a
/// little; dragged, it lifts further and its column shows where it will land.
struct CardTile: View {
    let card: TaskCard
    /// One of the cards chosen on the board (lane DS5): the binder's colour round it, a tint over it and a tick.
    var selected = false
    /// Being dragged: lifted and dimmed, while its preview follows the pointer.
    var lifted = false
    /// The note this card belongs to, shown on it when the board isn't grouped by note.
    var noteTitle: String? = nil
    var showNote = false
    @State private var hovering = false

    var body: some View {
        let accent = BoardDesign.accent(card.column)
        let items = metadataItems
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                Text(card.title)
                    .font(BoardDesign.cardTitle)
                    .foregroundStyle(BindersTheme.ink)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    // Chosen, its tick sits in the top corner: the title leaves it room.
                    .padding(.trailing, selected ? 12 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hovering, !selected, !lifted {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(BindersTheme.faint)
                        .padding(.top, 2)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            // What a run Binders started says it's doing between its reports, in its words.
            if card.column == .inProgress, let line = AgentDoingFeed.shared.lines[card.id] {
                DoingLine(agent: card.assignee ?? "The agent", line: line)
            }
            if card.column == .blocked {
                // A question or a request for your approval waits on you: amber. Blocked with a reason, such as a run that
                // stopped before it finished, is a problem: the problem style.
                let approving = card.waitingApproval() != nil
                let asking = approving || card.taskState() == .inputRequired
                if asking {
                    BoardPill(text: approving ? "Approve" : "Answer",
                              symbol: approving ? "checkmark.shield" : "questionmark.bubble",
                              color: BindersTheme.needsYou, strong: true)
                        .help(approving ? "Open it to approve or decline what it asks" : "Open it to answer")
                } else {
                    BoardPill(text: "Blocked: open it", symbol: BindersTheme.problemSymbol, color: BindersTheme.muted)
                        .help("Open it to see why")
                }
            } else if card.column == .review {
                // Finished work waits on you to check it: amber, as a question does.
                BoardPill(text: "Check", symbol: "eye", color: BindersTheme.needsYou, strong: true)
                    .help("Open it to check the work")
            }
            if !items.isEmpty {
                // Wide enough, the facts sit in a row; in a narrow column each keeps to its own line and truncates there.
                ViewThatFits(in: .horizontal) {
                    Wrapping(spacing: 4, lineSpacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            item.view
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            item.view.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, BoardDesign.cardHorizontalInset)
        .padding(.vertical, BoardDesign.cardVerticalInset)
        // Fill the column and no more: at 120 pt the title and its chips wrap and truncate inside it, never beside it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .boardCardSurface(hovered: hovering, lifted: lifted, accent: accent)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: BoardDesign.cardRadius, style: .continuous).fill(TintFill().opacity(0.10))
                RoundedRectangle(cornerRadius: BoardDesign.cardRadius, style: .continuous).strokeBorder(TintFill(), lineWidth: 2)
            }
        }
        .overlay(alignment: .leading) {
            if BoardDesign.needsYou(card.column) || card.column == .inProgress {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.opacity(0.75))
                    .frame(width: 3)
                    .padding(.vertical, 11)
                    .padding(.leading, 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnTintFill(), TintFill())
                    .padding(5)
                    .accessibilityHidden(true)
            }
        }
        .scaleEffect(lifted ? 1.035 : hovering ? 1.012 : 1)
        .opacity(lifted ? 0.92 : 1)
        .animation(BoardDesign.settle, value: hovering)
        .animation(BoardDesign.lift, value: lifted)
        .animation(BoardDesign.settle, value: selected)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        }
        .help("Click to open. Drag to move it to another column.")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The small facts a card carries: who has it, who it's for, when it's due, what it waits for, and its links.
    private struct Meta {
        let view: AnyView
    }

    private var metadataItems: [Meta] {
        var items: [Meta] = []
        if showNote, let noteTitle, !noteTitle.isEmpty {
            let shown = noteTitle.count > 24 ? String(noteTitle.prefix(24)) + "…" : noteTitle
            items.append(Meta(view: AnyView(BoardPill(text: shown, symbol: "square.stack.3d.down.right", color: BindersTheme.muted)
                .help("Part of “\(noteTitle)”"))))
        }
        if let assignee = card.assignee, BoardRules.isClaimed(card.state, at: .now) || card.column == .review || card.column == .done {
            items.append(Meta(view: AnyView(AssigneeChip(name: assignee, isAgent: card.assigneeIsAgent,
                                                         expires: card.column == .inProgress ? card.claimExpiresAt : nil))))
        }
        if let meantFor = card.meantFor, !BoardRules.isClaimed(card.state, at: .now), card.column != .done {
            // An agent's suggestion asks, and waits on you; your own choice says.
            if card.meantForByAgent {
                items.append(Meta(view: AnyView(BoardPill(text: "Give to \(meantFor)?", symbol: "questionmark.circle",
                                                         color: BindersTheme.needsYou, strong: true))))
            } else {
                items.append(Meta(view: AnyView(BoardPill(text: "For \(meantFor)", symbol: "person.crop.circle"))))
            }
        }
        if let due = card.dueAt, card.column != .done {
            let urgent = due < Date() || Calendar.current.isDateInToday(due)
            items.append(Meta(view: AnyView(BoardPill(text: CommitmentService.dueLabel(due), symbol: urgent ? "clock" : nil,
                                                     color: urgent ? BindersTheme.needsYou : BindersTheme.muted))))
        }
        // Lane DS1: it waits for other cards; an agent can't take it until they're done.
        if !card.waitsFor.isEmpty, card.column != .done, let waiting = CardWaitsBadge.count(card), waiting > 0 {
            items.append(Meta(view: AnyView(BoardPill(text: "Waits for \(waiting)", symbol: "hourglass")
                .help(CardWaitsBadge.line(card) ?? ""))))
        }
        if !card.links.isEmpty {
            items.append(Meta(view: AnyView(BoardPill(text: "\(card.links.count)", symbol: "link"))))
        }
        return items
    }
}

/// Who has a card: a person, or an agent, in lavender with its sparkle, with how long its claim has left.
struct AssigneeChip: View {
    let name: String
    let isAgent: Bool
    var expires: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let minutes = expires.flatMap { $0 > context.date && isAgent ? max(1, Int($0.timeIntervalSince(context.date) / 60)) : nil }
            // In a narrow column: the agent without its repository ("Claude Code · harbor-web"), then without the time
            // left, before its name is cut short.
            let short = name.components(separatedBy: " · ").first ?? name
            ViewThatFits(in: .horizontal) {
                chip(name, minutes: minutes)
                if short != name { chip(short, minutes: minutes) }
                if minutes != nil { chip(short, minutes: nil) }
                chip(name, minutes: nil)
            }
        }
    }

    private func chip(_ shown: String, minutes: Int?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: isAgent ? BindersTheme.agentSymbol : "person.fill")
                .font(.system(size: 9, weight: .bold))
            Text(shown).lineLimit(1)
            if let minutes {
                Text("· \(minutes)m").monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
        .font(BoardDesign.cardMeta)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(isAgent ? BindersTheme.agent.opacity(0.16) : BindersTheme.ink.opacity(0.07)))
        .foregroundStyle(isAgent ? BindersTheme.agent : BindersTheme.ink)
        .help(isAgent ? "\(name), an agent, is working on it" : "\(name) is working on it")
    }
}

/// What an agent working on a card says it's doing, in its own words (`AgentDoing`): in lavender with its sparkle, and
/// whose words they are. They're shown, never acted on.
struct DoingLine: View {
    let agent: String
    let line: String
    /// Its name before its words, where nothing beside them says whose they are.
    var named = true
    var lines = 2
    /// The words' colour: lavender, as on the board; the card's own page draws them muted beside the lavender sparkle.
    var words: Color = BindersTheme.agent

    var body: some View {
        let short = agent.components(separatedBy: " · ").first ?? agent
        let spoken = "\(short) says: \(line)"
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: BindersTheme.agentSymbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(BindersTheme.agent)
            (named ? Text(short + ": ").fontWeight(.semibold) + Text(line) : Text(line))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(words)
        }
        .font(.system(size: 11, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("What \(short) says it's doing, in its words, from its own task list. Binders looks every 30 seconds while the card is in progress, and keeps nothing but this line.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }
}

/// One line of a card's timeline.
struct EventRow: View {
    let event: TaskEvent
    /// Where the card is now: finished work is amber only while the card still waits in Review for you to check it.
    var cardColumn: BoardColumn?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.author).font(.caption.weight(.semibold))
                    if event.authorIsAgent { Image(systemName: BindersTheme.agentSymbol).font(.caption2).foregroundStyle(BindersTheme.agent) }
                    Text(headline).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(event.createdAt.formatted(.relative(presentation: .named))).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
                if !event.text.isEmpty {
                    Text(event.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(event.kind == .question || event.kind == .approval ? 8 : 0)
                        .background(event.kind == .question || event.kind == .approval ? RoundedRectangle(cornerRadius: 8).fill(BindersTheme.needsYou.opacity(0.1)) : nil)
                }
            }
        }
    }

    private var column: String { event.toColumn.flatMap(BoardColumn.init(rawValue:))?.title ?? "" }

    private var headline: String {
        switch event.kind {
        case .created: "added it\(column.isEmpty ? "" : " to \(column)")"
        case .moved: "moved it to \(column)"
        case .claimed: "picked it up"
        case .released: "let it go"
        case .lapsed: "went quiet"
        case .progress: "reported progress"
        case .question: "asked"
        case .answer: "answered"
        case .comment: "commented"
        case .completed: column == "Done" ? "finished it" : "finished it, for review"
        case .edited: "edited it"
        case .assigned: "said who it's for"
        case .woke: "was woken"
        case .context: "found this in the binder"
        case .approval: "asks your approval"
        case .decision: "kept the receipt"
        }
    }

    private var symbol: String {
        switch event.kind {
        case .created: "plus.circle"
        case .moved: "arrow.right.circle"
        case .claimed: "hand.raised"
        case .released, .lapsed: "arrow.uturn.backward.circle"
        case .progress: "chart.line.uptrend.xyaxis"
        case .question: "questionmark.bubble"
        case .answer: "text.bubble"
        case .comment: "bubble.left"
        case .completed: "checkmark.circle"
        case .edited: "pencil"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .woke: "bell"
        case .context: "books.vertical"
        case .approval: "checkmark.shield"
        case .decision: "signature"
        }
    }

    private var tint: AnyShapeStyle {
        switch event.kind {
        case .question, .approval: AnyShapeStyle(BindersTheme.needsYou)
        // Green only once it's in Done. Finished for review is amber, as a question, while the card still waits in Review
        // for you to check it; once it's checked (or moved on), that event no longer needs you.
        case .completed:
            if column == BoardColumn.done.title {
                AnyShapeStyle(BindersTheme.done)
            } else if cardColumn == .review {
                AnyShapeStyle(BindersTheme.needsYou)
            } else {
                AnyShapeStyle(.infoText)
            }
        case .lapsed: AnyShapeStyle(.secondary)
        // The accent's; neutral in a binder's card, whose colour is for what you act on.
        default: AnyShapeStyle(.infoText)
        }
    }
}

/// What Binders wrote on a card from its binder ("From your binders"), to change before an agent reads it again, or empty
/// to delete it. Agents that read the card later see it as you leave it.
struct ContextEditor: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let event: TaskEvent
    @State private var text: String

    init(event: TaskEvent) {
        self.event = event
        _text = State(initialValue: event.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From your binders").font(BindersTheme.cardTitle)
            Text("Binders wrote this when the card first went to an agent: passages from notes and meetings in its binder that match it. Agents that read the card see it as you leave it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(BindersTheme.lineStrong))
            HStack {
                Button("Delete", role: .destructive) {
                    controller.board.editContext(event, text: "")
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    controller.board.editContext(event, text: text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// "Add To-dos": the binder's open to-dos that aren't on its board yet, to pick from and turn into cards.
struct AddTodosButton: View {
    @Environment(DictationController.self) private var controller
    let binder: BinderRecord
    @Query private var meetings: [MeetingRecord]
    @Query private var notes: [NoteItem]
    @Query private var commitments: [CommitmentRecord]
    @Query(filter: #Predicate<TaskCard> { $0.sourceRef != nil }) private var linkedCards: [TaskCard]
    @State private var picking = false

    init(binder: BinderRecord) {
        self.binder = binder
        let id = binder.id
        _meetings = Query(filter: #Predicate<MeetingRecord> { $0.binderID == id }, sort: [SortDescriptor(\MeetingRecord.createdAt, order: .reverse)])
        _notes = Query(filter: #Predicate<NoteItem> { $0.binderID == id }, sort: [SortDescriptor(\NoteItem.updatedAt, order: .reverse)])
        _commitments = Query(filter: #Predicate<CommitmentRecord> { $0.binderID == id }, sort: [SortDescriptor(\CommitmentRecord.createdAt, order: .reverse)])
    }

    /// Open to-dos from the binder's meetings, notes and promises, without the ones that already have a card.
    private var waiting: [TaskEntry] {
        let carded = Set(linkedCards.compactMap(\.sourceRef))
        return TaskCollector.collect(meetings: Array(meetings.prefix(60)), notes: Array(notes.prefix(120)), commitments: Array(commitments.prefix(100)),
                                     openMeeting: { _ in }, openNote: { _ in })
            .filter { !$0.done && !carded.contains($0.ref) }
    }

    var body: some View {
        let waiting = waiting
        Button { picking = true } label: {
            Label(waiting.isEmpty ? "Add To-dos" : "Add To-dos (\(waiting.count))", systemImage: "rectangle.stack.badge.plus")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(waiting.isEmpty)
        .help(waiting.isEmpty ? "Every open to-do in this binder is on the board." : "Turn to-dos from this binder's meetings, notes and promises into cards")
        .sheet(isPresented: $picking) {
            TodoPickerSheet(binder: binder, todos: waiting).environment(controller)
        }
    }
}

/// Pick to-dos to put on the board. Each card stays linked to its to-do, which is ticked off when the card is done.
struct TodoPickerSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let binder: BinderRecord
    let todos: [TaskEntry]
    @State private var chosen: Set<String>
    @State private var column: BoardColumn = .ready

    init(binder: BinderRecord, todos: [TaskEntry], chosen: Set<String> = []) {
        self.binder = binder
        self.todos = todos
        _chosen = State(initialValue: chosen)
    }

    private struct Source: Identifiable {
        let id: UUID
        let kind: TaskEntry.Kind
        let title: String
        let date: Date
        var todos: [TaskEntry]
    }

    private var sources: [Source] {
        var ordered: [Source] = []
        var index: [UUID: Int] = [:]
        for todo in todos {
            if let at = index[todo.sourceID] {
                ordered[at].todos.append(todo)
            } else {
                index[todo.sourceID] = ordered.count
                ordered.append(Source(id: todo.sourceID, kind: todo.kind, title: todo.sourceTitle, date: todo.sourceDate, todos: [todo]))
            }
        }
        return ordered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add to-dos to the \(binder.name) board").font(BindersTheme.cardTitle)
                Text("Open to-dos from this binder's meetings, notes and promises. Each stays open where it is, marked as on the board, and is ticked off when its card is done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(chosen.count == todos.count ? "Select None" : "Select All") {
                    chosen = chosen.count == todos.count ? [] : Set(todos.map(\.ref))
                }
                Spacer()
                Picker("Add to", selection: $column) {
                    Text(BoardColumn.backlog.title).tag(BoardColumn.backlog)
                    Text(BoardColumn.ready.title).tag(BoardColumn.ready)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: source.kind == .meeting ? "person.2.wave.2" : (source.kind == .commitment ? "hand.raised" : "note.text"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(source.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(source.date, format: .relative(presentation: .named)).font(BindersTheme.time()).foregroundStyle(.secondary)
                            }
                            ForEach(source.todos) { todo in
                                Toggle(isOn: Binding(get: { chosen.contains(todo.ref) },
                                                     set: { if $0 { chosen.insert(todo.ref) } else { chosen.remove(todo.ref) } })) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        if let owner = todo.owner { OwnerChip(name: owner) }
                                        Text(todo.text).fixedSize(horizontal: false, vertical: true)
                                        if let due = todo.due {
                                            DueBadge(due: due)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 420)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Add 1 Card" : "Add \(chosen.count) Cards", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .pageGround()
        .binderTint(binder.colorIndex)
    }

    /// Newest on top, in the order they're listed.
    private func add() {
        for todo in todos.reversed() where chosen.contains(todo.ref) {
            let made = controller.board.create(from: todo.todo, column: column, binderID: binder.id, by: .you)
            if !made.existed { controller.router.suggestLater(for: made.card, origin: .toBoard) }
        }
        dismiss()
    }
}
