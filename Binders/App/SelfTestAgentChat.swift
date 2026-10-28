import AppKit
import Darwin
import Foundation
import BindersKit

extension SelfTest {
    /// Chats with your agents (lane AC1), with a stand-in for claude that keeps its arguments, folder and prompt and answers
    /// in stream-json: the first message starts a session in a worktree of its own for the chat, with the agent's
    /// permission mode and Binders' board tools alone; what it writes shows while it works; the next message carries the
    /// session on there; a session Claude Code lost starts again, once, with the chat so far; Stop ends a run. An agent that
    /// checks the board itself reads your messages and answers with list_messages and reply_message, only in its own chats;
    /// a script can't chat. In a throwaway folder (BINDERS_DATA_DIR) only; no real agent runs.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-agent-chat -notesShowMarkdown NO
    @MainActor
    static func agentChatSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes agents and chats")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let folder = AppPaths.support
        let files = FileManager.default
        let controller = DictationController()
        let registry = AgentRegistry.shared
        let chats = controller.chats
        let write = MCPServer.writeInApp(controller: controller)
        func until(seconds: Double = 10, _ done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        }
        func read(_ name: String) -> String { (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        AppDefaults.store.removeObject(forKey: AgentDispatcher.refusedOnlyBindersKey)

        // A stand-in for claude: keeps what it was given, makes the worktree it's asked for, says something, waits a moment
        // (so what it wrote shows), and answers; "No conversation found" for a session that's gone, when asked to.
        let bin = folder.appendingPathComponent("bin")
        try? files.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try? """
            #!/bin/sh
            here="$(cd "$(dirname "$0")/.." && pwd)"
            n=$(cat "$here/chat-count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$here/chat-count"
            cat > "$here/chat-prompt-$n.txt"
            printf '%s\\n' "$@" > "$here/chat-args-$n.txt"
            pwd > "$here/chat-pwd-$n.txt"
            printf '%s' "$BINDERS_CHAT" > "$here/chat-env-$n.txt"
            prev=""
            for a in "$@"; do
              if [ "$prev" = "--worktree" ]; then mkdir -p ".claude/worktrees/$a"; fi
              if [ "$prev" = "--resume" ] && [ -f "$here/chat-lose" ]; then rm -f "$here/chat-lose"; echo "Error: No conversation found with session ID: $a" >&2; exit 1; fi
              prev="$a"
            done
            printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at it, part %s"}]}}\\n' "$n"
            w=0; while [ ! -f "$here/chat-go" ] && [ $w -lt 40 ]; do sleep 0.1; w=$((w+1)); done
            rm -f "$here/chat-go"
            printf '{"type":"result","result":"**Done** with part %s.\\\\n\\\\n- one\\\\n- two"}\\n' "$n"
            """.write(to: fake, atomically: true, encoding: .utf8)
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func letItAnswer() { files.createFile(atPath: folder.appendingPathComponent("chat-go").path, contents: Data()) }

        let repository = folder.appendingPathComponent("repo")
        try? files.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let claude = AgentProfile(name: "Claude Code · app", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, permissionMode: "auto", executable: fake.path)),
                                  preset: "claude-code")
        let pennant = AgentProfile(name: "Pennant", wake: .board)
        let script = AgentProfile(name: "Deploy script", wake: .command(command: "true"))
        registry.upsert(claude)
        registry.upsert(pennant)
        registry.upsert(script)

        // A script can't chat.
        if case .failure(let failure) = chats.send("Deploy please", to: script.name, via: "mac") {
            check(failure.why.contains("can't chat"), "a script can't chat: it keeps cards")
        } else {
            check(false, "a script can't chat: it keeps cards")
        }

