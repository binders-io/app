import CryptoKit
import Foundation
import BindersKit

/// The agents Binders hands cards to (Settings → Agents), kept in agents.json in the data folder with no secrets in it: a
/// web hook's token is in the Keychain. The command-line coding tools (Codex, OpenCode, GitHub Copilot CLI, Antigravity) are kept in
/// agents-cli.json beside it, which no Mac 0.8.0 opens, so going back to 0.8.0 never sees them or saves over them. Each
/// agent is fingerprinted in the Keychain when it's saved here, so one changed by anything else (an agent rewriting its
/// own command, say) doesn't run until you look at it and save it again. Saving keeps any entry this build can't read as
/// it found it. Whether agents are paused is kept in agents.json and the Keychain, which Mac 0.8.0 reads and writes too,
/// so pausing or resuming there sticks; agents-cli.json always says not paused.
@MainActor
@Observable
final class AgentRegistry {
    /// The app's own, the one registry that clears a yes the file no longer says (`load`). Not in `Binders --mcp`.
    static let shared = AgentRegistry(clearsOldYes: !CommandLine.arguments.contains("--mcp"))

    private(set) var agents: [AgentProfile] = []
    /// While paused, Binders wakes no agent and no agent can take a card.
    private(set) var paused = false
    /// Agents changed outside Binders since they were saved here: they don't run until saved again.
    private(set) var changedOutside: Set<UUID> = []
    /// Agents Binders won't wake as they are, with why: one whose command or model turns checks off, or a CLI agent whose
    /// name an agent in agents.json also goes by.
    private(set) var held: [UUID: String] = [:]
    /// agents.json or agents-cli.json couldn't be read at all, so nothing is saved over either.
    private(set) var unreadable = false
    /// The file that couldn't be read.
    private(set) var unreadableFile: String?
    @ObservationIgnored private var skipped = 0
    @ObservationIgnored private var skippedCLI = 0
    /// What each file held that this build can't read, written back as it was.
    @ObservationIgnored private var kept: [JSONValue] = []
    @ObservationIgnored private var keptCLI: [JSONValue] = []
    @ObservationIgnored private let url: URL
    /// agents-cli.json, beside agents.json.
    @ObservationIgnored private let cliURL: URL
    /// Whether `load` clears a yes the file no longer says: only the app's own registry does, whose loads and Saves take
    /// turns. A one-off one (MCPServer's savedAgent and list_agents) or one in `Binders --mcp` could read the file just
    /// before a Save and the Keychain just after, and clear the yes that Save had just written.
    @ObservationIgnored private let clearsOldYes: Bool

    init(url: URL = AppPaths.support.appendingPathComponent("agents.json"), clearsOldYes: Bool = false) {
        self.url = url
        cliURL = Self.cliFile(beside: url)
        self.clearsOldYes = clearsOldYes
        load()
    }

    /// agents-cli.json, in the same folder as agents.json.
    static func cliFile(beside url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent("agents-cli.json") }

    /// The agents both files hold, as saved, without the Keychain: for names alone, as an MCP server reads them.
    static func savedAgents(at url: URL = AppPaths.support.appendingPathComponent("agents.json")) -> [AgentProfile] {
        [url, cliFile(beside: url)].flatMap { file in
            (try? Data(contentsOf: file)).flatMap { try? AgentFile.decode($0).file.agents } ?? []
        }
    }

    // MARK: Reading

