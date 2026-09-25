import AppKit
import BindersKit

/// binders:// links: how other apps, Raycast, Shortcuts and the MCP server drive Binders.
///
///     binders://todo?text=call%20Sam%20tomorrow      binders://calendar?text=lunch%20with%20Sam%20tomorrow%20at%20noon
///     binders://ask?q=what%20did%20we%20decide       binders://dictate   binders://command
///     binders://capture/on|off|toggle                binders://meeting/start|stop|toggle   binders://meeting/<id>
///     binders://open?section=home|writing|knowledge|settings[&page=automations]
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
            _ = controller.commitments.addSpoken(text)
        case "calendar":
            guard !text.isEmpty else { return warn("binders://calendar needs ?text=") }
            Task { await controller.addToCalendar(described: text) }
        case "ask":
            guard !text.isEmpty else { return warn("binders://ask needs ?q=") }
            hub.navigation.pendingKnowledgeQuery = text
            hub.show(section: .knowledge)
        case "dictate":
            controller.toggleSession(.dictation)
        case "command":
            controller.toggleSession(.command)
        case "capture":
            switch (path.first ?? query["state"] ?? "toggle").lowercased() {
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
                default: Task { await controller.meetings.toggle() }
                }
            }
        case "open":
            let section = HubSection(rawValue: (query["section"] ?? "home").lowercased()) ?? .home
            if let page = query["page"].flatMap({ SettingsPage(rawValue: $0.lowercased()) }) { hub.navigation.pendingSettingsPage = page }
            hub.show(section: section)
        case "apply":
            // A write from the MCP server or another local tool, waiting in the inbox.
            guard let name = query["file"] else { return warn("binders://apply needs ?file=") }
            Task { await InboxCommands.apply(named: name, controller: controller) }
        default:
            warn("Unknown binders:// command: \(command)")
        }
    }

    private static func warn(_ message: String) {
        Log.app.error("\(message, privacy: .public)")
    }
}
