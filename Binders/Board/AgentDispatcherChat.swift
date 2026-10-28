import Foundation
import BindersKit

/// Starting Claude Code for a chat (lane AC1), here because AgentDispatcher is the only code that starts an agent: as for
/// its cards, with its permission mode, its sandbox, Binders' board tools as the agent and its private folders denied
/// (`AgentChatLaunch`), in a worktree of its own for the chat. `AgentChatService` keeps the chat and its replies.
extension AgentDispatcher {
    /// Starts it on `prompt`, or says why it can't. `exited` hears the run's exit status and its log.
    func wakeChat(_ agent: AgentProfile, wake: ClaudeCodeWake, chat: AgentChat, session: UUID, resume: Bool, prompt: String, strict: Bool,
                  exited: @escaping @MainActor (Int32, URL) -> Void) -> Result<(Process, URL), AgentChatService.Failure> {
        guard !registry.paused else { return .failure(.init("Agents are paused in Settings → Agents.")) }
        guard registry.wakeable(agent) else { return .failure(.init("\(agent.name) can't be started as it is. Look at it in Settings → Agents.")) }
        // Not limited to Binders' tools, only the hook keeps it to Binders' board tools: an organization that runs its own
        // hooks alone would leave it out.
        if !strict, Self.managedHooksOnly {
            return .failure(.init("Claude Code on this Mac has settings from your organization that run only its own hooks, so Binders can't keep a chat to its tools. Give \(agent.name) a card instead, or ask your admin."))
        }
        var wake = wake
        wake.repository = (wake.repository as NSString).expandingTildeInPath
        wake.executable = wake.executable.map { ($0 as NSString).expandingTildeInPath }
        guard FileManager.default.fileExists(atPath: wake.repository) else {
            return .failure(.init("\(agent.name)'s folder, \((wake.repository as NSString).abbreviatingWithTildeInPath), isn't there."))
        }
        let directory = chat.directory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let launch = AgentChatLaunch.claude(chat: chat.id, boardName: agent.name, wake: wake, binders: MCPHost.executable,
                                            dataFolder: AppPaths.support.path, home: NSHomeDirectory(),
                                            alsoPrivate: [Self.logs.path] + [AppSettings.shared.teamFolderPath].compactMap { $0 },
                                            session: session, resume: resume && directory != nil, directory: directory, prompt: prompt, strictMCP: strict)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let log = Self.logs.appendingPathComponent("chat-\(chat.id.uuidString.prefix(8).lowercased())-\(stamp).jsonl")
        do {
            // The login shell finds claude on your PATH; the script is fixed, and everything else goes in as arguments.
            let environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, added in added }
            let process = try AutomationService.launch("/bin/zsh", ["-lc", "exec \"$@\"", "binders", wake.executable ?? "claude"] + launch.arguments,
                                                       stdin: launch.prompt, environment: environment, directory: URL(fileURLWithPath: launch.directory),
                                                       log: log, limit: Self.chatLimit) { status in
                Task { @MainActor in exited(status, log) }
            }
            return .success((process, log))
        } catch {
            return .failure(.init("Couldn't start Claude Code: \(error.localizedDescription)"))
        }
    }

    /// The longest one message's run goes on before Binders stops it.
    static let chatLimit: TimeInterval = 60 * 60
}
