import CryptoKit
import Foundation

// What the team sees of an agent, invites, a teammate's agent's consent, the dispatcher's rule for what comes from
// teammates, the line a refused change leaves, and Distill's part of a card the team shares (lane DB2).

// MARK: The agents' public rows

/// What the team sees of one of this Mac's agents, as `put_agent` takes it: its name with its owner, how it's woken (as a
/// word), what it's for, the shared binders it takes cards from, whether it starts on teammates' cards on its own, who it
/// sends cards to, its status, the card it's running and when it was last online. Never how it runs: no command, folder
/// or repository, model or permission mode, web hook or status address, Shortcut, token, or what it may read.
public enum TeamAgentRow {
    /// Every field the team may see: `put_agent` refuses any other, and so does this.
    public static let fields: Set<String> = ["name", "kind", "purpose", "binder_ids", "takes_team_cards", "status", "online_at",
                                             "running_card_id", "sends_to"]

    /// The row for `agent`. `binders`: the shared binders it takes cards from; `startsOnTeammatesCards`: its Take cards from
    /// teammates and its start switch are both on (and it isn't paused or held); `runningCard`: a card in a shared binder,
    /// or nil.
    public static func fields(for agent: AgentProfile, owner: String, binders: [UUID], startsOnTeammatesCards: Bool, status: String,
                              runningCard: UUID?, online: Date?) -> [String: TeamJSON] {
        var row: [String: TeamJSON] = [
            "name": .string(TeamNames.published(agent.name, owner: owner)),
            "kind": .string(agent.wake.kind),
            "purpose": .string(purpose(agent)),
            "binder_ids": TeamJSON(binders),
            "takes_team_cards": .bool(startsOnTeammatesCards),
            "status": .string(status),
            "sends_to": .string(sendsTo(agent)),
            "running_card_id": TeamJSON(runningCard),
        ]
        if let online { row["online_at"] = TeamJSON(online) }
        return row
    }

    /// The row for an agent that acted through this Mac without being set up in Settings → Agents (an MCP session): its
    /// name with its owner, and nothing it would be woken for.
    public static func session(name: String, owner: String) -> [String: TeamJSON] {
        ["name": .string(TeamNames.published(name, owner: owner)), "kind": "session", "purpose": "", "binder_ids": .array([]),
         "takes_team_cards": false, "status": "", "sends_to": ""]
    }

    /// What it's for, as you typed it, else its kinds of work: never the repository a coding agent works in, which
    /// `whatItsFor` would name.
    public static func purpose(_ agent: AgentProfile) -> String {
        if let typed = agent.purpose?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty { return String(typed.prefix(200)) }
        return AgentKinds.text(agent.workKinds) ?? ""
    }

    /// Who it sends cards to (its Sends cards to, or what its program says), left empty when it reads like an address: a
    /// web hook's host stays on its owner's Mac.
    public static func sendsTo(_ agent: AgentProfile) -> String {
        guard let vendor = AgentConsent.vendor(agent)?.trimmingCharacters(in: .whitespacesAndNewlines), !vendor.isEmpty,
              !looksLikeAddress(vendor) else { return "" }
        return String(vendor.prefix(120))
    }

    /// Whether some words read like an address rather than a name: a URL, a path, an e-mail or SSH login, a host name or
    /// an IP address, with or without a port.
    public static func looksLikeAddress(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.contains("://") || words.contains("/") || words.contains("@") || words.contains("\\") { return true }
        return words.split(whereSeparator: \.isWhitespace).contains { word in
            let part = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;()[]\"'"))
            // A host or an address: dots between letters or digits, with no spaces, optionally a port.
            return part.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d+)?$"#, options: .regularExpression) != nil
                || part.range(of: #"^\[?[0-9A-Fa-f:]+\]?(:\d+)?$"#, options: .regularExpression) != nil && part.contains(":")
        }
    }
}

// MARK: A teammate's agent: the yes

/// Giving a card to a teammate's agent: the first time, Binders asks once, naming its owner and who it sends cards to, and
/// again when either changes, as Give to asks for your own agents on the iPhone.
public enum TeamAgentConsent {
    /// "Give cards to Claude Code (Dana)?"
    public static func question(_ name: String) -> String { "Give cards to \(name)?" }

