import Foundation
import BindersKit

extension SelfTest {
    /// Pull requests for agents' work (lane PR1): Binders pushes the branch to origin and opens the pull request with gh,
    /// for an agent you let, never the default branch. A local bare repository is origin and a stand-in is gh, so nothing
    /// reaches GitHub.
    @MainActor
    static func pullRequestsSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test makes git repositories")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let files = FileManager.default
        let data = AppPaths.support
        @discardableResult
        func git(_ arguments: [String], in folder: URL) async -> AgentGit.Result {
            await AgentGit.run(["-C", folder.path] + arguments, path: "", temporary: nil, timeout: 60)
        }
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        // A stand-in gh: keeps its arguments and folder, and answers as gh does, or as one with a pull request open already.
        let bin = data.appendingPathComponent("bin", isDirectory: true)
        try? files.createDirectory(at: bin, withIntermediateDirectories: true)
        let ghArgs = data.appendingPathComponent("gh-args.txt"), ghExists = data.appendingPathComponent("gh-exists")
        try? """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(ghArgs.path)"
            pwd >> "\(ghArgs.path)"
            if [ -f "\(ghExists.path)" ]; then
              echo 'a pull request for branch "x" into branch "main" already exists:' >&2
              echo 'https://github.com/example/app/pull/6' >&2
              exit 1
            fi
            echo 'https://github.com/example/app/pull/7'
            """.write(to: bin.appendingPathComponent("gh"), atomically: true, encoding: .utf8)
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("gh").path)
        PullRequestOpener.testPath = bin.path + ":/usr/bin:/bin"
        defer { PullRequestOpener.testPath = nil }

        // origin, and a workspace holding a clone of it, as a folder of several repositories would.
        let origin = data.appendingPathComponent("origin.git", isDirectory: true)
        let workspace = data.appendingPathComponent("workspace", isDirectory: true)
        let service = workspace.appendingPathComponent("service-a", isDirectory: true)
        try? files.createDirectory(at: service, withIntermediateDirectories: true)
        try? files.createDirectory(at: origin, withIntermediateDirectories: true)
        await git(["init", "-q", "--bare", "-b", "main"], in: origin)
        await git(["init", "-q", "-b", "main"], in: service)
        await git(["config", "user.name", "Sam"], in: service)
        await git(["config", "user.email", "sam@example.invalid"], in: service)
        try? "# Service A\n".write(to: service.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        await git(["add", "-A"], in: service)
        await git(["commit", "-q", "-m", "First"], in: service)
        await git(["remote", "add", "origin", origin.path], in: service)
        await git(["push", "-q", "-u", "origin", "main"], in: service)
        await git(["remote", "set-head", "origin", "main"], in: service)

        // 1. On the default branch, and with nothing committed beyond it: refused, nothing pushed.
        let onMain = await PullRequestOpener.open(folder: service.path, title: "T", body: "B", draft: false)
        check((try? onMain.get()) == nil && { if case .failure(let f) = onMain { f.message.contains("never pushes main") } else { false } }(), "the default branch is never pushed")
        await git(["checkout", "-q", "-b", "binders/fix-login"], in: service)
        let empty = await PullRequestOpener.open(folder: service.path, title: "T", body: "B", draft: false)
        check({ if case .failure(let f) = empty { f.message.contains("nothing committed beyond main") } else { false } }(),
              "a branch with nothing new isn't pushed: \({ if case .failure(let f) = empty { f.message } else { "opened" } }())")

        // 2. Committed on a branch of its own: pushed to origin, and the pull request opened in the repository.
        try? "Fixed.\n".write(to: service.appendingPathComponent("login.txt"), atomically: true, encoding: .utf8)
        await git(["add", "-A"], in: service)
        await git(["commit", "-q", "-m", "Fix login"], in: service)
        let opened = await PullRequestOpener.open(folder: service.path, title: "Fix login", body: "It works now.", draft: true)
        let url = (try? opened.get())?.url
        check(url == "https://github.com/example/app/pull/7", "the pull request is opened, and its link read: \(url ?? { if case .failure(let f) = opened { f.message } else { "none" } }())")
        check(await git(["rev-parse", "--verify", "-q", "refs/heads/binders/fix-login"], in: origin).ok, "the branch is on origin")
        let asked = read(ghArgs).split(separator: "\n").map(String.init)
        check(asked.starts(with: ["pr", "create", "--head", "binders/fix-login", "--title", "Fix login", "--body", "It works now.", "--draft"])
              && AgentPlaces.real(asked.last ?? "") == AgentPlaces.real(service.path), "gh is asked for exactly that, in the repository: \(asked)")
        files.createFile(atPath: ghExists.path, contents: Data())
        let again = await PullRequestOpener.open(folder: service.path, title: "Fix login", body: "", draft: false)
        check((try? again.get())?.url == "https://github.com/example/app/pull/6", "one open already: its link")
        try? files.removeItem(at: ghExists)

        // 3. From a run: only an agent you let, holding the card, in a repository in the folder it works in.
        let controller = DictationController()
        let board = controller.board
        let registry = AgentRegistry.shared
        Store.shared.insert(BinderRecord(name: "Code", colorIndex: 4))
        let binder = Store.shared.binders(includeArchived: true).first { $0.name == "Code" }?.id
        var agent = AgentProfile(name: "Claude Code · workspace", wake: .claudeCode(ClaudeCodeWake(repository: workspace.path, permissionMode: "auto", inFolder: true)),
                                 preset: "claude-code")
        check(registry.upsert(agent) == nil, "an agent in the workspace is saved")
        let actor = BoardActor(name: agent.name, kind: .agent)
        let card = board.create(title: "Fix the login", binderID: binder, by: .you)
        try? board.claim(card, by: actor)
        func ask(_ fields: [String: String]) async -> InboxResult {
            let all = fields.merging(["id": card.id.uuidString, "actor": actor.name, "actor_kind": "agent"]) { a, _ in a }
            return await PullRequestOpener.fromRun(field: { all[$0] ?? "" }, controller: controller)
        }
        let notLet = await ask(["repository": "service-a", "title": "Fix login"])
        check(!notLet.ok && notLet.error?.contains("hasn't let") == true, "an agent you didn't let can't have one opened: \(notLet.error ?? "")")
        if case .claudeCode(var wake) = agent.wake { wake.pullRequests = true; agent.wake = .claudeCode(wake) }
        check(registry.upsert(agent) == nil, "let it")
        let outside = await ask(["repository": "../origin.git", "title": "Fix login"])
        check(!outside.ok && outside.error?.contains("isn't in the folder you work in") == true, "nothing outside the folder it works in: \(outside.error ?? "")")
        try? "More.\n".write(to: service.appendingPathComponent("more.txt"), atomically: true, encoding: .utf8)
        await git(["add", "-A"], in: service)
        await git(["commit", "-q", "-m", "More"], in: service)
        let gone = await ask(["repository": "../nowhere/../../elsewhere", "title": "Fix login"])
        check(!gone.ok && gone.error?.contains("isn't in the folder you work in") == true, "nor through .. to a folder that isn't there: \(gone.error ?? "")")
        let fromRun = await ask(["repository": "service-a", "title": "Fix login", "body": "Done."])
        check(fromRun.ok && fromRun.message.contains("pull/7"), "from the run: opened, with its link: \(fromRun.message)\(fromRun.error ?? "")")
        check(board.card(card.id)?.links.contains("https://github.com/example/app/pull/7") == true, "and the card has the link")
        check(read(ghArgs).contains("Opened by Claude Code · workspace for the Binders card “Fix the login”."), "its body says who opened it for which card")
        let other = board.create(title: "Someone else's", binderID: binder, by: .you)
        let unheld = await PullRequestOpener.fromRun(field: { ["id": other.id.uuidString, "actor": actor.name, "actor_kind": "agent", "title": "x"][$0] ?? "" },
                                                     controller: controller)
        check(!unheld.ok && unheld.error?.contains("Claim the card first") == true, "only for the card it holds: \(unheld.error ?? "")")

        // 4. What a run is told and given.
        if case .claudeCode(let wake) = agent.wake {
            let launch = ClaudeCodeLaunch.make(card: card.id, reason: .ready, boardName: agent.name, wake: wake, binders: "/Applications/Binders.app/Contents/MacOS/Binders",
                                               dataFolder: data.path, home: NSHomeDirectory(), worktreeExists: false, session: UUID())
            check(launch.prompt.contains(PullRequests.tool) && !launch.prompt.contains("and never push.") && launch.arguments.joined(separator: " ").contains("\"BINDERS_PR\":\"1\""),
                  "its run is told to ask for it, and its server offers the tool")
        }
        registry.remove(agent.id)
        print(failures == 0 ? "PULL_REQUESTS_OK" : "PULL_REQUESTS_FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }
}