    func load() {
        // A file that's missing holds no agents. Either one unreadable: nothing is saved over either.
        func read(_ file: URL) -> (file: AgentFile, skipped: Int)?? {
            guard let data = try? Data(contentsOf: file) else { return .some(nil) }
            guard let read = try? AgentFile.decode(data) else { return nil }
            return .some(read)
        }
        let keychainPaused = Keychain.read(Self.key("agents-paused")) == "1"
        guard let main = read(url), let cli = read(cliURL) else {
            unreadable = true
            unreadableFile = read(url) == nil ? url.lastPathComponent : cliURL.lastPathComponent
            agents = []
            held = [:]
            paused = true
            return
        }
        unreadable = false
        unreadableFile = nil
        skipped = main?.skipped ?? 0
        skippedCLI = cli?.skipped ?? 0
        kept = main?.file.kept ?? []
        keptCLI = cli?.file.kept ?? []
        // Paused if agents.json or the Keychain says so: unpausing takes Binders. Not agents-cli.json, which no Mac 0.8.0
        // opens, so resuming there could never clear it.
        paused = (main?.file.paused ?? false) || keychainPaused
        var seen: Set<UUID> = []
        agents = ((main?.file.agents ?? []) + (cli?.file.agents ?? [])).filter { seen.insert($0.id).inserted }
        changedOutside = Set(agents.filter(Self.isChangedOutside).map(\.id))
        held = Self.holds(agents)
        // Once per agent: Auto's yes as an earlier test build named it moves to today's name, and the old item is emptied.
        for agent in agents where clearsOldYes && Keychain.read(Self.key("agent-starts-yolo", agent.id)) == "1" { // reads what an earlier test build saved
            Keychain.write("1", for: Self.key("agent-starts-auto", agent.id))
            Keychain.write("", for: Self.key("agent-starts-yolo", agent.id)) // empties what an earlier test build saved
        }
        // An approval never outlives the file's own "on": a file that no longer says so (a save by Mac 0.8.0 drops the key)
        // clears the Keychain's yes, so a value written in later isn't approved by it. In the app's own registry alone.
        for agent in agents where clearsOldYes && agent.autoStart != true && Keychain.read(Self.key("agent-starts", agent.id)) == "1" {
            Keychain.write("", for: Self.key("agent-starts", agent.id))
        }
        // Auto's yes goes with it: it was renewed for a switch that's no longer on.
        for agent in agents where clearsOldYes && agent.autoStart != true && Keychain.read(Self.key("agent-starts-auto", agent.id)) == "1" {
            Keychain.write("", for: Self.key("agent-starts-auto", agent.id))
        }
        // And the yes for captures (lane Y2).
        for agent in agents where clearsOldYes && agent.autoStart != true && Keychain.read(Self.key("agent-starts-solo", agent.id)) == "1" {
            Keychain.write("", for: Self.key("agent-starts-solo", agent.id))
        }
    }

    /// Why Binders won't wake an agent as the files have it, by agent: a command or a model that turns checks off (saved
    /// before Binders refused it, or written in by anything else), or a CLI agent whose name an agent of agents.json also
    /// goes by, which wins.
    private static func holds(_ agents: [AgentProfile]) -> [UUID: String] {
        var held: [UUID: String] = [:]
        for agent in agents {
            var model: String?
            switch agent.wake {
            case .command(let command, _):
                // Named by the program whose part of the command turns its checks off, not the cd before it.
                if let culprit = AgentCommands.culprit(command) {
                    held[agent.id] = AgentCommands.held(culprit.what, program: culprit.program)
                }
            case .claudeCode(let wake): model = wake.model
            case .cliAgent(let wake): model = wake.model
            default: break
            }
            if let model, let what = AgentCommands.refusal(model) {
                held[agent.id] = "Binders won't run it: its model, \(model.trimmingCharacters(in: .whitespaces)), has \(what) in it, which turns checks off. Change it in Settings → Agents."
            }
        }
        let others = agents.filter { if case .cliAgent = $0.wake { return false } else { return true } }
        for agent in agents {
            guard case .cliAgent = agent.wake, held[agent.id] == nil,
                  others.contains(where: { $0.name.localizedCaseInsensitiveCompare(agent.name.trimmingCharacters(in: .whitespaces)) == .orderedSame
                      || isAgent($0, named: agent.name) }) else { continue }
            held[agent.id] = "Another agent goes by this name. Rename one of them."
        }
        return held
    }

