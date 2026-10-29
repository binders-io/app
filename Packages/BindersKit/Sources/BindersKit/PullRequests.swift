import Foundation

/// Pull requests from an agent's work (lane PR1), when you turn it on for the agent. Binders opens them, never the run:
/// the run still can't push, and Binders pushes its branch and opens the pull request with your own git and GitHub (gh)
/// sign-ins. Never the repository's default branch, and never a force push.
public enum PullRequests {
    /// The board tool a run calls when its work is committed on a branch of its own: Binders pushes it and opens the
    /// pull request. Offered only to a run whose agent may open them (BINDERS_PR on its server).
    public static let tool = "open_pull_request"
    /// The server's switch for the tool.
    public static let environmentKey = "BINDERS_PR"

    /// How a run's pull request is opened, as its prompt says.
    public enum Way: Sendable, Equatable {
        /// It commits on a branch of its own, and calls `tool` for each repository it changed (Claude Code, and Codex in
        /// the folder itself, which run git).
        case tool
        /// Binders commits what it changed on the card's branch when it stops, then pushes that and opens the pull request
        /// (the other command-line tools, in a worktree).
        case binders
    }

    /// Branches Binders never pushes, whatever the repository's default is.
    public static let neverPushed: Set<String> = ["main", "master", "trunk", "develop", "development", "production", "release", "HEAD"]

    /// Why Binders won't push a branch, or nil: none, detached, the default or one of `neverPushed`, or a name that isn't
    /// a plain branch name.
    public static func refusal(branch: String, defaultBranch: String?) -> String? {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "HEAD" { return "Its work isn't on a branch (git is on a detached HEAD). Commit it on a branch of your own first." }
        if name == defaultBranch || neverPushed.contains(name) {
            return "Binders never pushes \(name), the repository's \(name == defaultBranch ? "default" : "main") branch. Commit on a branch of your own, then ask again."
        }
        guard !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("@{"),
              name.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F && !" ~^:?*[\\".unicodeScalars.contains($0) }) else {
            return "“\(name)” isn't a branch name Binders pushes."
        }
        return nil
    }

    /// git's arguments to push a branch to origin and track it there: that branch alone, never forced.
    public static func push(branch: String) -> [String] {
        ["push", "--set-upstream", "origin", "refs/heads/\(branch):refs/heads/\(branch)"]
    }

    /// gh's arguments to open the pull request for a pushed branch.
    public static func create(branch: String, title: String, body: String, draft: Bool) -> [String] {
        ["pr", "create", "--head", branch, "--title", title, "--body", body] + (draft ? ["--draft"] : [])
    }

    /// The pull request's address in what gh printed (as it opened it, or as it said one is open already), or nil.
    public static func url(in output: String) -> String? {
        guard let match = output.range(of: #"https://[^\s"'<>]+/pull/\d+"#, options: .regularExpression) else { return nil }
        return String(output[match])
    }

    /// The title, kept to one line of a sensible length.
    public static func title(_ asked: String, card: String) -> String {
        let line = asked.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return String((line.isEmpty ? card : line).prefix(200))
    }

    /// The body: what the run wrote, then who opened it and for which card.
    public static func body(_ asked: String, agent: String, card: String) -> String {
        let text = asked.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(20_000)) + (text.isEmpty ? "" : "\n\n") + "Opened by \(agent) for the Binders card “\(card)”."
    }

    /// The prompt's line on committing, when the agent may open pull requests, in place of "never push".
    public static func promptLine(_ way: Way, inFolder: Bool) -> String {
        switch (way, inFolder) {
        case (.tool, false):
            return "4. Commit on its branch, and never push yourself. When the work is done and committed, call \(tool): Binders pushes the branch and opens the pull request."
        case (.tool, true):
            return "4. This is the user's own folder, not a worktree: in each repository you change, make a new branch of your own and commit there. Never commit on the default branch, and never push yourself. When the work is done, call \(tool) for each of those repositories: Binders pushes the branch and opens the pull request."
        case (.binders, _):
            return "4. Binders commits what you change here on its branch when you stop, then pushes it and opens a pull request. Never push."
        }
    }
}
