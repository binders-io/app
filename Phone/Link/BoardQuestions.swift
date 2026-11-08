import BindersKit
import Foundation
import UIKit
@preconcurrency import UserNotifications

/// An agent's question on a card rings on this iPhone, as it does on the Mac, and is answered from the notification; so
/// does an agent's request for your approval, which opens its card, where who it goes to and exactly what it says are
/// above Approve and Decline. Heard while the app holds the link to the Mac: in front, or in the background while All-day
/// capture listens.
@MainActor
final class BoardQuestions {
    static let shared = BoardQuestions()
    static let category = "board-question"
    /// The same, for a question from an agent you haven't said yes to as it's set up now: Answer opens the card, which asks.
    static let consentCategory = "board-question-consent"
    static let answer = "answer"
    static let open = "open"

    weak var connection: MacConnection?
    /// Questions already rung, as card and the moment it was asked, so each rings once.
    private var rung: [String]
    /// The pairing whose boards this iPhone has looked at. The first look at a pairing's boards only learns what's
    /// waiting there: questions from before don't all ring at once. Until a first look has read every card, a question
    /// asked since it began still rings.
    private var primedFor: String?
    private var primingFor: String?
    private var primingSince: Date
    /// When each waiting card last changed, as last read: only a card that changed is read again.
    private var seen: [String: String] = [:]
    /// Each open card's column as last read, for what's worth a word: an agent picking up a card you handed it, or
    /// finishing one for you to check. Learned quietly on a pairing's first look.
    private var columns: [String: String]
    private var newsPrimedFor: String?
    static let statusCategory = "board-status"
    private var checking = false
    private var again = false

    private init() {
        let defaults = UserDefaults.standard
        rung = defaults.stringArray(forKey: "questionsRung") ?? []
        primedFor = defaults.string(forKey: "questionsPrimedFor")
        primingFor = defaults.string(forKey: "questionsPrimingFor")
        primingSince = defaults.object(forKey: "questionsPrimingSince") as? Date ?? .distantFuture
        columns = defaults.dictionary(forKey: "boardColumnsSeen") as? [String: String] ?? [:]
        newsPrimedFor = defaults.string(forKey: "boardNewsPrimedFor")
    }

