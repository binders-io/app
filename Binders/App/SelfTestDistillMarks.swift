import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Work in the note (lane DS4), in a throwaway folder (BINDERS_DATA_DIR) with stand-in items (no model): a Distill note's
    /// cards placed from items with quotes, the editor marking each card's words and putting a chip at the end of their
    /// line ("Ready · Echo", "2 cards" for two on one line), headings counting their section's cards, a section with no
    /// card showing nothing, a card moving columns changing its chip, a card done going faint, an item left out in review
    /// showing nothing, typing moving the marks and editing the quoted words dropping that card to its heading, Show Work
    /// in the Note off showing nothing, a click on a chip opening its card, the card's way back to its words, and the
    /// saved Markdown, copy and Find never holding a chip. A folder after the flag gets a drawing of the note.
    ///
    ///     BINDERS_DATA_DIR=<new empty folder> Binders --selftest-distill-marks [folder] -notesShowMarkdown NO
    @MainActor
    static func distillMarksSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes notes, cards and agents")
            return 1
        }
        let controller = DictationController()
        let run = DistillTestRun(controller: controller)
        let store = Store.shared
        let board = controller.board
        let service = controller.distill
        let registry = AgentRegistry.shared
        if registry.paused { registry.setPaused(false) }
        service.start()
        service.settleDelay = .seconds(600)
        EditorWork.pause = 0.3
        DistillNoteMarks.shown = true

        // Echo takes cards from the board itself: nothing runs.
        let echo = AgentProfile(name: "Echo", wake: .board, purpose: "the checkout's web pages and payments")
        let scribe = AgentProfile(name: "Scribe", wake: .board, purpose: "writes and edits documents")
        for agent in [echo, scribe] { run.check(registry.upsert(agent) == nil, "\(agent.name) is saved") }
        let echoActor = BoardActor(name: "Echo", kind: .agent)
        let web = BinderRecord(name: "Web", colorIndex: 2)
        store.insert(web)
        let text = """
            # Checkout redesign

            We want one checkout page instead of three.

            ## Payment form
            - Put address, delivery and card on **one page** instead of three.
            - Add Apple Pay and Google Pay buttons above the form.

            ## Retry after a failed payment
            When the bank declines or the connection drops, keep what was typed and offer “Retry”.
            Log each failure with its reason code.

            ## Rollout
            Ship behind a flag to 10% of visitors.
            Decide on 100% after two weeks.

            ## Later
            - [ ] Need to follow up with the bank about fees by Friday.
            - Maybe a dark theme.
            """
        let note = NoteItem(text: text)
        note.binderID = web.id
        store.insert(note)
        service.setDistill(true, for: note)

        // MARK: Stand-in items, with the note's words each came from
        let items: [[String: Any]] = [
            ["title": "Combine checkout into one page", "section": "Payment form", "quote": "Put address, delivery and card on one page instead of three.", "for": "Echo"],
            ["title": "Add the Apple Pay button", "section": "Payment form", "quote": "Add Apple Pay", "for": "Echo"],
            ["title": "Add the Google Pay button", "section": "Payment form", "quote": "Google Pay buttons above the form", "for": "person"],
            ["title": "Keep what was typed and offer Retry", "section": "Retry after a failed payment", "quote": "keep what was typed and offer \"Retry\"", "for": "Echo"],
            ["title": "Log each failure", "section": "Retry after a failed payment", "for": "Echo"],
            ["title": "Ship behind a flag", "section": "Rollout", "quote": "Ship behind a flag to 10% of visitors.", "for": "Echo"],
            ["title": "Decide on 100%", "section": "Rollout", "quote": "Decide on 100% after two weeks.", "for": "person"],
        ]
        let proposed = await run.call("propose_work_items", ["id": note.id.uuidString, "items": items], as: BoardActor(name: "Scribe", kind: .agent))
        guard let proposal = DistillStore.shared.file(for: note.id).proposal else {
            run.check(false, "the stand-in items are proposed: \(proposed.text)")
            return 1
        }
        let replyItems = run.object(proposed.text)["items"] as? [[String: Any]] ?? []
        run.check(replyItems.first?["quote"] as? String == "Put address, delivery and card on one page instead of three.",
                  "propose_work_items takes a quote per item and says it back")
        run.check(proposal.items.map(\.quote) == ["Put address, delivery and card on one page instead of three.", "Add Apple Pay", "Google Pay buttons above the form",
                                                  "keep what was typed and offer \"Retry\"", nil, "Ship behind a flag to 10% of visitors.", "Decide on 100% after two weeks."],
                  "each item keeps its quote; one without has none: \(proposal.items.map { $0.quote ?? "-" })")
        // The review leaves the decision out.
        var reviewed = proposal
        reviewed.items[6].dropped = true
        service.save(reviewed)
        let placed = service.place(reviewed, items: Set(reviewed.items.prefix(6).map(\.id)), column: .ready)
        run.check(placed.count == 6, "6 cards are placed: \(placed.count)")
        guard placed.count == 6 else { return 1 }
        let form = placed[0], apple = placed[1], google = placed[2], retry = placed[3], log = placed[4], ship = placed[5]
        run.check(form.distilledFrom?.quote == "Put address, delivery and card on one page instead of three." && log.distilledFrom?.quote == nil,
                  "each card keeps the words it came from")
        let task = run.object((await run.call("get_task", ["id": form.id.uuidString], as: echoActor)).text)
        run.check((task["distilled_from"] as? [String: Any])?["quote"] as? String == form.distilledFrom?.quote, "get_task says them in distilled_from")

        // MARK: The note in its editor
        var shownText = note.text
        var work = DistillNoteMarks.work(for: note, controller: controller)
        run.check(work?.cards.count == 6, "the editor gets the 6 cards, not the item left out: \(work?.cards.count ?? -1)")
        let binding = Binding(get: { shownText }, set: { shownText = $0 })
        func page(_ work: NoteWork?) -> some View {
            MarkdownNoteEditor(text: binding, fontSize: 15, paper: true, work: work)
                .frame(width: 820, height: 760).background(Color(nsColor: BindersTheme.NS.paper))
        }
        let hosting = NSHostingView(rootView: AnyView(page(work)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.alphaValue = 0
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(1500))
        func find(_ view: NSView) -> MarkdownTextView? { (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(find).first }
        guard let editor = find(hosting), let storage = editor.textStorage else {
            run.check(false, "the editor opens")
            return 1
        }
        let string = { editor.string as NSString }
        func marked(_ words: String) -> Bool {
            let range = string().range(of: words)
            guard range.location != NSNotFound else { return false }
            var whole = NSRange()
            let tint = storage.attribute(.workMark, at: range.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
            return tint != nil && whole.location <= range.location && NSMaxRange(whole) >= NSMaxRange(range)
        }
        func chips() -> [(text: String, line: String, faint: Bool, chip: WorkChip, character: NSRange, rect: NSRect)] {
            editor.workChips().map { found in
                let line = string().substring(with: string().lineRange(for: found.character)).trimmingCharacters(in: .newlines)
                return (found.chip.text, line, found.chip.faint, found.chip, found.character, found.rect)
            }
        }
        func chip(onLineWith words: String) -> (text: String, line: String, faint: Bool, chip: WorkChip, character: NSRange, rect: NSRect)? {
            chips().first { $0.line.contains(words) }
        }
        func anyMarks() -> Bool {
            var found = false
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, stop in
                if attributes[.workMark] != nil || attributes[.workChip] != nil || attributes[.kern] != nil {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        // MARK: Marks at the right words, chips with the right words
        run.check(marked("Put address, delivery and card on **one page** instead of three"), "the form's words are marked, its bold included")
        run.check(marked("Add Apple Pay") && marked("Google Pay buttons above the form"), "both cards' words on the one line are marked")
        run.check(marked("keep what was typed and offer “Retry"), "words found loosely (straight quotes for curly ones) are marked")
        run.check(marked("Ship behind a flag to 10% of visitors."), "the rollout's words are marked")
        run.check(!marked("Decide on 100% after two weeks."), "an item left out in the review shows nothing")
        run.check(!marked("Log each failure") && chip(onLineWith: "Log each failure") == nil, "a card with no quote marks no words")
        run.check(chip(onLineWith: "Put address")?.text == "Ready · Echo", "one card: where it is and who it's for: \(chip(onLineWith: "Put address")?.text ?? "none")")
        run.check(chip(onLineWith: "Add Apple Pay")?.text == "2 cards", "two cards on one line: one chip with the count: \(chip(onLineWith: "Add Apple Pay")?.text ?? "none")")
        run.check(chips().filter { $0.line.contains("Add Apple Pay") }.count == 1, "and only one")
        run.check(chip(onLineWith: "## Payment form")?.text == "3 cards", "a heading counts its section's cards: \(chip(onLineWith: "## Payment form")?.text ?? "none")")
        run.check(chip(onLineWith: "## Retry")?.text == "2 cards", "the card with no quote is counted at its heading: \(chip(onLineWith: "## Retry")?.text ?? "none")")
        run.check(chip(onLineWith: "## Rollout")?.text == "1 card", "the item left out isn't counted: \(chip(onLineWith: "## Rollout")?.text ?? "none")")
        run.check(chip(onLineWith: "## Later") == nil && !marked("Need to follow up with the bank"), "a section with work-looking lines and no card shows nothing extra")
        let formChip = chip(onLineWith: "Put address")
        let formLine = string().lineRange(for: string().range(of: "Put address"))
        let lastShown = string().range(of: "three.", options: [], range: formLine)
        run.check(formChip.map { NSMaxRange($0.character) == NSMaxRange(lastShown) } == true, "the chip follows the line's last character")
        run.check((storage.attribute(.toolTip, at: formChip?.character.location ?? 0, effectiveRange: nil) as? String)
                    .map { $0.contains("“Combine checkout into one page”") && $0.contains("Web · Ready · for Echo") && $0.contains("Click to open the card.") } == true,
                  "hovering it says the card's title, board, column and who it's for: \((storage.attribute(.toolTip, at: formChip?.character.location ?? 0, effectiveRange: nil) as? String) ?? "none")")
        if let formChip {
            // The words up to the last character, whose box holds the chip's room too.
            let before = NSRange(location: formLine.location, length: lastShown.location + lastShown.length - 1 - formLine.location)
            let words = editor.layoutManager?.boundingRect(forGlyphRange: editor.layoutManager!.glyphRange(forCharacterRange: before, actualCharacterRange: nil),
                                                           in: editor.textContainer!) ?? .zero
            run.check(formChip.rect.minX >= words.maxX - 1 && formChip.rect.maxX <= editor.textContainer!.size.width,
                      "it's drawn after the words, inside the page: \(Int(words.maxX)) → \(Int(formChip.rect.minX))…\(Int(formChip.rect.maxX))")
        }
        if let directory {
            // In both appearances: the marks and chips read in each.
            capture(hosting, name: "distill-marks-light", directory: directory)
            window.appearance = NSAppearance(named: .darkAqua)
            editor.restyle()
            try? await Task.sleep(for: .milliseconds(300))
            capture(hosting, name: "distill-marks-dark", directory: directory)
            window.appearance = NSAppearance(named: .aqua)
            editor.restyle()
        }

        // MARK: A click on a chip opens its card
        var opened: [UUID] = []
        if var clicking = work {
            clicking.open = { opened.append($0) }
            editor.setWork(clicking)
            if let rect = formChip?.rect {
                let point = NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y)
                run.check(editor.clickedWorkChip(at: point) && opened == [form.id], "a click on the chip opens its card")
            }
            run.check(!editor.clickedWorkChip(at: NSPoint(x: 2, y: 2)), "a click elsewhere is the text's")
        }

        // MARK: A card moving columns changes its chip, without typing
        let revision = service.boardRevision
        try? board.claim(form, by: echoActor)
        try? board.move(ship, to: .done, by: .you)
        for _ in 0..<20 where service.boardRevision == revision { try? await Task.sleep(for: .milliseconds(100)) }
        run.check(service.boardRevision > revision, "the board's change reaches the note")
        work = DistillNoteMarks.work(for: note, controller: controller)
        hosting.rootView = AnyView(page(work))
        try? await Task.sleep(for: .milliseconds(400))
        run.check(chip(onLineWith: "Put address")?.text == "In progress · Echo", "Echo took it: “In progress · Echo”: \(chip(onLineWith: "Put address")?.text ?? "none")")
        run.check(chip(onLineWith: "Ship behind")?.text == "Done" && chip(onLineWith: "Ship behind")?.faint == true, "a card done: its chip says Done, faintly")
        let shipTint = storage.attribute(.workMark, at: string().range(of: "Ship behind").location, effectiveRange: nil) as? WorkTint
        let formTint = storage.attribute(.workMark, at: string().range(of: "Put address").location, effectiveRange: nil) as? WorkTint
        run.check((shipTint?.color.resolved(for: NSAppearance(named: .aqua)!).alphaComponent ?? 1) < (formTint?.color.resolved(for: NSAppearance(named: .aqua)!).alphaComponent ?? 0),
                  "and its words' mark goes faint")
        run.check(marked("Put address, delivery and card"), "the marks stay where they were")
        if let directory { capture(hosting, name: "distill-marks-moved", directory: directory) }

        // MARK: Typing moves the marks; editing the quoted words drops that card to its heading
        let top = string().range(of: "We want").location
        editor.setSelectedRange(NSRange(location: top, length: 0))
        let started = Date()
        for word in ["Today ", "we ", "agreed. "] { editor.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let typing = Date().timeIntervalSince(started)
        run.check(marked("Put address, delivery and card on **one page** instead of three") && chip(onLineWith: "Put address") != nil,
                  "typing above the words: the mark moves with them at once")
        run.check(typing < 0.5, "and typing doesn't stall: \(String(format: "%.3f", typing)) s for three words")
        let quoted = string().range(of: "keep what was typed")
        editor.setSelectedRange(quoted)
        editor.insertText("hold the card details", replacementRange: NSRange(location: NSNotFound, length: 0))
        run.check(!marked("hold the card details and offer"), "editing the quoted words drops their mark while you type")
        try? await Task.sleep(for: .milliseconds(900))
        run.check(editor.workState.placement.atHeading.contains(retry.id.uuidString) && chip(onLineWith: "hold the card details") == nil,
                  "once typing pauses, words no longer in the note fall back to the heading")
        run.check(chip(onLineWith: "## Retry")?.text == "2 cards", "which still counts the card: \(chip(onLineWith: "## Retry")?.text ?? "none")")
        // Putting words back finds them again.
        editor.setSelectedRange(string().range(of: "hold the card details"))
        editor.insertText("keep what was typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        try? await Task.sleep(for: .milliseconds(900))
        run.check(marked("keep what was typed and offer “Retry"), "put back, they're marked again")

        // MARK: The note, copy and Find never hold a chip
        MarkdownEditor.flushAll()
        try? await Task.sleep(for: .milliseconds(100))
        let expected = text.replacingOccurrences(of: "We want one", with: "Today we agreed. We want one")
        run.check(shownText == expected && editor.string == expected, "the saved Markdown is the note's words alone")
        run.check(!shownText.contains("Ready") && !shownText.contains("cards"), "no chip's words are in it")
        editor.setSelectedRange(NSRange(location: 0, length: string().length))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("binders-selftest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        // As Copy writes it: the text view's own plain-text type.
        let types = editor.writablePasteboardTypes
        pasteboard.declareTypes(types, owner: nil)
        let wrote = editor.writeSelection(to: pasteboard, types: types)
        let copied = pasteboard.string(forType: .string) ?? ""
        run.check(wrote && copied == expected, "copying the note copies its words alone: \(copied == expected ? "" : copied.debugDescription)")
        pasteboard.releaseGlobally()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        run.check(string().range(of: "In progress · Echo").location == NSNotFound, "Find never finds a chip")

        // MARK: The card's way back to its words
        WorkItemRow.open(section: retry.distilledFrom?.section, of: note, quote: retry.distilledFrom?.quote)
        let navigation = HubWindowController.shared.navigation
        run.check(navigation.pendingNoteID == note.id && navigation.pendingNotePlace == "Retry after a failed payment"
                    && navigation.pendingNoteQuote == "keep what was typed and offer \"Retry\"",
                  "Distilled from opens the note at the card's words")
        navigation.pendingNoteID = nil
        navigation.pendingNotePlace = nil
        navigation.pendingNoteQuote = nil
        editor.reveal(quote: "keep what was typed and offer \"Retry\"", in: "Retry after a failed payment")
        run.check(editor.selectedRange().location == string().range(of: "keep what was typed").location, "the editor goes to those words")
        editor.reveal(quote: "words that went", in: "Retry after a failed payment")
        run.check(editor.selectedRange().location == string().range(of: "## Retry").location, "words no longer there: their section, as before")
        editor.window?.makeFirstResponder(nil)

        // MARK: Show Work in the Note off: nothing
        run.check(DistillNoteMarks.work(for: note, controller: controller, shown: false) == nil, "off, the editor gets no cards")
        hosting.rootView = AnyView(page(nil))
        try? await Task.sleep(for: .milliseconds(300))
        run.check(!anyMarks(), "and the note shows no mark, chip or room for one")
        DistillNoteMarks.shown = false
        run.check(DistillNoteMarks.work(for: note, controller: controller) == nil, "the switch is remembered on this Mac")
        DistillNoteMarks.shown = true
        hosting.rootView = AnyView(page(DistillNoteMarks.work(for: note, controller: controller)))
        try? await Task.sleep(for: .milliseconds(300))
        run.check(chip(onLineWith: "Put address") != nil, "on again, they're back")

        // MARK: Work items waiting for review are marked too, as proposed
        _ = await run.call("propose_work_items", ["id": note.id.uuidString, "items": [
            ["title": "Ask the bank about fees", "section": "Later", "quote": "Need to follow up with the bank about fees by Friday."],
            ["title": "Try a dark theme", "section": "Later", "quote": "Maybe a dark theme."],
        ]], as: BoardActor(name: "Scribe", kind: .agent))
        work = DistillNoteMarks.work(for: note, controller: controller)
        run.check(work?.cards.filter(\.chip.proposed).map(\.title) == ["Ask the bank about fees", "Try a dark theme"],
                  "the editor gets the waiting items: \(work?.cards.filter(\.chip.proposed).map(\.title) ?? [])")
        hosting.rootView = AnyView(page(work))
        try? await Task.sleep(for: .milliseconds(500))
        run.check(marked("Need to follow up with the bank about fees by Friday.") && marked("Maybe a dark theme."), "their words are marked")
        run.check(chip(onLineWith: "follow up with the bank")?.text == "Proposed", "with a Proposed chip: \(chip(onLineWith: "follow up with the bank")?.text ?? "none")")
        run.check(chip(onLineWith: "## Later")?.text == "2 proposed", "and counted at their heading: \(chip(onLineWith: "## Later")?.text ?? "none")")
        let bankTint = storage.attribute(.workMark, at: string().range(of: "follow up with the bank").location, effectiveRange: nil) as? WorkTint
        run.check(bankTint?.underline != nil && (formTint?.underline == nil), "a dotted line under them, which cards don't have")
        let bankChip = chip(onLineWith: "follow up with the bank")
        run.check((storage.attribute(.toolTip, at: bankChip?.character.location ?? 0, effectiveRange: nil) as? String)
                    .map { $0.contains("Proposed by Scribe") && $0.contains("Click to review it in the Distill list.") } == true,
                  "hovering it says who proposed it and what a click does")
        if let rect = bankChip?.rect, let proposedWork = work {
            var reviewing: [UUID] = []
            var clicking = proposedWork
            clicking.open = { reviewing.append($0) }
            editor.setWork(clicking)
            let point = NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y)
            let bank = proposedWork.cards.first { $0.title == "Ask the bank about fees" }?.id
            run.check(editor.clickedWorkChip(at: point) && reviewing == [bank].compactMap { $0 }, "a click on its chip opens it")
            proposedWork.open(bank ?? UUID())
            run.check(service.list(for: note.id).selected == bank, "in the Distill list, at its row")
            editor.setWork(proposedWork)
        }
        if let directory {
            capture(hosting, name: "distill-marks-proposed-light", directory: directory)
            window.appearance = NSAppearance(named: .darkAqua)
            editor.restyle()
            try? await Task.sleep(for: .milliseconds(300))
            capture(hosting, name: "distill-marks-proposed-dark", directory: directory)
            window.appearance = NSAppearance(named: .aqua)
            editor.restyle()
        }
        _ = (apple, google, log)
        return run.failures == 0 ? 0 : 1
    }
}
