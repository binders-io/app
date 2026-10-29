import Foundation
import BindersKit

/// An agent's sessions for your iPhone, as the Agents page shows them (lane AC2, `AgentSessionLink`): its cards and chats,
/// and one as its terminal. The logs of a session the phone looks at are read as the page reads them, kept while it keeps
/// asking, and let go a minute and a half after it last asked. Only Binders' own logs of its runs are read.
@MainActor
final class PhoneSessions {
    private var followed: [String: (logs: AgentTerminalLogs, asked: Date)] = [:]
    private var sweeper: Timer?
    /// The ids of words sent, so words sent again (their reply lost on the way) go once.
    private var sent: [UUID] = []

    /// How long a session's logs are read after the phone last asked for it.
    static let kept: TimeInterval = 90

    // MARK: Asked

    /// `binders/sessions`: the agent named `agent`, and its sessions.
    func list(agent name: String, controller: DictationController) throws -> AgentSessionList {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MCPCore.ToolFailure("Say which agent.") }
        let profile = AgentRegistry.shared.agent(named: name)
        let cards = controller.board.cards(in: nil).sorted { $0.updatedAt > $1.updatedAt }
        let sessions = AgentWorkSessions.of(name, cards: cards, controller: controller).map { session in
            switch session.kind {
            case .card(let id):
                AgentSessionSummary(kind: .card, id: id.uuidString, title: session.title, updatedAt: session.updatedAt, running: session.running,
                                    needsYou: session.needsYou, done: session.done)
            case .chat(let id):
                AgentSessionSummary(kind: .chat, id: id.uuidString, title: session.title, updatedAt: session.updatedAt, running: session.running,
                                    needsYou: session.needsYou, done: session.done)
            }
        }
        return AgentSessionList(agent: profile?.name ?? name, what: AgentWorkspace.what(profile), avatar: AgentAvatar.kind(of: profile, name: name).rawValue,
                                chats: profile.map { AgentChatReach.chats($0.wake.kind) } ?? false,
                                terminal: AgentWorkSessions.tool(of: profile) != nil, sessions: sessions)
    }

    /// `binders/session`: one card's or chat's session as its terminal, once its logs are read.
    func shown(kind: String, id raw: String, agent: String?, controller: DictationController) async throws -> AgentSessionShown {
        guard let id = UUID(uuidString: raw) else { throw MCPCore.ToolFailure("No session with that id.") }
        switch kind {
        case AgentSessionSummary.Kind.card.rawValue:
            guard let card = controller.board.card(id) else { throw MCPCore.ToolFailure("That card isn't on this Mac any more.") }
            let name = agent.flatMap { $0.isEmpty ? nil : $0 } ?? card.assignee ?? card.meantFor ?? ""
            let profile = AgentRegistry.shared.agent(named: name)
            let events = controller.board.timeline(id)
            let tool = AgentSessionBlocks.tool(of: card, events: events, profile: profile)
            let files = AgentSessionBlocks.files(of: card)
            let logs = follow("card:" + raw, files: files, tool: tool)
            await logs.caughtUp()
            // Read again after the wait: the card may have moved.
            let events2 = controller.board.timeline(id)
            let running = controller.agents.isWorking(on: id)
            let blocks = AgentSessionBlocks.card(card, events: events2, logs: logs, tool: tool, files: files, running: running, controller: controller)
            let sent = AgentSessionLink.trimmed(blocks)
            let reach = controller.agents.commentReach(for: card, events: events2)
            return AgentSessionShown(kind: .card, id: raw, title: card.title.isEmpty ? "Untitled" : card.title, blocks: sent.blocks, earlier: sent.earlier,
                                     running: running, current: running ? logs.watches.last?.current : nil, since: running ? logs.watches.last?.startedAt : nil,
                                     intro: files.isEmpty && tool != nil ? AgentSessionBlocks.cardIntro(card, name: name) : nil,
                                     hint: Self.line(reach, answering: CardAnswering.of(card, events: events2)),
                                     needsYou: BoardDesign.needsYou(card.column), column: card.column.title)
        case AgentSessionSummary.Kind.chat.rawValue:
            guard let chat = controller.chats.chat(id) else { throw MCPCore.ToolFailure("That chat isn't on this Mac any more.") }
            let profile = AgentRegistry.shared.agent(named: chat.agent)
            let tool = AgentSessionBlocks.chatTool(profile)
            let files = controller.chats.logs(of: id)
            let logs = follow("chat:" + raw, files: files, tool: tool)
            await logs.caughtUp()
            let now = controller.chats.chat(id) ?? chat
            let running = now.status == .running
            let sent = AgentSessionLink.trimmed(AgentSessionBlocks.chat(now, logs: logs, tool: tool, files: controller.chats.logs(of: id), controller: controller))
            return AgentSessionShown(kind: .chat, id: raw, title: now.title, blocks: sent.blocks, earlier: sent.earlier, running: running,
                                     current: running ? logs.watches.last?.current : nil, since: running ? logs.watches.last?.startedAt : nil,
                                     hint: AgentSessionBlocks.chatHint(now, name: now.agent, profile: profile, controller: controller, keys: ""),
                                     blocked: AgentSessionBlocks.chatBlocked(name: now.agent, controller: controller))
        default:
            throw MCPCore.ToolFailure("A session is a card or a chat.")
        }
    }

    /// `binders/session-send`: your words into a card's session, as the Agents page's prompt sends them, when they reach the
    /// agent the phone asked you about (`agent`); else they stay on the card, waking at most that agent.
    func send(_ text: String, card raw: String, agent: String, id: UUID?, controller: DictationController) throws -> String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw MCPCore.ToolFailure("Write something first.") }
        guard let cardID = UUID(uuidString: raw), let card = controller.board.card(cardID) else { throw MCPCore.ToolFailure("That card isn't on this Mac any more.") }
        if let id {
            if sent.contains(id) { return "Sent." }
            sent.append(id)
            if sent.count > 200 { sent.removeFirst(sent.count - 200) }
        }
        let events = controller.board.timeline(cardID)
        let reaches = controller.agents.commentReach(for: card, events: events).agent
        if let reaches, BoardRules.isNamed(reaches, as: agent) || BoardRules.isNamed(agent, as: reaches) {
            if let why = AgentSessionBlocks.send(words, on: card, events: events, controller: controller) { throw MCPCore.ToolFailure(why) }
        } else if let why = controller.board.comment(card, text: words, by: .you, wake: .only(agent)) {
            throw MCPCore.ToolFailure(why)
        }
        return "Sent."
    }

    /// `binders/session-act`: Stop a card's run, as the Agents page's Stop does.
    func act(_ action: String, card raw: String, controller: DictationController) throws -> String {
        guard let id = UUID(uuidString: raw), controller.board.card(id) != nil else { throw MCPCore.ToolFailure("That card isn't on this Mac any more.") }
        guard action == "stop" else { throw MCPCore.ToolFailure("A card's session takes stop.") }
        controller.agents.stop(id)
        return "Stopped."
    }

    /// The prompt's line on the phone: the Agents page's, said without the Mac's card buttons.
    static func line(_ reach: CommentReach, answering: CardAnswering?) -> String? {
        let short = reach.agent?.shortAgentName ?? ""
        switch reach {
        case .sendsWithWakeNow(_, .youHoldIt) where answering == nil:
            return "You have this card. Binders puts your words on it and wakes \(short) now; letting go of the card hands it over."
        case .sendsWithWakeNow where answering == nil:
            return "Binders puts your words on the card and wakes \(short) now."
        case .finished:
            return "\(short) finished this. Your comment stays on the card; sending it back is on the card."
        case .notGiven:
            return "\(short) doesn't have it yet. Your comment stays on the card; Give to on the card hands it over."
        default:
            return reach.line(answering: answering)
        }
    }

    // MARK: Logs

    private func follow(_ key: String, files: [URL], tool: AgentSessionTool?) -> AgentTerminalLogs {
        let logs = followed[key]?.logs ?? AgentTerminalLogs()
        followed[key] = (logs, Date())
        logs.follow(files, tool: tool)
        if sweeper == nil {
            sweeper = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweep() }
            }
        }
        return logs
    }

    /// Lets go of the logs the phone stopped asking for.
    func sweep(now: Date = Date()) {
        for (key, entry) in followed where now.timeIntervalSince(entry.asked) > Self.kept {
            entry.logs.stop()
            followed[key] = nil
        }
        if followed.isEmpty {
            sweeper?.invalidate()
            sweeper = nil
        }
    }

    /// How many sessions' logs are being read, for the self-tests.
    var following: Int { followed.count }
}