    /// Open, on an agent's work: picked up, or ready for you to check. With previews hidden: who, and a count; the card's
    /// title, which can be what you said, waits for the unlock.
    static var statusNotificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: statusCategory, actions: [
            UNNotificationAction(identifier: open, title: "Open", options: [.foreground]),
        ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.boardsPlaceholder, options: [.hiddenPreviewsShowTitle])
    }

    /// The notification's answer box, and Open. Answering needs the iPhone unlocked: an answer sets an agent back to work.
    /// With previews hidden: who asked, and a count; the card's title and the question wait for the unlock.
    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: category, actions: [
            UNTextInputNotificationAction(identifier: answer, title: "Answer", options: [.authenticationRequired], textInputButtonTitle: "Send",
                                          textInputPlaceholder: "Your answer"),
            UNNotificationAction(identifier: open, title: "Open", options: [.foreground]),
        ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.waitingPlaceholder, options: [.hiddenPreviewsShowTitle])
    }

    /// Answering an agent you haven't said yes to: what you type opens the card, which says where your words go and asks
    /// first (App Store 5.1.2(i)), then sends them.
    static var consentNotificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: consentCategory, actions: [
            UNTextInputNotificationAction(identifier: answer, title: "Answer", options: [.authenticationRequired, .foreground], textInputButtonTitle: "Send",
                                          textInputPlaceholder: "Your answer"),
            UNNotificationAction(identifier: open, title: "Open", options: [.foreground]),
        ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.waitingPlaceholder, options: [.hiddenPreviewsShowTitle])
    }

    static let approvalCategory = "board-approval"
    /// What builds before this one rang for an agent you hadn't said yes to. Still registered, as one may still be in
    /// Notification Center: it opens the card too.
    static let approvalConsentCategory = "board-approval-consent"
    /// The buttons builds before this one put on an approval's notification, which decided from the Lock Screen.
    static let approve = "approve"
    static let decline = "decline"

    /// What an agent asks your approval for: Open, which takes an unlocked iPhone, and nothing that decides. You approve
    /// or decline on the card, where exactly who it goes to and what it says are above the buttons, as on the Mac. What it
    /// shows follows the Lock Screen rule: who asks and what, never who it goes to or what it says.
    static var approvalNotificationCategory: UNNotificationCategory { approvalCategory(approvalCategory) }

    /// The same, under the identifier builds before this one used for an agent you hadn't said yes to.
    static var approvalConsentNotificationCategory: UNNotificationCategory { approvalCategory(approvalConsentCategory) }

    private static func approvalCategory(_ identifier: String) -> UNNotificationCategory {
        UNNotificationCategory(identifier: identifier, actions: [
            UNNotificationAction(identifier: open, title: "Open", options: [.authenticationRequired, .foreground]),
        ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: LockScreenText.waitingPlaceholder, options: [.hiddenPreviewsShowTitle])
    }

    /// Every category a card's question or request for approval rings with.
    static let waitingCategories: Set<String> = [category, consentCategory, approvalCategory, approvalConsentCategory]

    /// Who asked, from a question's notification: its agent, or from a notification of an earlier build, its title.
    nonisolated static func asker(_ content: UNNotificationContent) -> String? {
        if let agent = content.userInfo["agent"] as? String, !agent.isEmpty { return agent }
        return content.title.hasSuffix(" asked") ? String(content.title.dropLast(" asked".count)) : nil
    }

    /// A board changed on the Mac: a new question from an agent rings, and one that no longer waits goes.
    func check() async {
        guard let connection, connection.isConnected else { return }
        guard !checking else {
            again = true
            return
        }
        checking = true
        defer { checking = false }
        repeat {
            again = false
            await look(connection)
        } while again
    }

    private func look(_ connection: MacConnection) async {
        guard let pairing = connection.brainKey,
              let text = try? await connection.call("list_tasks", ["column": BoardColumn.blocked.rawValue]),
              let waiting = try? MacConnection.decode([Card].self, from: text) else { return }
        let primed = primedFor == pairing
        if !primed, primingFor != pairing {
            primingFor = pairing
            primingSince = Date()
            UserDefaults.standard.set(pairing, forKey: "questionsPrimingFor")
            UserDefaults.standard.set(primingSince, forKey: "questionsPrimingSince")
        }
        // Learned only from a look that read every card: one it couldn't read now mustn't ring later for an old question.
        var whole = true
        /// Who the agents are now, asked once before the first question rings, so its Answer button asks first when it should.
        var agentsKnown = false
        await withdraw(except: Set(waiting.map(\.id)))
        for card in waiting where seen[card.id] != card.updated {
            guard let text = try? await connection.call("get_task", ["id": card.id]),
                  let detail = try? MacConnection.decode(CardDetail.self, from: text) else {
                whole = false
                continue
            }
            seen[card.id] = card.updated
            // A request for your approval, if the Mac didn't say so the moment it was asked.
            if let approval = detail.approval {
                let key = Self.approvalKey(approval.id)
                guard !rung.contains(key) else { continue }
                rung.append(key)
                if primed || Date(iso: approval.when).map({ $0 > primingSince.addingTimeInterval(-60) }) == true {
                    // It newly needs you: with Binders in front, a warning by touch too.
                    Haptics.shared.newlyNeedsYou()
                    if !agentsKnown {
                        await AgentConsents.refresh(connection)
                        agentsKnown = true
                    }
                    await post(AgentApproval.Notice(card: detail.id, approval: approval.id, agent: approval.who, headline: approval.headline,
                                                    title: detail.title, asked: approval.when))
                }
                continue
            }
            guard let question = detail.question, question.agent else { continue }
            let key = BoardRules.questionKey(card: card.id, asked: question.when)
            guard !rung.contains(key) else { continue }
            rung.append(key)
            // A minute's grace for the two clocks.
            let asked = Date(iso: question.when)
            if primed || asked.map({ $0 > primingSince.addingTimeInterval(-60) }) == true {
                Haptics.shared.newlyNeedsYou()
                if !agentsKnown {
                    await AgentConsents.refresh(connection)
                    agentsKnown = true
                }
                await post(question, on: detail)
            }
        }
        if !primed, whole {
            primedFor = pairing
            UserDefaults.standard.set(pairing, forKey: "questionsPrimedFor")
        }
        UserDefaults.standard.set(Array(rung.suffix(300)), forKey: "questionsRung")
        await news(connection, pairing: pairing)
    }

    /// Every open card, against what was last read: an agent that picked up a card you handed it, quietly; one that put
    /// its work in Review, with a sound. Only titles and who: never what's in the card.
    private func news(_ connection: MacConnection, pairing: String) async {
        guard let text = try? await connection.call("list_tasks"), let cards = try? MacConnection.decode([Card].self, from: text) else { return }
        // The copy the screens start from, and the widgets read: fresh, with the app in the background too.
        Cache.store(text, for: "tasks-all")
        CaptureActivity.update()
        let primed = newsPrimedFor == pairing
        for card in cards {
            let before = columns[card.id].flatMap(BoardColumn.init(rawValue:))
            columns[card.id] = card.column
            guard primed, let news = BoardRules.news(before: before, now: card.board, byAgent: card.assigneeIsAgent, meantFor: card.meantFor,
                                                     confirmed: card.meantForConfirmed ?? false) else { continue }
            await postStatus(news, on: card)
        }
        let open = Set(cards.map(\.id))
        columns = columns.filter { open.contains($0.key) }
        UserDefaults.standard.set(columns, forKey: "boardColumnsSeen")
        if !primed {
            newsPrimedFor = pairing
            UserDefaults.standard.set(pairing, forKey: "boardNewsPrimedFor")
        }
        // "Ready for review" goes once the card has left Review.
        let inReview = Set(cards.filter { $0.board == .review }.map(\.id))
        let center = UNUserNotificationCenter.current()
        let stale = await center.deliveredNotifications()
            .filter { $0.request.content.categoryIdentifier == Self.statusCategory }
            .filter { !inReview.contains($0.request.content.userInfo["card"] as? String ?? "") && $0.request.content.title == "Ready for review" }
            .map(\.request.identifier)
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }

    private func postStatus(_ news: BoardNews, on card: Card) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        switch news {
        case .pickedUp:
            content.title = "\(card.assignee) picked it up"
            content.interruptionLevel = .passive
        case .review:
            content.title = "Ready for review"
            content.body = "From \(card.assignee)"
            content.sound = .default
        }
        // The card's title can be what you said: on a Lock Screen that shows previews, where it is instead.
        content.subtitle = LockScreenText.card(card.title, binder: card.binder, showsWords: await LockScreen.showsWords())
        content.categoryIdentifier = Self.statusCategory
        content.userInfo = ["card": card.id]
        try? await center.add(UNNotificationRequest(identifier: "status-\(card.id)", content: content, trigger: nil))
    }

    private func post(_ question: CardEvent, on card: CardDetail) async {
        let center = UNUserNotificationCenter.current()
        // Permission is asked for only with the app open; in the background, only one already given counts.
        if UIApplication.shared.applicationState == .active {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        } else {
            guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        }
        let content = UNMutableNotificationContent()
        content.title = "\(question.who) asked"
        // The card's title can be what you said: on a Lock Screen that shows previews, where it is instead. The question
        // is the agent's, to answer from here.
        content.subtitle = LockScreenText.card(card.title, binder: card.binder, showsWords: await LockScreen.showsWords())
        content.body = question.text
        content.sound = .default
        content.categoryIdentifier = AgentConsents.answerWaits(for: question.who, connection: connection) ? Self.consentCategory : Self.category
        // Its title too, for the word that an answer typed into it waits here, which says it only where it may.
        content.userInfo = ["card": card.id, "asked": question.when, "agent": question.who, "title": card.title]
        try? await center.add(UNNotificationRequest(identifier: Self.identifier(card.id), content: content, trigger: nil))
    }

    /// Answered here, on the Mac or by a move: questions on cards that no longer wait go from the Lock Screen.
    private func withdraw(except waiting: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let stale = await center.deliveredNotifications()
            .filter { Self.waitingCategories.contains($0.request.content.categoryIdentifier) }
            .filter { !waiting.contains($0.request.content.userInfo["card"] as? String ?? "") }
            .map(\.request.identifier)
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }

    /// The answer typed into the notification, to the question asked at `asked`. When the Mac can't be reached it waits
    /// here, and a note says so; tapped, the note opens the card. To an agent you haven't said yes to as it's set up now
    /// (`agent`), it waits on this iPhone instead: the card asks first, opened at once when the notification opened the
    /// app (`opened`), else from a note that says so.
    func answer(_ card: String, asked: String?, text: String, about title: String, agent: String? = nil, opened: Bool = false) async {
        guard let connection else { return }
        // The card's title can be what you said: named in the word about your answer only where your words may show.
        let yours = LockScreenText.yourAnswer(on: title, showsWords: await LockScreen.showsWords())
        if let agent, AgentConsents.answerWaits(for: agent, connection: connection) {
            AgentConsents.hold(AgentConsents.HeldAnswer(text: text, asked: asked, agent: agent), card: card)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifier(card)])
            if opened {
                PhoneNavigation.shared.pendingCard = card
            } else {
                let note = UNMutableNotificationContent()
                note.body = "\(yours) waits on this iPhone. Open the card to say yes to giving \(agent) your words, and it goes."
                note.userInfo = ["card": card]
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.noteIdentifier(card), content: note, trigger: nil))
            }
            return
        }
        let result = await connection.answer(card: card, question: asked, text: text)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifier(card)])
        // Sent, or turned down: `answerSettled` has already said so.
        guard result == .kept else { return }
        let note = UNMutableNotificationContent()
        note.body = "\(yours) waits on this iPhone. It goes to \(connection.brainName ?? "your Mac") the next time Binders reaches it."
        note.userInfo = ["card": card]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.noteIdentifier(card), content: note, trigger: nil))
    }

    /// An answer reached the Mac, or the Mac turned it down because its question wasn't waiting any more: the note that it
    /// waited goes, or says it didn't go.
    func answerSettled(card: String, sent: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.noteIdentifier(card)])
        guard !sent else { return }
        let note = UNMutableNotificationContent()
        note.body = "An answer you typed didn't go: its question isn't waiting on \(connection?.brainName ?? "your Mac") any more."
        center.add(UNNotificationRequest(identifier: Self.noteIdentifier(card), content: note, trigger: nil))
    }

    // MARK: Approvals

    /// An agent asks your approval, as the Mac said the moment it asked: it rings once, in place of anything else the card
    /// rang for.
    func approvalAsked(_ notice: AgentApproval.Notice) async {
        let key = Self.approvalKey(notice.approval)
        guard !rung.contains(key) else { return }
        rung.append(key)
        UserDefaults.standard.set(Array(rung.suffix(300)), forKey: "questionsRung")
        // It newly needs you: with Binders in front, a warning by touch too.
        Haptics.shared.newlyNeedsYou()
        // Who the agents are now, so its buttons ask first when they should.
        if let connection { await AgentConsents.refresh(connection) }
        await post(notice)
    }

    private func post(_ notice: AgentApproval.Notice) async {
        let center = UNUserNotificationCenter.current()
        if UIApplication.shared.applicationState == .active {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        } else {
            guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        }
        let text = notice.notification
        let content = UNMutableNotificationContent()
        content.title = text.title
        // The card's title can be what you said: on a Lock Screen that shows previews, where it is instead.
        content.subtitle = LockScreenText.card(notice.title, binder: Self.binder(of: notice.card), showsWords: await LockScreen.showsWords())
        content.body = text.body
        content.sound = .default
        // Open alone: the card asks first, for an agent you haven't said yes to, when you approve or decline there.
        content.categoryIdentifier = Self.approvalCategory
        content.userInfo = ["card": notice.card, "approval": notice.approval, "agent": notice.agent]
        try? await center.add(UNNotificationRequest(identifier: Self.identifier(notice.card), content: content, trigger: nil))
    }

    /// Approve or Decline, tapped on a notification an earlier build rang with, before this build put its own buttons in
    /// place: nothing is decided from a notification, as it can't show who it goes to or what it says. The card opens
    /// where the tap brought the app up (`opened`); otherwise the notification stays, and a note says to open the card.
    func decisionTapped(card: String, opened: Bool) {
        if opened {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifier(card)])
            PhoneNavigation.shared.pendingCard = card
        } else {
            note(card, "Nothing was decided. \(AgentApproval.Notice.openToDecide)")
        }
    }

    /// A decision, to the Mac: what it said, or why it didn't go. Refused when the request isn't waiting any more, or was
    /// replaced by another, so a tap on an old notification never approves something else.
    static func send(_ decision: AgentApproval.Decision, over connection: MacConnection) async -> (message: String, problem: String?) {
        let what = decision.approve ? "approval" : "decline"
        // Only to a Mac that takes them (one whose agents ask for approval at all).
        guard connection.macFeatures.contains(LinkFeatures.approvals) else {
            return ("", connection.brain == .hub ? "Your hub doesn't take your \(what) from here yet." : "\(connection.brainName ?? "Your Mac") needs a newer Binders to take your \(what).")
        }
        do {
            guard let reply = try await connection.request(LinkFeatures.decisionMethod, decision.params) as? [String: Any] else {
                return ("", "\(connection.brainName ?? "Your Mac") is out of reach, so your \(what) didn't go. Open the card to try again.")
            }
            return (reply["message"] as? String ?? "", nil)
        } catch LinkClient.Failure.rejected(let message) {
            return ("", "Your \(what) didn't go: \(message)")
        } catch {
            return ("", "Your \(what) didn't go: \(error.localizedDescription)")
        }
    }

    /// A word about a decision that didn't go, which opens the card.
    private func note(_ card: String, _ text: String) {
        let note = UNMutableNotificationContent()
        note.body = text
        note.userInfo = ["card": card]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.noteIdentifier(card), content: note, trigger: nil))
    }

    /// The binder a card is on, from the copy of the boards this iPhone keeps: what a notification names in place of the
    /// card's title.
    static func binder(of card: String) -> String? {
        let cards = Cache.load("tasks-all").flatMap { try? MacConnection.decode([Card].self, from: $0) }
        return cards?.first { $0.id == card }.map(\.binder)
    }

    private static func approvalKey(_ approval: String) -> String { "approval|\(approval.lowercased())" }

    private static func identifier(_ card: String) -> String { "question-\(card)" }
    private static func noteIdentifier(_ card: String) -> String { "answered-\(card)" }
}
