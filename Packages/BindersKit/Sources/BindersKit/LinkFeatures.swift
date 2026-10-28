import Foundation

/// What each end of the link understands beyond the tools, said in `binders/hello`. The Mac lists the methods it takes
/// (`conversation`, `suggestions`…); a phone lists the suggestion kinds and notifications it reads, and whether it's told
/// what runs say they're doing (`workStreamsDoing`). Neither sends the other anything it didn't list.
///
/// iPhone 2.0 lists nothing, and reads only card and answer suggestions and `binders/changed`: it decodes suggestions
/// against a closed list, so one kind it doesn't know empties the whole refresh, and it takes any other notification as
/// "everything changed".
public enum LinkFeatures {
    public static let changed = "binders/changed"
    /// A Mac with the Manager (lane MG1): `binders/manager` asks it something or asks for a tidy, `binders/manager-requests`
    /// lists what you asked with its replies, changes and suggested note edits, and `binders/manager-act` stops one, undoes
    /// one's changes, or accepts or dismisses a suggested edit. `binders/changed` says "manager" when any of it changes.
    public static let manager = "manager"
    public static let managerMethod = "binders/manager"
    public static let managerListMethod = "binders/manager-requests"
    public static let managerActMethod = "binders/manager-act"
    /// A Mac with chats with your agents (lane AC1): `binders/chats` lists them (one agent's, with `agent`), `binders/chat`
    /// gives one with its messages and what its run has written so far, `binders/chat-send` sends your message (a new chat
    /// without `chat`), and `binders/chat-act` stops its run. `binders/changed` says "chats" when any of it changes.
    public static let chats = "agentChats"
    public static let chatListMethod = "binders/chats"
    public static let chatMethod = "binders/chat"
    public static let chatSendMethod = "binders/chat-send"
    public static let chatActMethod = "binders/chat-act"
    /// A Mac that takes `binders/warm` loads its model when the phone hears someone start talking, so the write-up
    /// doesn't wait for it.
    public static let warm = "warm"
    public static let warmMethod = "binders/warm"
    /// A Mac that remembers the `request_id` a phone sends with notes, to-dos, answers and hand-offs, so one sent twice
    /// (its reply lost on the way) is saved once.
    public static let dedupe = "dedupe"
    /// A Mac that streams Ask: keyword hits first, then the answer as it's written, in `binders/ask-progress`.
    public static let askProgress = "askProgress"
    public static let askProgressMethod = "binders/ask-progress"
    /// A Mac that gives a capture's card or idea to the agent you pick: `binders/suggestion` with action "give" and the
    /// agent's name. One without it takes any action but "accept" as Not Now, so a phone sends "give" only to a Mac that
    /// lists this.
    public static let giveTo = "giveTo"
    /// A Mac whose agents ask for your approval before they send, post or buy, in `binders/approval`: it tells a phone
    /// that lists that notification when an agent asks (`AgentApproval.Notice`), and takes your decision in
    /// `binders/decision` (`AgentApproval.Decision`). Macs up to 0.8.0 listed it before they had any approvals to ask.
    public static let approvals = "approvals"
    public static let approvalMethod = "binders/approval"
    public static let decisionMethod = "binders/decision"
    /// A phone that shows what a run Binders started says it's doing (`doing` in work_streams, and the summary's "… and
    /// says: …") and keeps it out of its saved copy of the reply. A phone without it saves work_streams whole, so the Mac
    /// leaves the run's words out of the reply it gives that phone.
    public static let workStreamsDoing = "workStreamsDoing"
    /// A Mac that says where a phone can reach it: `addresses` in its hello reply (LinkAddress objects, in the order to try
    /// them) to a phone that lists `addresses` too, and `binders/addresses` `{addresses}` with the whole new list when it
    /// changes, to a phone that lists that notification. A phone that lists neither is told neither.
    public static let addresses = "addresses"
    public static let addressesMethod = "binders/addresses"
    /// A Mac that wakes the agent holding a card in progress when you comment on it, and reads `to` with a phone's comment:
    /// the agent the phone asked you about, or has your yes for. A phone asks first before a comment only on a Mac that
    /// lists it.
    public static let commentWakes = "commentWakes"
    /// A phone that asks before a comment goes to an agent you haven't said yes to, on a Mac that lists `commentWakes`, and
    /// sends `to` with the comment: the agent it asked about. The Mac wakes on its comment only for that agent while it
    /// holds the card; a comment from a phone that doesn't list it stays on the card, and the card says Wake Now sends it.
    public static let commentsAskFirst = "commentsAskFirst"
    /// A Mac with folders inside binders: `list_folders`, `folder` on `list_notes` ("/" for the top, or a folder's id)
    /// and on `add_note` (a folder's id; one that's gone puts the note at the top), and `folder`/`folder_id` on notes.
    /// A phone uses them only with a Mac that lists this; one that doesn't (iPhone 2.0) never passes `folder`, and
    /// `list_notes` without it lists every note in the binder, as before. This phone lists it too.
    public static let folders = "folders"
    /// Distill (lane DS1): a Mac that answers `note_progress` (a Distill note's Work bar, panel and report, or a binder's
    /// Work list) and says `distill: true` on get_note and list_notes for a note with Distill on; and a phone that shows
    /// them, read-only. A phone shows none of it for a Mac that doesn't list it; an older phone never asks, and its
    /// decoders leave the new keys be.
    public static let distill = "distill"
    /// Teammates' agents (lane DB2): a Mac sharing binders through a team database puts its teammates' agents in
    /// list_agents, after yours, for a phone that lists this too: each with `teammate`, `owner`, `sends_to`, the shared
    /// `binders` it takes cards from, and a fingerprint of those, so the phone asks once, naming its owner and who it sends
    /// cards to, before it gives one a card ("Give cards to Claude Code (Dana)? It sends them to Anthropic."), and again when
    /// that changes. An older phone never sees them; a phone shows them only from a Mac that lists this.
    public static let teamAgents = "teamAgents"

