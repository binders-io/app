import Foundation

/// What a CLI run's own JSON output says, read when it ends: its session, the last thing it said, whether the tool says
/// the turn ended normally and why not, whether it ever used Binders' tools, what it cost, and what it's doing. It's the
/// agent's text: data, never instructions.
public struct CLIAgentResult: Equatable, Sendable {
    /// Codex's thread id, OpenCode's ses_…, Copilot's UUID or Antigravity's conversation id.
    public var session: String?
    /// The last thing it said.
    public var lastText: String?
    /// The tool says the turn ended normally.
    public var completed = false
    /// Its own words for why not, when it says.
    public var failure: String?
    /// It called at least one of Binders' tools.
    public var usedBoard = false
    /// In US dollars: OpenCode only.
    public var cost: Double?
    /// OpenCode's steps, or Copilot's turns.
    public var turns: Int?
    /// Copilot's premium requests: the sum of each request's model multiplier, so it can be 0.33 or 1.66.
    public var premiumRequests: Double?
    /// What it says it's doing, for the card's line.
    public var plan: String?
    /// Antigravity: the steps it says it refused (its denied_actions), as it says them.
    public var denied: [String] = []

    public init() {}
}

/// Fed one line at a time, so a log of any size is read in one pass with little memory. Lines that aren't a JSON object
/// (coloured stderr, a line cut short) are skipped; it never fails.
public struct CLIAgentOutputReader: Sendable {
    public let tool: CLIAgent
    private var reading = CLIAgentResult()
    /// OpenCode: the last step's reason, and whether an error line came.
    private var lastStop: String?
    private var errored = false
    private var stepsCapped = false
    /// Copilot: an organization's policy turned other MCP servers off.
    private var policyBlocked = false
    /// Antigravity: what each response step has said so far, by its index, and the latest of them.
    private var responses: [Int: String] = [:]
    private var latestResponse: Int?
    private var finalResponse = false

    public init(tool: CLIAgent) {
        self.tool = tool
    }

    public mutating func feed(_ line: Substring) {
        let line = line.drop { $0 == " " || $0 == "\t" }
        guard line.first == "{", let data = String(line).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch tool {
        case .codex: codex(object)
        case .opencode: opencode(object)
        case .copilot: copilot(object)
        case .antigravity: antigravity(object)
        }
    }

    /// What it says so far, with what only the end says worked out.
    public var result: CLIAgentResult {
        var result = reading
        if tool == .opencode {
            result.completed = lastStop == "stop" && !errored
            if result.failure == nil, stepsCapped { result.failure = "it used its 150 steps" }
        }
        // Codex prints an error line for one it retries past too (will_retry), and Copilot a session error for a model call
        // it goes on from: a turn that completed didn't fail. An organization's policy that kept the board away still did.
        if tool == .codex, result.completed { result.failure = nil }
        if tool == .copilot, result.completed { result.failure = policyBlocked ? Self.policyFailure : nil }
        return result
    }

    // MARK: Codex (`codex exec --json`)

