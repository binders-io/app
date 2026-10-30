import AppKit
import SwiftUI
import BindersKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DictationController?
    private var statusItem: StatusItemController?
    /// Links and files that came before launching finished, such as the binders://apply of an agent's write that launched
    /// Binders: opened once it's ready.
    private var waiting: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would both answer fn, and an older build would migrate the database back to its own schema.
        // Exit before anything opens the store. The MCP server and self-tests are this executable too, run with a flag;
        // they don't count, or a Claude Desktop that started its server first would keep Binders from opening.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != ownPID && Self.isAppInstance($0.processIdentifier) }) {
            Log.app.error("Another Binders is already running (pid \(existing.processIdentifier)); exiting")
            existing.activate()
            exit(0)
        }
        MainMenu.install()
        // Once: preferences an earlier test build saved under Auto mode's old name, under today's.
        EarlierSpellings.moveDefaults(in: AppDefaults.store)
        // Tidying the library waits until Binders is open and settled, off launch's path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { MainActor.assumeIsolated { LaunchHousekeeping.run() } }
        let controller = DictationController()
        self.controller = controller
        // A save you ask for while the library is out says why, instead of seeming to work.
        Store.shared.onRefused = { [weak controller] in
            controller?.flowBar.toast(Store.unavailableMessage, symbol: "exclamationmark.triangle", duration: 7)
        }
        HubWindowController.shared.controller = controller
        CardWindows.shared.controller = controller
        statusItem = StatusItemController(controller: controller)
        MacNotifications.shared.controller = controller
        MacNotifications.shared.install()
        controller.start()
        if controller.settings.phoneLink { controller.link.start() }
        controller.board.start()
        controller.distill.start()
        // Linked binders' notes and folders, both ways with the hub.
        HubNotesSync.shared.refresh()

        // The library didn't open: the window comes up with its banner, so it's seen before anything seems to be saved.
        if !AppSettings.shared.hasCompletedSetup || !Permissions.accessibility || Permissions.microphone != .authorized || Store.shared.isFallback {
            HubWindowController.shared.show(section: .home)
        }
        // Notes left open in their own windows, or folded into bubbles.
        NotePopouts.shared.restore()
        let early = waiting
        waiting = []
        if !early.isEmpty { application(NSApp, open: early) }
    }

    /// Whether a running Binders is the app proper, from its launch arguments. When they can't be read, it counts.
    static func isAppInstance(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return true }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              let arguments = AppInstances.arguments(fromProcArgs: Array(buffer.prefix(size))) else { return true }
        return AppInstances.isApp(arguments: arguments)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Typing an editor hasn't handed to its note yet, and whatever isn't saved.
        MarkdownEditor.flushAll()
        Store.shared.save()
        HubNotesSync.shared.flushToDisk()
        // Deleted meetings' recordings waited for Undo, which goes with the window: they go now.
        MeetingTrash.forgetWaiting(keepingThisRun: false)
        guard let controller else { return .terminateNow }
        let recording = controller.meetings.isRecording
        let freeModel = AppSettings.shared.managesModelMemory
        // The decision model: a measure stops, and a pass under way finishes (3 s at most) and takes its marker with it,
        // so a quit, a logout or an update never starts the model failed at the next launch.
        let decisionModel = DecisionModels.shared.backend != nil
        guard recording || freeModel || decisionModel else { return .terminateNow }
        Task { @MainActor in
            async let decided: Void = DecisionModels.shared.prepareForQuit(within: .seconds(3))
            if recording { await controller.meetings.prepareForTermination() }
            if freeModel { await controller.unloadLLM() }
            await decided
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        HubWindowController.shared.show()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller else { return waiting += urls }
        for url in urls {
            // A Binders file from the iPhone (AirDrop, Files, Mail), or a binders:// link.
            if url.isFileURL, url.pathExtension.lowercased() == BindersTransfer.fileExtension {
                BindersFiles.open(url, controller: controller)
            } else {
                URLCommands.handle(url, controller: controller)
            }
        }
    }
}

/// Whole-library tidying: writing past its keep-by, unused attachments, old audio, the history of deleted notes, the
/// recordings of meetings deleted before a crash. In the app it runs a little after launch, once this copy is the one
/// running; self-tests run it first, as they always have.
@MainActor
enum LaunchHousekeeping {
    static func run() {
        let settings = AppSettings.shared
        Store.shared.pruneWriting(olderThanDays: settings.captureRetentionDays)
        Store.shared.cleanupWriting()
        NoteHistory.forgetDeletedNotes()
        MeetingTrash.forgetWaiting(keepingThisRun: true)
        Attachments.trashUnused()
        Store.shared.pruneOldAudio(olderThanDays: settings.audioRetentionDays)
    }
}

