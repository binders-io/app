import Foundation
import BindersKit

// What the Mac's tools return (see docs/AUTOMATIONS.md), decoded with snake_case keys.

struct Todo: Decodable, Identifiable, Hashable {
    let id: String
    let task: String
    let owner: String?
    let kind: String
    var status: String
    let due: String?
    let dueAsSaid: String?
    let to: String?
    let source: String
    let sourceId: String?
    let binder: String?
    let created: String?
    /// The card it's on, when it's on a board.
    let cardId: String?
    let cardColumn: String?
    /// Where it came from (TodoOrigin: voice, phone, suggestion, moment, agent, link), from a Mac that says. Nil from one
    /// before that, and for checklist items.
    let origin: String?

    var isDone: Bool { status == "done" }
    var isOnBoard: Bool { !(cardId ?? "").isEmpty }
    /// Said to yourself (done at once, or offered and added): your own words, quoted where it's listed. A Mac before
    /// `origin` says so in its source (`TodoOrigin.isSaidToYourself(origin:source:)`).
    var isSaidToYourself: Bool { TodoOrigin.isSaidToYourself(origin: origin, source: source) }
    var dueDate: Date? { due.flatMap(Date.init(iso:)) }
    /// Whose it is, when it isn't simply yours.
    var ownerName: String? {
        guard let owner, !owner.isEmpty, owner != "You" else { return nil }
        return owner
    }
}

/// A card on a binder's board, as list_tasks gives it.
struct Card: Decodable, Identifiable, Hashable, BoardPlaced {
    let id: String
    let title: String
    var column: String
    var assignee: String
    var assigneeIsAgent: Bool
    var claimExpires: String
    let binder: String
    let due: String
    let links: Int
    let updated: String
    let preview: String
    let todo: String?
    /// Who it's meant for, and whether you said so or an agent only suggested it. Nil from a Mac before 0.8.1.
    let meantFor: String?
    let meantForConfirmed: Bool?

    var board: BoardColumn { BoardColumn(rawValue: column) ?? .backlog }
    /// Minutes left on an agent's claim.
    var minutesLeft: Int? {
        guard assigneeIsAgent, let date = Date(iso: claimExpires) else { return nil }
        return max(0, Int(date.timeIntervalSinceNow / 60))
    }
}

/// One card in full, as get_task gives it.
struct CardDetail: Decodable, Equatable, BoardPlaced {
    let id: String
    let title: String
    var column: String
    var assignee: String
    var assigneeIsAgent: Bool
    var claimExpires: String
    let binder: String
    let due: String
    let details: String
    let links: [String]
    let source: String
    let todo: String?
    let timeline: [CardEvent]
    /// Who it's meant for, and whether you said so or an agent only suggested it. Nil from a Mac before 0.8.1.
    let meantFor: String?
    let meantForConfirmed: Bool?
    /// What an agent asks your approval for while the card waits on it; nil when nothing does, and from a Mac before 0.8.1.
    var approval: CardApproval? = nil

    var board: BoardColumn { BoardColumn(rawValue: column) ?? .backlog }
    /// The agent's question the card is waiting on: its last, unless the card left Blocked since. One answered before the
    /// card went back to Blocked by hand isn't asking again.
    var question: CardEvent? {
        guard board == .blocked, let index = BoardRules.waitingQuestion(in: timeline.map { (kind: $0.kind, to: $0.to) }) else { return nil }
        return timeline[index]
    }
}

/// What an agent asks your approval for, as get_task gives it while the card waits: exactly who it goes to and what it
/// says, shown in the app before you approve or decline, never on the Lock Screen.
struct CardApproval: Decodable, Equatable, Hashable {
    /// The request's id: a decision is for this one and no other.
    let id: String
    let who: String
    let when: String
    let action: String
    let recipients: [String]
    let text: String
    let link: String
    /// "Claude Code asks to send an email": the words a notification may show.
    let headline: String
}

/// Where a card stands on its board, which taking it, letting it go or moving it changes.
protocol BoardPlaced {
    var column: String { get set }
    var assignee: String { get set }
    var assigneeIsAgent: Bool { get set }
    var claimExpires: String { get set }
}

