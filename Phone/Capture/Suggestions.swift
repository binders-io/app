import BindersKit
import Foundation
import Observation
import UserNotifications

/// What the Mac offers about the conversations this iPhone heard: a card to put on a board, an idea for its Backlog, an
/// answer from your binders. They come as notifications (Add to Board, Give to an Agent, Not Now) and wait on the
/// conversation's page.
@MainActor
@Observable
final class SuggestionCenter {
    static let shared = SuggestionCenter()

    private(set) var suggestions: [ConversationSuggestion] = []
    /// Notify about them; they're on the conversation either way.
    var notifies: Bool {
        didSet { UserDefaults.standard.set(notifies, forKey: "suggestionNotifications") }
    }

    @ObservationIgnored weak var connection: MacConnection?
    @ObservationIgnored private var notified: Set<String>
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    static let add = "add"
    static let notNow = "not-now"
    static let give = "give"
    /// A card's or an idea's notification when the Mac takes Give to and there are agents: Give to an Agent opens it.
    static let giveCategory = "conversation-card-give"

    /// A card or idea whose Give to an Agent was tapped in its notification: its capture lists the agents.
    var pendingGive: String?

    private init() {
        notifies = UserDefaults.standard.object(forKey: "suggestionNotifications") as? Bool ?? true
        notified = Set(UserDefaults.standard.stringArray(forKey: "suggestionsNotified") ?? [])
        suggestions = (try? Data(contentsOf: Self.file)).map { ConversationSuggestion.decodeList(String(decoding: $0, as: UTF8.self)) } ?? []
    }

    func forConversation(_ id: UUID) -> [ConversationSuggestion] { suggestions.filter { $0.conversation == id } }

    /// The buttons the notifications carry, an agent's question's answer box among them, and what each shows while
    /// previews are hidden: a count, and a title that holds no words ("You asked: …" does, so an answer's stays hidden).
    static func registerCategories() {
        // Swiping one away says Not Now, as the button does.
        let card = UNNotificationCategory(identifier: ConversationSuggestion.cardCategory, actions: [
            UNNotificationAction(identifier: add, title: "Add to Board", options: [.authenticationRequired]),
            UNNotificationAction(identifier: notNow, title: "Not Now"),
        ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.waitingPlaceholder, options: [.customDismissAction, .hiddenPreviewsShowTitle])
        // Never first (a Watch's double tap runs the first), and only on an unlocked iPhone, in the app, which lists the
        // agents and asks first the first time for each.
        let giving = UNNotificationCategory(identifier: giveCategory, actions: [
            UNNotificationAction(identifier: add, title: "Add to Board", options: [.authenticationRequired]),
            UNNotificationAction(identifier: give, title: "Give to an Agent", options: [.authenticationRequired, .foreground]),
            UNNotificationAction(identifier: notNow, title: "Not Now"),
        ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.waitingPlaceholder, options: [.customDismissAction, .hiddenPreviewsShowTitle])
        let answer = UNNotificationCategory(identifier: ConversationSuggestion.answerCategory, actions: [], intentIdentifiers: [],
                                            hiddenPreviewsBodyPlaceholder: LockScreenText.answeredPlaceholder, options: [])
        // Capture's own notices hold no words, so their titles show too.
        let capture = [CaptureSession.pausedCategory, CaptureSession.firstTimeCategory, CaptureActivity.lostCategory].map {
            UNNotificationCategory(identifier: $0, actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.capturePlaceholder,
                                   options: [.hiddenPreviewsShowTitle])
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set([card, giving, answer, BoardQuestions.notificationCategory,
                                                                          BoardQuestions.consentNotificationCategory, BoardQuestions.statusNotificationCategory,
                                                                          BoardQuestions.approvalNotificationCategory,
                                                                          BoardQuestions.approvalConsentNotificationCategory]
                                                                        + MomentCenter.categories + capture))
    }

    /// Asks the Mac what it offers, and notifies about anything new on a conversation this iPhone heard.
    func refresh() async {
        guard let connection, connection.hasSuggestions else { return }
        // Asked for again while one runs: it runs once more after, so nothing the Mac offered meanwhile is missed.
        guard !refreshing else { return refreshAgain = true }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await refreshOnce(connection)
        } while refreshAgain
    }

    private func refreshOnce(_ connection: MacConnection) async {
        guard let reply = try? await connection.request(ConversationSuggestion.listMethod) as? [String: Any],
              let list = reply["suggestions"] as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: list) else { return }
        let fresh = ConversationSuggestion.decodeEach(data)
        let mine = Set(CaptureStore.shared.conversations.map(\.id))
        suggestions = fresh.filter { mine.contains($0.conversation) }
        save()
        // A capture with something new offered joins Needs you: with Binders in front, a warning by touch.
        Haptics.shared.waits(NeedsYouSection.fromCopies().items)
        // Who the agents are, for Give to on what's new.
        if givesTo(connection), suggestions.contains(where: { $0.status == .offered && $0.kind != .answer && !notified.contains($0.id) }) {
            await AgentConsents.refresh(connection)
        }
        for suggestion in suggestions where suggestion.status == .offered && !notified.contains(suggestion.id) {
            notified.insert(suggestion.id)
            if notifies { post(suggestion) }
        }
        UserDefaults.standard.set(Array(notified.suffix(500)), forKey: "suggestionsNotified")
    }

