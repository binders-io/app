import Darwin
import Foundation
import BindersKit

/// `Binders --stub-cli-agent <tool> …`: the self-tests' stand-in for Codex, OpenCode, GitHub Copilot CLI or Antigravity
/// (agy), which they start through a two-line script in their throwaway folder, never the real tools. It notes what it
/// was given (its arguments, environment, folder and prompt), finds Binders' MCP server the way that tool would (Codex
/// from its -c overrides, OpenCode from OPENCODE_CONFIG_CONTENT, Copilot from its --additional-mcp-config file,
/// Antigravity from its workspace's .agents/mcp_config.json, as documented) and starts it with the
/// environment that tool gives it, asks it for its tools and for two cards, does what its mode says in its folder, prints
/// the canned output the test left for it, and exits as told. Anywhere but a throwaway folder it does nothing.
enum CLIAgentStub {
    static func run(_ arguments: [String]) -> Never {
        guard AppPaths.isDemo, arguments.count >= 3, let tool = CLIAgent(rawValue: arguments[2]) else {
            FileHandle.standardError.write(Data("The stand-in for a coding tool runs only in a throwaway folder.\n".utf8))
            exit(2)
        }
        let given = Array(arguments.dropFirst(3))
        let folder = AppPaths.support.appendingPathComponent("stub", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func setting(_ name: String) -> String? {
            (try? String(contentsOf: folder.appendingPathComponent("\(tool.rawValue)-\(name).txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func note(_ name: String, _ data: Data) { try? data.write(to: folder.appendingPathComponent("\(tool.rawValue)-\(name)")) }

        // Asked its version, in the tool's own shape.
        if given == tool.versionArguments {
            let version = setting("version") ?? tool.checkedVersion
            let shape = switch tool {
            case .codex: "codex-cli \(version)\n"
            case .opencode: "\(version)\n"
            case .copilot: "GitHub Copilot CLI \(version).\nRun 'copilot update' to check for updates.\n"
            // agy's own shape isn't documented: one of those Binders reads.
            case .antigravity: "agy \(version)\n"
            }
            FileHandle.standardOutput.write(Data(shape.utf8))
            exit(0)
        }

        // SIGINT ends the turn, as the tools do, whenever it comes.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler {
            note("signal.txt", Data("SIGINT\n".utf8))
            exit(Int32(setting("interrupt-exit") ?? "") ?? 1)
        }
        interrupt.resume()

        let environment = ProcessInfo.processInfo.environment
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        note("argv.bin", Data(given.joined(separator: "\0").utf8))
        note("env.bin", Data(environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\0").utf8))
        note("cwd.txt", Data(FileManager.default.currentDirectoryPath.utf8))
        note("stdin.txt", stdin)

        // Antigravity's workspace server, as the run found it.
        if tool == .antigravity {
            note("mcp-config.json", (try? Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + AntigravityLaunch.mcpConfig))) ?? Data())
        }

        // Binders' server, found and started as this tool would. Antigravity's prompt is a stream-json message.
        var prompt = String(decoding: stdin, as: UTF8.self)
        if tool == .antigravity, let line = prompt.split(separator: "\n").first,
           let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
           let content = (message["message"] as? [String: Any])?["content"] as? String {
            prompt = content
        }
        let card = prompt.split(separator: "\n").first { $0.hasPrefix("Card: ") }.map { String($0.dropFirst("Card: ".count)) } ?? ""
        let other = setting("other-card") ?? UUID().uuidString
        if let server = server(tool, given, environment) {
            note("mcp.jsonl", Data(talk(to: server, card: card, other: other).joined(separator: "\n").utf8))
        } else {
            note("mcp.jsonl", Data("no server\n".utf8))
        }

        // What its mode does in its folder.
        let here = FileManager.default.currentDirectoryPath
        switch setting("mode") ?? "finish" {
        case "edit":
            if let handle = FileHandle(forWritingAtPath: here + "/README.md") {
                handle.seekToEndOfFile()
                handle.write(Data("A line the stand-in added.\n".utf8))
                try? handle.close()
            }
        case "pointer":
            // Points the worktree's .git at the repository's own git folder.
            if let text = try? String(contentsOfFile: here + "/.git", encoding: .utf8), let gitDir = AgentWorktree.pointer(text) {
                let common = ((gitDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                try? "gitdir: \(common)\n".write(toFile: here + "/.git", atomically: true, encoding: .utf8)
                try? "Changed by the stand-in.\n".write(toFile: here + "/README.md", atomically: true, encoding: .utf8)
            }
        case "nested":
            // A repository inside the worktree, with a clean filter that would leave a mark if anything ran it.
            let sub = here + "/sub"
            try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
            git(["init", "-q", sub])
            let mark = AppPaths.support.appendingPathComponent("filter-ran.txt").path
            git(["-C", sub, "config", "filter.x.clean", "sh -c 'touch \"\(mark)\"; cat'"])
            try? "* filter=x\n".write(toFile: sub + "/.gitattributes", atomically: true, encoding: .utf8)
            try? "inside\n".write(toFile: sub + "/inside.txt", atomically: true, encoding: .utf8)
        case "plant-hooks":
            // A hooks file of its own, which Antigravity would run outside its sandbox.
            try? FileManager.default.createDirectory(atPath: here + "/.agents", withIntermediateDirectories: true)
            try? #"{"mine":{"PreToolUse":[{"matcher":"*","hooks":[{"command":"touch /tmp/never"}]}]}}"#.write(toFile: here + "/.agents/hooks.json", atomically: true, encoding: .utf8)
        case "delete":
            for name in (try? FileManager.default.contentsOfDirectory(atPath: here)) ?? [] where name != ".git" {
                try? FileManager.default.removeItem(atPath: here + "/" + name)
            }
        default:
            break
        }

        // Its canned output, then a line on stderr.
        var output = (try? String(contentsOf: folder.appendingPathComponent("canned/\(tool.rawValue)-\(setting("mode") ?? "finish").jsonl"), encoding: .utf8)) ?? ""
        if let resume = given.first(where: { $0.hasPrefix("--resume=") }) {
            output = output.replacingOccurrences(of: "@SESSION@", with: String(resume.dropFirst("--resume=".count)))
        }
        FileHandle.standardOutput.write(Data(output.utf8))
        FileHandle.standardError.write(Data(((setting("stderr") ?? "stand-in: done") + "\n").utf8))

        // Works a while.
        let end = Date().addingTimeInterval(Double(setting("sleep") ?? "") ?? 0)
        while Date() < end { usleep(50_000) }
        exit(Int32(setting("exit") ?? "") ?? 0)
    }

    /// Binders' server as the tool reads it: the program, its arguments and the environment it gets.
    private struct Server {
        var command: String
        var arguments: [String]
        var environment: [String: String]
    }

    private static func server(_ tool: CLIAgent, _ arguments: [String], _ environment: [String: String]) -> Server? {
        switch tool {
        case .codex:
            // Its -c overrides, read as TOML; a stdio server gets a fixed set of Codex's own variables, then `env`.
            let overrides = TOMLValue.overrides(arguments)
            guard let command = overrides["mcp_servers.binders.command"]?.string else { return nil }
            let args = overrides["mcp_servers.binders.args"]?.array?.compactMap(\.string) ?? []
            var env = environment.filter { ["HOME", "LOGNAME", "PATH", "SHELL", "USER", "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL", "TERM", "TMPDIR", "TZ"].contains($0.key) }
            for (key, value) in overrides["mcp_servers.binders.env"]?.table ?? [:] { env[key] = value.string }
            return Server(command: command, arguments: args, environment: env)
        case .opencode:
            // Its config from the environment; the server gets OpenCode's whole environment, then `environment`.
            guard let text = environment["OPENCODE_CONFIG_CONTENT"],
                  let config = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let entry = ((config["mcp"] as? [String: Any])?["binders"]) as? [String: Any],
                  let command = entry["command"] as? [String], let first = command.first else { return nil }
            var env = environment
            for (key, value) in entry["environment"] as? [String: String] ?? [:] { env[key] = value }
            return Server(command: first, arguments: Array(command.dropFirst()), environment: env)
        case .copilot:
            // Its run file, with $VAR and ${VAR} expanded; the stricter, documented behaviour: PATH alone, then `env`.
            guard let flag = arguments.first(where: { $0.hasPrefix("--additional-mcp-config=@") }),
                  let data = FileManager.default.contents(atPath: String(flag.dropFirst("--additional-mcp-config=@".count))),
                  let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let entry = ((config["mcpServers"] as? [String: Any])?["binders"]) as? [String: Any],
                  let command = entry["command"] as? String else { return nil }
            func expand(_ text: String) -> String {
                var out = text
                for (key, value) in environment { out = out.replacingOccurrences(of: "${\(key)}", with: value).replacingOccurrences(of: "$\(key)", with: value) }
                return out
            }
            var env = ["PATH": environment["PATH"] ?? "/usr/bin:/bin"]
            for (key, value) in entry["env"] as? [String: String] ?? [:] { env[key] = expand(value) }
            return Server(command: expand(command), arguments: (entry["args"] as? [String] ?? []).map(expand), environment: env)
        case .antigravity:
            // Its workspace's mcp_config.json, as documented: the server gets agy's environment, then `env`.
            guard let data = FileManager.default.contents(atPath: FileManager.default.currentDirectoryPath + "/" + AntigravityLaunch.mcpConfig),
                  let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let entry = ((config["mcpServers"] as? [String: Any])?["binders"]) as? [String: Any],
                  let command = entry["command"] as? String else { return nil }
            var env = environment
            for (key, value) in entry["env"] as? [String: String] ?? [:] { env[key] = value }
            return Server(command: command, arguments: entry["args"] as? [String] ?? [], environment: env)
        }
    }

    /// Asks the server for its tools and for two cards, another's and its own, and gives back what it answered, a line
    /// a reply.
    private static func talk(to server: Server, card: String, other: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: server.command)
        process.arguments = server.arguments
        process.environment = server.environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ["didn't start"] }
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                                                           "clientInfo": ["name": "stand-in", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "get_task", "arguments": ["id": other]]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "get_task", "arguments": ["id": card]]],
        ]
        for request in requests {
            if let data = try? JSONSerialization.data(withJSONObject: request) {
                input.fileHandleForWriting.write(data)
                input.fileHandleForWriting.write(Data("\n".utf8))
            }
        }
        // Replies come back by id; four of them, or as many as came within 30 seconds.
        var lines: [String] = []
        var pending = Data()
        let reading = DispatchSemaphore(value: 0)
        let lock = NSLock()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.withLock {
                if chunk.isEmpty { reading.signal(); return }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
                if lines.count >= 4 { reading.signal() }
            }
        }
        _ = reading.wait(timeout: .now() + 30)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        return lock.withLock { lines }
    }

    private static func git(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
