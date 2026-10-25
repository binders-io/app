import Foundation

/// Who can take work in a note's binder, as Distill's reader is told it (lane AS1): each of your agents that takes the
/// binder's cards, by its exact name, with what it's for and its kinds of work; you; and the team's people. With it the
/// reader names who an item is for instead of only saying "agent" or "person", and the schema holds `for` to those names.
/// Names and what each is for only: never a path, a command, a host or a key.
public struct DistillTakers: Equatable, Sendable {
    /// One of your agents, as the reader reads it.
    public struct Agent: Equatable, Sendable {
        public var name: String
        /// What it's for: what you typed, else what Binders works out from how it's woken (`AgentProfile.whatItsFor`).
        public var whatFor: String?
        /// Its kinds of work in a few words ("coding, research"), or nil for none.
        public var kinds: String?

        public init(name: String, whatFor: String?, kinds: String?) {
            self.name = name
            self.whatFor = whatFor
            self.kinds = kinds
        }

        /// From its profile: `modelDescription`'s parts, what it's for and its kinds of work.
        public init(_ profile: AgentProfile) {
            self.init(name: profile.name, whatFor: profile.whatItsFor, kinds: AgentKinds.summary(profile.workKinds))
        }
    }

    public var agents: [Agent]
    /// The team's people (and teammates' agents) an item can be meant for, by name; you aren't among them.
    public var people: [String]

    /// The most agents and people listed, and how much of what an agent is for.
    public static let maxAgents = 23
    public static let maxPeople = 20
    public static let whatForLimit = 160
    /// How the list names you.
    public static let you = BoardActor.you.name

    public static let none = DistillTakers(agents: [], people: [])

