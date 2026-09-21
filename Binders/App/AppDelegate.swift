import AppKit
import SwiftUI
import BindersKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DictationController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would both answer fn, and an older build would migrate the database back to its own schema.
        // Exit before anything opens the store.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != ownPID }) {
            Log.app.error("Another Binders is already running (pid \(existing.processIdentifier)); exiting")
            existing.activate()
            exit(0)
        }
        NSApp.mainMenu = MainMenu.build()
        let controller = DictationController()
        self.controller = controller
        HubWindowController.shared.controller = controller
        statusItem = StatusItemController(controller: controller)
        controller.start()

        if !AppSettings.shared.hasCompletedSetup || !Permissions.accessibility || Permissions.microphone != .authorized {
            HubWindowController.shared.show(section: .home)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        let recording = controller.meetings.isRecording
        let freeModel = AppSettings.shared.managesModelMemory
        guard recording || freeModel else { return .terminateNow }
        Task { @MainActor in
            if recording { await controller.meetings.prepareForTermination() }
            if freeModel { await controller.unloadLLM() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        HubWindowController.shared.show()
        return false
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
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Binders")
            image?.isTemplate = true
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
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
    @objc private func openSettings() { HubWindowController.shared.show(section: .settings) }
    @objc private func checkForUpdates() { UpdateService.shared.checkNow() }
    @objc private func openScratchpad() { ScratchpadController.shared.show() }
    @objc private func toggleMeeting() { Task { await controller.meetings.toggle() } }
    @objc private func pasteLast() { Task { await controller.pasteLast() } }
    @objc private func toggleAI() { AppSettings.shared.aiFormatting.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func copyTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        TextInserter.copyToClipboard(text)
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Binders", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Binders", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Binders", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "Binders")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: window, title: "Window")
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
