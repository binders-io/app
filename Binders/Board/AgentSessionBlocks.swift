import Foundation
import BindersKit

/// An agent's session as its terminal shows it, for the Agents page and for your iPhone alike (lane AC2): a card's runs,
/// with your words where they reached it, or a chat's; and the prompt's line saying where your words go.
@MainActor
enum AgentSessionBlocks {
    // MARK: A card

    /// The tool a card's runs are, as the receipt that started the last says; else as the agent is woken now.
    static func tool(of card: TaskCard, events: [TaskEvent], profile: AgentProfile?) -> AgentSessionTool? {
        AgentSessionWatch.run(of: card, timeline: events)?.tool ?? AgentWorkSessions.tool(of: profile)
    }

    /// The logs of a card's runs, oldest first.
    static func files(of card: TaskCard) -> [URL] {
        AgentDoing.runLogs(links: card.links, card: card.id, logs: AgentPlaces.logs.path).map { URL(fileURLWithPath: $0) }
    }

    static func cardIntro(_ card: TaskCard, name: String) -> String {
        "\(card.title.isEmpty ? "This card" : "“\(card.title)”") hasn't had a run yet. When \(name.shortAgentName) starts on it, what it does shows here as it goes."
    }

    /// Every run of the card, with your answers and comments where they reached it, and those waiting; a card with no runs
    /// Binders read, its conversation.
    static func card(_ card: TaskCard, events: [TaskEvent], logs: AgentTerminalLogs, tool: AgentSessionTool?, files: [URL], running: Bool,
                     controller: DictationController) -> [AgentTerminalBlock] {
        guard tool != nil, !files.isEmpty else {
            // What you asked for leads: the card itself, then what was said on it.
            let asked = [card.title, card.details.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let start = AgentTerminalBlock(id: "card", kind: .run("The card · " + card.createdAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())))
            return [start] + (asked.isEmpty ? [] : [AgentTerminalBlock(id: "card-asked", kind: .you(asked))]) + conversation(events)
        }
        let yours = events.filter { CardConversation.isYours($0.conversation) }.map { ($0.createdAt, $0.text) }
        let (runs, after) = logs.runs(yours: yours)
        let why = running ? (controller.agents.takesLive(card.id) ? "Sending" : "Goes to it when this run ends")
            : controller.agents.unsent(for: card)?.why ?? "On the card"
        return AgentTerminal.blocks(runs, waiting: after.map { ($0, why) })
    }

    /// A card with no runs Binders read (one an agent checks itself, a web hook's): its conversation, your words and the
    /// agent's.
    static func conversation(_ events: [TaskEvent]) -> [AgentTerminalBlock] {
        var blocks: [AgentTerminalBlock] = []
        for event in events {
            let id = event.id.uuidString
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if CardConversation.isYours(event.conversation) {
                blocks.append(AgentTerminalBlock(id: id, kind: .you(text)))
            } else if event.kind == .woke {
                blocks.append(AgentTerminalBlock(id: id, kind: .run("Woken · " + event.createdAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))))
            } else if event.authorIsAgent, !text.isEmpty, [.progress, .question, .approval, .completed, .comment, .moved, .released].contains(event.kind) {
                let lead = event.kind == .question ? "Asks: " : event.kind == .approval ? "Asks your approval: " : ""
                blocks.append(AgentTerminalBlock(id: id, kind: .said(lead + text)))
            }
        }
        return blocks
    }

    /// As the card's composer sends: Send to (your words, then Wake Now) where only that reaches it, else a comment, which
    /// goes straight into a run that takes it, or on the card for its next one. Why it didn't go, or nil.
    static func send(_ words: String, on card: TaskCard, events: [TaskEvent], controller: DictationController) -> String? {
        let reach = controller.agents.commentReach(for: card, events: events)
        let answering = CardAnswering.of(card, events: events)
        if let first = reach.buttons(answering: answering).first, first.wakesNow {
            return CardActions.sendToAgent(card, words: words, controller: controller)
        }
        return controller.board.comment(card, text: words, by: .you)
    }

    // MARK: A chat

    /// The tool whose logs a chat's runs are: Claude Code's, when Binders runs it.
    static func chatTool(_ profile: AgentProfile?) -> AgentSessionTool? {
        if case .claudeCode = profile?.wake { .claude } else { nil }
    }

    /// Its runs' logs when Binders runs it (Claude Code), else your messages and its replies; and why its last run stopped.
    static func chat(_ chat: AgentChat, logs: AgentTerminalLogs, tool: AgentSessionTool?, files: [URL], controller: DictationController) -> [AgentTerminalBlock] {
        var blocks: [AgentTerminalBlock]
        if tool != nil, !files.isEmpty {
            let yours = chat.messages.filter { $0.from == .you }.map { ($0.at, $0.text) }
            let (runs, after) = logs.runs(yours: yours)
            let why = chat.status == .running ? (controller.chats.takesLive(chat.id) ? "Sending" : "Goes to it when it's done answering") : ""
            blocks = AgentTerminal.blocks(runs, waiting: after.map { ($0, why) })
        } else {
            blocks = chat.messages.map { message in
                if message.from == .you {
                    message.delivered || chat.status != .waiting || chat.messages.lastIndex(where: { $0.from == .agent }).map({ last in
                        chat.messages.firstIndex { $0.id == message.id }.map { $0 < last } ?? false
                    }) == true
                        ? AgentTerminalBlock(id: message.id.uuidString, kind: .you(message.text))
                        : AgentTerminalBlock(id: message.id.uuidString, kind: .waiting(message.text, why: "Waits for it to check the board"))
                } else {
                    AgentTerminalBlock(id: message.id.uuidString, kind: .said(message.text))
                }
            }
        }
        if let why = chat.why { blocks.append(AgentTerminalBlock(id: "why", kind: .end(ok: false, line: why))) }
        return blocks
    }

    /// Where your words to a chat go. `keys`: how a new line is made where you write.
    static func chatHint(_ chat: AgentChat?, name: String, profile: AgentProfile?, controller: DictationController,
                         keys: String = " Return sends, Shift-Return starts a new line.") -> String? {
        let short = name.shortAgentName
        guard let chat else { return nil }
        if profile?.wake == .board { return "\(short) reads this when it next checks the board, and answers here." }
        if chat.status == .running {
            return controller.chats.takesLive(chat.id) ? "\(short) takes your words now: they go straight into its session."
                : "What you write now goes to \(short) when it's done answering."
        }
        return "Carries on the chat's session." + keys
    }

    /// Why nothing can be sent to a chat with it now.
    static func chatBlocked(name: String, controller: DictationController) -> String? {
        guard let profile = controller.chats.agent(named: name) else { return "\(name) can't chat now. Look at it in Settings → Agents." }
        return controller.chats.problem(with: profile)
    }
}
