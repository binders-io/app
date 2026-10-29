import XCTest
@testable import BindersKit

/// Pull requests for agents' work (lane PR1): what Binders pushes and never pushes, what it asks gh, and what a run is told.
final class PullRequestsTests: XCTestCase {
    func testOnlyABranchOfItsOwnIsPushed() {
        XCTAssertNil(PullRequests.refusal(branch: "binders/fix-login", defaultBranch: "main"))
        XCTAssertNotNil(PullRequests.refusal(branch: "main", defaultBranch: "main"))
        XCTAssertNotNil(PullRequests.refusal(branch: "trunk-work", defaultBranch: "trunk-work"), "the repository's own default, whatever it's called")
        XCTAssertNotNil(PullRequests.refusal(branch: "master", defaultBranch: nil), "a main branch, even when the default isn't known")
        XCTAssertNotNil(PullRequests.refusal(branch: "HEAD", defaultBranch: "main"), "a detached HEAD")
        XCTAssertNotNil(PullRequests.refusal(branch: "", defaultBranch: "main"))
        for odd in ["--force", "a..b", "a b", "x:y", "topic.lock", "a@{1}"] {
            XCTAssertNotNil(PullRequests.refusal(branch: odd, defaultBranch: "main"), odd)
        }
    }

    func testThePushIsThatBranchAloneNeverForced() {
        let push = PullRequests.push(branch: "binders/fix-login")
        XCTAssertEqual(push, ["push", "--set-upstream", "origin", "refs/heads/binders/fix-login:refs/heads/binders/fix-login"])
        XCTAssertFalse(push.contains { $0.contains("force") || $0.hasPrefix("+") })
        XCTAssertEqual(PullRequests.create(branch: "b", title: "T", body: "B", draft: true), ["pr", "create", "--head", "b", "--title", "T", "--body", "B", "--draft"])
    }

    func testTheLinkIsReadFromWhatGhSays() {
        XCTAssertEqual(PullRequests.url(in: "Creating pull request\nhttps://github.com/example/app/pull/42\n"), "https://github.com/example/app/pull/42")
        XCTAssertEqual(PullRequests.url(in: "a pull request for branch \"b\" into branch \"main\" already exists:\nhttps://ghe.example.com/team/app/pull/7"),
                       "https://ghe.example.com/team/app/pull/7")
        XCTAssertNil(PullRequests.url(in: "error: not signed in"))
        XCTAssertEqual(PullRequests.title("", card: "Fix the login"), "Fix the login")
        XCTAssertEqual(PullRequests.title("First line\nmore", card: "x"), "First line")
        XCTAssertTrue(PullRequests.body("Done.", agent: "Codex · app", card: "Fix").hasSuffix("Opened by Codex · app for the Binders card “Fix”."))
    }

    func testWhoOpensItForEachKindOfRun() {
        var wake = CLIAgentWake(tool: .opencode, repository: "/Users/sam/code/app", model: "anthropic/claude-sonnet-4-5")
        XCTAssertNil(wake.pullRequestWay, "off unless turned on")
        wake.pullRequests = true
        XCTAssertEqual(wake.pullRequestWay, .binders, "in a worktree, Binders opens it after its commit")
        wake.inFolder = true
        XCTAssertNil(wake.pullRequestWay, "in the folder itself OpenCode can't make a branch")
        var codex = CLIAgentWake(tool: .codex, repository: "/Users/sam/code", inFolder: true, pullRequests: true)
        XCTAssertEqual(codex.pullRequestWay, .tool, "Codex runs git: it commits on its own branch and asks")
        codex.permissionMode = "plan"
        XCTAssertNil(codex.pullRequestWay, "not when it only reads")
        let prompt = AgentRunPrompt.text(card: UUID(), reason: .ready, commits: .agent, inFolder: true, pullRequests: .tool)
        XCTAssertTrue(prompt.contains("call \(PullRequests.tool) for each of those repositories") && prompt.contains("never push yourself"))
        XCTAssertTrue(AgentRunPrompt.text(card: UUID(), reason: .ready, commits: .binders, pullRequests: .binders).contains("then pushes it and opens a pull request"))
    }
}
