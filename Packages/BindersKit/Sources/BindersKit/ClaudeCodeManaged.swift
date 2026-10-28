import Foundation

/// Claude Code under an organization's managed settings, which Binders' card runs live with. An organization can deploy,
/// in `folder` on a Mac:
/// - managed-mcp.json, its own MCP servers, which then have the say over every other: Claude Code refuses a run limited to
///   the servers it's given ("You cannot use --strict-mcp-config when an enterprise MCP config is present"), and leaves
///   out servers given on its command line (2.1.304 says "Ignored: …"; earlier versions refused them too);
/// - managed-settings.json, whose disableSideloadFlags leaves out servers given on the command line, and whose
///   allowedMcpServers and deniedMcpServers leave out the servers they don't allow, Binders' among them.
/// Binders' runs start without the limit there (`ClaudeCodeLaunch.make`'s `strictMCP`), and the card says when the
/// organization's settings kept Binders' tools out of a run.
public enum ClaudeCodeManaged {
    /// Where an organization's managed settings for Claude Code are on a Mac.
    public static let folder = "/Library/Application Support/ClaudeCode"
    public static let mcpFile = "managed-mcp.json"
    public static let settingsFile = "managed-settings.json"

    /// What a run's output says of the organization's settings.
    public enum Finding: Equatable, Sendable {
        /// It wouldn't start a run limited to Binders' tools.
        case refusedOnlyBinders
        /// It left Binders' server out of the run.
        case keptOut
    }

    /// The refusal of a run limited to the servers it's given.
    static let refusal = "You cannot use --strict-mcp-config when an enterprise MCP config is present"
    /// Lines that mean every server given on the command line was left out, or refused.
    static let allLeftOut = ["has exclusive control over MCP servers", "keeps exclusive control over MCP servers",
                             "You cannot dynamically configure MCP servers when an enterprise MCP config is present",
                             "forbids --mcp-config", "forbids server-delivered MCP server"]
    /// Lines that name servers the organization's policy blocked: Binders' when they name it.
    static let blockedByPolicy = ["Blocked by enterprise policy (allowedMcpServers/deniedMcpServers)", "blocked by the organization's managed policy",
                                  "not allowed by enterprise policy", "is blocked by enterprise policy"]

    /// What a run's output (its log: what it printed, and its stream-json events) says, if anything. The refusal comes
    /// first, as the run ends with it. Binders' server (`server`, as the run named it) was kept out when a line says every
    /// server given was, when a line of the organization's policy names it, or when the run's start lists the servers it
    /// has (stream-json's init event) without it, or with it blocked. Only what Claude Code printed counts, never what the
    /// run said in its messages.
    public static func finding(in output: String, server: String = "binders") -> Finding? {
        var keptOut = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("{") {
                guard line.contains("\"mcp_servers\""), let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      event["type"] as? String == "system", event["subtype"] as? String == "init",
                      let servers = event["mcp_servers"] as? [[String: Any]] else { continue }
                if let ours = servers.first(where: { $0["name"] as? String == server }) {
                    if blocked(ours) { keptOut = true }
                } else {
                    keptOut = true
                }
                continue
            }
            if line.contains(refusal) { return .refusedOnlyBinders }
            if allLeftOut.contains(where: line.contains) || (blockedByPolicy.contains(where: line.contains) && names(line, server)) { keptOut = true }
        }
        return keptOut ? .keptOut : nil
    }

    /// Whether a server's entry in the run's start says a policy blocked it, rather than that it failed or is starting.
    private static func blocked(_ entry: [String: Any]) -> Bool {
        entry.values.compactMap { $0 as? String }.contains { value in
            let value = value.lowercased()
            return value.contains("block") || value.contains("policy") || value.contains("denied") || value.contains("disabled")
        }
    }

    /// Whether a line names the server as a word of its own: "binders", and not "binders-card".
    static func names(_ line: String, _ server: String) -> Bool {
        line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }).contains { $0 == server[...] }
    }

    // MARK: What the card and Settings say

    /// The card's line when a run limited to Binders' tools was refused, and started again without that limit.
    public static let startedAgainLine = "Claude Code on this Mac is managed by your organization and wouldn't start a run limited to Binders' tools, so Binders started it again without that limit. The run still can't use your other connected tools."

    /// The card's line when the organization's settings kept Binders' tools out of the run.
    public static let keptOutLine = "Claude Code on this Mac has settings from your organization that keep Binders' board tools out of its runs, so this run couldn't read or update the card. Ask your admin to allow Binders' server, named binders; or turn on “Post to the Claude Code session open in this repository” for this agent in Settings → Agents; or use a command agent instead."

    /// The Manager's request when the organization's settings kept Binders' tools out of its run.
    public static let managerKeptOutLine = "Claude Code on this Mac has settings from your organization that keep Binders' tools out of its runs, so the Manager couldn't read or change anything. Ask your admin to allow Binders' server, named binders, or make a local model the Manager in Settings → Agents."

    /// Settings → Agents' line for a Claude Code agent on a Mac whose Claude Code an organization manages.
    public static let settingsLine = "Claude Code on this Mac is managed by your organization. Binders starts its runs without limiting them to Binders' tools, which managed settings refuse, and still keeps your other connected tools out of them. When the organization's settings keep Binders' tools out of a run too, the card says so and what to do."
}

/// What a card run not limited to Binders' tools (`ClaudeCodeManaged`) may use of the MCP tools in it: only Binders' board
/// tools. `Binders --agent-hook pre-tool`, the run's PreToolUse hook for every MCP tool, asks this and refuses the rest,
/// whether they're your own servers', your organization's, or Binders' other tools from a server of that name the run
/// didn't bring (yours from Settings → MCP, say). Claude Code's reviewer in auto mode, and allow rules in your own
/// settings, never get to them.
public enum ClaudeCodeToolGuard {
    /// The hook's name on Binders' command line.
    public static let hook = "pre-tool"
    /// The same for a run of the Manager, which may use the Manager's tools (`ManagerTools.offered`) and no other.
    public static let managerHook = "pre-tool-manager"

    /// The board's tools, as Binders' server offers them to a woken run (`MCPServer.boardTools`).
    public static let boardTools: Set<String> = ["list_tasks", "get_task", "create_task", "claim_task", "update_task", "ask_on_task",
                                                 "comment_task", "release_task", "complete_task", "request_approval",
                                                 // Distill: through the card alone, to the note it came from.
                                                 "propose_work_items", "get_note_history", "get_note_version"]

    /// Why the tool in a PreToolUse hook's JSON may not run, or nil when it's one of Binders' board tools. Anything it
    /// can't read is refused.
    public static func refusal(_ input: Data, server: String = "binders") -> String? {
        let tool = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any])?["tool_name"] as? String ?? ""
        let prefix = "mcp__\(server)__"
        if tool.hasPrefix(prefix), boardTools.contains(String(tool.dropFirst(prefix.count))) { return nil }
        return "A Binders card run may use only Binders' board tools for its card\(tool.isEmpty ? "" : ", not \(tool)"). Carry on with those and your built-in tools."
    }

    /// The same for a run of the Manager: only the Manager's tools from Binders' server.
    public static func managerRefusal(_ input: Data, server: String = ManagerLaunch.server) -> String? {
        let tool = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any])?["tool_name"] as? String ?? ""
        let prefix = "mcp__\(server)__"
        if tool.hasPrefix(prefix), ManagerTools.offered.contains(String(tool.dropFirst(prefix.count))) { return nil }
        return "The Manager may use only Binders' Manager tools\(tool.isEmpty ? "" : ", not \(tool)"). Carry on with those."
    }
}
