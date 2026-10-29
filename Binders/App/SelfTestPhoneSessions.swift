import Foundation
import BindersKit

extension SelfTest {
    /// An agent's sessions on your iPhone (lane AC2), as the link gives them: the same sessions the Agents page lists, a
    /// card's run as the same terminal, a chat, your words into a card's session (once, though sent twice; waking at most
    /// the agent the phone asked about), and its logs let go once the phone stops asking. Part of --selftest-agents-page.
    @MainActor
    static func phoneSessionsSelfTest(check: (Bool, String) -> Void, controller: DictationController, agent: String, other: String,
                                      working: TaskCard, review: TaskCard, chat: UUID?, sessions: [AgentWorkSession]) async {
        let phone = PhoneSessions()
        let board = controller.board
        func ids(_ list: [AgentWorkSession]) -> Set<String> {
            Set(list.map { switch $0.kind { case .card(let id), .chat(let id): id.uuidString } })
        }

        guard let listed = try? phone.list(agent: agent, controller: controller) else { return check(false, "the iPhone lists the agent's sessions") }
        check(Set(listed.sessions.map(\.id)) == ids(sessions) && listed.sessions.first?.id == working.id.uuidString,
              "the iPhone lists the sessions the Agents page does, the one running first: \(listed.sessions.map(\.title))")
        check(listed.avatar == "claude" && listed.chats && !listed.terminal && listed.what == "Checks the board itself",
              "with what the agent is and wears: \(listed.what), \(listed.avatar)")
        let back = AgentSessionLink.decode(AgentSessionList.self, from: AgentSessionLink.object(listed))
        check(back?.sessions.map(\.id) == listed.sessions.map(\.id) && back?.what == listed.what && back?.avatar == listed.avatar, "and reads back as sent")
        check(listed.sessions.first { $0.id == review.id.uuidString }?.state() == "needs you", "each says where it is")
        check((try? phone.list(agent: " ", controller: controller)) == nil, "a list for no agent is refused")

        // A card's run, as the Agents page's terminal shows it.
        guard let card = try? await phone.shown(kind: "card", id: working.id.uuidString, agent: agent, controller: controller) else {
            return check(false, "the iPhone shows a card's session")
        }
        let tools = card.blocks.compactMap { if case .tool(let tool) = $0.kind { tool } else { nil } }
        check(tools.contains { $0.name == "Bash" && $0.argument == "swift test --filter BoardTests" && $0.output == ["Executed 24 tests, with 0 failures"] }
                  && tools.contains { $0.name == "Update" && $0.diff.contains("- .frame(minWidth: 260)") },
              "a card's session comes as its terminal, read at once: \(tools.map { "\($0.name)(\($0.argument))" })")
        check(card.blocks.contains { $0.kind == .you("Can it fold Done into a narrower strip?") }, "with your words where they reached it")
        check(card.running && card.title == working.title && !card.needsYou && card.hint != nil, "running, with where your words go: \(card.hint ?? "none")")
        let cardBack = AgentSessionLink.decode(AgentSessionShown.self, from: AgentSessionLink.object(card))
        check(cardBack?.blocks == card.blocks && cardBack?.hint == card.hint
                  && abs((cardBack?.since ?? Date.distantPast).timeIntervalSince(card.since ?? Date.distantPast)) < 0.01,
              "and reads back as sent")
        check(phone.following == 1, "its logs are read while the iPhone asks")

        // One waiting on you.
        if let waits = try? await phone.shown(kind: "card", id: review.id.uuidString, agent: agent, controller: controller) {
            check(waits.needsYou && waits.column == BoardColumn.review.title && !waits.running, "a card in Review says it waits on you")
        } else {
            check(false, "the iPhone shows a card in Review")
        }

        // A chat with one that checks the board itself: your messages and its replies.
        if let chat, let shown = try? await phone.shown(kind: "chat", id: chat.uuidString, agent: agent, controller: controller) {
            check(shown.blocks.contains { $0.kind == .you("What's waiting on me today?") }
                      && shown.blocks.contains { if case .said(let text) = $0.kind { text.contains("**Waiting on you**") } else { false } },
                  "a chat comes as your messages and its replies")
            check(shown.hint?.contains("next checks the board") == true && shown.blocked == nil, "with where your words go: \(shown.hint ?? "none")")
        } else {
            check(false, "the iPhone shows a chat")
        }
        let goneCard = try? await phone.shown(kind: "card", id: UUID().uuidString, agent: agent, controller: controller)
        let notASession = try? await phone.shown(kind: "note", id: working.id.uuidString, agent: agent, controller: controller)
        check(goneCard == nil && notASession == nil,
              "a card that's gone, or what isn't a session, is refused")

        // Your words into a card's session: once, though sent twice.
        let words = "Use 120 pt for Done."
        let id = UUID()
        _ = try? phone.send(words, card: review.id.uuidString, agent: agent, id: id, controller: controller)
        _ = try? phone.send(words, card: review.id.uuidString, agent: agent, id: id, controller: controller)
        check(board.timeline(review.id).filter { $0.text == words }.count == 1, "your words go on the card once, though sent twice")
        // For an agent that isn't the one it reaches, they stay on the card.
        let aside = "Leave the spacing for now."
        _ = try? phone.send(aside, card: working.id.uuidString, agent: other, id: UUID(), controller: controller)
        check(board.timeline(working.id).contains { $0.text == aside }, "words for another agent stay on the card")
        check((try? phone.send(" ", card: working.id.uuidString, agent: agent, id: UUID(), controller: controller)) == nil
                  && (try? phone.act("archive", card: working.id.uuidString, controller: controller)) == nil,
              "nothing to send, or anything but Stop, is refused")

        phone.sweep(now: Date().addingTimeInterval(PhoneSessions.kept + 5))
        check(phone.following == 0, "its logs are let go once the iPhone stops asking")
    }
}
