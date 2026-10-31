import AppKit
import BindersKit

/// binders:// links: how other apps, Raycast, Shortcuts and the MCP server drive Binders.
///
///     binders://todo?text=call%20Sam%20tomorrow      binders://calendar?text=lunch%20with%20Sam%20tomorrow%20at%20noon
///     binders://ask?q=what%20did%20we%20decide       binders://dictate   binders://command
///     binders://capture/on|off|toggle                binders://meeting/start|stop|toggle   binders://meeting/<id>
///     binders://card/<id>   opens the card in its own window, without bringing Binders forward or putting the cursor in
///                           it (the BINDERS_LINK every woken agent gets)
///     binders://note/<id>   opens the note in its binder (a card put on the board from a note links back with one);
///                           ?section=<heading> opens it at that section (a card Distill placed links back so)
///     binders://open?section=home|writing|knowledge|settings[&page=automations]
///     binders://link/pair   turns the phone link on and opens pairing; the one-time link is written to
///                           Application Support/Binders/link-pairing.txt (yours only), for a phone that isn't at the Mac
///     binders://auth?token=bnp_…&state=…&hub=…   a hub's hand-back of Sign In (HubAccount): kept only for the sign-in
///                           this Mac started
@MainActor
enum URLCommands {
    static func handle(_ url: URL, controller: DictationController) {
        guard url.scheme?.lowercased() == "binders" else { return }
        let command = (url.host ?? "").lowercased()
        let path = url.pathComponents.filter { $0 != "/" }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let value = item.value { query[item.name] = value }
        }
        let text = (query["text"] ?? query["q"] ?? "").trimmed
        let hub = HubWindowController.shared

        switch command {
        case "todo":
            guard !text.isEmpty else { return warn("binders://todo needs ?text=") }
            guard Store.shared.allowsSave() else { return }
            // Anything on this Mac can open a link: the to-do says it came from one, and your automations leave it be
            // unless a rule takes such to-dos.
            _ = controller.commitments.addSpoken(text, origin: .link, madeBy: "a link")
        case "card":
            // Opening a card changes nothing, so it asks nothing.
            guard let id = (path.first ?? query["id"]).flatMap(UUID.init(uuidString:)) else { return warn("binders://card needs a card's id") }
            guard let card = controller.board.card(id) else {
                hub.show(section: .home)
                controller.flowBar.toast("That card isn't on a board any more.", symbol: "exclamationmark.circle", duration: 4)
                return
            }
            // Any app can open a link: the card's window comes forward without Binders taking what you're typing.
            CardWindows.shared.open(card, controller: controller, fromLink: true)
        case "note":
            // Opening a note changes nothing, so it asks nothing.
            guard let id = NoteCards.noteID(in: url) else { return warn("binders://note needs a note's id") }
            guard let note = Store.shared.note(id) else {
                hub.show(section: .home)
                controller.flowBar.toast("That note isn't in your binders any more.", symbol: "exclamationmark.circle", duration: 4)
                return
            }
            hub.navigation.open(note: note)
            // A card Distill placed links to its section: the note opens there.
            if let section = DistillLinks.heading(in: url) { hub.navigation.pendingNotePlace = section }
            hub.show()
        case "calendar":
            guard !text.isEmpty else { return warn("binders://calendar needs ?text=") }
            Task { await controller.addToCalendar(described: text) }
        case "ask":
            guard !text.isEmpty else { return warn("binders://ask needs ?q=") }
            hub.navigation.pendingKnowledgeQuery = text
            hub.show(section: .knowledge)
        case "link":
            guard (path.first ?? query["action"] ?? "").lowercased() == "pair" else { return warn("binders://link/pair") }
            // A paired device acts as you: nothing but you starts pairing one.
            guard confirmed("Pair a new iPhone?", detail: "Something on this Mac asked Binders to pair a device. A paired iPhone can read and change everything in Binders as you. Only go on if you're pairing your own iPhone.",
                            action: "Pair") else { return }
            if !controller.settings.phoneLink { controller.settings.phoneLink = true }
            controller.link.start()
            Task {
                for _ in 0..<30 where controller.link.status != .listening { try? await Task.sleep(for: .milliseconds(100)) }
                guard let pairing = await controller.link.beginPairing() else { return }
                let file = LinkServer.pairingLinkFile
                try? Data(pairing.url.absoluteString.utf8).write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                hub.navigation.pendingSettingsPage = .phone
                hub.show(section: .settings)
            }
        case "dictate", "command":
            // Starting turns the microphone on, and what's heard is kept as a dictation: never without you. Finishing doesn't ask.
            if case .idle = controller.phase,
               !confirmed(command == "dictate" ? "Start dictating?" : "Start Command Mode?",
                          detail: "Something on this Mac asked Binders to start listening, hands-free, with the microphone.", action: "Start") { return }
            controller.toggleSession(command == "dictate" ? .dictation : .command)
        case "capture":
            let asked = (path.first ?? query["state"] ?? "toggle").lowercased()
            let turningOn = asked == "on" || (asked != "off" && !controller.capture.isOn)
            // Turning it on reads what you write in other apps: never without you.
            if turningOn, !confirmed("Turn on writing capture?", detail: "Something on this Mac asked Binders to start keeping what you write in other apps.",
                                     action: "Turn On") { return }
            switch asked {
            case "on": controller.capture.start()
            case "off": controller.capture.stop()
            default: controller.capture.toggle()
            }
        case "meeting":
            let what = path.first ?? "toggle"
            if let id = UUID(uuidString: what) {
                hub.navigation.binderID = Store.shared.binderID(ofMeeting: id) ?? Store.shared.defaultBinder().id
                hub.navigation.pendingBinderTab = .meetings
                hub.navigation.pendingMeetingID = id
                hub.show(section: .binder)
            } else {
                let recording = controller.meetings.isRecording
                switch what.lowercased() {
                case "start" where recording, "stop" where !recording: break
                default:
                    // Starting a recording turns the microphone on: never without you.
                    if !recording, !confirmed("Record a meeting?", detail: "Something on this Mac asked Binders to start recording, with the microphone and what your Mac plays.",
                                              action: "Record") { return }
                    Task { await controller.meetings.toggle() }
                }
            }
        case "open":
            let section = HubSection(rawValue: (query["section"] ?? "home").lowercased()) ?? .home
            if let page = query["page"].flatMap({ SettingsPage(rawValue: $0.lowercased()) }) { hub.navigation.pendingSettingsPage = page }
            hub.show(section: section)
        case "auth":
            // A hub handing back the person token Settings → Team's Sign In asked for. Kept only when it carries the
            // state of the sign-in this Mac started; Settings → Team comes forward to say who's signed in.
            hub.navigation.pendingSettingsPage = .team
            hub.show(section: .settings)
            Task { await HubAccount.shared.finish(url) }
        case "apply":
            // A write from the MCP server or another local tool, waiting in the inbox.
            guard let name = query["file"] else { return warn("binders://apply needs ?file=") }
            Task { await InboxCommands.apply(named: name, controller: controller) }
        default:
            warn("Unknown binders:// command: \(command)")
        }
    }

    /// Asked by a link for the microphone, writing capture or a new paired device: Binders comes forward and asks, every
    /// time, so no agent, script, web page or link an agent left on a card can do it unseen. Binders' own buttons don't
    /// go through links.
    private static func confirmed(_ message: String, detail: String, action: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func warn(_ message: String) {
        Log.app.error("\(message, privacy: .public)")
    }
}