    public static func suggestion(_ kind: ConversationSuggestion.Kind) -> String { "suggestion:" + kind.rawValue }
    public static func notification(_ method: String) -> String { "notification:" + method }

    /// What a phone that lists nothing reads: iPhone 2.0.
    public static let firstPhone: Set<String> = [suggestion(.card), suggestion(.answer), notification(changed)]

    /// What a phone reads, from what its hello listed.
    public static func phone(_ listed: [String]?) -> Set<String> {
        guard let listed, !listed.isEmpty else { return firstPhone }
        return Set(listed)
    }

    /// Everything this build of the phone reads: every suggestion kind it knows, the notifications it handles, what a
    /// run says it's doing, where its Mac can be reached, that it sends its yes with a "Binders, …" said in your voice
    /// (`MomentPayload.agreedFeature`), so the Mac fingerprints an agent that starts on its own with "starts" for it, and
    /// that it asks first before a comment goes to an agent (`commentsAskFirst`), and
    /// that it sends its mode for what you say on your own (`MomentPayload.autoFeature`): the Mac then fingerprints an
    /// agent with its Auto yes with Auto's part too, says in list_agents what Auto can do (`auto`, `auto_mode_start`,
    /// `auto_left_out`), and puts `handedOver`, `waiting`, `late` and `stop` in its moments' outcomes; and that it vouches
    /// for a capture in which it heard only you (`ConversationPayload.soloFeature`): it sends the capture's mode and vouch,
    /// a moment's `fromTranscript` and `uncued`, Stop All, Not Only Me and a capture's mode, and reads `found`, `soloLine`,
    /// `joins` and list_agents' `solo_start`, `solo` and `auto_fingerprint`; and that it shows a binder's folders
    /// (`folders`).
    public static let thisPhone: [String] = ConversationSuggestion.Kind.allCases.map(suggestion)
        + [notification(changed), notification(askProgressMethod), notification(approvalMethod), notification(addressesMethod)]
        + [workStreamsDoing, addresses, MomentPayload.agreedFeature, commentsAskFirst, MomentPayload.autoFeature, ConversationPayload.soloFeature,
           folders]
        + [distill, teamAgents]
}
