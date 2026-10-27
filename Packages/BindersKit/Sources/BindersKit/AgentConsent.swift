import CryptoKit
import Foundation

// Before the first card goes to an agent from the iPhone, it says where the card goes and what goes with it, and asks
// (App Store 5.1.2(i)). The Mac says where for each agent (list_agents' sends_to, and vendor: who it hands the card to for
// its work) and fingerprints that and what goes with a card, so an agent pointed somewhere new, or given more to read, is
// asked about again.

public enum AgentConsent {
    /// Where a card handed to `agent` goes, in a few words: Anthropic (or the vendor you named) for Claude Code, a web
    /// hook's host, the program a command runs, Shortcuts on your Mac. One that checks the board itself takes the card from
    /// the Mac and works on it "wherever it runs", or "on another machine, over SSH" when it reports from one. A Claude Code
    /// agent whose cards go to the session you have open says so here too, where every iPhone that asks before the first
    /// card shows it. Who the others hand the card to for their work is `vendor`, kept apart: iPhones before it read this
    /// as a host or a program's name.
    public static func sendsTo(_ agent: AgentProfile) -> String {
        switch agent.wake {
        case .claudeCode(let wake):
            let vendor = vendor(agent) ?? "Anthropic"
            return wake.postsToOpenSession ? "\(vendor), or the Claude Code session you have open in its repository" : vendor
        case .webhook(let address): return URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "the address it was set up with"
        case .command(let command, _): return program(in: command) ?? "a command on your Mac"
        case .shortcut: return "Shortcuts on your Mac"
        case .board:
            if case .ssh = agent.reporting { return "on another machine, over SSH" } else { return "wherever it runs" }
        case .cliAgent(let wake):
            return vendor(agent) ?? "\(wake.tool.name), wherever it's set up to"
        case .localModel:
            return vendor(agent) ?? "your own model, as Settings → AI sets it up"
        }
    }

    /// Who a card handed to `agent` goes to for its work: what you said in Settings → Agents ("Sends cards to"), else
    /// Anthropic for Claude Code, else the company behind a program it runs that Binders knows (`knownVendors`). Nil when
    /// nothing says: a program, a Shortcut, a web hook or an agent that checks the board itself can send cards anywhere.
    public static func vendor(_ agent: AgentProfile) -> String? {
        // Codex, Copilot and Antigravity send cards where Binders starts them to (it fixes their settings), so a typed name can't say
        // otherwise.
        if case .cliAgent(let wake) = agent.wake, let company = wake.tool.company { return company }
        if let said = agent.vendor?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty { return said }
        return knownVendor(agent)
    }

    /// The vendor the way it's woken says, without what you said: Anthropic for Claude Code, and for a command, the company
    /// behind the program it runs, when Binders knows it.
    static func knownVendor(_ agent: AgentProfile) -> String? {
        switch agent.wake {
        case .claudeCode: return "Anthropic"
        case .cliAgent(let wake):
            // OpenCode sends cards to the provider of its model, as your OpenCode sets that provider up: Binders names the
            // provider, not a company, since your config can point a provider anywhere.
            if let company = wake.tool.company { return company }
            return wake.provider.map { "the \($0) provider, as set up in your OpenCode" }
        case .command(let command, _):
            guard let program = program(in: command)?.lowercased() else { return nil }
            return knownVendors[program] ?? knownVendors[(program as NSString).deletingPathExtension]
        default: return nil
        }
    }

    /// Programs whose company Binders knows, by the program's name: the agents' own command-line tools.
    static let knownVendors = ["claude": "Anthropic", "codex": "OpenAI", "gemini": "Google", "grok": "xAI", "copilot": "GitHub (Microsoft)", "agy": "Google"]