    /// Yes or no, from the notification or the conversation's page. Returns what the Mac said, or why it couldn't.
    @discardableResult
    func act(_ id: String, accept: Bool) async -> String {
        guard let connection, connection.hasBrain else { return "Pair with your Mac, or sign in to your hub, to put it on a board." }
        do {
            guard let reply = try await connection.request(ConversationSuggestion.actMethod, ["id": id, "action": accept ? "accept" : "dismiss"])
                    as? [String: Any] else { return "\(connection.brainName ?? "\(MacConnection.BrainWords)") is out of reach. Try again from the capture." }
            if let index = suggestions.firstIndex(where: { $0.id == id }) {
                suggestions[index].status = accept ? .accepted : .dismissed
                save()
            }
            // On the board: filed, by touch (with Binders in front).
            if accept { Haptics.shared.success() }
            return reply["message"] as? String ?? ""
        } catch {
            return error.localizedDescription
        }
    }

    /// Give to, from the conversation's page or its notification: the Mac puts the card or idea on its binder's board,
    /// meant for the agent and in Ready, and hands it over. Only a Mac that lists Give to: an older one would read it as
    /// Not Now. Returns what the Mac said, or why it couldn't.
    func give(_ id: String, to agent: String) async -> String {
        guard let connection, connection.hasBrain else { return "Pair with your Mac, or sign in to your hub, to give it to an agent." }
        guard givesTo(connection) else {
            return connection.brain == .hub ? "Your hub doesn't hand cards to agents from here yet. Add it to the board, then give it to an agent there." : "\(connection.brainName ?? "Your Mac") needs a newer Binders for that. Add it to the board, then use Give to on the card."
        }
        do {
            guard let reply = try await connection.request(ConversationSuggestion.actMethod, ["id": id, "action": "give", "agent": agent])
                    as? [String: Any] else { return "\(connection.brainName ?? "\(MacConnection.BrainWords)") is out of reach. Try again from the capture." }
            if let index = suggestions.firstIndex(where: { $0.id == id }) {
                suggestions[index].status = .accepted
                save()
            }
            // On the board for the agent: filed, by touch.
            Haptics.shared.success()
            return reply["message"] as? String ?? ""
        } catch {
            return error.localizedDescription
        }
    }

    /// The Mac takes Give to on what a capture brought up.
    func givesTo(_ connection: MacConnection? = nil) -> Bool {
        (connection ?? self.connection)?.macFeatures.contains(LinkFeatures.giveTo) ?? false
    }

    /// On a Lock Screen that shows previews, it says what the conversation brought up and when, not what was said in it,
    /// unless you turned your words on (LockScreen). Give to rides on a card's notification when the Mac takes it and has
    /// agents.
    private func post(_ suggestion: ConversationSuggestion) {
        let heard = CaptureStore.shared.conversations.first { $0.id == suggestion.conversation }?.started.formatted(date: .omitted, time: .shortened)
        let agents = AgentConsents.agents(connection)
        let giving = givesTo() && !(agents?.agents.isEmpty ?? true)
        Task {
            let text = LockScreenText.suggestion(suggestion, heard: heard, showsWords: await LockScreen.showsWords())
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            content.categoryIdentifier = suggestion.kind == .answer ? ConversationSuggestion.answerCategory
                : giving ? Self.giveCategory : ConversationSuggestion.cardCategory
            content.userInfo = ["suggestion": suggestion.id, "conversation": suggestion.conversation.uuidString]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: suggestion.id, content: content, trigger: nil))
        }
    }

    private static var file: URL { CaptureFiles.folder.appendingPathComponent("suggestions.json") }

    private func save() {
        try? Data(ConversationSuggestion.encodeList(suggestions).utf8).write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Where a tapped notification leads.
@MainActor
@Observable
final class PhoneNavigation {
    static let shared = PhoneNavigation()
    /// A conversation to open on the capture screen.
    var pendingConversation: UUID?
    /// A card to open, from an agent's question.
    var pendingCard: String?
    /// The capture screen: from the Live Activity, a Give to that asks first, or a moment this iPhone no longer has.
    var pendingCapture = false
    /// A moment's notification, opened: what it made, or its own page (MomentCenter.place).
    var pendingMoment: UUID?
    /// That moment opens on its own page whatever it made: from a word about it (it couldn't be done, or waits for your
    /// Mac), as Undo and Give to are there to try again.
    var pendingMomentPage = false
    /// What needs you, from its widget.
    var pendingNeedsYou = false
    /// The binder open on screen, so the tabs' Dictate files into it as its own button would.
    var binderInView: String?
    /// And the folder open in it, so a note dictated there goes in it.
    var folderInView: FolderInfo?
}
