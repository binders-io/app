import Foundation
import BindersKit

/// Waking the Manager (lane MG1), here because AgentDispatcher is the only code that starts an agent: Claude Code, for one
/// request, in an empty folder Binders keeps for it, with its permission checks on and Binders' tools alone
/// (`ManagerLaunch`). `ManagerService` keeps the requests and says when one is over.
extension AgentDispatcher {
    /// The folder the Manager's runs start in, kept empty: it works through Binders' tools, never on files.
    static var managerFolder: URL { AgentPlaces.root.appendingPathComponent("manager", isDirectory: true) }

    /// Starts the Manager for a request, or says why it can't. `exited` hears the run's exit status and its log.
    func wakeManager(_ agent: AgentProfile, request: UUID, exited: @escaping @MainActor (Int32, URL) -> Void) -> Result<Process, ManagerWakeFailure> {
        guard !registry.paused else { return .failure(.init("Agents are paused in Settings → Agents, so the Manager can't start.")) }
        guard registry.isManager(agent), registry.wakeable(agent), case .claudeCode(var wake) = agent.wake else {
            return .failure(.init("\(agent.name) can't be woken as it is. Look at it in Settings → Agents."))
        }
        // The Manager has Binders' tools and nothing else, which a Claude Code that an organization manages may refuse.
        guard Self.asksOnlyBinders else {
            return .failure(.init("This Mac's Claude Code is managed in a way that won't run with Binders' tools alone, so the Manager can't start."))
        }
        wake.executable = wake.executable.map { ($0 as NSString).expandingTildeInPath }
        let folder = Self.managerFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failure(.init("Couldn't make the Manager's folder: \(error.localizedDescription)"))
        }
        let launch = ManagerLaunch.make(request: request, boardName: agent.name, wake: wake, binders: MCPHost.executable,
                                        dataFolder: AppPaths.support.path, home: NSHomeDirectory(),
                                        alsoPrivate: [Self.logs.path] + [AppSettings.shared.teamFolderPath].compactMap { $0 },
                                        session: UUID(), directory: folder.path)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let log = Self.logs.appendingPathComponent("manager-\(request.uuidString.prefix(8).lowercased())-\(stamp).jsonl")
        do {
            // The login shell finds claude on your PATH; the script is fixed, and everything else goes in as arguments.
            let environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, added in added }
            let process = try AutomationService.launch("/bin/zsh", ["-lc", "exec \"$@\"", "binders", wake.executable ?? "claude"] + launch.arguments,
                                                       stdin: launch.prompt, environment: environment, directory: folder,
                                                       log: log, limit: Self.managerLimit) { status in
                Task { @MainActor in exited(status, log) }
            }
            return .success(process)
        } catch {
            return .failure(.init("Couldn't start Claude Code: \(error.localizedDescription)"))
        }
    }

    /// Starts a local model as the Manager for a request (lane MG2), or says why it can't: Binders' own `--mcp` under the
    /// Manager's confinement, and the model's turns (`ManagerLocalRun`). `client`: the model, nil when Settings → AI has
    /// none. `pump`: self-tests only.
    func wakeLocalManager(_ agent: AgentProfile, request: UUID, client: LLMClient?, pump: (@MainActor () async -> Void)? = nil,
                          exited: @escaping @MainActor (Int32, URL) -> Void) -> Result<any ManagerRunning, ManagerWakeFailure> {
        guard !registry.paused else { return .failure(.init("Agents are paused in Settings → Agents, so the Manager can't start.")) }
        guard registry.isManager(agent), registry.wakeable(agent), case .localModel = agent.wake else {
            return .failure(.init("\(agent.name) can't be woken as it is. Look at it in Settings → Agents."))
        }
        guard let client else {
            return .failure(.init("No model is set for the Manager. Choose one in Settings → AI, or name one for \(agent.name) in Settings → Agents."))
        }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let log = Self.logs.appendingPathComponent("manager-\(request.uuidString.prefix(8).lowercased())-\(stamp).jsonl")
        do {
            try FileManager.default.createDirectory(at: Self.logs, withIntermediateDirectories: true)
            return .success(try ManagerLocalRun(request: request, agentName: agent.name, client: client, executable: MCPHost.executable,
                                                log: log, limit: Self.managerLimit, pump: pump, exited: exited))
        } catch {
            return .failure(.init("Couldn't start Binders' tools for the Manager: \(error.localizedDescription)"))
        }
    }

    /// The longest a request runs before Binders stops it.
    static let managerLimit: TimeInterval = 30 * 60
}

/// Why the Manager didn't start, in words for the request.
struct ManagerWakeFailure: Error {
    var why: String
    init(_ why: String) { self.why = why }
}