    /// A short fingerprint, 16 hex digits, of where a card handed to `agent` goes and what goes with it: how it's woken
    /// and where to (a web hook's address, a command and its folder, a Shortcut, the sites Claude Code's commands may
    /// reach, and whether a Claude Code agent's cards go to the session you have open), who it hands them to (when you said
    /// so, or the company behind a command's program), how it reports back, whether Binders adds what the card's binder
    /// knows, from what `reads` lets it see, and whether you let it send, post or buy for you without asking. Its name, whether it's on, its boards, what it's for
    /// and how often it may be woken don't change it.
    ///
    /// `startsOnItsOwn`: Binders may hand it a card without asking (AgentRegistry.startsOnItsOwn), for an iPhone that
    /// sends its yes with what you say (`MomentPayload.agreedFeature`). Then "starts" is part of it, so a yes given before,
    /// which never saw the start sentence, doesn't count for it. False everywhere else, which leaves every fingerprint as
    /// it always was.
    ///
    /// `auto`: it also has the Mac's yes for Auto (AgentRegistry.startsInAuto), for an iPhone that lists
    /// `MomentPayload.autoFeature`. With `startsOnItsOwn`, Auto's part is in it too, so a yes given to the start sentence
    /// alone, which never mentioned Auto, doesn't count for what Auto hands over (`autoModeStartSentence`). Without
    /// `startsOnItsOwn` it changes nothing.
    ///
    /// `solo` (lane Y2): the Mac's yes for captures too (AgentRegistry.startsInSolo), for a phone that lists `soloAuto`: a
    /// "solo" part after Auto's, so a yes given to Y1's words doesn't count for what Auto reads from a capture.
    public static func fingerprint(_ agent: AgentProfile, reads: AgentReads, startsOnItsOwn: Bool = false, auto: Bool = false,
                                   solo: Bool = false) -> String {
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var parts = ["wake " + agent.wake.kind]
        switch agent.wake {
        case .board: break
        case .command(let command, let folder): parts += [clean(command), clean(folder ?? "")]
        case .webhook(let address): parts.append(clean(address))
        case .shortcut(let name): parts.append(clean(name))
        case .claudeCode(let wake):
            parts.append((wake.allowedDomains ?? []).map { clean($0).lowercased() }.filter { !$0.isEmpty }.sorted().joined(separator: ","))
            // Your open session reads with its own tools, not just the card: a yes given before doesn't stand for it.
            if wake.postsToOpenSession { parts.append("open session") }
        case .cliAgent(let wake):
            parts.append("tool " + wake.tool.rawValue)
            // Another program in its place asks again.
            if let program = wake.executable.map(clean), !program.isEmpty { parts.append("program " + program) }
            if wake.tool.honoursSites {
                parts.append((wake.allowedDomains ?? []).map { clean($0).lowercased() }.filter { !$0.isEmpty }.sorted().joined(separator: ","))
            }
            // Switching OpenCode from one provider to another (OpenCode Zen's free models among them) asks again, even with a
            // name typed under "Sends cards to".
            if wake.tool == .opencode { parts.append("provider " + (wake.provider ?? "")) }
        case .localModel(let wake):
            // Another model asks again.
            parts.append("model " + (wake.namedModel ?? ""))
        }
        // Who it hands cards to. Claude Code always named Anthropic, so only a vendor you said that differs counts there. A
        // command running a program Binders knows (codex: OpenAI) is named now where it wasn't before, so a yes given before
        // didn't see it: its vendor always counts, said or known.
        let said = clean(agent.vendor ?? "")
        let vendorCounts: Bool = switch agent.wake {
        case .command, .cliAgent: true
        default: false
        }
        if vendorCounts, let vendor = vendor(agent) {
            parts.append("vendor " + clean(vendor).lowercased())
        } else if !said.isEmpty, said.lowercased() != knownVendor(agent)?.lowercased() {
            parts.append("vendor " + said.lowercased())
        }
        parts.append("report " + agent.reporting.kind)
        parts.append("context \(agent.addsContext)")
        if agent.addsContext { parts.append("captures \(reads.captures) team \(reads.team)") }
        // Drafting first is how every agent starts, so only letting one act adds to it: a yes given before stands for it.
        if !agent.draftsFirst { parts.append("acts") }
        if startsOnItsOwn { parts.append("starts") }
        // Auto's part is still the word an earlier test build hashed, so a yes given to it there still matches.
        if startsOnItsOwn, auto { parts.append("yolo") } // hashes what an earlier test build saved a yes to
        if startsOnItsOwn, auto, solo { parts.append("solo") }
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// What the iPhone says before the first card goes to an agent: what goes with a card, where it goes, and what the
    /// agent is told about acting for you. Each part is what the Mac said in list_agents, nil from a Mac that didn't:
    /// `wakes` its kind (claudeCode, cliAgent, webhook, command, shortcut, board), `sendsTo` where to, `vendor` who it hands the card
    /// to for its work, `contextFrom` what Binders adds from the binder, `mayAct` whether you let it act without asking,
    /// and `openSession` whether a Claude Code agent's cards go to the session you have open. `startsOnItsOwn`: you let
    /// Binders hand it a card without asking (list_agents' auto_start), which adds a sentence. `autoModeStart`: the Mac's yes
    /// for Auto too (list_agents' auto_mode_start), which makes that sentence `autoModeStartSentence`, as its fingerprint has Auto's part.
    public static func disclosure(name: String, wakes: String, sendsTo: String? = nil, vendor: String? = nil, addsContext: Bool? = nil,
                                  contextFrom: String? = nil, mayAct: Bool? = nil, openSession: Bool? = nil, startsOnItsOwn: Bool? = nil,
                                  autoModeStart: Bool? = nil, soloStart: Bool? = nil) -> String {
        func given(_ text: String?) -> String? {
            text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var what = "its title, details and links, its binder and due date, and your answers and comments on it"
        if addsContext == true {
            what += ", with up to 3 short passages from \(given(contextFrom) ?? "notes and meetings") in its binder that match it"
        }
        let goes = goesSentence(name: name, wakes: wakes, sendsTo: sendsTo, vendor: vendor, openSession: openSession)
        // What it's told about acting for you, from a Mac that says (part of the fingerprint when you let it act).
        let acting = actingSentence(mayAct).map { " " + $0 } ?? ""
        let starts = autoModeStart == true && soloStart == true ? " " + soloStartSentence
            : autoModeStart == true ? " " + autoModeStartSentence : startsOnItsOwn == true ? " " + startSentence : ""
        return "Binders on your Mac hands \(name) the card: \(what). \(goes)\(acting)\(starts) Nothing else from your binders goes with it."
    }

    /// Where the cards go, as the disclosure says it for the way the agent is woken: one sentence, and for a Claude Code
    /// agent whose cards go to your open session, a second on what that session may do.
    static func goesSentence(name: String, wakes: String, sendsTo: String?, vendor: String?, openSession: Bool?) -> String {
        func given(_ text: String?) -> String? {
            text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let sendsTo = given(sendsTo), vendor = given(vendor)
        /// "to OpenAI", or where a program or a Shortcut sends things when nothing says.
        let onward = vendor.map { "to \($0)" } ?? "wherever it's set up to"
        switch wakes {
        case "claudeCode":
            // A Mac that posts its cards to your open session names the session in sends_to, which every build shows here;
            // this one also says what that session may do.
            return "\(name) sends them to \(sendsTo ?? vendor ?? "Anthropic") to work on them."
                + (openSession == true ? " " + openSessionSentence : "")
        case "webhook":
            let address = sendsTo.map { "Binders sends them to \($0), the address \(name) was set up with" }
                ?? "Binders sends them to the address \(name) was set up with"
            return address + (vendor.map { ", which sends them on to \($0)." } ?? ".")
        case "command":
            if let program = sendsTo, !program.contains(" ") {
                return "Binders hands them to “\(program)”, a program on your Mac, which sends them \(onward)."
            }
            return "Binders hands them to a program on your Mac, which sends them \(onward)."
        case "shortcut":
            return "Binders hands them to a Shortcut, in \(sendsTo ?? "Shortcuts on your Mac"), which sends them \(onward)."
        case "board":
            return "\(name) reads them from your Mac itself, and works on them \(sendsTo ?? "wherever it runs")"
                + (vendor.map { ", sending them to \($0)." } ?? ".")
        case "cliAgent":
            return "Binders starts \(name) on your Mac, which sends them \(onward)."
        default:
            return "\(name) sends them \(vendor.map { "to \($0)" } ?? "wherever it sends its work")."
        }
    }

    /// What a Claude Code agent's open session may do, said where its cards go to it.
    static let openSessionSentence = "That session keeps its own permissions, and its Binders tools read what you let Claude Code read."

    /// What it's told about acting for you, from a Mac that says (part of the fingerprint when you let it act).
    static func actingSentence(_ mayAct: Bool?) -> String? {
        mayAct.map {
            $0 ? "You let it send, post or buy for you without asking first." : "Binders tells it to ask your approval before it sends, posts or buys anything for you."
        }
    }

    /// What the disclosure adds for an agent Binders may hand a card without asking.
    public static let startSentence = "Binders may also hand it a card without asking, when a “Binders, …” you say in your voice is clearly its work."

    /// What it adds instead for an agent that also has the Mac's yes for Auto (list_agents' auto_mode_start): what the start
    /// sentence says, and what Auto hands over.
    public static let autoModeStartSentence = "Binders may also hand it a card without asking: when a “Binders, …” you say in your voice is clearly its work, "
        + "and, while this iPhone is in Auto, when something you say on your own looks like its work, even hours later, with your words."

    /// What it adds for an agent with the Mac's yes for captures too (list_agents' solo_start, lane Y2): what Auto hands
    /// over now includes what you think out loud.
    public static let soloStartSentence = "Binders may also hand it a card without asking: when a “Binders, …” you say in your voice is clearly its work, "
        + "and, while this iPhone is in Auto, when something you say on your own, or think out loud where only you speak, looks like its work, "
        + "even hours later, with your words: from what you think out loud, only the sentences it came from."


    /// The name of the program a command runs, for saying where its card goes: "wake-agent" for "~/bin/wake-agent --card",
    /// "pennant" for "cd ~/agents && ./pennant run", "grok.py" for "python3 ~/bots/grok.py". Variables, cd and wrappers
    /// such as env or nohup are passed over. Nil when there's none to find.
    static func program(in command: String) -> String? {
        let wrappers: Set = ["env", "exec", "nohup", "command", "builtin", "time", "sudo", "nice", "caffeinate"]
        let noProgram: Set = ["cd", "export", "set", "unset", "alias", "local", "true", "false", ":"]
        let interpreters: Set = ["sh", "bash", "zsh", "python", "python3", "node", "ruby", "perl", "deno", "bun", "osascript", "swift"]
        for segment in command.components(separatedBy: CharacterSet(charactersIn: ";&|\n")) {
            var words = segment.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()")) }.filter { !$0.isEmpty }
            while let word = words.first {
                let isVariable = word.contains("=") && !word.hasPrefix("/") && !word.hasPrefix("~") && !word.hasPrefix(".")
                if isVariable || wrappers.contains(word) || (word.hasPrefix("-") && word != "-") {
                    words.removeFirst()
                    continue
                }
                break
            }
            guard let first = words.first, !noProgram.contains(first), !["if", "then", "do", "!", "[", "[["].contains(first) else { continue }
            if first == "source" || first == "." { return words.dropFirst().first.map { ($0 as NSString).lastPathComponent } }
            let name = (first as NSString).lastPathComponent
            // An interpreter running a file: the file says more.
            if interpreters.contains(name), let file = words.dropFirst().first(where: { !$0.hasPrefix("-") }),
               file.contains("/") || file.contains(".") {
                return (file as NSString).lastPathComponent
            }
            return name.isEmpty ? nil : name
        }
        return nil
    }
}

extension AgentProfile {
    /// Where a card handed to it goes: see `AgentConsent.sendsTo`.
    public var sendsTo: String { AgentConsent.sendsTo(self) }
}
