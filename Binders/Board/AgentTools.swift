import CoreFoundation
import Foundation
import Observation
import BindersKit

/// Which of the coding agents' command-line tools are on this Mac, for Settings → Agents: looked up by name on the login
/// shell's PATH each time the page appears, as Claude Code's Check does, so a tool installed while Binders runs shows up
/// the next time you open it. Nothing is started. Run against a throwaway data folder, it finds nothing.
@MainActor
@Observable
final class AgentTools {
    static let shared = AgentTools()

    /// Each program found, by its name: codex, opencode, copilot, agy, grok.
    private(set) var found: [String: String] = [:]
    @ObservationIgnored private var looking = false

    func has(_ tool: CLIAgent) -> Bool { found[tool.program] != nil }

    /// Grok Build is on this Mac, though Binders doesn't start it.
    var hasGrok: Bool { found["grok"] != nil }

    /// Looks again, each time the page appears; one look at a time. What it found before stays until this one answers.
    func look() async {
        guard !looking, !AppPaths.isDemo else { return }
        looking = true
        defer { looking = false }
        let script = #"for p in codex opencode copilot agy grok; do printf '%s=%s\n' "$p" "$(command -v "$p")"; done"#
        guard let result = try? await AutomationService.runProcess("/bin/zsh", ["-lc", script], stdin: nil, environment: nil, timeout: 20) else { return }
        var found: [String: String] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, CLIProgram.isProgram(parts[1]) else { continue }
            found[parts[0]] = parts[1]
        }
        self.found = found
    }
}

/// Finding and checking a CLI tool's program, for a run and for Check. Never a shell with a path in it: the login shell
/// runs one fixed script with the program's name as its argument, and the program itself is run directly.
enum CLIProgram {
    struct Found: Sendable {
        /// The program.
        var path: String
        /// The login shell's PATH, for the run, or "" for the system's.
        var searchPath: String
    }