    /// Whether it differs from what Binders last saved: in what Mac 0.8.0 also reads (`fingerprint`), or in who it sends
    /// cards to or what it's for, when it says either (`workFingerprint`). Neither said is never a change: going back to
    /// 0.8.0 and saving there drops both, and without them it can't steer anything.
    private static func isChangedOutside(_ agent: AgentProfile) -> Bool {
        if Keychain.read(key("agent-fingerprint", agent.id)) != fingerprint(agent) { return true }
        let work = workFingerprint(agent)
        if !work.isEmpty, Keychain.read(key("agent-work-fingerprint", agent.id)) != work { return true }
        let route = routeFingerprint(agent)
        return !route.isEmpty && Keychain.read(key("agent-route-fingerprint", agent.id)) != route
    }

    /// An enabled agent by the name it goes by on the boards, exactly (ignoring case). Never one whose name only begins
    /// the same: a card for "Sam", a person, or "Claude Code", your own sessions, doesn't wake "Sam Bot" or
    /// "Claude Code · app".
    func agent(named name: String) -> AgentProfile? {
        agents.first { $0.isEnabled && Self.isAgent($0, named: name) }
    }

    /// Whether `holder`, a name on the board, is exactly this agent.
    static func isAgent(_ agent: AgentProfile, named holder: String) -> Bool {
        holder.trimmingCharacters(in: .whitespaces).localizedCaseInsensitiveCompare(agent.name.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// Binders may wake it: on, not changed outside, not held, not paused, and woken some way other than checking the
    /// board itself.
    func wakeable(_ agent: AgentProfile) -> Bool {
        !paused && agent.isEnabled && !changedOutside.contains(agent.id) && held[agent.id] == nil && agent.wake != .board
    }

    /// The agents a card from this binder could be given to now, for a moment's Give to: on, not changed outside Binders,
    /// agents not paused, and taking that binder's cards. One that checks the board itself counts: it picks up what's
    /// meant for it.
    func takers(for binder: UUID?) -> [AgentProfile] {
        guard !paused else { return [] }
        return agents.filter { $0.isEnabled && !changedOutside.contains($0.id) && held[$0.id] == nil && $0.takesCards(from: binder) }
    }

    // MARK: Starting on its own

    /// "Start on cards Binders sends it", as Binders reads it: on in the file, approved by the turn-on alert (the Keychain's
    /// own yes, which only Save in Settings writes, from that alert), and the agent not changed outside Binders. So a value
    /// written into the file by anything else starts nothing.
    func startsOnItsOwn(_ agent: AgentProfile) -> Bool {
        agent.autoStart == true && !changedOutside.contains(agent.id) && Keychain.read(Self.key("agent-starts", agent.id)) == "1"
    }

    /// The yes itself: Save writes it from the turn-on alert (`upsert(…, startsOnItsOwn:)`), and Save with the switch off
    /// takes it away, with Auto's. The self-tests set it directly.
    func setStartsOnItsOwn(_ id: UUID, _ on: Bool) {
        Keychain.write(on ? "1" : "", for: Self.key("agent-starts", id))
        if !on {
            setStartsInAuto(id, false)
            setStartsInSolo(id, false)
        }
    }

    /// The Mac's yes for Auto too: the start switch's yes, renewed by the turn-on alert that names Auto (or its Review…
    /// for an agent switched on before Auto), a second Keychain item beside it. Only then may Auto hand the agent what you
    /// say on your own near your iPhone (RouterRules.mayHandOver, `switchBeforeAuto`). A second item, not a new value in the
    /// first, so a build before Auto still reads the first as it always did.
    func startsInAuto(_ agent: AgentProfile) -> Bool {
        startsOnItsOwn(agent) && Keychain.read(Self.key("agent-starts-auto", agent.id)) == "1"
    }

    /// Auto's yes itself: Save writes it from the alert that names Auto (`upsert(…, startsInAuto:)`), and it goes with the
    /// start switch's. The self-tests set it directly.
    func setStartsInAuto(_ id: UUID, _ on: Bool) {
        Keychain.write(on ? "1" : "", for: Self.key("agent-starts-auto", id))
        if !on { setStartsInSolo(id, false) }
    }

    /// The Mac's yes for captures too (lane Y2): Auto's yes, renewed by the turn-on alert that names what you think out
    /// loud (or its Review… for an agent switched on before), a third Keychain item, `agent-starts-solo`. Only then may Auto
    /// hand the agent what it reads from a capture in which your iPhone heard only you (`switchBeforeSolo`). A third item,
    /// not a new value in Auto's, so a Y1 build never reads it.
    func startsInSolo(_ agent: AgentProfile) -> Bool {
        startsInAuto(agent) && Keychain.read(Self.key("agent-starts-solo", agent.id)) == "1"
    }

    /// The yes for captures itself, written beside Auto's and taken away with it. The self-tests set it directly.
    func setStartsInSolo(_ id: UUID, _ on: Bool) {
        Keychain.write(on ? "1" : "", for: Self.key("agent-starts-solo", id))
    }

    func token(for id: UUID) -> String? {
        Keychain.read(Self.key("agent-token", id)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The token Binders shows its status address, when it reports through one and has a token.
    func statusToken(for id: UUID) -> String? {
        Keychain.read(Self.key("agent-status-token", id)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether the agent holding a card by this name is one whose cards you move yourself: its claims have no time limit,
    /// so they never lapse. Enabled or not.
    func movedByHand(_ holder: String) -> Bool {
        agents.contains { $0.reporting == .manual && Self.isAgent($0, named: holder) }
    }

    // MARK: Changing

    /// Adds or replaces an agent as you saved it in Settings, and approves it as it is now. A token, when given, goes to
    /// the Keychain ("" removes it), and so does its status address's. `startsOnItsOwn`, from the editor's start switch
    /// (on only through the turn-on alert, or the yes it had), writes or takes away the Keychain's yes once the file is
    /// saved: on only when the file now says so, so a load between the alert and Save never finds a yes the file doesn't
    /// say yet. `startsInAuto`, from the alert that names Auto, writes Auto's yes the same way, only beside the switch's;
    /// the switch's own yes taken away takes it too. Returns why it can't be saved, or nil.
    @discardableResult
    func upsert(_ agent: AgentProfile, token: String? = nil, statusToken: String? = nil, startsOnItsOwn: Bool? = nil,
                startsInAuto: Bool? = nil, startsInSolo: Bool? = nil) -> String? {
        if let problem = problem(with: agent) { return problem }
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent } else { agents.append(agent) }
        if let token { Keychain.write(token, for: Self.key("agent-token", agent.id)) }
        if let statusToken { Keychain.write(statusToken, for: Self.key("agent-status-token", agent.id)) }
        save(approving: [agent.id])
        if let startsOnItsOwn { setStartsOnItsOwn(agent.id, startsOnItsOwn && agent.autoStart == true) }
        if let startsInAuto {
            setStartsInAuto(agent.id, startsInAuto && agent.autoStart == true && Keychain.read(Self.key("agent-starts", agent.id)) == "1")
        }
        if let startsInSolo {
            setStartsInSolo(agent.id, startsInSolo && agent.autoStart == true && Keychain.read(Self.key("agent-starts-auto", agent.id)) == "1")
        }
        return nil
    }

    /// For the self-tests: an agent saved as an earlier build would have saved it, without the checks `upsert` makes now,
    /// and approved as it is. Only in a throwaway folder.
    func saveAsBefore(_ agent: AgentProfile) {
        guard AppPaths.isDemo else { return }
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent } else { agents.append(agent) }
        save(approving: [agent.id])
    }

    func remove(_ id: UUID) {
        agents.removeAll { $0.id == id }
        Keychain.write("", for: Self.key("agent-token", id))
        Keychain.write("", for: Self.key("agent-status-token", id))
        Keychain.write("", for: Self.key("agent-fingerprint", id))
        Keychain.write("", for: Self.key("agent-work-fingerprint", id))
        Keychain.write("", for: Self.key("agent-route-fingerprint", id))
        Keychain.write("", for: Self.key("agent-starts", id))
        Keychain.write("", for: Self.key("agent-starts-auto", id))
        Keychain.write("", for: Self.key("agent-starts-solo", id))
        changedOutside.remove(id)
        save(approving: [])
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = agents.firstIndex(where: { $0.id == id }), !changedOutside.contains(id) else { return }
        agents[index].isEnabled = enabled
        save(approving: [id])
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        save(approving: [])
    }

    /// Why an agent can't be saved as it is: a name the boards can't tell apart, or a command Binders won't run. Without
    /// `checkingRepository`, a Claude Code or CLI agent's folder isn't asked to be a repository (Check says so itself), and
    /// everything else, its program among it, still is.
    func problem(with agent: AgentProfile, checkingRepository: Bool = true) -> String? {
        let name = agent.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give it the name it goes by on the boards." }
        if name.count > 60 { return "That name is too long for the boards: 60 characters at most." }
        if BoardRules.isReserved(name) { return "That's your name on the boards. Give the agent its own." }
        if agents.contains(where: { $0.id != agent.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return "Another agent goes by that name."
        }
        if let host = MCPHost.allCases.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            let example = ["claudeCode", "cliAgent"].contains(agent.wake.kind) ? "my-repo" : "helper"
            return "\(host.name) itself goes by that name on the boards. Give the agent its own, such as “\(host.name) · \(example)”."
        }
        switch agent.wake {
        case .command(let command, _):
            if command.trimmed.isEmpty { return "Give the command that wakes it." }
            if let what = AgentCommands.refusal(command) { return AgentCommands.message(what) }
        case .webhook(let address):
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return "The web hook needs an http or https address."
            }
        case .shortcut(let name):
            if name.trimmed.isEmpty { return "Choose the Shortcut that wakes it." }
        case .claudeCode(let wake):
            var folder: ObjCBool = false
            let repository = (wake.repository as NSString).expandingTildeInPath
            // Working in the folder itself, any folder will do; otherwise it needs a repository for the worktree.
            guard !checkingRepository || FileManager.default.fileExists(atPath: repository, isDirectory: &folder) && folder.boolValue
                    && (wake.worksInFolder || FileManager.default.fileExists(atPath: (repository as NSString).appendingPathComponent(".git"))) else {
                return wake.worksInFolder ? "Choose a folder: Claude Code works there."
                    : "Choose a folder with a git repository in it: Claude Code works there, in a worktree of its own. For a folder that isn't one, turn on Work in the Folder Itself."
            }
            if let model = wake.model, let what = AgentCommands.refusal(model) { return AgentCommands.message(what) }
            // Claude Code itself, wherever it's installed, and nothing else in its place.
            if let program = wake.executable {
                let path = (program as NSString).expandingTildeInPath
                guard path.hasPrefix("/"), (path as NSString).lastPathComponent == "claude", FileManager.default.isExecutableFile(atPath: path) else {
                    return "The program for Claude Code must be the claude program itself. Use claude on your PATH, or install it again."
                }
            }
        case .cliAgent(let wake):
            let tool = wake.tool
            let repository = (wake.repository as NSString).expandingTildeInPath
            var folder: ObjCBool = false
            guard !checkingRepository || FileManager.default.fileExists(atPath: repository, isDirectory: &folder) && folder.boolValue
                    && FileManager.default.fileExists(atPath: (repository as NSString).appendingPathComponent(".git")) else {
                return "Choose a folder with a git repository in it: \(tool.name) works there, in a worktree Binders makes for each card."
            }
            if let program = wake.executable {
                // The tool itself, wherever it's installed. It's never put into a shell, so its folders' names don't matter.
                let path = (program as NSString).expandingTildeInPath
                guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                      (path as NSString).lastPathComponent == tool.program, FileManager.default.isExecutableFile(atPath: path) else {
                    return "The program for \(tool.name) must be the \(tool.program) program itself. Use \(tool.program) on your PATH, or install it again."
                }
            }
            let model = wake.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !model.isEmpty {
                if let what = AgentCommands.refusal(model) { return AgentCommands.message(what) }
                if model.hasPrefix("-") { return "A model is a name, not an option: \(model)." }
            }
            if tool.needsModel, !CLIAgentWake.isOpenCodeModel(model) {
                return "Give OpenCode its model as provider/model, such as anthropic/claude-sonnet-4-5: Binders starts it with that model only, so cards go only to the provider you chose."
            }
            if tool == .copilot, name.contains("$") { return "A GitHub Copilot CLI agent's name can't have $ in it: Copilot would read it as a variable." }
            if !tool.readsOnly, !wake.editsFiles {
                return "\(tool.name) can't be held to reading only, so Binders starts it only to edit files in the card's worktree. Set its Permissions to Edits Files."
            }
        case .board:
            break
        }
        // Claude Code reports with Binders' tools and its run's hooks, and a CLI tool with the tools and its output,
        // whatever the file says.
        guard !["claudeCode", "cliAgent"].contains(agent.wake.kind) else { return nil }
        switch agent.report {
        case .ssh(let host):
            if !AgentMCPEntry.isHost(host) { return "Give this Mac's address as the other machine reaches it, such as you@this-mac.local." }
        case .status(let address):
            if agent.wake == .board { return "An agent that checks the board itself reports with Binders' tools, on this Mac or over SSH." }
            if !AgentStatusReply.isAddress(address) { return "The status address needs an http or https address." }
        case .manual:
            if agent.wake == .board { return "An agent that checks the board itself reports with Binders' tools, on this Mac or over SSH." }
        case .mcp:
            break
        }
        return nil
    }

    // MARK: Storage

    /// Writes agents.json, and agents-cli.json for the command-line coding tools, never over a file it couldn't read, and
    /// with every entry this build can't read written back as it was. A copy is kept first of a file that held such
    /// entries. A CLI agent edited into agents.json by hand moves to agents-cli.json. Only the agents named are approved as
    /// they are now.
    private func save(approving approved: Set<UUID>) {
        guard !unreadable else { return }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        func backup(_ file: URL) {
            try? FileManager.default.copyItem(at: file, to: file.deletingPathExtension().appendingPathExtension("before-\(stamp).json"))
        }
        if skipped > 0 {
            backup(url)
            skipped = 0
        }
        if skippedCLI > 0 {
            backup(cliURL)
            skippedCLI = 0
        }
        let isCLI: (AgentProfile) -> Bool = { if case .cliAgent = $0.wake { true } else { false } }
        let cli = agents.filter(isCLI)
        do {
            try AgentFile(paused: paused, agents: agents.filter { !isCLI($0) }, kept: kept).encoded().write(to: url, options: .atomic)
            // agents-cli.json only once there's something for it, and never paused: agents.json and the Keychain say that.
            if !cli.isEmpty || !keptCLI.isEmpty || FileManager.default.fileExists(atPath: cliURL.path) {
                try AgentFile(paused: false, agents: cli, kept: keptCLI).encoded().write(to: cliURL, options: .atomic)
            }
        } catch {
            Log.app.error("Couldn't save agents: \(error.localizedDescription)")
            return
        }
        for agent in agents where approved.contains(agent.id) {
            Keychain.write(Self.fingerprint(agent), for: Self.key("agent-fingerprint", agent.id))
            Keychain.write(Self.workFingerprint(agent), for: Self.key("agent-work-fingerprint", agent.id))
            Keychain.write(Self.routeFingerprint(agent), for: Self.key("agent-route-fingerprint", agent.id))
            changedOutside.remove(agent.id)
        }
        Keychain.write(paused ? "1" : "0", for: Self.key("agents-paused"))
        held = Self.holds(agents)
    }

    /// Where a card handed to the agent goes and what goes with it, fingerprinted for the iPhone's yes before its first
    /// card (`AgentConsent.fingerprint`): an agent pointed somewhere new, or given more to read, is asked about again.
    /// Unlike `fingerprint`, turning it off and on or changing how often it's woken leaves it as it was.
    /// `startsOnItsOwn`: for a phone that sends its yes with what you say (MomentPayload.agreedFeature), whether Binders may
    /// start the agent on its own; every other caller leaves it false, which keeps every fingerprint as it was. `auto`: for
    /// a phone in Auto's reach (MomentPayload.autoFeature), the agent also has the Mac's yes for Auto (`startsInAuto`), so a
    /// yes given to the start sentence alone doesn't count for what Auto hands over.
    /// `solo` (lane Y2): for a phone that lists `soloAuto`, the agent also has the Mac's yes for captures (`startsInSolo`).
    static func consentFingerprint(_ agent: AgentProfile, reads: AgentReads, startsOnItsOwn: Bool = false, auto: Bool = false,
                                   solo: Bool = false) -> String {
        AgentConsent.fingerprint(agent, reads: reads, startsOnItsOwn: startsOnItsOwn, auto: auto, solo: solo)
    }

    /// Everything about an agent as saved here, so a change by anything else shows.
    /// Without who it sends cards to, what it's for, its kinds of work and its start switch, which Mac 0.8.0 doesn't read:
    /// 0.8.0 fingerprints the agent it reads the same way, so going back to it doesn't hold every agent you gave any of them
    /// as changed outside Binders.
    static func fingerprint(_ agent: AgentProfile) -> String {
        var asBefore = agent
        asBefore.vendor = nil
        asBefore.purpose = nil
        asBefore.kinds = nil
        asBefore.autoStart = nil
        asBefore.takesTeamCards = nil
        return hash(asBefore)
    }

    /// Its kinds of work and its start switch, which steer what the router reads and what starts, fingerprinted apart;
    /// "" when it says neither, which never counts as a change.
    /// Take cards from teammates (lane DB2) is in it only when it says something, so an agent saved before it fingerprints
    /// as it did, and one whose "off" went missing (a save by a Mac before it) is held as changed outside Binders.
    static func routeFingerprint(_ agent: AgentProfile) -> String {
        guard agent.kinds != nil || agent.autoStart != nil || agent.takesTeamCards != nil else { return "" }
        var parts = ["kinds": (agent.kinds ?? []).joined(separator: "\n"), "autoStart": agent.autoStart.map { $0 ? "on" : "off" } ?? ""]
        if let teammates = agent.takesTeamCards { parts["takesTeamCards"] = teammates ? "on" : "off" }
        return hash(parts)
    }

    /// Who it sends cards to and what it's for, fingerprinted apart from the rest (`fingerprint`); "" when it says neither.
    static func workFingerprint(_ agent: AgentProfile) -> String {
        guard agent.vendor != nil || agent.purpose != nil else { return "" }
        return hash(["vendor": agent.vendor ?? "", "purpose": agent.purpose ?? ""])
    }

    private static func hash(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    /// Keychain items, kept apart in a throwaway folder so the self-tests never touch yours.
    private static func key(_ name: String, _ id: UUID? = nil) -> String {
        keychainKey(name + (id.map { "-\($0.uuidString)" } ?? ""))
    }

    /// A Keychain item's name as Binders' own items are named: apart in a throwaway folder. DecisionMeasureStore's seals
    /// are named this way too.
    nonisolated static func keychainKey(_ name: String) -> String {
        (AppPaths.isDemo ? "selftest-" : "") + name
    }
}