    /// "It sends them to Anthropic. It runs on Dana's Mac."
    public static func message(owner: String, sendsTo: String?, headless: Bool = false) -> String {
        let sends = sendsTo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let first = sends.isEmpty ? "\(owner) hasn't said where it sends them." : "It sends them to \(sends)."
        return first + (headless ? " It runs on its own, as \(owner)'s agent." : " It runs on \(owner)'s Mac.")
    }

    /// The yes is for the agent as it is now: its name, its owner and who it sends cards to. "team-" and 16 hex digits.
    public static func fingerprint(name: String, owner: String, sendsTo: String) -> String {
        let text = ["team-agent", name.trimmingCharacters(in: .whitespaces).lowercased(), owner.trimmingCharacters(in: .whitespaces).lowercased(),
                    sendsTo.trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: "\n")
        return "team-" + SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Invites

extension TeamInvite {
    /// An invite saved as a file: `<team> invite for <login>.binders-invite`.
    public static let fileExtension = "binders-invite"
    /// What an invite says about itself, wherever it's shown.
    public static let sendPrivately = "Send it privately: it holds a one-time password, which works once, for 7 days."

    /// `binders://team/join?v=1&team=…&by=…&host=…&port=…&database=…&login=…&tls=…&password=…`, every value
    /// percent-encoded; `by` (who invited) only when it's known.
    public var link: URL? {
        var items: [(String, String)] = [("v", "1"), ("team", teamName)]
        if let invitedBy = invitedBy?.trimmingCharacters(in: .whitespacesAndNewlines), !invitedBy.isEmpty { items.append(("by", invitedBy)) }
        items += [("host", server.host), ("port", String(server.port)), ("database", server.database), ("login", server.login)]
        if let name = server.serverName, !name.isEmpty { items.append(("tls", name)) }
        items.append(("password", oneTimePassword))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let query = items.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return URL(string: "binders://team/join?" + query)
    }

    /// An invite from its link; nil for any other link, or one that lacks the server, the login or the password. Keys it
    /// doesn't know are ignored.
    public init?(link: URL) {
        guard link.scheme?.lowercased() == "binders", link.host?.lowercased() == "team",
              link.pathComponents.filter({ $0 != "/" }).first?.lowercased() == "join",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var values: [String: String] = [:]
        for item in items { if let value = item.value { values[item.name] = value } }
        self.init(values: values)
    }

    private init?(values: [String: String]) {
        func value(_ key: String) -> String? { values[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
        guard let host = value("host"), let database = value("database"), let login = value("login"),
              let password = values["password"], !password.isEmpty, TeamSchema.isValidRoleName(login) else { return nil }
        let port = value("port").flatMap(Int.init) ?? 5432
        guard (1...65535).contains(port) else { return nil }
        self.init(server: TeamDatabaseServer(host: host, port: port, database: database, login: login, serverName: value("tls")),
                  oneTimePassword: password, teamName: value("team") ?? "", invitedBy: value("by"))
    }

    /// The file: JSON a person can read too, saying what it is, who it's from and to send it privately.
    public func fileData() -> Data {
        let from = invitedBy?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        var object: [String: TeamJSON] = ["binders_invite": 1, "team": .string(teamName), "host": .string(server.host),
                                          "port": .number(Double(server.port)), "database": .string(server.database),
                                          "login": .string(server.login), "one_time_password": .string(oneTimePassword),
                                          "about": .string("An invite\(from.map { " from \($0)" } ?? "") to join \(teamName.isEmpty ? "a team" : "“\(teamName)”") in Binders, as \(server.login). Open it in Binders on your Mac. \(Self.sendPrivately)")]
        if let name = server.serverName, !name.isEmpty { object["tls_name"] = .string(name) }
        if let from { object["invited_by"] = .string(from) }
        return Data(TeamJSON.object(object).text.utf8)
    }

    /// An invite from its file; nil for a file that isn't one. Keys it doesn't know are ignored.
    public init?(fileData: Data) {
        guard let text = String(data: fileData, encoding: .utf8), let object = TeamJSON(text: text)?.object,
              object["binders_invite"] != nil else { return nil }
        var values: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case .string(let text): values[key] = text
            case .number(let number): values[key] = number.rounded() == number ? String(Int(number)) : String(number)
            default: break
            }
        }
        values["password"] = values["one_time_password"]
        values["tls"] = values["tls_name"]
        values["by"] = values["invited_by"]
        self.init(values: values)
    }

    /// "Design team invite for robin.binders-invite": a file name with nothing a file system minds.
    public var fileName: String {
        let team = teamName.isEmpty ? "Team" : teamName
        let safe = "\(team) invite for \(server.login)".map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
        return String(safe.prefix(100)) + "." + Self.fileExtension
    }
}

// MARK: Teammates' cards and the dispatcher

/// Why a change on a card might wake one of this Mac's agents: made here (yours), by a teammate on their Mac, or an
/// agent's placing under Agents may place work items (on this Mac, or on a teammate's).
public enum TeamWakeCause: Equatable, Sendable {
    case yours
    case teammate
    case placedByAgent(fromTeammate: Bool)
}

/// The dispatcher's rule for what didn't come from you: a teammate's card meant for one of your agents starts it on its own
/// only when the agent's Take cards from teammates is on (the default) and its start switch allows; an agent's placing
/// starts it only when its start switch allows. Otherwise the card waits for your Give to, with why.
public enum TeamWakeRule {
    public enum Verdict: Equatable, Sendable {
        case wake
        /// It waits for your Give to: the line that says why.
        case waits(String)
    }

    public static func verdict(_ cause: TeamWakeCause, agent: String, takesTeammatesCards: Bool, startsOnItsOwn: Bool) -> Verdict {
        switch cause {
        case .yours:
            return .wake
        case .teammate, .placedByAgent(fromTeammate: true):
            if !takesTeammatesCards { return .waits("Waits for your Give to: \(agent) takes teammates' cards only when you give them.") }
            if !startsOnItsOwn {
                return .waits("Waits for your Give to: \(agent) starts on teammates' cards only once it may start on cards on its own (Settings → Agents).")
            }
            return .wake
        case .placedByAgent(fromTeammate: false):
            if !startsOnItsOwn {
                return .waits("Waits for your Give to: \(agent) starts on cards an agent placed only once it may start on cards on its own (Settings → Agents).")
            }
            return .wake
        }
    }
}

// MARK: A change the database refused

/// The line a card gets on this Mac when the team database refused a change made here: what didn't go through, and why.
public enum TeamRefusalLine {
    /// The change, in a word or two: "move to Done", "claim", "comment".
    public static func what(_ call: TeamCall) -> String {
        switch call.function {
        case "claim_card": "claim"
        case "move_card": "move to " + (call.argument("p_column").flatMap(BoardColumn.init(rawValue:))?.title ?? "another column")
        case "report": "report"
        case "keep_alive": "check-in"
        case "ask": "question"
        case "answer": "comment"
        case "request_approval": "request for approval"
        case "decide": "decision"
        case "release": "release"
        case "finish": "finish"
        case "create_card": "new card"
        case "edit_card": "edit"
        case "assign_card": "choice of who it's for"
        case "delete_card": "deletion"
        case "add_dependency", "remove_dependency": "change to what it waits for"
        case "log_card": "note"
        case "move_card_to_binder": "move to another board"
        case "bring_card": "share"
        case "place_work_items": "placing"
        case "set_card_distilled": "update from Distill"
        default: "change"
        }
    }

    /// "Your move to Done didn't go through on the team's board: This card is done. …"; for an agent's change, "Claude
    /// Code's claim didn't …".
    public static func line(_ call: TeamCall, by who: String, reason: String) -> String {
        let whose = BoardRules.isReserved(who) ? "Your" : "\(who)'s"
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(whose) \(what(call)) didn't go through on the team's board" + (reason.isEmpty ? "." : ": " + reason)
    }
}

// MARK: Distill's part of a card

extension DistilledFrom {
    /// The part the whole team shares, as the database keeps it (`cards.distilled`): the note, the distill and item, the
    /// section and its hash, the note's words it came from, the version read, a "Distill with…" request, when its brief was
    /// brought up to date and when it was closed. What this Mac noticed about it (`noticedHash`, `held`, `change`, `seenText`) stays here.
    public var teamJSON: TeamJSON {
        // Put in the note's group by hand (lane DS5): the note alone, so a Mac before reads no Distill part on it.
        if byHand == true { return .object(["note": TeamJSON(note), "by_hand": true]) }
        // Made with Put on Board (lane DS6): as one put in by hand, for a Mac before, with the words and section it came
        // from, which this build reads.
        if put == true {
            var object: [String: TeamJSON] = ["note": TeamJSON(note), "by_hand": true, "put": true]
            if let section { object["section"] = .string(section) }
            if let sectionHash { object["section_hash"] = .string(sectionHash) }
            if let quote, !quote.isEmpty { object["quote"] = .string(quote) }
            return .object(object)
        }
        var object: [String: TeamJSON] = ["note": TeamJSON(note), "distill": TeamJSON(distill), "item": TeamJSON(item)]
        if let section { object["section"] = .string(section) }
        if let sectionHash { object["section_hash"] = .string(sectionHash) }
        if let version { object["version"] = .string(version) }
        if request == true { object["request"] = true }
        if let briefUpdated { object["brief_updated"] = TeamJSON(briefUpdated) }
        if let closed { object["closed"] = TeamJSON(closed) }
        // The note's words it came from (lane DS4), so a teammate's note marks it there too. A Mac before ignores it.
        if let quote, !quote.isEmpty { object["quote"] = .string(quote) }
        return .object(object)
    }

    /// From the team's part, keeping what this Mac noticed (`local`) when it's about the same item. Nil when there's no
    /// team part, or it isn't one.
    public init?(team: TeamJSON?, keeping local: DistilledFrom? = nil) {
        guard let object = team?.object, let note = object["note"]?.uuid else { return nil }
        // Put in the note's group by hand (lane DS5): the note, and nothing of Distill.
        if object["by_hand"]?.bool == true {
            if object["put"]?.bool == true {
                // Made with Put on Board (lane DS6): what this Mac noticed of its section stays, when it's the same note's.
                let same = local.map { $0.note == note && $0.put == true } ?? false
                self.init(note: note, distill: note, item: note, section: object["section"]?.string, sectionHash: object["section_hash"]?.string,
                          noticedHash: same ? local?.noticedHash : nil, held: same ? local?.held : nil, change: same ? local?.change : nil,
                          seenText: same ? local?.seenText : nil, quote: object["quote"]?.string, put: true)
                return
            }
            self = .byHand(note: note)
            return
        }
        guard let distill = object["distill"]?.uuid, let item = object["item"]?.uuid else { return nil }
        let same = local.map { $0.note == note && $0.item == item } ?? false
        self.init(note: note, distill: distill, item: item, section: object["section"]?.string, sectionHash: object["section_hash"]?.string,
                  version: object["version"]?.string, noticedHash: same ? local?.noticedHash : nil, held: same ? local?.held : nil,
                  request: object["request"]?.bool == true ? true : nil, change: same ? local?.change : nil,
                  briefUpdated: object["brief_updated"]?.date, closed: object["closed"]?.date, seenText: same ? local?.seenText : nil,
                  quote: object["quote"]?.string)
    }
}

/// One work item for `place_work_items`, as Distill's Place on Board has it: its card's id (made on this Mac, so the card it
/// shows at once is the one the database makes), title, details, place, the note it came from and its section, Distill's
/// part, the cards it waits for, and who it's meant for (as the team names them).
public enum TeamPlacing {
    public static func item(card: UUID, title: String, details: String, position: Double, note: UUID, noteTitle: String, item: UUID,
                            section: String?, distilled: DistilledFrom?, waitsFor: [UUID], meantFor: String?) -> TeamRow {
        var row: TeamRow = ["card": TeamJSON(card), "title": .string(title), "details": .string(details), "position": .number(position),
                            "note": TeamJSON(note), "note_title": .string(noteTitle), "item": TeamJSON(item), "waits_for": TeamJSON(waitsFor)]
        if let section { row["section"] = .string(section) }
        if let distilled { row["distilled"] = distilled.teamJSON }
        if let meantFor, !meantFor.trimmingCharacters(in: .whitespaces).isEmpty { row["meant_for"] = .string(meantFor) }
        return row
    }
}

// MARK: The status line's advice

extension TeamDatabaseStatus {
    /// What to check while it's offline: the VPN that reaches the database, and that the database is one of its
    /// destinations. Nil while connected, or when someone has to act first (the reason says what).
    public var check: String? {
        guard case .offline(_, _, true) = self else { return nil }
        return "Check that your VPN (such as Covee) is connected and that the team database is one of its destinations."
    }
}
