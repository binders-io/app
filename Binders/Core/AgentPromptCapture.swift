import AppKit
import SQLite3
import BindersKit

/// The harnesses Binders reads prompts from: the ones it knows, yours from `agent-harnesses.json`, and the record
/// `Binders --capture-prompt` keeps for tools with hooks.
@MainActor
enum AgentHarnesses {
    /// Your own descriptions: an array of harnesses, see docs/CAPTURE.md.
    static var customFile: URL { AppPaths.support.appendingPathComponent("agent-harnesses.json") }
    /// What hooks send, one prompt a line, while capture is on.
    nonisolated static var hookRecord: URL { AppPaths.support.appendingPathComponent("agent-prompts.jsonl") }
    /// Present while capture is on, so a hook knows whether to keep anything.
    nonisolated static var captureFlag: URL { AppPaths.support.appendingPathComponent(".capture-on") }

    static var hooks: AgentHarness {
        AgentHarness(id: AgentHarness.hooksID, name: "Tools with hooks", format: .jsonl, path: hookRecord.path,
                     text: "text", time: "time", timeUnit: .ms, project: "project", tool: "tool")
    }

    /// Opens `agent-harnesses.json`, with an example to copy the first time.
    static func revealCustomFile() {
        if !FileManager.default.fileExists(atPath: customFile.path) {
            let example = """
            [
              {
                "id": "example",
                "name": "An AI tool",
                "format": "jsonl",
                "path": "~/.example/history.jsonl",
                "text": "prompt",
                "time": "timestamp",
                "timeUnit": "ms",
                "project": "cwd"
              }
            ]
            """
            try? example.write(to: customFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([customFile])
    }

    static func all() -> [AgentHarness] {
        let custom = (try? Data(contentsOf: customFile)).map(AgentHarness.decode) ?? []
        return AgentHarness.all(adding: custom) + [hooks]
    }

    /// The files a harness keeps, now: "~" is the home folder, and each "*" any one folder.
    nonisolated static func files(of harness: AgentHarness) -> [URL] {
        let home = ProcessInfo.processInfo.environment["BINDERS_AGENT_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = harness.path.hasPrefix("~") ? home + harness.path.dropFirst() : harness.path
        var candidates = ["/"]
        for part in expanded.split(separator: "/").map(String.init) {
            if part == "*" {
                candidates = candidates.flatMap { base in
                    ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).filter { !$0.hasPrefix(".") }
                        .map { (base as NSString).appendingPathComponent($0) }
                }
            } else {
                candidates = candidates.map { ($0 as NSString).appendingPathComponent(part) }
            }
        }
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Whether the harness is on this Mac: its record, or the folder it keeps it in.
    nonisolated static func isInstalled(_ harness: AgentHarness) -> Bool {
        if harness.id == AgentHarness.hooksID || !files(of: harness).isEmpty { return true }
        let home = ProcessInfo.processInfo.environment["BINDERS_AGENT_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = harness.path.hasPrefix("~") ? home + harness.path.dropFirst() : harness.path
        let fixed = expanded.components(separatedBy: "/*").first ?? expanded
        let folder = fixed == expanded ? (fixed as NSString).deletingLastPathComponent : fixed
        return FileManager.default.fileExists(atPath: folder)
    }
}

/// Reads the prompts you send AI agents in the terminal while writing capture is on, from each harness's own record,
/// starting where the record was when capture started. Terminal screens are never read.
@MainActor
final class AgentPromptCapture {
    private enum Mark {
        /// jsonl: how far into the file has been read.
        case offset(UInt64)
        /// json: the prompts already there, and when the file last changed.
        case seen(Set<String>, Date?)
        /// sqlite: prompts newer than this, in milliseconds, and the ones already kept at that moment.
        case since(Int64, Set<String>, Date?)
    }

    private var harnesses: [AgentHarness] = []
    private var marks: [String: Mark] = [:]

    func start(_ harnesses: [AgentHarness]) {
        self.harnesses = harnesses
        marks = [:]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for harness in harnesses {
            for file in AgentHarnesses.files(of: harness) {
                switch harness.format {
                case .jsonl: marks[file.path] = .offset(Self.size(of: file))
                case .json: marks[file.path] = .seen(Set(Self.items(harness, file).map { Self.fingerprint($0, harness) }), Self.modified(file))
                case .sqlite: marks[file.path] = .since(now, [], nil)
                }
            }
        }
    }

    func stop() {
        harnesses = []
        marks = [:]
    }

    /// The prompts sent since the last look, with the name of the harness they went to.
    func poll() -> [(tool: String, prompt: AgentPrompt)] {
        var found: [(String, AgentPrompt)] = []
        for harness in harnesses {
            for file in AgentHarnesses.files(of: harness) {
                for prompt in read(harness, file) { found.append((prompt.tool ?? harness.name, prompt)) }
            }
        }
        return found
    }

    private func read(_ harness: AgentHarness, _ file: URL) -> [AgentPrompt] {
        switch harness.format {
        case .jsonl:
            // A record that appeared after capture started is all new.
            var offset: UInt64 = 0
            if case .offset(let known) = marks[file.path] { offset = known }
            let size = Self.size(of: file)
            guard size >= offset else {
                marks[file.path] = .offset(size)
                return []
            }
            guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else {
                marks[file.path] = .offset(offset)
                return []
            }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: Int(min(size - offset, 4_000_000))) else { return [] }
            let (lines, consumed) = AgentPrompts.completeLines(in: data)
            marks[file.path] = .offset(offset + UInt64(consumed))
            return lines.compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))).flatMap(harness.prompt(from:))
            }

        case .json:
            var seen = Set<String>(), changed: Date?
            if case .seen(let known, let date) = marks[file.path] { (seen, changed) = (known, date) }
            let modified = Self.modified(file)
            guard modified != changed || marks[file.path] == nil else { return [] }
            let prompts = Self.items(harness, file)
            let new = prompts.filter { !seen.contains(Self.fingerprint($0, harness)) }
            marks[file.path] = .seen(seen.union(prompts.map { Self.fingerprint($0, harness) }), modified)
            return new

        case .sqlite:
            guard case .since(let since, let kept, let changed) = marks[file.path] ?? .since(Int64(Date().timeIntervalSince1970 * 1000), [], nil),
                  let query = harness.query else { return [] }
            // Nothing has been written since the last look: the database and its write-ahead log are as they were.
            let modified = [Self.modified(file), Self.modified(URL(fileURLWithPath: file.path + "-wal"))].compactMap { $0 }.max()
            guard modified != changed else { return [] }
            let rows = Self.rows(file, query: query, since: since)
            var latest = since, keptNow = kept
            var prompts: [AgentPrompt] = []
            for row in rows where !kept.contains(row.id) {
                latest = max(latest, row.time)
                keptNow.insert(row.id)
                if let words = AgentPrompts.worthKeeping(row.text) {
                    prompts.append(AgentPrompt(text: words, project: row.project, date: Date(timeIntervalSince1970: Double(row.time) / 1000), session: nil))
                }
            }
            marks[file.path] = .since(latest, latest == since ? keptNow : Set(rows.filter { $0.time == latest }.map(\.id)), modified)
            return prompts
        }
    }

    // MARK: Reading records

    private static func items(_ harness: AgentHarness, _ file: URL) -> [AgentPrompt] {
        guard let data = try? Data(contentsOf: file), let document = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return harness.items(in: document).compactMap(harness.prompt(from:))
    }

    /// A prompt told apart from the others: by its words, and its time when the record keeps one (Copilot's doesn't).
    private static func fingerprint(_ prompt: AgentPrompt, _ harness: AgentHarness) -> String {
        harness.time == nil ? prompt.text : prompt.text + "|" + String(Int(prompt.date.timeIntervalSince1970))
    }

    private static func rows(_ file: URL, query: String, since: Int64) -> [(id: String, text: String, time: Int64, project: String?)] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 200)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let index = sqlite3_bind_parameter_index(statement, ":since")
        if index > 0 { sqlite3_bind_int64(statement, index, since) }
        var rows: [(String, String, Int64, String?)] = []
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        while sqlite3_step(statement) == SQLITE_ROW, rows.count < 500 {
            guard let id = text(0), let words = text(1) else { continue }
            rows.append((id, words, sqlite3_column_int64(statement, 2), text(3)))
        }
        return rows
    }

    private static func size(of url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// `Binders --capture-prompt [--tool Name] [--project folder]`, for an AI tool's hook: reads the prompt from stdin (the
/// hook's JSON, or plain words) and keeps it for writing capture, only while capture is on. Prints nothing, and always
/// succeeds, so a hook never holds up the tool it's in.
enum PromptHook {
    static func run(_ arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard FileManager.default.fileExists(atPath: AgentHarnesses.captureFlag.path), let payload = HookPayload.read(input) else { exit(0) }
        let line: [String: Any] = ["tool": value("--tool") ?? "AI tool", "text": payload.text,
                                   "time": Int(Date().timeIntervalSince1970 * 1000), "project": value("--project") ?? payload.project ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: line) else { exit(0) }
        let record = AgentHarnesses.hookRecord
        if !FileManager.default.fileExists(atPath: record.path) { FileManager.default.createFile(atPath: record.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: record) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
        exit(0)
    }
}
