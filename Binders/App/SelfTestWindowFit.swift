import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// The main window keeps the size it was given whatever a page holds, and every page fits it, from its smallest
    /// (840 × 560, the sidebar shown) up, with nothing cut off: a long note in the rich and the Markdown views, a Distill
    /// note with its Work bar, a note three folders deep with Put on Board's notice, a meeting, a capture, the meetings and
    /// the captures pages with several selected (lane RF3), Today, Home and the board. Each page is made in the real window (`HubWindowController.makeWindow`) at 1020 × 720, made narrow
    /// (840 × 560), then wide (1440 × 900); at each size the window is the size it was given, and the page and its
    /// controls (the note's bottom row, its toolbar, its digest column's edge, the Work bar, the meeting's tabs, Today's
    /// and the board's headers) lie inside it, by their frames (`FitProbe`). The other windows that hold pages (a note's own
    /// window, a card's, the Scratchpad, the live meeting notes) keep their sizes with long content too. Draws each page to
    /// `directory`. Then every text field in Settings and its sheets, stacked (`formFieldsFit`, lane UI1). A throwaway
    /// store (BINDERS_DATA_DIR).
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-window-fit <dir> -notesShowMarkdown NO
    @MainActor
    static func windowFitSelfTest(directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this seeds fictional data there")
            return 1
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Before any view is made: the controls the checks look for say where they are.
        FitProbe.isOn = true
        defer { FitProbe.isOn = false }
        let controller = DictationController()
        CardWindows.shared.controller = controller
        guard await DemoData.seed(knowledge: controller.knowledge),
              let harbor = Store.shared.binders().first(where: { $0.name == DemoData.binderName }) else { return 1 }
        let context = Store.shared.context
        AppDefaults.store.set(true, forKey: "notesShowDigest")
        AppDefaults.store.set(300.0, forKey: "notesDigestWidth")

        // Far longer than any window: headings, paragraphs that wrap, lists, a checklist, a quote and a code block.
        var lines = ["# A long spec"]
        for part in 1...40 {
            lines += ["", "## Part \(part)", "", "Paragraph \(part): " + String(repeating: "words that wrap across the page ", count: 12),
                      "", "- point one of \(part)", "- point two of \(part)", "- [ ] check \(part)", "", "> a quote in part \(part)",
                      "", "```", "let part = \(part)", "print(part)", "```"]
        }
        let long = lines.joined(separator: "\n")
        let note = NoteItem(text: long)
        note.binderID = harbor.id
        context.insert(note)
        // A Distill note with cards placed from it, so its Work bar shows its progress.
        let distilled = NoteItem(text: "# Spring launch plan\n\n## Pricing\n\nSettle the tiers.\n\n## Support\n\nWrite the macros.\n\n## Press\n\nBrief the reporters.\n\n"
                                 + long.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
        distilled.binderID = harbor.id
        context.insert(distilled)
        Store.shared.save()
        controller.distill.setDistill(true, for: distilled)
        let distill = UUID()
        var boardSeveral: Set<UUID> = []
        for (title, column, section) in [("Settle the pricing tiers", BoardColumn.done, "Pricing"), ("Write the support macros", .inProgress, "Support"),
                                         ("Brief the reporters", .ready, "Press")] {
            let card = TaskCard(title: title, binderID: harbor.id, column: column)
            card.sourceID = distilled.id.uuidString
            card.distilledFrom = DistilledFrom(note: distilled.id, distill: distill, item: UUID(), section: section)
            context.insert(card)
            boardSeveral.insert(card.id)
        }
        // A crowded board in a binder of its own: 14 notes' cards and loose ones, far more than any column holds, with
        // titles that wrap. Its headers stay in the window and every column scrolls by itself.
        let crowded = BinderRecord(name: "Crowded", colorIndex: 3)
        Store.shared.insert(crowded)
        let wordy = " with a title long enough to wrap onto a third line of the card"
        for part in 1...14 {
            let source = NoteItem(text: "# Plan \(part)\n\nThe work for part \(part).")
            source.binderID = crowded.id
            context.insert(source)
            let run = UUID()
            for index in 0..<9 {
                let column = BoardColumn.allCases[(part + index) % BoardColumn.allCases.count]
                let card = TaskCard(title: "Part \(part) card \(index)" + (index % 2 == 0 ? wordy : ""), binderID: crowded.id, column: column)
                card.sourceID = source.id.uuidString
                card.distilledFrom = DistilledFrom(note: source.id, distill: run, item: UUID(), section: "Part \(part)")
                // The chips a busy board carries: who it's for, an agent's suggestion, links.
                card.meantFor = index % 3 == 0 ? "Helder Claude Code" : "Penny"
                card.meantForByAgent = index % 4 == 1
                card.links = Array(repeating: "https://example.com", count: index % 3)
                context.insert(card)
            }
        }
        for index in 0..<60 {
            let column = BoardColumn.allCases[index % BoardColumn.allCases.count]
            context.insert(TaskCard(title: "Loose card \(index)" + (index % 3 == 0 ? wordy : ""), binderID: crowded.id, column: column))
        }
        // One column far longer than the rest, as a backlog left to grow is.
        for index in 0..<300 {
            context.insert(TaskCard(title: "Long list card \(index)" + (index % 3 == 0 ? wordy : ""), binderID: crowded.id, column: .ready))
        }
        Store.shared.save()
        // A note three folders deep, the folders with long names, with Put on Board's notice showing.
        let top = Store.shared.createFolder(named: "Marketing and communications", in: harbor.id)
        let middle = Store.shared.createFolder(named: "Launch campaigns for the spring", in: harbor.id, parent: top?.id)
        let deep = Store.shared.createFolder(named: "Social posts and announcements", in: harbor.id, parent: middle?.id)
        let filed = NoteItem(text: "# Posts for the week the harbor launch goes out to everyone on the list\n\n"
                             + long.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
        filed.binderID = harbor.id
        filed.folderID = deep?.id
        context.insert(filed)
        let meeting = MeetingRecord(title: "A long review", appName: "Zoom", templateID: "general")
        meeting.status = "ready"
        meeting.binderID = harbor.id
        meeting.summary = long
        meeting.userNotes = long
        context.insert(meeting)
        let heard = MeetingRecord(title: "A long capture", appName: nil, templateID: "general")
        heard.status = "ready"
        heard.kind = MeetingRecord.conversationKind
        heard.binderID = harbor.id
        heard.folderID = deep?.id
        heard.summary = long
        context.insert(heard)
        // Several meetings and several captures in a folder, to select together (lane RF3): long titles, a teammate's meeting
        // and one still recording among them, so the page shows each of its lines.
        let booth = Store.shared.createFolder(named: "Booth week at the spring trade show", in: harbor.id)
        var severalMeetings: Set<UUID> = [], severalCaptures: Set<UUID> = []
        for index in 1...4 {
            let record = MeetingRecord(title: "Booth planning session \(index) with the events team and the printer, about the banners", appName: "Zoom",
                                       templateID: "general")
            record.status = index == 4 ? "recording" : "ready"
            record.binderID = harbor.id
            record.folderID = booth?.id
            if index == 3 {
                record.isTeamCopy = true
                record.teamAuthorName = "Dana"
            }
            context.insert(record)
            severalMeetings.insert(record.id)
        }
        for index in 1...3 {
            let record = MeetingRecord(title: "Hallway conversation \(index) about the crates and the stand on the second morning", appName: "iPhone",
                                       templateID: "conversation")
            record.kind = MeetingRecord.conversationKind
            record.status = "ready"
            record.binderID = harbor.id
            record.folderID = booth?.id
            context.insert(record)
            severalCaptures.insert(record.id)
        }
        Store.shared.save()
        check(deep != nil && Store.shared.folderNames(filed.folderID).count == 3, "the note is three folders deep: \(Store.shared.folderPath(filed.folderID))")
        let noticeCard = controller.board.create(from: filed, by: .you)
        NoteEditor.noticeOnOpen = (filed.id, noticeCard, "Added to the \(harbor.name) board")
        defer { NoteEditor.noticeOnOpen = nil }

        // An agent's long conversation, with a question waiting on you, for the Agents page.
        let pennant = AgentProfile(name: "Pennant", wake: .board)
        AgentRegistry.shared.upsert(pennant)
        let talk = controller.board.create(title: "Book flights for Ignite", details: String(repeating: "Find a nonstop on the 16th. ", count: 12),
                                           binderID: harbor.id, by: .you)
        controller.board.give(talk, to: pennant.name, by: .you)
        let pennantActor = BoardActor(name: pennant.name, kind: .agent)
        try? controller.board.claim(talk, by: pennantActor)
        for turn in 0..<24 {
            _ = controller.board.comment(talk, text: String(repeating: "Verified live on the airline's page: DL679, JFK to SFO, 3:59 PM to 7:35 PM, $831.80 with taxes. ", count: 4 + turn % 3),
                                         by: turn.isMultiple(of: 3) ? .you : pennantActor)
        }
        let quiet = controller.board.create(title: "Compare fares", binderID: harbor.id, by: .you)
        controller.board.give(quiet, to: pennant.name, by: .you)
        try? controller.board.claim(quiet, by: pennantActor)
        for turn in 0..<24 {
            _ = controller.board.comment(quiet, text: String(repeating: "Checked again: the fare holds at $831.80 with taxes. ", count: 4 + turn % 3), by: pennantActor)
        }
        _ = try? controller.board.ask(talk, question: String(repeating: "Should I book the 3:59 PM nonstop at $831.80, or wait for the fare to drop? ", count: 3), by: pennantActor)
        Store.shared.save()

        func hub(_ configure: (HubNavigation) -> Void) -> some View {
            let navigation = HubNavigation()
            navigation.binderID = harbor.id
            configure(navigation)
            return HubView().environment(navigation).environment(controller).environment(controller.meetings)
                .environment(controller.knowledge).environment(controller.team).environment(controller.capture)
                .environment(controller.commitments).environment(AppSettings.shared).modelContainer(Store.shared.container)
        }

        struct Page {
            let name: String
            /// Controls that must be there, at every size.
            let probes: [String]
            let configure: (HubNavigation) -> Void
            var markdown = false
            /// Meetings or captures to select as the list opens, as ⌘-click would.
            var selected: Set<UUID>? = nil
        }
        let notePage: (NoteItem) -> (HubNavigation) -> Void = { item in
            { $0.selection = .binder; $0.pendingBinderTab = .notes; $0.pendingNoteID = item.id }
        }
        let noteProbes = ["note.bottom.first", "note.bottom.last", "toolbar.first", "toolbar.last", "distill.button"]
        let crowdedColumns = [BoardColumn.ready, .inProgress, .blocked, .review].map { "board.column." + $0.rawValue }
        let pages = [
            Page(name: "note", probes: noteProbes, configure: notePage(note)),
            Page(name: "note-markdown", probes: noteProbes, configure: notePage(note), markdown: true),
            Page(name: "distill", probes: noteProbes + ["workbar.first", "workbar.last"], configure: notePage(distilled)),
            Page(name: "folder-note", probes: noteProbes + ["note.notice"], configure: notePage(filed)),
            Page(name: "meeting", probes: ["meeting.tabs.first", "meeting.tabs.last"],
                 configure: { $0.selection = .binder; $0.pendingBinderTab = .meetings; $0.pendingMeetingID = meeting.id }),
            Page(name: "capture", probes: ["meeting.tabs.first", "meeting.tabs.last"],
                 configure: { $0.selection = .binder; $0.pendingBinderTab = .conversations; $0.pendingMeetingID = heard.id }),
            Page(name: "meetings-several", probes: ["meetings.several"],
                 configure: { $0.selection = .binder; $0.folderID = booth?.id; $0.pendingBinderTab = .meetings }, selected: severalMeetings),
            Page(name: "captures-several", probes: ["meetings.several"],
                 configure: { $0.selection = .binder; $0.folderID = booth?.id; $0.pendingBinderTab = .conversations }, selected: severalCaptures),
            Page(name: "today", probes: ["today.header.last"], configure: { $0.selection = .today }),
            Page(name: "home", probes: ["home.header.last"], configure: { $0.selection = .home }),
            Page(name: "board", probes: ["board.header.last"], configure: { $0.selection = .binder; $0.pendingBinderTab = .board }),
            // Lane DS5: grouped by note, with several cards chosen: the bar over the columns, every button of it.
            Page(name: "board-several", probes: ["board.header.last", "board.several", "board.several.last"],
                 configure: { $0.selection = .binder; $0.pendingBinderTab = .board }),
            // Far more cards than the window holds, grouped and not: the switches and the names of the columns that never fold
            // stay in the window.
            Page(name: "board-crowded", probes: ["board.header.last"] + crowdedColumns,
                 configure: { $0.selection = .binder; $0.binderID = crowded.id; $0.pendingBinderTab = .board }),
            Page(name: "board-crowded-grouped", probes: ["board.header.last"] + crowdedColumns,
                 configure: { $0.selection = .binder; $0.binderID = crowded.id; $0.pendingBinderTab = .board }),
        ]
        // Every other page fits too, from its smallest: the page lies inside the window.
        let others: [Page] = [
            Page(name: "overview", probes: [], configure: { $0.selection = .binder; $0.pendingBinderTab = .overview }),
            Page(name: "binder-knowledge", probes: [], configure: { $0.selection = .binder; $0.pendingBinderTab = .knowledge }),
            Page(name: "work", probes: [], configure: { $0.selection = .work }),
            Page(name: "agents", probes: [], configure: { $0.selection = .agents }),
            Page(name: "agents-conversation", probes: ["agents.header", "agents.conversation.header", "card.composer"],
                 configure: { $0.selection = .agents; $0.agentsPick = AgentsPick.card(talk.id).raw }),
            Page(name: "agents-conversation-quiet", probes: ["agents.header", "agents.conversation.header", "card.composer"],
                 configure: { $0.selection = .agents; $0.agentsPick = AgentsPick.card(quiet.id).raw }),
            Page(name: "agents-agent", probes: ["agents.header", "agents.chat.message"],
                 configure: { $0.selection = .agents; $0.agentsPick = AgentsPick.agent(pennant.id).raw }),
            Page(name: "writing", probes: [], configure: { $0.selection = .writing }),
            Page(name: "knowledge", probes: [], configure: { $0.selection = .knowledge }),
            Page(name: "dictionary", probes: [], configure: { $0.selection = .dictionary }),
            Page(name: "snippets", probes: [], configure: { $0.selection = .snippets }),
            Page(name: "style", probes: [], configure: { $0.selection = .style }),
        ] + SettingsPage.Group.allCases.compactMap { group in
            SettingsPage.allCases.first { $0.group == group }.map { first in
                Page(name: "settings-\(first.rawValue)", probes: [], configure: { $0.selection = .settings; $0.pendingSettingsPage = first })
            }
        }
        let sizes = [HubWindowController.defaultSize, HubWindowController.smallestSize, NSSize(width: 1440, height: 900)]
        let showed = AppDefaults.store.bool(forKey: "notesShowMarkdown")
        defer { AppDefaults.store.set(showed, forKey: "notesShowMarkdown") }

        // BINDERS_FIT_ONLY=<prefix>: only the pages whose names start with it.
        let only = ProcessInfo.processInfo.environment["BINDERS_FIT_ONLY"]
        for page in (pages + others) where only.map({ page.name.hasPrefix($0) }) ?? true {
            AppDefaults.store.set(page.markdown, forKey: "notesShowMarkdown")
            MeetingsView.selectOnOpen = page.selected
            defer { MeetingsView.selectOnOpen = nil }
            AppDefaults.store.set(page.name == "board-several", forKey: BoardView.groupKey(harbor.id))
            AppDefaults.store.set(page.name == "board-crowded-grouped", forKey: BoardView.groupKey(crowded.id))
            BoardView.selectOnOpen = page.name == "board-several" ? boardSeveral : nil
            defer { BoardView.selectOnOpen = nil; AppDefaults.store.removeObject(forKey: BoardView.groupKey(harbor.id)) }
            let window = HubWindowController.makeWindow(hub(page.configure), size: sizes[0])
            window.alphaValue = 0
            window.orderFrontRegardless()
            for (step, size) in sizes.enumerated() {
                if step > 0 { window.setContentSize(size) }
                try? await Task.sleep(for: .milliseconds(step == 0 ? 2_200 : 1_000))
                window.contentView?.layoutSubtreeIfNeeded()
                let label = "\(page.name) at \(Int(size.width)) × \(Int(size.height))"
                let kept = window.contentView?.frame.size ?? .zero
                check(abs(kept.width - size.width) < 0.5 && abs(kept.height - size.height) < 0.5,
                      "\(label): the window keeps its size (\(Int(kept.width)) × \(Int(kept.height)) pt)")
                // The page's column: from the sidebar's edge to the window's.
                let sidebar = FitProbe.frames("sidebar", in: window).first
                let pane = NSRect(x: sidebar?.maxX ?? 0, y: 0, width: kept.width - (sidebar?.maxX ?? 0), height: kept.height)
                func inside(_ frame: NSRect) -> Bool {
                    frame.minX >= pane.minX - 0.5 && frame.maxX <= pane.maxX + 0.5 && frame.minY >= pane.minY - 0.5 && frame.maxY <= pane.maxY + 0.5
                }
                let drawn = FitProbe.all(in: window).filter { $0.name != "sidebar" }
                let outside = drawn.filter { !inside($0.frame) }.map { "\($0.name) \(Int($0.frame.minX))–\(Int($0.frame.maxX)) y\(Int($0.frame.minY))–\(Int($0.frame.maxY))" }
                let missing = (page.probes + ["page"]).filter { name in !drawn.contains { $0.name == name } }
                check(sidebar != nil && missing.isEmpty && outside.isEmpty,
                      "\(label): the page and its controls lie inside the window, beside the sidebar (\(Int(pane.minX))–\(Int(pane.maxX)) pt)"
                      + (missing.isEmpty ? "" : "; not found: \(missing.joined(separator: ", "))")
                      + (outside.isEmpty ? "" : "; outside: \(outside.joined(separator: ", "))"))
                if page.name.hasPrefix("note") || page.name == "distill" || page.name == "folder-note" {
                    let column = FitProbe.frames("note.column", in: window).first
                    if size.width <= 840 {
                        check(column == nil, "\(label): no room for the digest beside the note, so it hides (your choice stays: shown)")
                    } else if size.width >= 1440 {
                        // Wide, as it always was: the digest at its width, the bottom row's words, the whole toolbar.
                        check(column.map { abs($0.width - 300) < 1 } == true, "\(label): the digest is back, at its own width (\(Int(column?.width ?? 0)) pt)")
                        check(!FitProbe.frames("note.bottom.labels", in: window).isEmpty, "\(label): the bottom row's buttons have their words")
                        check(!FitProbe.frames("toolbar.whole", in: window).isEmpty, "\(label): the toolbar shows every button")
                    }
                }
                // Drawn: the pages above at every size; every other page at its smallest.
                if others.allSatisfy({ $0.name != page.name }) || size.width <= 840, let content = window.contentView {
                    capture(content, name: "window-fit-\(page.name)-\(Int(size.width))", directory: directory)
                }
            }
            window.close()
            try? await Task.sleep(for: .milliseconds(200))
        }

        // A window an earlier build stretched past its screen comes back on it; any other stays where it was left.
        if let visible = NSScreen.main?.visibleFrame {
            let stretched = HubWindowController.makeWindow(hub { $0.selection = .home })
            stretched.setFrame(NSRect(x: visible.minX - 200, y: visible.minY, width: visible.width + 600, height: visible.height + 300), display: false)
            HubWindowController.keepOnScreen(stretched)
            check(visible.contains(stretched.frame) || stretched.frame.equalTo(visible), "a window stretched past the screen is made to fit it: \(stretched.frame)")
            let ordinary = NSRect(x: visible.minX + 40, y: visible.minY + 30, width: 1020, height: 720)
            stretched.setFrame(ordinary, display: false)
            HubWindowController.keepOnScreen(stretched)
            check(stretched.frame.equalTo(ordinary), "one that fits stays exactly where it was")
            stretched.close()
        }

        // The page's smallest width, as the window the old way (sized to its page) would have taken it.
        for page in pages where ["note", "meeting", "capture", "today"].contains(page.name) {
            AppDefaults.store.set(page.markdown, forKey: "notesShowMarkdown")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                                  styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.contentMinSize = NSSize(width: 300, height: 300)
            let hosting = NSHostingView(rootView: hub(page.configure))
            hosting.sizingOptions = [.minSize]
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1_800))
            let needs = window.frame.width
            check(needs <= HubWindowController.smallestSize.width, "\(page.name): the page needs \(Int(needs)) pt, the window's smallest is 840")
            window.close()
        }
        AppDefaults.store.set(false, forKey: "notesShowMarkdown")

        // The windows beside the main one keep their sizes with long content too.
        func settle(_ window: NSWindow?, _ name: String, to size: NSSize? = nil) async {
            guard let window else { return check(false, "\(name): its window opened") }
            window.alphaValue = 0
            if let size { window.setContentSize(size) }
            try? await Task.sleep(for: .milliseconds(300))
            let before = window.frame.size
            try? await Task.sleep(for: .milliseconds(1_500))
            window.contentView?.layoutSubtreeIfNeeded()
            let after = window.frame.size
            check(abs(after.width - before.width) < 0.5 && abs(after.height - before.height) < 0.5,
                  "\(name): the window stays \(Int(before.width)) × \(Int(before.height)) pt (\(Int(after.width)) × \(Int(after.height)) pt)")
        }
        // A note's own window, at its size and at its smallest.
        let popoutsKept = AppDefaults.store.data(forKey: "notePopouts")
        filed.text = "# " + String(repeating: "A title far longer than the window ", count: 6) + "\n\n" + long
        Store.shared.save()
        NotePopouts.shared.open(filed)
        let popout = NSApp.windows.first { $0.identifier?.rawValue == filed.id.uuidString }
        await settle(popout, "a note's own window, with a long note")
        await settle(popout, "a note's own window at its smallest", to: NSSize(width: 300, height: 220))
        if let content = popout?.contentView { capture(content, name: "window-fit-popout-300", directory: directory) }
        NotePopouts.shared.close(filed.id)
        // A Distill note's own window (lane RF2): its Work bar, and its Work panel in the note's place, inside the window at
        // its size and at its smallest.
        HubWindowController.shared.controller = HubWindowController.shared.controller ?? controller
        let workShown = AppDefaults.store.object(forKey: NotePopouts.workPanelKey)
        for shown in [false, true] {
            AppDefaults.store.set(shown, forKey: NotePopouts.workPanelKey)
            NotePopouts.shared.open(distilled)
            // The one open now: a window closed a moment ago can still be in the list.
            let window = NSApp.windows.first { $0.identifier?.rawValue == distilled.id.uuidString && $0.isVisible }
            for size in [nil, NSSize(width: 300, height: 220)] {
                let label = "a Distill note's own window\(shown ? ", its Work panel shown" : "")\(size == nil ? "" : ", at its smallest")"
                await settle(window, label, to: size)
                guard let window else { continue }
                let bounds = NSRect(origin: .zero, size: window.frame.size).insetBy(dx: -0.5, dy: -0.5)
                let probes = ["workbar.first", "workbar.last"] + (shown ? ["workpanel"] : [])
                // Drawn by now, or within three seconds more on a busy Mac.
                for _ in 0..<30 where probes.contains(where: { FitProbe.frames($0, in: window).isEmpty }) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let missing = probes.filter { FitProbe.frames($0, in: window).isEmpty }
                let outside = probes.filter { name in FitProbe.frames(name, in: window).contains { !bounds.contains($0) } }
                check(missing.isEmpty && outside.isEmpty, "\(label): \(shown ? "the Work bar and panel lie" : "the Work bar lies") inside it"
                      + (missing.isEmpty ? "" : "; not found: \(missing.joined(separator: ", "))")
                      + (outside.isEmpty ? "" : "; outside: \(outside.joined(separator: ", "))"))
            }
            if let content = window?.contentView { capture(content, name: "window-fit-popout-distill\(shown ? "-work" : "")-300", directory: directory) }
            NotePopouts.shared.close(distilled.id)
        }
        AppDefaults.store.set(workShown, forKey: NotePopouts.workPanelKey)
        AppDefaults.store.set(popoutsKept, forKey: "notePopouts")
        // A card's window, with a long title, details and timeline.
        let card = controller.board.create(title: String(repeating: "A card title longer than any window ", count: 4), details: long, binderID: harbor.id,
                                          by: .you)
        for index in 1...30 {
            controller.board.comment(card, text: "Comment \(index): " + String(repeating: "words that wrap ", count: 20), by: .you, wake: .none)
        }
        CardWindows.shared.open(card, controller: controller)
        let cardWindow = CardWindows.shared.window(for: card.id)
        await settle(cardWindow, "a card's window, with a long card")
        await settle(cardWindow, "a card's window at its smallest", to: NSSize(width: CardLayout.smallestWidth, height: CardLayout.smallestHeight))
        CardWindows.shared.close(card.id)
        // The Scratchpad, with a long note in it.
        ScratchpadController.shared.show()
        let scratchpad = NSApp.windows.first { $0.title == "Scratchpad" }
        if let scratch = ((try? context.fetch(FetchDescriptor<NoteItem>())) ?? []).first(where: { $0.text.isEmpty }) { scratch.text = long }
        await settle(scratchpad, "the Scratchpad, with a long note")
        await settle(scratchpad, "the Scratchpad, made narrow", to: NSSize(width: 320, height: 300))
        scratchpad?.orderOut(nil)
        // The live meeting notes, with a long title and notes.
        meeting.title = String(repeating: "A meeting title longer than the panel ", count: 4)
        MeetingWindowController.shared.show(service: controller.meetings, meeting: meeting, activate: false)
        let live = NSApp.windows.first { $0.title == "Meeting notes" }
        await settle(live, "the live meeting notes, with a long meeting")
        MeetingWindowController.shared.close()

        // Lane UI1: every text field in Settings and its sheets, its name above a box from the left, at both sizes and themes.
        await formFieldsFit(directory: directory, controller: controller, hub: { AnyView(hub($0)) }, check: check)

        print(failures == 0 ? "WINDOW_FIT_OK" : "WINDOW_FIT_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