    private mutating func codex(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "thread.started":
            if reading.session == nil, let thread = object["thread_id"] as? String { reading.session = thread }
        case "turn.completed":
            reading.completed = true
        case "turn.failed":
            if let message = (object["error"] as? [String: Any])?["message"] as? String { reading.failure = message }
        case "error":
            if reading.failure == nil, let message = object["message"] as? String { reading.failure = message }
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any] else { return }
            switch item["type"] as? String {
            case "agent_message":
                if object["type"] as? String == "item.completed", let text = item["text"] as? String, !text.isEmpty { reading.lastText = text }
            case "mcp_tool_call":
                if item["server"] as? String == "binders" { reading.usedBoard = true }
            case "todo_list":
                let items = (item["items"] as? [[String: Any]]) ?? []
                reading.plan = items.first { $0["completed"] as? Bool != true }?["text"] as? String
            default:
                break
            }
        default:
            break
        }
    }

    // MARK: OpenCode (`opencode run --format json`)

    private mutating func opencode(_ object: [String: Any]) {
        if let session = object["sessionID"] as? String, reading.session == nil { reading.session = session }
        let part = object["part"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "text":
            if let text = part["text"] as? String, !text.isEmpty {
                reading.lastText = text
                let lowered = text.lowercased()
                stepsCapped = lowered.contains("maximum steps") || lowered.contains("max steps") || lowered.contains("step limit")
            }
        case "step_finish":
            lastStop = part["reason"] as? String
            reading.turns = (reading.turns ?? 0) + 1
            if let cost = (part["cost"] as? NSNumber)?.doubleValue { reading.cost = (reading.cost ?? 0) + cost }
        case "tool_use":
            let tool = part["tool"] as? String ?? ""
            if OpenCodeLaunch.boardTools.contains(tool) { reading.usedBoard = true }
            let state = part["state"] as? [String: Any] ?? [:]
            if state["status"] as? String == "error", let error = state["error"] as? String, error.lowercased().contains("rejected permission") {
                reading.failure = "it stopped at a step a run can't approve: \(tool)"
            }
            if tool == "todowrite" {
                let todos = ((state["input"] as? [String: Any])?["todos"] as? [[String: Any]])
                    ?? ((state["metadata"] as? [String: Any])?["todos"] as? [[String: Any]]) ?? []
                reading.plan = todos.first { $0["status"] as? String == "in_progress" }?["content"] as? String
            }
        case "error":
            errored = true
            let error = object["error"] as? [String: Any] ?? [:]
            let message = ((error["data"] as? [String: Any])?["message"] as? String) ?? (error["name"] as? String)
            if let message, !message.isEmpty { reading.failure = message }
        default:
            break
        }
    }

    // MARK: Antigravity (`agy --output-format stream-json`)

    /// {"event":"init"|"step_update"|"result", "<event>":{…}}: the event's fields under its own name, or at the top as a
    /// fallback. Any other event is skipped.
    private mutating func antigravity(_ object: [String: Any]) {
        let event = (object["event"] ?? object["type"]) as? String ?? ""
        let body = object[event] as? [String: Any] ?? object
        if let id = (body["conversation_id"] ?? object["conversation_id"]) as? String, !id.isEmpty { reading.session = id }
        switch event {
        case "step_update":
            let index = (body["step_index"] as? NSNumber)?.intValue ?? -1
            switch body["step_type"] as? String {
            case "agent_response":
                if let delta = body["text_delta"] as? String, !delta.isEmpty, !finalResponse {
                    // A step that's done may carry its whole text again: it replaces the deltas when it does.
                    let sofar = responses[index] ?? ""
                    let done = body["state"] as? String == "DONE"
                    responses[index] = done && delta.hasPrefix(sofar) && !sofar.isEmpty ? delta : sofar + delta
                    latestResponse = index
                    let text = responses[index] ?? ""
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reading.lastText = text }
                }
            case "tool":
                let info = body["tool_info"] as? [String: Any] ?? [:]
                let name = ((body["tool_name"] ?? info["name"] ?? info["tool_name"]) as? String) ?? ""
                let server = (info["server"] ?? info["server_name"] ?? info["mcp_server"]) as? String
                if AntigravityOutput.isBoardTool(name: name, server: server) { reading.usedBoard = true }
                let arguments = (info["parameters"] ?? info["args"] ?? info["arguments"] ?? info["input"]) as? [String: Any] ?? [:]
                if body["state"] as? String != "DONE", let plan = AntigravityOutput.plan(tool: name, arguments: arguments) { reading.plan = plan }
            default:
                break
            }
        case "result":
            let status = body["status"] as? String ?? ""
            reading.completed = status.uppercased() == "SUCCESS"
            reading.failure = AntigravityOutput.failure(status: status, error: body["error"] as? String)
            if let response = body["response"] as? String, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reading.lastText = response
                finalResponse = true
            }
            for entry in body["denied_actions"] as? [Any] ?? [] {
                if let said = AntigravityDenials.read(entry), !reading.denied.contains(said) { reading.denied.append(said) }
            }
            reading.plan = nil
        default:
            break
        }
    }

    // MARK: GitHub Copilot CLI (`--output-format=json --stream=off`)

    private static let policyFailure = "your organization's Copilot policy turns off other MCP servers, so the run couldn't reach the board"

    private mutating func copilot(_ object: [String: Any]) {
        let data = object["data"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "result":
            if let session = object["sessionId"] as? String { reading.session = session }
            reading.completed = (object["exitCode"] as? NSNumber)?.intValue == 0
            if let premium = ((object["usage"] as? [String: Any])?["premiumRequests"] as? NSNumber)?.doubleValue, premium.isFinite {
                reading.premiumRequests = premium
            }
        case "assistant.message":
            if data["parentToolCallId"] == nil || data["parentToolCallId"] is NSNull,
               let content = data["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reading.lastText = content
            }
        case "assistant.turn_start":
            reading.turns = (reading.turns ?? 0) + 1
        case "tool.execution_start":
            if data["mcpServerName"] as? String == "binders" { reading.usedBoard = true }
            let arguments = data["arguments"] as? [String: Any] ?? [:]
            switch data["toolName"] as? String {
            case "report_intent":
                if let intent = arguments["intent"] as? String, !intent.isEmpty { reading.plan = intent }
            case "update_todo":
                if let todos = arguments["todos"] as? String,
                   let open = todos.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("- [ ]") }) {
                    reading.plan = String(open.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
            default:
                break
            }
        case "session.error":
            if let message = data["message"] as? String, !message.isEmpty { reading.failure = message }
        case "session.warning":
            if data["warningType"] as? String == "policy" {
                policyBlocked = true
                reading.failure = Self.policyFailure
            }
        default:
            break
        }
    }
}

