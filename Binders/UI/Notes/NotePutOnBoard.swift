import AppKit
import BindersKit

// Lane DS6: Put on Board from a note's editor. With words selected, the editor's menu puts them on the board as one card,
// or one card for each line; Note → Put on Board (⇧⌘B, Settings → Shortcuts) does the same, or the whole note with
// nothing selected. Each card is among the note's cards (`NoteWorkCards`): the note marks it at its words, and its Work bar
// follows it.

/// Putting a note, or words in it, on the board, and what it says.
@MainActor
enum NotePutOnBoard {
    /// Posted by Note → Put on Board when no editor of the note has the keyboard: "note" (its id) and "popout" (whether
    /// it's the note's own window), for the page showing it to put the whole note.
    static let wholeNote = Notification.Name("BindersPutNoteOnBoard")

    /// Puts `selection` of the note on the board (the whole note for an empty one), one card or one per line, in the note's
    /// binder, and has the router look at each later, as Put on Board always has. Returns the cards and what to say; nil
    /// when nothing was made (the library can't save, or the selection has no words).
    static func put(_ note: NoteItem, selection: NSRange = NSRange(location: 0, length: 0), eachLine: Bool = false,
                    controller: DictationController) -> (cards: [TaskCard], line: String)? {
        guard Store.shared.allowsSave() else { return nil }
        MarkdownEditor.flushAll()
        let cards = controller.board.create(from: note, selection: selection, eachLine: eachLine, by: .you)
        guard !cards.isEmpty else { return nil }
        for card in cards { controller.router.suggestLater(for: card, origin: .toBoard) }
        return (cards, line(cards.count, board: Store.shared.binder(cards[0].binderID)?.name))
    }

    /// "Added to the Web board", "Added 5 cards to the Web board".
    static func line(_ count: Int, board: String?) -> String {
        let place = board.map { "the \($0) board" } ?? "the board"
        return count == 1 ? "Added to \(place)" : "Added \(count) cards to \(place)"
    }

    /// Open: one card in its window; several on their board, chosen.
    static func open(_ cards: [TaskCard]) {
        let navigation = HubWindowController.shared.navigation
        guard cards.count > 1, let board = cards[0].binderID else {
            if let card = cards.first { navigation.open(card: card) }
            return
        }
        navigation.binderID = board
        navigation.pendingBoardSelection = Set(cards.filter { $0.binderID == board }.map(\.id))
        navigation.pendingBinderTab = .board
        navigation.selection = .binder
        HubWindowController.shared.show()
    }
}

extension MarkdownTextView {
    /// The selected lines that would each be a card, for "Put Each Line on Board (5)".
    func linesToPut() -> Int {
        let selection = selectedRange()
        guard selection.length > 0 else { return 0 }
        return NoteSelectionCards.lines(in: string, selection: selection).count
    }

    /// The editor's menu with Put on Board first, while words are selected in a note's editor: one card, and for two lines
    /// or more, one for each.
    func withPutOnBoard(_ menu: NSMenu?) -> NSMenu? {
        guard putOnBoard != nil, selectedRange().length > 0 else { return menu }
        let menu = menu ?? NSMenu()
        let one = NSMenuItem(title: "Put on Board", action: #selector(putSelectionOnBoard(_:)), keyEquivalent: "")
        one.target = self
        if let (key, flags) = MenuShortcuts.keyEquivalent(MenuShortcuts.shortcut(for: .putOnBoard)) {
            one.keyEquivalent = key
            one.keyEquivalentModifierMask = flags
        }
        one.toolTip = "A card on this binder's board with these words, marked in the note where they are"
        var items = [one]
        let lines = linesToPut()
        if lines > 1 {
            let each = NSMenuItem(title: "Put Each Line on Board (\(lines))", action: #selector(putEachLineOnBoard(_:)), keyEquivalent: "")
            each.target = self
            each.toolTip = "A card for each selected line, each marked in the note at its line"
            items.append(each)
        }
        items.append(.separator())
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        return menu
    }

    @objc func putSelectionOnBoard(_ sender: Any?) {
        putOnBoard?(selectedRange(), false)
    }

    @objc func putEachLineOnBoard(_ sender: Any?) {
        putOnBoard?(selectedRange(), true)
    }

    /// Note → Put on Board while this editor has the keyboard: the selection as one card, or the whole note for none.
    /// False where the editor isn't a note's.
    func putOnBoardFromMenu() -> Bool {
        guard let putOnBoard else { return false }
        putOnBoard(selectedRange(), false)
        return true
    }
}