extension BoardPlaced {
    /// The card as the Mac will have it once you take it (claim_task), let it go (release_task) or move it (update_task
    /// with `to`), by the rules the Mac keeps: shown at once, until the Mac's own copy arrives. Nil when the rules say no,
    /// which the Mac then explains.
    func after(_ tool: String, to target: BoardColumn? = nil, at now: Date = Date()) -> Self? {
        let state = CardState(column: BoardColumn(rawValue: column) ?? .backlog, assignee: assignee.isEmpty ? nil : assignee,
                              assigneeIsAgent: assigneeIsAgent, claimExpires: Date(iso: claimExpires))
        let next: CardState?
        switch tool {
        case "claim_task": next = try? BoardRules.claim(state, by: .you, at: now)
        case "release_task": next = try? BoardRules.release(state, by: .you, at: now)
        case "update_task": next = target.flatMap { try? BoardRules.move(state, to: $0, by: .you, agentsMayFinish: false, at: now) }
        default: next = nil
        }
        guard let next else { return nil }
        var placed = self
        placed.column = next.column.rawValue
        placed.assignee = next.assignee ?? ""
        placed.assigneeIsAgent = next.assigneeIsAgent
        placed.claimExpires = next.claimExpires.map { Date.isoParser.string(from: $0) } ?? ""
        return placed
    }
}

/// The agents your Mac hands cards to, as list_agents gives them: their names and kinds, and, from a Mac that says, where
/// each one's cards go and what goes with them, for asking before the first card goes to one.
struct AgentList: Codable, Equatable {
    struct Agent: Codable, Equatable, Hashable {
        let name: String
        /// How the Mac wakes it: claudeCode, command, webhook, shortcut or board.
        let wakes: String
        /// Where its cards go: "Anthropic", a web hook's host, a command's program, "Shortcuts on your Mac". Nil from a Mac
        /// before 0.8.1, as are the rest.
        var sendsTo: String? = nil
        /// Who it hands them to for its work ("OpenAI"), as said in Settings → Agents on the Mac or as its program says.
        /// Nil when nothing says, and from a Mac before it.
        var vendor: String? = nil
        /// Where they go and what goes with them, fingerprinted: a yes is for the agent as it is, and a change asks again.
        var fingerprint: String? = nil
        /// Whether Binders adds what the card's binder knows, and from what ("notes and meetings").
        var addsContext: Bool? = nil
        var contextFrom: String? = nil
        /// Whether you let it send, post or buy for you without asking; false, it drafts first and asks your approval.
        var mayAct: Bool? = nil
        /// Whether a Claude Code agent's cards go to the Claude Code session you have open in its repository, when one is.
        /// Nil from a Mac that doesn't say, and for every other agent.
        var openSession: Bool? = nil
        /// Your Mac may hand it a card without asking, from a "Binders, …" you say in your voice (auto_start). Only from a
        /// Mac told this iPhone sends its yes with what you say; nil otherwise.
        var autoStart: Bool? = nil
        /// To an iPhone that lists MomentPayload.autoFeature: whether Auto can hand it what you say ("takes"), or the
        /// first reason it can't (AutoReach.Agent's codes; one this build doesn't know reads as unknown). Nil otherwise.
        var auto: String? = nil
        /// It has the Mac's yes for Auto too, so its fingerprint has Auto's part and its disclosure says what Auto hands it.
        var autoModeStart: Bool? = nil
        /// Agents Binders can't weigh now that take one of its binders, so Auto hands it nothing there.
        var autoLeftOut: [String]? = nil
        /// Lane Y2, to an iPhone that lists ConversationPayload.soloFeature: it has the Mac's yes for captures too (its
        /// fingerprint has "solo", and its disclosure says what Auto reads from what you think out loud); whether it takes
        /// that ("takes", or "switch-before" on the Mac); and its fingerprint without "solo", so a yes given to Y1's words
        /// is told from one given to Y2's.
        var soloStart: Bool? = nil
        var solo: String? = nil
        var autoFingerprint: String? = nil
        /// A teammate's agent (lane DB2), from a Mac that lists LinkFeatures.teamAgents: its owner's Mac starts it, on cards
        /// in the shared binders it takes (`binders`, by name). Your Mac can't wake it; giving it a card asks first, naming
        /// its owner and who it sends cards to (`sendsTo`). Nil from any other Mac, and for your own agents.
        var teammate: Bool? = nil
        var owner: String? = nil
        /// The binders whose cards it takes, by name: a teammate's agent's shared binders, and, from a Mac with the Manager
        /// (`LinkFeatures.manager`), your own agent's, for where a message to it goes. Nil from any other Mac.
        var binders: [String]? = nil
        /// Your agent that has the Manager's role; nil from a Mac before it.
        var manager: Bool? = nil
        var headless: Bool? = nil
        var purpose: String? = nil
        var takesTeamCards: Bool? = nil
        var online: Bool? = nil