        // The first message: a session in a worktree of its own, with the agent's mode and Binders' board tools alone.
        guard case .success(let first) = chats.send("Why does the board clip at 1100 pt?", to: claude.name, via: "mac") else {
            check(false, "a message to Claude Code starts a chat")
            return 1
        }
        check(first.title == "Why does the board clip at 1100 pt?" && first.agent == claude.name, "a message to Claude Code starts a chat, named by its first words")
        await until { read("chat-count").trimmingCharacters(in: .whitespacesAndNewlines) == "1" && chats.live[first.id] != nil }
        check(chats.chat(first.id)?.status == .running, "it's answering")
        check(chats.live[first.id] == "Looking at it, part 1", "what it has written so far shows while it works (\(chats.live[first.id] ?? "nothing"))")
        let args1 = read("chat-args-1.txt").split(separator: "\n").map(String.init)
        let session = chats.chat(first.id)?.session?.uuidString.lowercased() ?? "?"
        check(args1.contains("--session-id") && args1.contains(session) && args1.contains(AgentChatLaunch.worktreeName(for: first.id))
              && args1.contains("auto") && args1.contains("--strict-mcp-config") && !args1.contains("--resume"),
              "a new session, in the chat's own worktree, in the agent's mode, with Binders' tools alone")
        check(read("chat-prompt-1.txt").hasPrefix(AgentChatPrompt.marker) && read("chat-prompt-1.txt").contains("clip at 1100 pt")
              && AgentPrompts.worthKeeping(read("chat-prompt-1.txt")) == nil, "its prompt says what the chat is, then your words; writing capture leaves it out")
        check(read("chat-env-1.txt") == first.id.uuidString && args1.contains { $0.contains("BINDERS_CHAT") && !$0.contains("BINDERS_RUN") },
              "its server knows it's a chat, with the board's tools as the agent")
        // Written while it works: it goes after.
        _ = chats.send("And at 900?", to: claude.name, chat: first.id, via: "iphone")
        check(read("chat-count").trimmingCharacters(in: .whitespacesAndNewlines) == "1", "a message while it answers waits")
        letItAnswer()
        await until { chats.chat(first.id)?.messages.contains { $0.from == .agent } == true }
        let answered = chats.chat(first.id)
        check(answered?.messages.first { $0.from == .agent }?.text.hasPrefix("**Done** with part 1.") == true, "its last word is its reply, in Markdown")
        let worktree = AgentChatLaunch.worktree(repository: repository.path, chat: first.id)
        check(answered?.directory == worktree, "the chat keeps the worktree its session is in")

        // The next message carries the session on, there.
        await until { read("chat-count").trimmingCharacters(in: .whitespacesAndNewlines) == "2" }
        let args2 = read("chat-args-2.txt").split(separator: "\n").map(String.init)
        check(args2.contains("--resume") && args2.contains(session) && !args2.contains("--worktree"), "the next message carries the session on")
        check(read("chat-pwd-2.txt").trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(AgentChatLaunch.worktreeName(for: first.id))
              && read("chat-prompt-2.txt") == "And at 900?", "in the chat's worktree, with your words alone")
        letItAnswer()
        await until { chats.chat(first.id)?.status == .idle }
        check(chats.chat(first.id)?.messages.filter { $0.from == .agent }.count == 2, "and answers that too")

        // A session Claude Code lost starts again, once, with the chat so far.
        files.createFile(atPath: folder.appendingPathComponent("chat-lose").path, contents: Data())
        _ = chats.send("Fold Done, then.", to: claude.name, chat: first.id, via: "mac")
        await until { read("chat-count").trimmingCharacters(in: .whitespacesAndNewlines) == "4" }
        let args4 = read("chat-args-4.txt").split(separator: "\n").map(String.init)
        check(args4.contains("--session-id") && !args4.contains("--resume") && !args4.contains("--worktree")
              && read("chat-pwd-4.txt").trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(AgentChatLaunch.worktreeName(for: first.id)),
              "a lost session starts again as a new one, in the same worktree")
        check(read("chat-prompt-4.txt").contains("Earlier in this chat") && read("chat-prompt-4.txt").contains("Fold Done, then."), "with the chat so far")
        letItAnswer()
        await until { chats.chat(first.id)?.status == .idle }
        check(chats.chat(first.id)?.messages.last?.from == .agent && chats.chat(first.id)?.why == nil, "and answers")

        // Stop.
        _ = chats.send("One more thing", to: claude.name, chat: first.id, via: "mac")
        await until { chats.chat(first.id)?.status == .running }
        chats.stop(first.id)
        await until { chats.chat(first.id)?.status == .idle }
        check(chats.chat(first.id)?.why == "You stopped it.", "Stop ends a run")