public enum CLIAgentOutput {
    /// The reader over a whole text, a line at a time.
    public static func read(_ tool: CLIAgent, _ text: String) -> CLIAgentResult {
        var reader = CLIAgentOutputReader(tool: tool)
        for line in text.split(whereSeparator: \.isNewline) { reader.feed(line) }
        return reader.result
    }

    /// The most a line is read at: a longer one is skipped and counted.
    public static let lineLimit = 4 * 1024 * 1024

    /// Copilot's premium requests as Copilot says them: a whole number plain, anything else to at most two decimals
    /// ("0.33", "1.5"), in the same words in every locale.
    public static func premiumRequests(_ count: Double) -> String {
        var number: String
        if count.isFinite, abs(count) < 1e15, count == count.rounded() {
            number = String(Int(count))
        } else {
            number = String(format: "%.2f", count)
            while number.contains("."), number.hasSuffix("0") { number.removeLast() }
            if number.hasSuffix(".") { number.removeLast() }
        }
        if number == "-0" { number = "0" }
        return number == "1" ? "1 premium request" : "\(number) premium requests"
    }

    /// What a tool printed on stderr when it stopped, for the card: its last line that starts with "Error:", which a
    /// tool's hints can follow (Copilot's way of saying it isn't signed in ends with a list of ways to sign in), else its
    /// last line that isn't blank or JSON. Colour codes are taken out. Nil when there's none.
    public static func reason(inErrors text: String) -> String? {
        let plain = text.replacingOccurrences(of: #"\x1B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        let lines = plain.split(whereSeparator: \.isNewline).reversed().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("{") }
        return lines.first { $0.lowercased().hasPrefix("error:") } ?? lines.first
    }

    /// The card's line for a known failure to sign in, from the tool's own words, or nil.
    public static func signIn(_ tool: CLIAgent, said: String, model: String? = nil) -> String? {
        let text = said.lowercased()
        switch tool {
        case .codex:
            guard text.contains("401") || text.contains("403") || text.contains("not logged in") || text.contains("unauthorized")
                    || text.contains("please log in") || text.contains("login") && text.contains("required") else { return nil }
            return "Codex isn't signed in for Binders' runs. Sign in to Codex in Terminal (codex login), then Wake Now. If you keep your Codex sign-in in the Keychain, Binders' runs can't see it, as they don't load your Codex settings."
        case .copilot:
            guard text.contains("no authentication information found") else { return nil }
            return "GitHub Copilot CLI isn't signed in for Binders' runs. Sign in with copilot login in Terminal, then Wake Now."
        case .antigravity:
            guard ["authentication required", "authentication expired", "not authenticated", "not signed in", "please log back in",
                   "please log in", "sign in to continue", "locked-keyring", "keyring is locked", "/login"].contains(where: text.contains) else { return nil }
            return "Sign in to Antigravity: open Terminal and run agy once, then Wake Now. Binders' runs use the sign-in agy keeps on this Mac; Binders never sees it."
        case .opencode:
            guard text.contains("providerinit") || text.contains("provider") && (text.contains("not found") || text.contains("auth") || text.contains("api key"))
                    || text.contains("api key") || text.contains("unauthorized") else { return nil }
            return "OpenCode couldn't use \(model ?? "its model"): set up that provider with opencode auth login, then Wake Now. Binders doesn't pass your shell's API keys to a run, and runs don't load OpenCode plugins, so a provider that signs in through a plugin doesn't work there."
        }
    }
}