        var isTeammates: Bool { teammate == true }
    }
    let paused: Bool
    /// Every agent the Mac listed: yours, then teammates' (lane DB2).
    let all: [Agent]
    /// Your agents: what Give to, Auto and a capture's suggestions offer, as they always did.
    var agents: [Agent] { all.filter { !$0.isTeammates } }
    /// Teammates' agents, for cards in the shared binders each takes.
    var teammates: [Agent] { all.filter(\.isTeammates) }
    /// What Auto can hand over now, to an iPhone that lists MomentPayload.autoFeature; nil from any other Mac.
    var auto: Auto? = nil

    private enum CodingKeys: String, CodingKey {
        case paused, all = "agents", auto
    }

    init(paused: Bool, agents: [Agent], auto: Auto? = nil) {
        self.paused = paused
        self.all = agents
        self.auto = auto
    }

    /// list_agents' `auto` object. Its own type, every field Optional, as the list is read with snake-case keys
    /// (MacConnection.decode), which AutoReach's own keys don't take: a Mac that sends something odd here never stops the
    /// agents being read.
    struct Auto: Codable, Equatable, Hashable {
        var handsOver: Bool?
        var why: String?
        var model: String?
        var level: Double?

        var reach: AutoReach { AutoReach(handsOver: handsOver ?? false, why: why, model: model, level: level) }
    }
}

struct CardEvent: Decodable, Hashable {
    let when: String
    let who: String
    let agent: Bool
    let kind: String
    let text: String
    let to: String
}

struct BinderInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let archived: Bool
    let shared: Bool
    let meetings: Int
    let notes: Int
    let color: Int?

    var counts: String {
        [meetings == 1 ? "1 meeting" : "\(meetings) meetings", notes == 1 ? "1 note" : "\(notes) notes"].joined(separator: " · ")
    }
}

struct NoteSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let updated: String
    let binder: String
    let preview: String
    /// The folder it's in ("DevOps/Pipelines", "" at the top of its binder). Nil from a Mac before folders.
    var folder: String? = nil
    /// Distill is on for it (lane DS1): only from a Mac that lists LinkFeatures.distill, and only when it's on.
    var distill: Bool? = nil
}

/// A folder in a binder, as list_folders gives it, from a Mac that lists LinkFeatures.folders.
struct FolderInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    /// "Ops/DevOps": where it is in its binder.
    let path: String
    let binder: String
    let binderId: String
    /// "" at the top of the binder.
    let parentId: String
    let notes: Int
    let meetings: Int
    let folders: Int
}

/// Into a folder, on a binder's notes.
struct FolderLink: Hashable {
    let binder: BinderInfo
    let folder: FolderInfo
}

struct Note: Decodable {
    let id: String
    let title: String
    let updated: String
    let binder: String
    let text: String
    let digest: String
    /// The agent whose words are in it, until it's made yours on the Mac: made_by, edited_by and edited_at, sent only when
    /// set, and never by a Mac before these (so a note from one decodes as yours).
    let madeBy: String?
    let editedBy: String?
    let editedAt: String?
    /// Distill is on for it (lane DS1): its work shows under it. Nil from a Mac before Distill, and for every other note.
    var distill: Bool? = nil

    var agentMark: AgentMark { AgentMark(madeBy: madeBy, editedBy: editedBy, editedAt: editedAt.flatMap { Date(iso: $0) }) }
}

struct MeetingSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let date: String
    let durationMinutes: Int
    let attendees: [String]
    let binder: String
    let status: String
    let preview: String
}

struct Meeting: Decodable {
    let id: String
    let title: String
    let date: String
    let durationMinutes: Int
    let attendees: [String]
    let app: String
    let binder: String
    let notes: String
    let ownNotes: String
}

struct Passage: Decodable, Identifiable, Hashable {
    var id: String { "\(sourceId)|\(text.prefix(40))" }
    let kind: String
    let sourceId: String
    let title: String
    let date: String
    let binder: String
    let text: String
}

struct Answer: Decodable {
    let answer: String
    let sources: [Passage]
}

extension Date {
    init?(iso text: String) {
        guard !text.isEmpty, let date = Date.isoParser.date(from: text) else { return nil }
        self = date
    }

    /// One parser for every timestamp from the Mac, the one BindersKit reads agents' questions' times with too: making one
    /// is the slow part, and it's safe to share.
    static var isoParser: ISO8601DateFormatter { BoardRules.isoParser }
}

extension String {
    /// "Today 3:10 PM", "Tuesday", "Sep 12": a timestamp from the Mac, as people read dates.
    var friendlyDate: String {
        guard let date = Date(iso: self) else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today \(date.formatted(date: .omitted, time: .shortened))" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