    /// Names trimmed, empty ones, repeats (whatever their case), you and the three words left out, at most `maxAgents`
    /// agents and `maxPeople` people.
    public init(agents: [Agent], people: [String]) {
        var seen: Set<String> = Set(([Self.you] + DistillSchema.fors).map { $0.lowercased() })
        func keep(_ name: String) -> String? {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains(where: \.isNewline), seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
        var kept: [Agent] = []
        for agent in agents {
            guard kept.count < Self.maxAgents, let name = keep(agent.name) else { continue }
            kept.append(Agent(name: name, whatFor: agent.whatFor.flatMap(Self.cut), kinds: agent.kinds))
        }
        self.agents = kept
        self.people = Array(people.compactMap(keep).prefix(Self.maxPeople))
    }

    /// No agents and no team: the reader is asked as it always was.
    public var isEmpty: Bool { agents.isEmpty && people.isEmpty }

    /// The names `for` may be, in the list's order: the agents, you, the people. Empty when there's no one to list.
    public var names: [String] { isEmpty ? [] : agents.map(\.name) + [Self.you] + people }

    /// The names the reader may write that aren't you: what `DistillReading.read` takes as names before its loose words.
    public var others: [String] { agents.map(\.name) + people }

    /// What an agent is for, on one line, at most `whatForLimit` characters, cut at a word.
    static func cut(_ text: String) -> String? {
        let line = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        guard line.count > whatForLimit else { return line }
        let head = line.prefix(whatForLimit)
        let atWord = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return atWord.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// One agent's line: `"Echo", an AI agent: the checkout's web pages. Kinds of work: coding.`
    static func line(_ agent: Agent) -> String {
        var about: [String] = []
        if let what = agent.whatFor { about.append(what.hasSuffix(".") || what.hasSuffix("…") ? what : what + ".") }
        if let kinds = agent.kinds { about.append("Kinds of work: \(kinds).") }
        let said = about.isEmpty ? "nothing says what it's for." : about.joined(separator: " ")
        return "- \"\(agent.name)\", an AI agent: \(said)"
    }

    /// The list, a line each: the agents, you, the people.
    public var lines: [String] {
        guard !isEmpty else { return [] }
        return agents.map(Self.line) + ["- \"\(Self.you)\": the person who reviews these items and wrote or keeps the note."]
            + people.map { "- \"\($0)\": a teammate." }
    }

    /// The block the reader's instructions get: its heading and the list.
    public var block: String? {
        guard !isEmpty else { return nil }
        return (["Who can take work in this note's binder:"] + lines).joined(separator: "\n")
    }

    /// What `for` means once there's a list: a name from it, the three words only when no one listed fits.
    public var forLine: String {
        var line = "- for: who should do it, written exactly as one of the names under \"Who can take work\" below."
        if !agents.isEmpty {
            line += " Name an agent when what it's for covers the work, even if a person approves it at the end: agents draft, and ask "
                + "before they send, post or buy anything."
        }
        line += " Write \"\(Self.you)\" only for what only a person can do: a decision, a conversation, signing, paying, being somewhere, "
            + "or signing in with their own account."
        if !people.isEmpty { line += " Name a teammate when the note says the work is theirs." }
        line += " When no one listed fits, write \"person\" if it needs a human, \"agent\" if an AI agent could do it alone, or "
            + "\"either\" when you can't tell."
        return line
    }

    /// For the card that asks an agent to distill a note (`DistillCards.requestDetails`): what `for` may be, in the
    /// card's sentence, and the list after it.
    public var requestFor: String {
        "for (one of the names listed below, exactly as written: an agent when what it's for covers the work, even if you approve it "
            + "at the end; \"\(Self.you)\" only for what only a person can do; else agent, person or either)"
    }
}

/// Who an item is meant for, from what read the note (lane AS1): a name the reader gave that is someone the item can be
/// meant for here wins; "person" with no name is you; "agent", "either", or a name that's no one here, go to the decision
/// model. A name of an agent that doesn't take the binder's cards is no one here.
public enum DistillMeantFor {
    public enum ReaderPick: Equatable, Sendable {
        /// Meant for you, as the reader said ("person", "You").
        case you
        /// Meant for this agent or person, as the reader named them.
        case named(String)
        /// The reader didn't say who: the decision model is asked.
        case ask
    }

    /// The reader's pick for an item it read with `hint` and `name` (`DistillReading.Item`). `resolve`: the agent or
    /// person a name is here, or nil (`DistillService.named`).
    public static func reader(hint: DistillItem.Hint?, name: String?, resolve: (String) -> String?) -> ReaderPick {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, let who = resolve(name) {
            return who == DistillTakers.you ? .you : .named(who)
        }
        return hint == .person ? .you : .ask
    }

    /// The review sheet's few words on who picked who an item is for: by the reader (or the agent that read the note), by
    /// the decision model, or by you. Nil while it's meant for no one.
    public static func pickedLine(how: String?, meantFor: String?, readBy: String?, readByAgent: Bool) -> String? {
        guard meantFor != nil else { return nil }
        switch how {
        case "reader": return readByAgent ? readBy.map { "Picked by \($0)" } ?? "Picked by the agent that read it" : "Picked by the reader"
        case "model": return "Suggested by the decision model"
        case "you": return "Your choice"
        default: return nil
        }
    }

    /// What the review sheet says of the agents with no typed What it's for (`AgentProfile.hasOwnPurpose`): "Penny has no
    /// What it's for, so Distill can only guess what to give it." Nil for none.
    public static func noPurposeLine(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        if names.count == 1 { return "\(first) has no What it's for, so Distill can only guess what to give it." }
        let list = names.count == 2 ? "\(names[0]) and \(names[1])" : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "\(list) have no What it's for, so Distill can only guess what to give them."
    }
}

/// What the decision model reads to pick who a Distill item or a Put on Board card is meant for (lane AS1): the title and
/// the start of its brief or details, Binders' own lines and Markdown left out, well under `RouterQuestions.stateLimit`.
public enum DistillWhoState {
    /// The most of a brief or a card's details that goes in.
    public static let briefLimit = 480

    /// "Title\nThe brief's start." The title alone when there's no brief.
    public static func state(title: String, brief: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = cut(plain(brief))
        guard !brief.isEmpty, brief.caseInsensitiveCompare(title) != .orderedSame else { return title }
        return title + "\n" + brief
    }

    /// A card's: its details without the line back to the note, the line saying an agent placed it, or the one saying a
    /// note's words weren't copied, and without a first line that only repeats its title.
    public static func cardState(title: String, details: String) -> String {
        let ours = ["From the note", "Distilled from ", "Placed by "]
        var paragraphs = details.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .filter { paragraph in
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !ours.contains { trimmed.hasPrefix($0) } && !trimmed.contains("Its words aren't copied onto the card")
            }
        if let first = paragraphs.first, plain(first).caseInsensitiveCompare(title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            paragraphs.removeFirst()
        }
        return state(title: title, brief: paragraphs.joined(separator: "\n"))
    }

    /// Words as a person reads them: links as their words, Markdown marks and list markers off, on one line.
    static func plain(_ text: String) -> String {
        var text = text
        let replacements: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),
            (#"\[\[([^\]|]+)\|([^\]]+)\]\]"#, "$2"),
            (#"\[\[([^\]]+)\]\]"#, "$1"),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"(?m)^\s*(?:#{1,6}\s+|>\s*|[-*+•]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)"#, ""),
            (#"(\*\*|__)(.+?)\1"#, "$2"),
            (#"`([^`]+)`"#, "$1"),
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// At most `briefLimit` characters: at a sentence's end when one comes after half of it, else at a word, with "…".
    static func cut(_ text: String) -> String {
        guard text.count > briefLimit else { return text }
        let head = String(text.prefix(briefLimit))
        let characters = Array(head)
        if let end = characters.indices.dropLast().last(where: { ".!?".contains(characters[$0]) && characters[$0 + 1] == " " }),
           end + 1 >= briefLimit / 2 {
            return String(characters[...end])
        }
        let atWord = head.lastIndex(of: " ").map { head[..<$0] } ?? head[...]
        return atWord.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }
}