        // Its worktree gone: a new session, with the chat so far, where a new one is made.
        let before = Int(read("chat-count").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        try? files.removeItem(atPath: worktree)
        _ = chats.send("Still there?", to: claude.name, chat: first.id, via: "mac")
        await until { (Int(read("chat-count").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == before + 1 }
        let argsGone = read("chat-args-\(before + 1).txt").split(separator: "\n").map(String.init)
        check(argsGone.contains("--session-id") && argsGone.contains("--worktree") && !argsGone.contains("--resume")
              && read("chat-prompt-\(before + 1).txt").contains("Earlier in this chat"), "a chat whose worktree is gone starts a new session, with the chat so far")
        letItAnswer()
        await until { chats.chat(first.id)?.status == .idle }
        check(chats.chat(first.id)?.messages.last?.from == .agent, "and answers")

        // An agent that checks the board itself: your message waits for it, it reads it and answers with its tools.
        guard case .success(let talk) = chats.send("Can you draft the launch post?", to: pennant.name, via: "iphone") else {
            check(false, "a message to an agent that checks the board itself")
            return 1
        }
        check(chats.chat(talk.id)?.status == .waiting, "a message to one that checks the board itself waits for it")
        let run = ["BINDERS_TOOLS": "board", "BINDERS_AGENT": pennant.name]
        for (key, value) in run { setenv(key, value, 1) }
        let offered = Set(MCPServer.offered.map(\.name))
        check(offered.isSuperset(of: AgentChatTools.all), "its own server for Binders offers list_messages and reply_message")
        func call(_ tool: String, _ arguments: [String: Any], as name: String = pennant.name) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: BoardActor(name: name, kind: .agent))) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        let listed = await call(AgentChatTools.list, [:])
        check(listed.ok && listed.text.contains("draft the launch post") && listed.text.contains(talk.id.uuidString), "list_messages gives it your message (\(listed.text.prefix(120)))")
        check(chats.chat(talk.id)?.unsent.isEmpty == true, "and marks it read")
        check(await call(AgentChatTools.list, [:]).text.contains("draft") == false, "read once")
        let other = await call(AgentChatTools.reply, ["chat": first.id.uuidString, "text": "Hi"])
        check(!other.ok, "it can't answer another agent's chat")
        let replied = await call(AgentChatTools.reply, ["chat": talk.id.uuidString, "text": "Here's a draft:\n\n> Binders 0.12.1 is out."])
        check(replied.ok && chats.chat(talk.id)?.messages.last?.from == .agent && chats.chat(talk.id)?.status == .idle, "reply_message answers in the chat")
        // A reply to what it read leaves what it hasn't read waiting for it.
        _ = chats.send("And a short one for X?", to: pennant.name, chat: talk.id, via: "mac")
        _ = await call(AgentChatTools.list, [:])
        _ = chats.send("Also one for Bluesky.", to: pennant.name, chat: talk.id, via: "mac")
        _ = await call(AgentChatTools.reply, ["chat": talk.id.uuidString, "text": "Short one: Binders 0.12.1."])
        check(chats.chat(talk.id)?.status == .waiting && chats.chat(talk.id)?.unsent.map(\.text) == ["Also one for Bluesky."],
              "a reply leaves what it hasn't read waiting for it")
        // An agent whose name only starts the same, and a Claude Code chat, are out of its reach.
        let reviewer = AgentProfile(name: "Pennant Reviewer", wake: .board)
        registry.upsert(reviewer)
        setenv("BINDERS_AGENT", reviewer.name, 1)
        check(!(await call(AgentChatTools.list, [:], as: reviewer.name)).text.contains("Bluesky"), "an agent named like it doesn't see its chats")
        check(!(await call(AgentChatTools.reply, ["chat": talk.id.uuidString, "text": "x"], as: reviewer.name)).ok, "nor answers them")
        setenv("BINDERS_AGENT", pennant.name, 1)
        _ = await call(AgentChatTools.list, [:])
        setenv("BINDERS_CHAT", first.id.uuidString, 1)
        check(!Set(MCPServer.offered.map(\.name)).contains(AgentChatTools.list), "a Claude Code chat run's server has no chat tools")
        unsetenv("BINDERS_CHAT")
        for key in run.keys { unsetenv(key) }

        // What the iPhone reads, and what's kept.
        let object = chats.chat(first.id)?.jsonObject(messages: true) ?? [:]
        check((object["messages"] as? [[String: Any]])?.count == chats.chat(first.id)?.messages.count && object["agent"] as? String == claude.name,
              "the phone hears a chat and its messages")
        check(AgentChatService.read().chats.count == 2, "the file keeps both chats")
        AppDefaults.store.removeObject(forKey: AgentDispatcher.refusedOnlyBindersKey)

        print(failures == 0 ? "AGENT_CHAT_OK" : "AGENT_CHAT_FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }
}