    /// An absolute path to an executable file: not an alias, a function or nothing.
    static func isProgram(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// The program for a tool: the override, when it's set, which must be that program; otherwise the one on the login
    /// shell's PATH. With the login shell's PATH, except in a throwaway folder, which never runs your shell.
    static func find(_ tool: CLIAgent, executable: String?) async -> Result<Found, AgentWorktrees.Failure> {
        if let executable {
            let path = (executable as NSString).expandingTildeInPath
            guard isProgram(path), (path as NSString).lastPathComponent == tool.program else {
                return .failure(AgentWorktrees.Failure("Couldn't start \(tool.name): its program, \(AgentWorktrees.display(path)), isn't the \(tool.program) program. Use \(tool.program) on your PATH in Settings → Agents."))
            }
            return .success(Found(path: path, searchPath: AppPaths.isDemo ? "" : await loginPath() ?? ""))
        }
        guard !AppPaths.isDemo else { return .failure(AgentWorktrees.Failure("Not run in a throwaway folder")) }
        let script = #"p="$(command -v "$1")"; printf '%s\n%s' "$p" "$PATH""#
        guard let result = try? await AutomationService.runProcess("/bin/zsh", ["-lc", script, "binders", tool.program], stdin: nil, environment: nil, timeout: 20) else {
            return .failure(AgentWorktrees.Failure("Couldn't start \(tool.name): your login shell didn't answer in time."))
        }
        let lines = result.stdout.components(separatedBy: "\n")
        let path = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard isProgram(path) else { return .failure(AgentWorktrees.Failure("Couldn't start \(tool.name): \(tool.program) isn't on your PATH.")) }
        return .success(Found(path: path, searchPath: lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// The login shell's PATH.
    static func loginPath() async -> String? {
        guard let result = try? await AutomationService.runProcess("/bin/zsh", ["-lc", #"printf '%s' "$PATH""#], stdin: nil, environment: nil, timeout: 20),
              result.status == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The version the program says, when what it printed is this tool's shape; nil when it isn't the tool. Run directly,
    /// with the runs' allowlist environment.
    static func version(_ tool: CLIAgent, at found: Found) async -> String? {
        let environment = CLIAgentLaunches.environment(base: ProcessInfo.processInfo.environment, home: NSHomeDirectory(), path: found.searchPath,
                                                       temporary: NSTemporaryDirectory(), throwawayData: AppPaths.isDemo ? AppPaths.support.path : nil)
        guard let result = try? await AutomationService.runProcess(found.path, tool.versionArguments, stdin: nil, environment: environment, timeout: 10) else {
            return nil
        }
        return tool.version(in: result.stdout)
    }

    // MARK: A version you accepted

    /// The Keychain item for the version of a tool you accepted with Check, apart in a throwaway folder: no agent can
    /// accept one.
    private static func key(_ tool: CLIAgent) -> String { (AppPaths.isDemo ? "selftest-" : "") + "agent-cli-version-" + tool.rawValue }

    static func accepted(_ tool: CLIAgent) -> String? {
        Keychain.read(key(tool)).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func accept(_ version: String?, for tool: CLIAgent) {
        Keychain.write(version ?? "", for: key(tool))
    }

    /// Why Binders won't start this version, or nil.
    static func versionProblem(_ tool: CLIAgent, version: String) -> String? {
        guard !tool.starts(version, accepted: accepted(tool)) else { return nil }
        return "Binders didn't start \(tool.name): this is \(tool.name) \(version), and Binders' options were checked with \(tool.checkedVersion). Open its agent in Settings → Agents and press Check to use this version."
    }

    // MARK: Codex's settings from an administrator

    /// What's in Codex's folder of settings from an administrator, by the names Codex looks for (/etc/codex/<name>), and
    /// the managed preferences an administrator forced. It lists the folder and asks whether a preference is forced
    /// without reading either, as Codex itself does, and opens none of the files.
    static func managedCodex() -> (existing: [String], forced: [String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: AgentPlaces.managedCodexFolder)) ?? []
        let existing = names.filter(CodexManaged.counts).sorted().map { CodexManaged.folder + "/" + $0 }
        guard !AppPaths.isDemo else { return (existing, []) }
        let forced = CodexManaged.forcedKeys.filter { CFPreferencesAppValueIsForced($0 as CFString, CodexManaged.application as CFString) }
        return (existing, forced)
    }

    // MARK: Copilot's settings folder for runs

    /// Makes Copilot's settings folder for Binders' runs ready: refuses while anything that runs code or changes where
    /// cards go is in it, sets back what a look-in may have changed, and deletes approvals given while looking in. Why it
    /// can't, or nil.
    static func prepareCopilotHome() -> String? {
        let manager = FileManager.default
        let folder = AgentPlaces.ensure(AgentPlaces.copilotHome)
        let shown = AgentWorktrees.display(folder.path)
        var present: Set<String> = []
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let path = folder.appendingPathComponent(name).path
            var isFolder: ObjCBool = false
            manager.fileExists(atPath: path, isDirectory: &isFolder)
            if !isFolder.boolValue || !((try? manager.contentsOfDirectory(atPath: path)) ?? []).isEmpty { present.insert(name) }
        }
        let servers = try? Data(contentsOf: folder.appendingPathComponent("mcp-config.json"))
        if let problem = CopilotHome.problem(present: present, mcpConfig: servers, folder: shown) { return problem }
        for name in CopilotHome.settingsFiles {
            let url = folder.appendingPathComponent(name)
            // config.json always, so a first run starts safe; settings.json when a later Copilot made one.
            guard name == "config.json" || manager.fileExists(atPath: url.path) else { continue }
            do {
                try AgentPlaces.write(try CopilotHome.reset(try? Data(contentsOf: url)), to: url)
            } catch {
                return "Binders didn't start GitHub Copilot CLI: \(name) in its settings folder for Binders' runs, \(shown), isn't JSON Binders can read. Fix it or remove it there, then Wake Now."
            }
        }
        for name in CopilotHome.deleted { try? manager.removeItem(at: folder.appendingPathComponent(name)) }
        return nil
    }

    /// What's in Copilot's settings folder that would stop a run, for Check; nil when nothing would. Changes nothing.
    static func copilotHomeProblem() -> String? {
        let manager = FileManager.default
        let folder = AgentPlaces.copilotHome
        var present: Set<String> = []
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let path = folder.appendingPathComponent(name).path
            var isFolder: ObjCBool = false
            manager.fileExists(atPath: path, isDirectory: &isFolder)
            if !isFolder.boolValue || !((try? manager.contentsOfDirectory(atPath: path)) ?? []).isEmpty { present.insert(name) }
        }
        return CopilotHome.problem(present: present, mcpConfig: try? Data(contentsOf: folder.appendingPathComponent("mcp-config.json")),
                                   folder: AgentWorktrees.display(folder.path))
    }
}

// MARK: - Antigravity's files

/// What Binders reads and writes around an Antigravity run: two settings in your Antigravity settings file (read, never
/// changed), Binders' server for the run in the worktree's .agents folder (written before, taken out after), and the
/// card's last conversation, so the next run carries on from it. In a throwaway folder, the settings file sits under
/// Binders' folder for runs, so a self-test never reads yours.
enum AntigravityFiles {
    /// Your Antigravity settings: ~/.gemini/antigravity-cli/settings.json.
    static var settings: URL {
        let home = AppPaths.isDemo ? AgentPlaces.root : FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(AntigravitySettings.path)
    }

    /// What no run may read, as a run is given it (`AgentDispatcher.cliRun`), with the team folder when there is one.
    private static func privatePaths(team: String?) -> [String] {
        CLIAgentLaunches.privatePaths(home: NSHomeDirectory(), dataFolder: AppPaths.support.path, alsoPrivate: [AgentPlaces.logs.path] + [team].compactMap { $0 })
    }

    /// Why a run in `worktree` can't start with your settings as they are, or nil. Only toolPermission and
    /// permissions.allow are looked at (AntigravitySettings).
    static func settingsProblem(worktree: String, team: String?) -> String? {
        AntigravitySettings.problem(try? Data(contentsOf: settings), worktree: worktree, home: NSHomeDirectory(), privatePaths: privatePaths(team: team))
    }

    /// The same, for Check; nil when a run could start.
    static func settingsFound(team: String?) -> String? {
        AntigravitySettings.found(try? Data(contentsOf: settings), worktree: nil, home: NSHomeDirectory(), privatePaths: privatePaths(team: team))
    }

    private static func folder(_ worktree: String) -> URL {
        URL(fileURLWithPath: worktree, isDirectory: true).appendingPathComponent(AntigravityLaunch.workspaceFolder, isDirectory: true)
    }

    /// Takes out Binders' server for a run, when it's the one Binders wrote, and the .agents folder when nothing else is
    /// in it. One a run changed, or anyone else's, stays.
    static func takeOut(worktree: String) {
        let manager = FileManager.default
        let file = URL(fileURLWithPath: AntigravityLaunch.mcpConfigPath(worktree: worktree))
        if let data = try? Data(contentsOf: file), AntigravityLaunch.isOurs(data, binders: MCPHost.executable) { try? manager.removeItem(at: file) }
        let place = folder(worktree)
        if let left = try? manager.contentsOfDirectory(atPath: place.path), left.isEmpty { try? manager.removeItem(at: place) }
    }

    /// What's in the worktree's .agents folder: the names there, of files and of folders that hold anything.
    private static func present(worktree: String) -> Set<String> {
        let manager = FileManager.default
        let place = folder(worktree)
        var present: Set<String> = []
        for name in (try? manager.contentsOfDirectory(atPath: place.path)) ?? [] {
            let path = place.appendingPathComponent(name).path
            var isFolder: ObjCBool = false
            manager.fileExists(atPath: path, isDirectory: &isFolder)
            if !isFolder.boolValue || !((try? manager.contentsOfDirectory(atPath: path)) ?? []).isEmpty { present.insert(name) }
        }
        return present
    }

    /// Before a run: Binders' own server left from one that ended badly goes; then why the worktree can't have a run, or nil.
    static func workspaceProblem(worktree: String) -> String? {
        takeOut(worktree: worktree)
        return AntigravityWorkspace.problem(present: present(worktree: worktree))
    }

    /// After a run, before the commit: Binders' server goes; then why Binders won't commit what's there, or nil.
    static func commitProblem(worktree: String) -> String? {
        takeOut(worktree: worktree)
        return AntigravityWorkspace.added(present: present(worktree: worktree), worktree: AgentWorktrees.display(worktree))
    }

    /// The card's last conversation, beside the runs' logs (pruned with them after 14 days).
    private static func conversationFile(_ card: UUID) -> URL {
        AgentPlaces.logs.appendingPathComponent("\(CLIAgentLaunches.card12(card))-antigravity.conversation")
    }

    static func conversation(for card: UUID) -> String? {
        (try? String(contentsOf: conversationFile(card), encoding: .utf8)).flatMap(AntigravityLaunch.conversationID)
    }

    static func remember(_ conversation: String?, for card: UUID) {
        guard let id = conversation.flatMap(AntigravityLaunch.conversationID) else { return }
        try? FileManager.default.createDirectory(at: AgentPlaces.logs, withIntermediateDirectories: true)
        try? AgentPlaces.write(Data(id.utf8), to: conversationFile(card))
    }
}
