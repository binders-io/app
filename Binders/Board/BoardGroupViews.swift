import AppKit
import SwiftUI
import BindersKit

// Lane DS5: a note's cards as one group on the board, the card's way back to its note, and the bar for many cards at once.

/// Over a note's cards in a column, with Group by Note on: the note's title and how many of its cards are in this column,
/// how the whole group is going on the board ("4 of 9 done"), Select All (its cards in every column) and a click to fold
/// it. A card dropped on it goes in the note's group; on "Not from a note", out of its group.
struct BoardGroupHeader: View {
    let group: BoardGroups.Group
    let folded: Bool
    let toggle: () -> Void
    let selectAll: () -> Void
    /// The way back to the note this group belongs to, on its header.
    var openNote: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // The note's name has the top row to itself, so a narrow column wraps it instead of squeezing it to nothing.
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .foregroundStyle(.secondary)
                        .frame(width: 11)
                        .padding(.top, 3)
                    Text(group.title)
                        .font(BoardDesign.groupTitle)
                        .foregroundStyle(.sectionInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(folded ? "Show this group's cards in the column" : "Fold this group in the column")
            // How many are in this column, the way back to the note, and Select All: a row of its own, never beside the name.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    countLine
                    Spacer(minLength: 2)
                    openNoteButton
                    selectAllButton(words: true)
                }
                HStack(spacing: 6) {
                    countLine
                    Spacer(minLength: 2)
                    openNoteButton
                    selectAllButton(words: false)
                }
            }
            if let progress = group.progress {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        WorkProgressBar(counts: DistillProgress.Counts(total: progress.total, done: progress.done)).frame(width: 38)
                        progressLine(progress)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        progressLine(progress)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BoardDesign.groupRadius, style: .continuous).fill(BindersTheme.surface2))
        .overlay(RoundedRectangle(cornerRadius: BoardDesign.groupRadius, style: .continuous)
            .strokeBorder(hovering ? BindersTheme.lineStrong : BindersTheme.line))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(group.note == nil ? AnyShapeStyle(BindersTheme.ink.opacity(0.18)) : AnyShapeStyle(TintFill().opacity(0.45)))
                .frame(width: 2)
                .padding(.vertical, 8)
                .padding(.leading, 1)
        }
        .onHover { inside in
            hovering = inside
            if inside, openNote != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .animation(BoardDesign.settle, value: hovering)
        .fitProbe(BoardView.probesCards ? "board.group." + (group.note?.uuidString ?? "loose") : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BoardGroups.spoken(group))
    }

    private var countLine: some View {
        Text("\(group.cards.count) here")
            .font(.system(size: 10.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var openNoteButton: some View {
        if let openNote {
            Button(action: openNote) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .quietControl()
            .opacity(hovering ? 1 : 0.35)
            .help("Open “\(group.title)”")
            .accessibilityLabel("Open the note")
        }
    }

}

extension BoardGroupHeader {
    fileprivate func progressLine(_ progress: BoardGroups.Progress) -> some View {
        Text(progress.line)
            .font(.system(size: 11.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    fileprivate func selectAllButton(words: Bool) -> some View {
        Button(action: selectAll) {
            if words {
                Text("Select All")
                    .font(.system(size: 11.5, weight: .semibold))
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .buttonStyle(.borderless)
        .quietControl(words: true)
        .help(group.note == nil ? "Select every card on this board that's from no note" : "Select every card from “\(group.title)” on this board, in every column")
        .accessibilityLabel("Select All")
        .fitProbe(BoardView.probesCards ? "board.group.all." + (group.note?.uuidString ?? "loose") : "")
    }
}

/// Over the board with several cards selected: how many, a few of their titles, what to do with them all (Move to, Assign
/// to, Part of, Delete…), and what stays as it is, a line each, as the several-notes panel has them.
struct SeveralCardsBar<Actions: View>: View {
    /// "5 cards selected"
    let heading: String
    let titles: [String]
    /// What some of them keep to, and why: "1 is being worked on by Claude Code: it doesn't move or change hands under it."
    let rules: [String]
    let clear: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One row while it fits, with a few of their titles under it; short of room, the buttons go under the heading,
            // wrapping as they must, and the titles give way: the lines under them say what stays as it is.
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        glyph
                        Text(heading).font(BoardDesign.panelTitle).fixedSize()
                        Spacer(minLength: 8)
                        HStack(spacing: 8) {
                            actions()
                            clearButton(words: true)
                        }
                        .fixedSize()
                    }
                    Text(titleLine).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).modifier(IdealWidthCap(cap: 200))
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        glyph
                        Text(heading).font(BoardDesign.panelTitle)
                        Spacer(minLength: 4)
                        clearButton(words: false)
                    }
                    Wrapping(spacing: 8, lineSpacing: 6) { actions() }
                }
            }
            ForEach(rules, id: \.self) { rule in
                Text(rule)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BindersTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TintFill().opacity(0.6), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .fitProbe("board.several")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(heading)
    }

    private var glyph: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(TintFill().opacity(0.16))
            .overlay {
                Image(systemName: "square.on.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tintText)
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
    }

    private var titleLine: String {
        titles.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + (titles.count > 3 ? " and \(titles.count - 3) more" : "")
    }

    /// Clear, last on the row; short of room, its mark alone at the heading's end.
    private func clearButton(words: Bool) -> some View {
        Button(action: clear) {
            if words { Label("Clear", systemImage: "xmark") } else { Image(systemName: "xmark") }
        }
        .help("Clear the selection (Esc)")
        .accessibilityLabel("Clear the selection")
        .fitProbe("board.several.last")
    }
}

/// What can be done with several cards at once, on the bar and in a selected card's menu: Move to a column, Assign to
/// someone, Part of a note's group, and Delete…, which asks once for all of them.
struct SeveralCardsButtons: View {
    let count: Int
    let binderID: UUID?
    /// The column every one of them is in, which Move to leaves out; nil when they're in several.
    let column: BoardColumn?
    /// The note whose group every one of them is in; nil when it's none or several.
    let group: UUID?
    /// In the card's menu, the items' words name the count: "Move 5 Cards to".
    var inMenu = false
    let move: (BoardColumn) -> Void
    let assign: (AssignChoice) -> Void
    let putIn: (NoteItem?) -> Void
    let delete: () -> Void

    var body: some View {
        let cards = count == 1 ? "1 Card" : "\(count) Cards"
        Menu {
            ForEach(BoardColumn.allCases, id: \.self) { each in
                Button(each.title) { move(each) }.disabled(each == column)
            }
        } label: { Label(inMenu ? "Move \(cards) to" : "Move to", systemImage: "arrow.right.square") }
            .fixedSize()
            .controlSize(.small)
            .font(.system(size: 12, weight: .medium))
            .help("Move the \(count) cards to a column, as dragging each there would. A card someone is working on stays.")
        Menu { AssignItems(binderID: binderID, choose: assign) } label: {
            Label(inMenu ? "Assign \(cards) to" : "Assign to", systemImage: "person.crop.circle.badge.checkmark")
        }
            .fixedSize()
            .controlSize(.small)
            .font(.system(size: 12, weight: .medium))
            .help("Who the \(count) cards are for: you, a teammate, one of your agents, or anyone")
        Menu { PartOfItems(binderID: binderID, current: group, canTakeOut: true, put: putIn) } label: {
            Label(inMenu ? "Put \(cards) in a Note's Group" : "Part of", systemImage: "square.stack.3d.down.right")
        }
            .fixedSize()
            .controlSize(.small)
            .font(.system(size: 12, weight: .medium))
            .help("Put the \(count) cards in a note's group on the board, or take them out of theirs")
        if inMenu { Divider() }
        Button(role: .destructive, action: delete) { Label(inMenu ? "Delete \(cards)…" : "Delete…", systemImage: "trash") }
            .fixedSize()
            .controlSize(.small)
            .font(.system(size: 12, weight: .medium))
            .help("Delete the \(count) cards, after one question")
    }
}

/// Whom Assign to gives cards to.
enum AssignChoice: Equatable {
    case who(BoardBulk.Who)
}

/// Assign to's choices, as a card's own Who menu has them: anyone, you, your agents that take this board's cards, and the
/// people on this board.
struct AssignItems: View {
    @Environment(DictationController.self) private var controller
    let binderID: UUID?
    let choose: (AssignChoice) -> Void

    var body: some View {
        Section("For") {
            Button("Anyone") { choose(.who(.nobody)) }
            Button("You") { choose(.who(.you)) }
        }
        let agents = AgentRegistry.shared.agents.filter { $0.isEnabled && $0.takesCards(from: binderID) }
        if !agents.isEmpty {
            Section("Give to an Agent") {
                ForEach(agents) { agent in Button(agent.name) { choose(.who(.agent(agent.name))) } }
            }
        }
        let people = peopleOnThisBoard
        if !people.isEmpty {
            Section("People") {
                ForEach(people, id: \.self) { name in Button(name) { choose(.who(.person(name))) } }
            }
        }
    }

    /// The other people named on this board's cards: who held them, and who they were for.
    private var peopleOnThisBoard: [String] {
        let cards = controller.board.cards(in: binderID)
        let names = cards.compactMap { $0.assigneeIsAgent ? nil : $0.assignee } + cards.compactMap { $0.meantFor }
        let agents = AgentRegistry.shared.agents.map(\.name)
        return Array(Set(names)).filter { name in
            !BoardRules.isReserved(name) && !agents.contains { BoardRules.isNamed(name, as: $0) || BoardRules.isNamed($0, as: name) }
        }.sorted()
    }
}

/// Part of: the notes whose work is followed in the board's binder (Distill on, or with cards, lane DS6), whose group a
/// card can go in, and Take Out of Its Group.
struct PartOfItems: View {
    let binderID: UUID?
    /// The note whose group they're in now, left out.
    let current: UUID?
    let canTakeOut: Bool
    let put: (NoteItem?) -> Void

    var body: some View {
        let notes = DistillBoard.workNotes(in: binderID)
        if notes.isEmpty {
            Button("No Notes with Distill On or Cards in This Binder") {}.disabled(true)
        } else {
            Section("Put in the Group of") {
                ForEach(notes.prefix(30), id: \.id) { note in
                    Button(note.title) { put(note) }.disabled(note.id == current)
                }
            }
        }
        if canTakeOut {
            Divider()
            Button("Take Out of Its Group") { put(nil) }
        }
    }
}

/// On a card's Details: the note whose group it's in, "Part of “Checkout redesign”", which opens the note, and Part of…
/// to put it in a note's group or take it out. A card Distill made, or one put on the board from a note, stays in its
/// note's group.
struct CardGroupLine: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.undoManager) private var undoManager
    @Bindable var card: TaskCard

    var body: some View {
        let from = card.distilledFrom
        let groupNote = card.groupNote
        let note = groupNote.flatMap { Store.shared.note($0) }
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(TintFill().opacity(0.12))
                .overlay {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tintText)
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            if groupNote != nil {
                Button("Part of “\(note?.title ?? card.sourceTitle ?? "a note")”") {
                    guard let note else { return }
                    HubWindowController.shared.navigation.open(note: note)
                    HubWindowController.shared.show()
                }
                .buttonStyle(.borderless)
                .themedLink()
                .lineLimit(1)
                .disabled(note == nil)
                .help(note == nil ? "The note isn't on this Mac" : "Open the note this card is part of")
            } else {
                Text("Not part of a note").foregroundStyle(BindersTheme.muted)
            }
            Spacer(minLength: 4)
            if card.noteMembership?.tie == .distilled {
                BoardPill(text: "Distill made it", symbol: BindersTheme.modelSymbol, color: BindersTheme.muted)
                    .help("Distill made this card from the note, so it stays in that note's group")
            } else if card.noteMembership?.tie == .put {
                // Lane DS6: made with Put on Board from the note.
                BoardPill(text: "Put on the board from it", symbol: "rectangle.split.3x1", color: BindersTheme.muted)
                    .help("This card was put on the board from the note, so it stays in that note's group")
            } else if from?.request != true {
                Menu {
                    PartOfItems(binderID: card.binderID, current: groupNote, canTakeOut: groupNote != nil) { put($0) }
                } label: { Text("Part of…").font(.system(size: 11, weight: .semibold)) }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .menuIndicator(.hidden)
                .fixedSize()
                .quietControl(words: true)
                .help("Put this card in a note's group on the board, or take it out")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BindersTheme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BindersTheme.line))
    }

    private func put(_ note: NoteItem?) {
        let outcome = BoardBulk.group([card], into: note, board: controller.board, undoManager: undoManager)
        controller.flowBar.toast(outcome.line, symbol: "square.stack.3d.down.right", duration: 4)
    }
}
