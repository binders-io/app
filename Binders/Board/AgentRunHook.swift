import AppKit
import Foundation
import BindersKit

/// `Binders --agent-hook stop` and `--agent-hook session-end`: the Stop and SessionEnd hooks of a Claude Code run Binders
/// started (`ClaudeCodeLaunch`). It reads the hook's JSON on standard input and puts a short report on the run's card
/// (BINDERS_CARD) as its agent (BINDERS_AGENT), through the inbox like any agent's write: what the run said last, or that
/// its session ended. The app keeps it to one report a run (`AgentDispatcher.reported`), and the run's end stands in when
/// no hook comes. It prints nothing and always exits 0, so a hook never holds the run up or keeps Claude from stopping.
/// And `--agent-hook pre-tool`, the PreToolUse hook of a run not limited to Binders' tools, which refuses every MCP tool
/// but Binders' board tools (`ClaudeCodeToolGuard`).
@MainActor
enum AgentRunHook {
    static func run(_ arguments: [String]) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        // `--agent-hook pre-tool`: a run not limited to Binders' tools asks before each MCP tool. A refusal is said on standard
        // error with exit status 2, which Claude Code takes as "don't run it" and tells the run why.
        if let index = arguments.firstIndex(of: "--agent-hook"), arguments.indices.contains(index + 1),
           [ClaudeCodeToolGuard.hook, ClaudeCodeToolGuard.managerHook].contains(arguments[index + 1]) {
            let manager = arguments[index + 1] == ClaudeCodeToolGuard.managerHook
            guard let why = manager ? ClaudeCodeToolGuard.managerRefusal(input) : ClaudeCodeToolGuard.refusal(input) else { exit(0) }
            FileHandle.standardError.write(Data((why + "\n").utf8))
            exit(2)
        }
        let environment = ProcessInfo.processInfo.environment
        guard let index = arguments.firstIndex(of: "--agent-hook"), arguments.indices.contains(index + 1),
              let hook = AgentRunReport.Hook(rawValue: arguments[index + 1]),
              let card = environment["BINDERS_CARD"].flatMap(UUID.init(uuidString:)),
              let agent = environment["BINDERS_AGENT"]?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty,
              !BoardRules.isReserved(agent),
              let report = AgentRunReport.make(hook, input: input, transcript: tail) else { exit(0) }
        send(InboxRequest(action: "report_run", fields: ["id": card.uuidString, "hook": hook.rawValue, "session": report.session,
                                                        "text": report.text, "actor": String(agent.prefix(60)),
                                                        "actor_kind": BoardActor.Kind.agent.rawValue]),
             waiting: hook == .stop ? 20 : 10)
        exit(0)
    }

    /// The end of a transcript, where its last message is: up to its last 4 MB.
    private static func tail(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: (path as NSString).expandingTildeInPath) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let limit: UInt64 = 4 * 1024 * 1024
        try? handle.seek(toOffset: size > limit ? size - limit : 0)
        return try? handle.readToEnd()
    }

    /// Hands the request to the running app as `Binders --mcp` does, and waits up to `seconds` for it to be taken. One not
    /// taken by then is withdrawn: the run's end says what happened instead.
    private static func send(_ request: InboxRequest, waiting seconds: TimeInterval) {
        let name = UUID().uuidString
        let directory = AppPaths.support.appendingPathComponent(Inbox.folder, isDirectory: true)
        let requestURL = directory.appendingPathComponent(Inbox.requestFile(name))
        let resultURL = directory.appendingPathComponent(Inbox.resultFile(name))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        } catch {
            return
        }
        // In a throwaway folder the self-test takes the request; the link would go to the real app. Never to the front.
        if !AppPaths.isDemo {
            var components = URLComponents()
            components.scheme = "binders"
            components.host = "apply"
            components.queryItems = [URLQueryItem(name: "file", value: name)]
            if let url = components.url {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
            }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: resultURL.path) {
                try? FileManager.default.removeItem(at: resultURL)
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        try? FileManager.default.removeItem(at: requestURL)
    }
}