/// Menu bar icon and menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController

    init(controller: DictationController) {
        self.controller = controller
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
        observeChanges({ "\(controller.phase)|\(controller.meetings.isRecording)|\(controller.capture.isOn)" }) { [weak self] _ in self?.updateIcon() }
        UpdateService.shared.announce = { [weak controller] message in controller?.flowBar.toast(message, symbol: "arrow.down.circle", duration: 7) }
        UpdateService.shared.start()
        controller.commitments.refreshReminders()
        controller.commitments.analyzePending()
    }

    private func updateIcon() {
        let symbol: String?
        switch controller.phase {
        case .idle: symbol = controller.meetings.isRecording ? "record.circle" : nil
        case .recording: symbol = "waveform.circle.fill"
        case .processing: symbol = "ellipsis.circle"
        }
        if let symbol {
            var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Binders")
            var micLive = controller.meetings.isRecording
            if case .recording = controller.phase { micLive = true }
            if micLive {
                // Red while the microphone is live, and only then.
                image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [BindersTheme.NS.live]))
                image?.isTemplate = false
            } else {
                image?.isTemplate = true
            }
            item.button?.image = image
        } else {
            item.button?.image = BindersTheme.binderGlyph(capturing: controller.capture.isOn)
        }
    }

    private var statusText: String {
        let settings = AppSettings.shared
        switch controller.speech.state {
        case .downloading(let fraction): return "Downloading speech model… \(Int(fraction * 100))%"
        case .loading: return "Loading speech model…"
        case .failed: return "Speech model failed to load"
        default: break
        }
        if !Permissions.accessibility { return "Grant Accessibility access to start" }
        if Permissions.microphone != .authorized { return "Allow microphone access to start" }
        return "Hold \(settings.hotkeys.dictation.displayString()) to dictate"
    }

    /// While the library didn't open: the line the menu starts with, which opens what to do. Nil otherwise. It needs you,
    /// so its glyph, the problem style's, is amber.
    static func libraryLine(target: AnyObject?) -> NSMenuItem? {
        guard Store.shared.isFallback else { return nil }
        let line = NSMenuItem(title: Store.unavailableMessage, action: #selector(StatusItemController.openLibraryHelp), keyEquivalent: "")
        line.target = target
        line.image = NSImage(systemSymbolName: BindersTheme.problemSymbol, accessibilityDescription: "Warning")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [BindersTheme.NS.needsYou]))
        line.toolTip = "What to do, on binders.io"
        return line
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // First, before anything that would seem to work.
        if let line = Self.libraryLine(target: self) {
            menu.addItem(line)
            menu.addItem(.separator())
        }
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let error = controller.lastError {
            let item = NSMenuItem(title: "Last issue: \(error.prefix(70))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(to: menu, "Open Binders", #selector(openHub))
        add(to: menu, "Paste Last Transcript", #selector(pasteLast))
        add(to: menu, "Scratchpad", #selector(openScratchpad))
        add(to: menu, controller.meetings.isRecording ? "Stop Meeting Notes" : "Start Meeting Notes", #selector(toggleMeeting))
        let capture = add(to: menu, "Writing Capture", #selector(toggleCapture))
        capture.state = controller.capture.isOn ? .on : .off
        capture.toolTip = "Keep what you write in Teams, Outlook, Mail and allowed sites once it's sent (\(controller.capture.hotkeyHint))"
        let allDay = add(to: menu, "All-day Capture", #selector(toggleAllDay))
        allDay.state = controller.allDay.isOn ? .on : .off
        allDay.toolTip = "Listen for conversations through the day and keep them, written down, in your binders"
        if controller.allDay.isOn {
            add(to: menu, controller.allDay.isMuted ? "Unmute All-day Capture" : "Mute All-day Capture", #selector(toggleAllDayMute))
        }

        let recent = Store.shared.recentTranscripts(limit: 10).filter { !$0.finalText.isEmpty }
        if !recent.isEmpty {
            let submenu = NSMenu()
            for record in recent {
                let title = record.finalText.replacingOccurrences(of: "\n", with: " ")
                let entry = NSMenuItem(title: title.count > 60 ? String(title.prefix(60)) + "…" : title,
                                       action: #selector(copyTranscript(_:)), keyEquivalent: "")
                entry.representedObject = record.finalText
                entry.target = self
                entry.toolTip = "Click to copy"
                submenu.addItem(entry)
            }
            let recentItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
            recentItem.submenu = submenu
            menu.addItem(recentItem)
        }

        menu.addItem(.separator())
        let ai = add(to: menu, "AI Formatting", #selector(toggleAI))
        ai.state = AppSettings.shared.aiFormatting ? .on : .off
        let pending = UpdateService.shared.pendingVersion
        add(to: menu, pending.map { "Update to Binders \($0)…" } ?? "Check for Updates…", #selector(checkForUpdates))
        add(to: menu, "Settings…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        add(to: menu, "Quit Binders", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func openHub() { HubWindowController.shared.show(section: .home) }
    @objc private func toggleCapture() { controller.capture.toggle() }
    @objc private func toggleAllDay() {
        if controller.allDay.isOn { controller.allDay.turnOff() } else { Task { await controller.allDay.turnOn() } }
    }
    @objc private func toggleAllDayMute() {
        if controller.allDay.isMuted { controller.allDay.unmute() } else { controller.allDay.mute() }
    }
    @objc private func openSettings() { HubWindowController.shared.show(section: .settings) }
    @objc private func checkForUpdates() { UpdateService.shared.checkNow() }
    @objc private func openScratchpad() { ScratchpadController.shared.show() }
    @objc private func toggleMeeting() { Task { await controller.meetings.toggle() } }
    @objc private func pasteLast() { Task { await controller.pasteLast() } }
    @objc private func toggleAI() { AppSettings.shared.aiFormatting.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openLibraryHelp() { NSWorkspace.shared.open(Store.unavailableHelp) }

    @objc private func copyTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        TextInserter.copyToClipboard(text)
    }
}

@MainActor
enum MainMenu {
    /// The menu bar, with its Window menu as the app's: AppKit then lists the open windows in it, each card by its title.
    static func install() {
        NSApp.mainMenu = build()
        NSApp.windowsMenu = NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu
    }

    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Binders", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Binders", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Binders", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "Binders")

        // The commands' shortcuts are the ones set in Settings → Shortcuts.
        let file = NSMenu(title: "File")
        file.addItem(MenuShortcuts.item(.newNote))
        file.addItem(MenuShortcuts.item(.newNoteWindow))
        main.addItem(submenu: file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        // Find, in notes and anywhere else text can be searched.
        let find = NSMenu(title: "Find")
        for (title, key, modifiers, action) in [("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
                                                ("Find and Replace…", "f", [.command, .option], .showReplaceInterface),
                                                ("Find Next", "g", .command, .nextMatch),
                                                ("Find Previous", "g", [.command, .shift], .previousMatch),
                                                ("Use Selection for Find", "", .command, .setSearchString)] {
            let item = find.addItem(withTitle: title, action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = action.rawValue
        }
        edit.addItem(submenu: find, title: "Find")
        main.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(MenuShortcuts.item(.toggleDigest, title: "Show Digest"))
        view.addItem(.separator())
        view.addItem(MenuShortcuts.item(.zoomIn))
        // ⌘+ as well as ⌘=: the same key, with or without shift.
        if MenuShortcuts.shortcut(for: .zoomIn) == MenuCommand.zoomIn.defaultShortcut {
            let plus = NSMenuItem(title: "Zoom In", action: MenuCommand.zoomIn.action, keyEquivalent: "+")
            plus.target = HubWindowController.shared
            plus.isHidden = true
            plus.allowsKeyEquivalentWhenHidden = true
            view.addItem(plus)
        }
        view.addItem(MenuShortcuts.item(.zoomOut))
        view.addItem(MenuShortcuts.item(.actualSize))
        main.addItem(submenu: view, title: "View")

        let note = NSMenu(title: "Note")
        note.addItem(MenuShortcuts.item(.popOut))
        note.addItem(MenuShortcuts.item(.foldIntoBubble))
        note.addItem(.separator())
        note.addItem(MenuShortcuts.item(.putOnBoard))
        note.addItem(MenuShortcuts.item(.distill))
        main.addItem(submenu: note, title: "Note")

        let go = NSMenu(title: "Go")
        go.addItem(MenuShortcuts.item(.openQuickly, title: "Open Quickly…"))
        go.addItem(MenuShortcuts.item(.commandPalette, title: "Command Palette…"))
        main.addItem(submenu: go, title: "Go")

        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(.separator())
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu: windows, title: "Window")
        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
