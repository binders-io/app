import Foundation
import BindersKit

/// Opening pull requests for agents' work (lane PR1, `PullRequests`): Binders pushes the branch and opens the pull request
/// with your own git and GitHub's gh, never the run, and only for an agent you let. The card gets its link.
enum PullRequestOpener {
    struct Opened: Sendable {
        let url: String?
        let branch: String
        /// What the card says.
        let line: String
    }

    struct Failure: Error, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Self-tests only: the PATH git and gh are found on, with a stand-in gh, in place of your login shell's.
    nonisolated(unsafe) static var testPath: String?

    /// The longest a run waits for its pull request before it's told the link will be on the card.
    static let wait: Duration = .seconds(25)

    // MARK: A run asks

    /// open_pull_request from a run: the agent holds the card and may open pull requests, and the repository is in the
    /// folder it works in. Answered with the link when it's open in time; otherwise the card gets it when it is.
    @MainActor
    static func fromRun(field: (String) -> String, controller: DictationController) async -> InboxResult {
        let board = controller.board
        let name = field("actor")
        guard BoardActor.Kind(rawValue: field("actor_kind")) == .agent, let agent = AgentRegistry.shared.agent(named: name) else {
            return .failure("Only an agent set up in Binders can have it open a pull request.")
        }
        guard let id = UUID(uuidString: field("id")), let card = board.card(id) else { return .failure("No card with that id. list_tasks shows them.") }
        guard AgentRegistry.isAgent(agent, named: card.assignee ?? "") else { return .failure("Claim the card first: Binders opens pull requests for the card you hold.") }
        guard let base = folder(of: agent, card: card.id) else {
            return .failure("The user hasn't let \(agent.name) open pull requests. They can turn it on in Settings → Agents.")
        }
        let asked = field("repository").trimmingCharacters(in: .whitespaces)
        // ".." and links resolved before the check, whether or not the folder is there.
        let joined = asked.isEmpty || asked == "." ? base : asked.hasPrefix("/") ? asked : (base as NSString).appendingPathComponent(asked)
        let place = AgentPlaces.real(URL(fileURLWithPath: joined).standardizedFileURL.path)
        guard AgentWorktree.isInside(place, AgentPlaces.real(base)) else {
            return .failure("\(asked) isn't in the folder you work in, \(AgentWorktrees.display(base)).")
        }
        let title = PullRequests.title(field("title"), card: card.title)
        let body = PullRequests.body(field("body"), agent: agent.name, card: card.title)
        let draft = field("draft") == "true"
        let work = Task { () -> Result<Opened, Failure> in
            let result = await open(folder: place, title: title, body: body, draft: draft)
            record(result, on: id, board: board)
            return result
        }
        let answered = await withTaskGroup(of: Result<Opened, Failure>?.self) { group in
            group.addTask { await work.value }
            group.addTask { try? await Task.sleep(for: wait); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch answered {
        case .success(let opened): return InboxResult(ok: true, id: card.id.uuidString, message: opened.line)
        case .failure(let failure): return .failure(failure.message)
        case nil: return InboxResult(ok: true, id: card.id.uuidString, message: "Binders is still pushing and opening the pull request. Its link goes on the card when it's open.")
        }
    }

    /// The folder an agent's runs work in for a card, when it may have Binders open pull requests there: Claude Code's
    /// worktree for the card or the folder itself, and Codex's folder itself. Nil otherwise: the other tools' pull requests
    /// Binders opens itself when their run ends (`afterCommit`).
    @MainActor
    static func folder(of agent: AgentProfile, card: UUID) -> String? {
        switch agent.wake {
        case .claudeCode(let wake) where wake.opensPullRequests:
            let repository = (wake.repository as NSString).expandingTildeInPath
            return wake.worksInFolder ? repository : ClaudeCodeLaunch.worktree(repository: repository, card: card)
        case .cliAgent(let wake) where wake.pullRequestWay == .tool:
            return (wake.repository as NSString).expandingTildeInPath
        default:
            return nil
        }
    }

    /// After Binders committed a CLI run's work on the card's branch in its worktree: its pull request, when you let the
    /// agent have them. The card says how it went.
    @MainActor
    static func afterCommit(worktree: String, branch: String, agent: String, card id: UUID, said: String?, board: BoardService) {
        guard let card = board.card(id) else { return }
        let title = PullRequests.title("", card: card.title)
        let body = PullRequests.body(said ?? "", agent: agent, card: card.title)
        Task {
            let result = await open(folder: worktree, branch: branch, title: title, body: body, draft: false)
            record(result, on: id, board: board)
        }
    }

    /// The card's line and link for how it went.
    @MainActor
    private static func record(_ result: Result<Opened, Failure>, on id: UUID, board: BoardService) {
        guard let card = board.card(id) else { return }
        switch result {
        case .success(let opened):
            board.report(card, progress: opened.line, links: opened.url.map { [$0] } ?? [], by: BoardService.binders, renewing: false)
        case .failure(let failure):
            board.note(card, text: "Binders didn't open a pull request: " + failure.message)
        }
    }

    // MARK: Opening

    /// Pushes the branch (the one the repository at `folder` is on, or `branch`) to origin and opens its pull request with
    /// gh, from your own login shell's PATH and sign-ins. Refuses a detached HEAD, the default branch or a main one, no
    /// origin, and a branch with nothing committed beyond the default.
    nonisolated static func open(folder: String, branch asked: String? = nil, title: String, body: String, draft: Bool) async -> Result<Opened, Failure> {
        let path: String
        if let testPath { path = testPath } else { path = await CLIProgram.loginPath() ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" }
        func git(_ arguments: [String], in place: String) async -> Ran { await run(["git", "-C", place] + arguments, in: place, path: path, timeout: 30) }
        let top = await git(["rev-parse", "--show-toplevel"], in: folder)
        guard top.ok, let root = top.firstLine else { return .failure(Failure("\(AgentWorktrees.display(folder)) isn't in a git repository.")) }
        var branch = asked ?? ""
        if branch.isEmpty { branch = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: root).firstLine ?? "" }
        let head = await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root).firstLine
        let defaultBranch = head.map { $0.hasPrefix("origin/") ? String($0.dropFirst("origin/".count)) : $0 }
        if let refusal = PullRequests.refusal(branch: branch, defaultBranch: defaultBranch) { return .failure(Failure(refusal)) }
        guard await git(["remote", "get-url", "origin"], in: root).ok else {
            return .failure(Failure("\(AgentWorktrees.display(root)) has no origin to push \(branch) to."))
        }
        if let defaultBranch, await git(["rev-list", "--count", "origin/\(defaultBranch)..refs/heads/\(branch)"], in: root).firstLine == "0" {
            return .failure(Failure("\(branch) has nothing committed beyond \(defaultBranch), so there's nothing to open a pull request for."))
        }
        let pushed = await run(["git", "-C", root] + PullRequests.push(branch: branch), in: root, path: path, timeout: 180)
        guard pushed.ok else { return .failure(Failure("git couldn't push \(branch): \(pushed.lastErrorLine ?? "exit \(pushed.status)").")) }
        let made = await run(["gh"] + PullRequests.create(branch: branch, title: title, body: body, draft: draft), in: root, path: path, timeout: 120)
        let said = made.output + "\n" + made.errors
        if made.ok, let url = PullRequests.url(in: said) {
            return .success(Opened(url: url, branch: branch, line: "Opened a pull request for \(branch): \(url)"))
        }
        if let url = PullRequests.url(in: said), said.localizedCaseInsensitiveContains("already exists") {
            return .success(Opened(url: url, branch: branch, line: "Pushed \(branch); its pull request was open already: \(url)"))
        }
        if made.status == 127 || said.contains("command not found") {
            return .success(Opened(url: nil, branch: branch, line: "Pushed \(branch) to origin. Binders couldn't open the pull request: GitHub's gh isn't installed. Install it (brew install gh) and sign in with gh auth login."))
        }
        return .failure(Failure("pushed \(branch), but gh couldn't open the pull request: \(made.lastErrorLine ?? "exit \(made.status)")."))
    }

    struct Ran: Sendable {
        let status: Int32
        let output: String
        let errors: String
        var ok: Bool { status == 0 }
        var firstLine: String? { output.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } }
        var lastErrorLine: String? {
            errors.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
                .map { AgentRunReport.trimmed($0, limit: 240) }
        }
    }

    /// A program in the folder, through zsh only to change into it: the folder and every argument go in as arguments.
    /// Your own environment, so git and gh find your sign-ins; nothing ever asks a question on a terminal.
    nonisolated private static func run(_ command: [String], in folder: String, path: String, timeout: TimeInterval) async -> Ran {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GIT_DIR"] = nil
        environment["GIT_WORK_TREE"] = nil
        do {
            let result = try await AutomationService.runProcess("/bin/zsh", ["-fc", #"cd -- "$1" && shift && exec "$@""#, "binders", folder] + command,
                                                                stdin: nil, environment: environment, timeout: timeout)
            return Ran(status: result.status, output: result.stdout, errors: result.stderr)
        } catch {
            return Ran(status: -1, output: "", errors: error.localizedDescription)
        }
    }
}
