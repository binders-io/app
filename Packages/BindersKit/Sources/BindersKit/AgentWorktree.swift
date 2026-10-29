import CryptoKit
import Foundation

// The git worktrees Binders makes for the command-line coding tools: one per card and tool, under ~/.binders/worktrees,
// so no tool ever starts in a folder another tool wrote. Binders makes each with git, keeps a record of it, and commits
// what a run changed when it stops, with every git call naming the worktree's git folder itself and with hooks,
// fsmonitor, submodules and automatic gc off. Your checkout's files, index and HEAD are never touched. These are the
// names, the git arguments and the decisions; the app runs git.

/// Binders' record of a worktree it made, in worktrees.json beside them. Only one marked ready is ever reused.
public struct AgentWorktreeRecord: Codable, Equatable, Sendable {
    /// The card's whole id: its name has 12 hex digits of it.
    public var card: UUID
    public var tool: CLIAgent
    /// The repository, as a realpath.
    public var repository: String
    /// The realpath of the repository's git folder.
    public var commonDir: String
    /// The worktree.
    public var path: String
    /// binders-card-<card12>-<tool>
    public var branch: String
    /// The realpath of the worktree's own git folder (<commonDir>/worktrees/<name>), read right after it was made.
    public var gitDir: String
    /// True only once `git worktree add` exited 0.
    public var ready: Bool
    public var made: Date

    /// A run in the folder itself (`CLIAgentWake.inFolder`): no worktree, no branch, nothing to commit; never in
    /// worktrees.json. Nil for a worktree.
    public var inFolder: Bool?

    /// Whether this is the folder itself rather than a worktree Binders made.
    public var isFolder: Bool { inFolder == true }

    /// The record for a run in the folder itself.
    public static func folder(_ path: String, card: UUID, tool: CLIAgent, made: Date = Date()) -> AgentWorktreeRecord {
        var record = AgentWorktreeRecord(card: card, tool: tool, repository: path, commonDir: "", path: path, branch: "", gitDir: "", ready: true, made: made)
        record.inFolder = true
        return record
    }

    public init(card: UUID, tool: CLIAgent, repository: String, commonDir: String, path: String, branch: String, gitDir: String, ready: Bool, made: Date) {
        self.card = card
        self.tool = tool
        self.repository = repository
        self.commonDir = commonDir
        self.path = path
        self.branch = branch
        self.gitDir = gitDir
        self.ready = ready
        self.made = made
    }

}

/// worktrees.json, the list of Binders' records of its worktrees, shared by every Binders that opens this home folder. An
/// entry this build can't read (one a later Binders wrote for a tool it added, say) is kept as it was and written back,
/// so saving here never drops it, and a later build's worktree never looks like one Binders didn't finish making.
public struct AgentWorktreeFile: Equatable, Sendable {
    public var records: [AgentWorktreeRecord]
    /// The entries this build couldn't read, as they were. Written back after the records it knows.
    public var kept: [JSONValue]

    public init(records: [AgentWorktreeRecord] = [], kept: [JSONValue] = []) {
        self.records = records
        self.kept = kept
    }

    /// Reads it, entry by entry. Nil when it isn't a list at all (a file cut short, say): then nothing is saved over it.
    /// An empty file holds no records.
    public static func decode(_ data: Data) -> AgentWorktreeFile? {
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return AgentWorktreeFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([Entry].self, from: data) else { return nil }
        return AgentWorktreeFile(records: entries.compactMap(\.record), kept: entries.compactMap(\.raw))
    }

    /// As Binders writes it: a list, pretty printed, with sorted keys and ISO 8601 dates; with nothing kept, the bytes a
    /// list of the records alone would be.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(records.map(Entry.init(record:)) + kept.map(Entry.init(raw:)))
    }

    /// One entry: a record this build reads, or what it can't, as it was.
    private struct Entry: Codable {
        let record: AgentWorktreeRecord?
        let raw: JSONValue?

        init(record: AgentWorktreeRecord) {
            self.record = record
            raw = nil
        }

        init(raw: JSONValue) {
            record = nil
            self.raw = raw
        }

        init(from decoder: Decoder) throws {
            record = try? AgentWorktreeRecord(from: decoder)
            raw = record == nil ? try JSONValue(from: decoder) : nil
        }

        func encode(to encoder: Encoder) throws {
            if let record { try record.encode(to: encoder) } else { try raw?.encode(to: encoder) }
        }
    }
}

public enum AgentWorktree {
    // MARK: Names

    /// The repository's folder under the worktrees: its name with anything outside [A-Za-z0-9._-] as "-", at most 32
    /// characters ("repo" when nothing's left), and the first 8 hex digits of the SHA-256 of its standardized path, so two
    /// repositories called "app" don't share one.
    public static func repositoryFolder(_ repository: String) -> String {
        let standard = (CLIAgentLaunches.trimmed(repository) as NSString).standardizingPath
        let name = (standard as NSString).lastPathComponent
        var cleaned = name == "/" ? "" : String(name.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar)) ? Character(scalar) : "-"
        }.prefix(32))
        if cleaned.isEmpty { cleaned = "repo" }
        let hash = SHA256.hash(data: Data(standard.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return cleaned + "-" + hash
    }

    /// The worktree's folder: binders-<card12>-<tool>.
    public static func name(card: UUID, tool: CLIAgent) -> String { "binders-\(CLIAgentLaunches.card12(card))-\(tool.rawValue)" }

    /// Its branch: binders-card-<card12>-<tool>.
    public static func branch(card: UUID, tool: CLIAgent) -> String { "binders-card-\(CLIAgentLaunches.card12(card))-\(tool.rawValue)" }

    /// Where it is: <root>/worktrees/<repo>-<hash8>/binders-<card12>-<tool>.
    public static func path(root: String, repository: String, card: UUID, tool: CLIAgent) -> String {
        CLIAgentLaunches.trimmed(root) + "/worktrees/" + repositoryFolder(repository) + "/" + name(card: card, tool: tool)
    }

    /// The commit's message, with no trailers.
    public static func commitMessage(card: UUID, agent: String) -> String {
        "Binders card \(CLIAgentLaunches.card12(card)): changes from \(agent)"
    }

    // MARK: How every git call runs

    /// On every call: no hooks, no fsmonitor, no submodule recursion, no automatic gc or maintenance. Command-line -c
    /// outranks every config file, a core.hooksPath in the repository's own config included.
    public static let safety = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "submodule.recurse=false",
                                "-c", "diff.ignoreSubmodules=all", "-c", "status.submoduleSummary=false", "-c", "gc.auto=0",
                                "-c", "maintenance.auto=false"]

    /// A call on the repository, before the worktree exists.
    public static func onRepository(_ repository: String, _ arguments: [String]) -> [String] {
        ["-C", repository] + safety + arguments
    }

    /// A call on a worktree: its git folder and work tree named from Binders' record, so git never reads its .git file,
    /// and a pointer a run rewrote can't send the call into your checkout.
    public static func onWorktree(gitDir: String, workTree: String, _ arguments: [String]) -> [String] {
        ["--git-dir=\(gitDir)", "--work-tree=\(workTree)"] + safety + arguments
    }

    /// The repository's top folder and git folder, as absolute paths.
    public static func checkRepository(_ repository: String) -> [String] {
        onRepository(repository, ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"])
    }

    public static func list(_ repository: String) -> [String] {
        onRepository(repository, ["worktree", "list", "--porcelain"])
    }

    public static func branchExists(_ repository: String, branch: String) -> [String] {
        onRepository(repository, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"])
    }

    /// A new branch, from the commit you have checked out.
    public static func addNew(_ repository: String, path: String, branch: String) -> [String] {
        onRepository(repository, ["worktree", "add", "-b", branch, path, "HEAD"])
    }

    /// The branch from an earlier worktree of the card, whose commits the work carries on from.
    public static func addExisting(_ repository: String, path: String, branch: String) -> [String] {
        onRepository(repository, ["worktree", "add", path, branch])
    }

    /// Replacing Binders' own worktree whose folder is gone: this one stale entry, never a prune of them all.
    public static func addReplacing(_ repository: String, path: String, branch: String) -> [String] {
        onRepository(repository, ["worktree", "add", "--force", path, branch])
    }

    /// Taking back a half-made worktree Binders made in the same attempt.
    public static func remove(_ repository: String, path: String) -> [String] {
        onRepository(repository, ["worktree", "remove", "--force", path])
    }

    /// The new worktree's own git folder, read before any run touched it.
    public static func absoluteGitDir(_ path: String) -> [String] {
        ["-C", path] + safety + ["rev-parse", "--absolute-git-dir"]
    }

    public static func head(gitDir: String, workTree: String) -> [String] {
        onWorktree(gitDir: gitDir, workTree: workTree, ["symbolic-ref", "HEAD"])
    }

    public static func status(gitDir: String, workTree: String) -> [String] {
        onWorktree(gitDir: gitDir, workTree: workTree, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all"])
    }

    public static func addAll(gitDir: String, workTree: String) -> [String] {
        onWorktree(gitDir: gitDir, workTree: workTree, ["add", "-A"])
    }

    public static func staged(gitDir: String, workTree: String) -> [String] {
        onWorktree(gitDir: gitDir, workTree: workTree, ["diff", "--cached", "--raw", "-z", "--no-renames"])
    }

    public static func tracked(gitDir: String, workTree: String) -> [String] {
        onWorktree(gitDir: gitDir, workTree: workTree, ["ls-tree", "-r", "-z", "--name-only", "HEAD"])
    }

    public static func unstage(gitDir: String, workTree: String) -> [String] {
        onWorktree(gitDir: gitDir, workTree: workTree, ["reset", "-q"])
    }

    /// The commit, unsigned so it never pops a prompt, and with no hooks.
    public static func commit(gitDir: String, workTree: String, message: String) -> [String] {
        ["--git-dir=\(gitDir)", "--work-tree=\(workTree)"] + safety + ["-c", "commit.gpgsign=false", "commit", "--no-verify", "-q", "-m", message]
    }

    public static func shortHead(gitDir: String, workTree: String) -> [String] {
        onWorktree(gitDir: gitDir, workTree: workTree, ["rev-parse", "--short", "HEAD"])
    }

    /// The files the commit changed, one a line.
    public static func committedFiles(gitDir: String, workTree: String) -> [String] {
        onWorktree(gitDir: gitDir, workTree: workTree, ["show", "--name-only", "--format=", "HEAD"])
    }

    // MARK: Reading git's answers

    /// One worktree in `git worktree list --porcelain`.
    public struct Listed: Equatable, Sendable {
        public var path: String
        /// Its branch's full ref, when it's on one.
        public var branch: String?
        public init(path: String, branch: String?) {
            self.path = path
            self.branch = branch
        }
    }

    public static func listed(_ porcelain: String) -> [Listed] {
        var found: [Listed] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var path: String?, branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst("branch ".count)) }
            }
            if let path { found.append(Listed(path: path, branch: branch)) }
        }
        return found
    }

    /// One staged change in `diff --cached --raw -z --no-renames`.
    public struct Change: Equatable, Sendable {
        /// A, M, D, T…
        public var status: String
        public var newMode: String
        public var path: String
        public init(status: String, newMode: String, path: String) {
            self.status = status
            self.newMode = newMode
            self.path = path
        }
    }

    public static func changes(_ raw: String) -> [Change] {
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var changes: [Change] = []
        var index = 0
        while index < fields.count {
            let header = fields[index]
            guard header.hasPrefix(":"), index + 1 < fields.count else { index += 1; continue }
            // :<old mode> <new mode> <old sha> <new sha> <status>
            let parts = header.dropFirst().split(separator: " ")
            let status = parts.count >= 5 ? String(parts[4].prefix(1)) : "?"
            changes.append(Change(status: status, newMode: parts.count >= 2 ? String(parts[1]) : "", path: fields[index + 1]))
            index += 2
        }
        return changes
    }

    /// The entries of `status --porcelain=v1 -z`: their two-letter code and path.
    public static func statusEntries(_ status: String) -> [(code: String, path: String)] {
        let fields = status.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [(String, String)] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            guard field.count > 3 else { index += 1; continue }
            let code = String(field.prefix(2))
            entries.append((code, String(field.dropFirst(3))))
            // A rename or a copy names where it came from next.
            index += code.first == "R" || code.first == "C" ? 2 : 1
        }
        return entries
    }

    /// A nested repository: an untracked folder git shows whole under --untracked-files=all, because it holds a .git of
    /// its own. Its path, or nil.
    public static func nestedRepository(status: String) -> String? {
        statusEntries(status).first { $0.code == "??" && $0.path.hasSuffix("/") }?.path
    }

    /// The path a worktree's .git file points at, from its "gitdir: <path>" line.
    public static func pointer(_ gitFile: String) -> String? {
        gitFile.split(whereSeparator: \.isNewline).first { $0.hasPrefix("gitdir:") }
            .map { $0.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: What stops a commit

    /// Why Binders won't commit what a run changed.
    public enum CommitProblem: Equatable, Sendable {
        /// It made a git repository inside the worktree.
        case nested(String)
        /// It added a gitlink (mode 160000).
        case gitlink(String)
        /// More paths changed than a card would.
        case tooMany(Int)
        /// More bytes added or changed than a card would.
        case tooBig(Int)
        /// It deletes more than half the branch's tracked files, and more than 20 of them.
        case deletes(Int, of: Int)
        /// Its .git file was changed during the run.
        case pointerChanged
        /// git has no name and email to commit with.
        case noIdentity
    }

    public static let pathLimit = 2_000
    public static let byteLimit = 100 * 1024 * 1024

    /// The staged changes Binders refuses to commit: a gitlink, more than 2,000 paths, more than 100 MB added or changed
    /// (`bytes`, from the files), or deleting more than half of the branch's `tracked` files and more than 20 of them.
    public static func stagedProblem(_ changes: [Change], tracked: Int, bytes: Int) -> CommitProblem? {
        if let link = changes.first(where: { $0.newMode == "160000" }) { return .gitlink(link.path) }
        if changes.count > pathLimit { return .tooMany(changes.count) }
        if bytes > byteLimit { return .tooBig(bytes) }
        let deleted = changes.filter { $0.status == "D" }.count
        if deleted > 20, deleted * 2 > tracked { return .deletes(deleted, of: tracked) }
        return nil
    }

    /// The card's line for a problem.
    public static func describe(_ problem: CommitProblem, tool: CLIAgent, worktree: String) -> String {
        let still = "They're still in \(worktree)."
        let yours = still + " Commit them yourself if that's right."
        switch problem {
        case .nested(let path):
            return "Didn't commit \(tool.name)'s changes: it made a git repository inside the worktree, at \(path). \(still)"
        case .gitlink(let path):
            return "Didn't commit \(tool.name)'s changes: it added a link to another git repository, at \(path). \(yours)"
        case .tooMany(let count):
            return "Didn't commit \(tool.name)'s changes: they change \(grouped(count)) files, more than the \(grouped(pathLimit)) a card would. \(yours)"
        case .tooBig(let bytes):
            return "Didn't commit \(tool.name)'s changes: they add or change \(bytes / (1024 * 1024)) MB, more than the 100 MB a card would. \(yours)"
        case .deletes(let deleted, let tracked):
            return "Didn't commit \(tool.name)'s changes: they delete \(deleted) of the branch's \(tracked) files. \(yours)"
        case .pointerChanged:
            return "Didn't commit \(tool.name)'s changes: the worktree's .git file was changed during the run. \(still)"
        case .noIdentity:
            return "Couldn't commit \(tool.name)'s changes: git needs your name and email (git config --global user.name …). \(still)"
        }
    }

    /// 2000 as "2,000", the same in every locale.
    static func grouped(_ number: Int) -> String {
        let digits = String(abs(number))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (number < 0 ? "-" : "") + out
    }

    // MARK: Links that lead out of a worktree

    /// Whether `path` is `root` or inside it, both as realpaths.
    public static func isInside(_ path: String, _ root: String) -> Bool {
        let root = CLIAgentLaunches.trimmed(root), path = CLIAgentLaunches.trimmed(path)
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Why Binders won't start a tool whose file tools check a path by its text and then follow a link in it (OpenCode):
    /// a link in the worktree leads outside it. `link` is its path in the worktree.
    public static func outwardLinkProblem(_ link: String, tool: CLIAgent) -> String {
        "Binders didn't start \(tool.name): \(link) in the card's worktree is a link to somewhere outside it, and \(tool.name)'s file tools would follow it there. Remove the link there if the card doesn't need it, or give the card to another agent, then Wake Now."
    }

    // MARK: Using a worktree again

    /// Why a ready worktree can't be used for the next run: its folder is there, but its .git file doesn't point at the git
    /// folder Binders recorded, or it's on another branch. `pointsTo` is the realpath of where its .git file points (nil
    /// when it isn't a file with a gitdir line); `head` is `symbolic-ref HEAD`'s answer.
    public static func reuseProblem(_ record: AgentWorktreeRecord, pointsTo: String?, head: String?) -> String? {
        let which: String?
        if pointsTo == nil {
            which = "its .git file is missing or isn't one git wrote"
        } else if pointsTo != record.gitDir {
            which = "its .git file points at another git folder"
        } else if head?.trimmingCharacters(in: .whitespacesAndNewlines) != "refs/heads/\(record.branch)" {
            which = "it isn't on \(record.branch)"
        } else {
            which = nil
        }
        return which.map { "The worktree at \(record.path) isn't as Binders left it (\($0)). Nothing was started." }
    }

    /// What stops the first run for a card and tool before git is asked anything: a record of another card or tool at the
    /// path, or a folder there with no ready record, which Binders never deletes, since it can't tell a half-made checkout
    /// from work that lost its record.
    public static func placeProblem(path: String, records: [AgentWorktreeRecord], card: UUID, tool: CLIAgent, folderExists: Bool) -> String? {
        if let record = records.first(where: { $0.path == path && $0.ready }), record.card != card || record.tool != tool {
            return "A worktree at \(path) belongs to another card. Nothing was started."
        }
        guard folderExists, !records.contains(where: { $0.path == path && $0.ready && $0.card == card && $0.tool == tool }) else { return nil }
        return "A folder is already at \(path), and Binders didn't finish making it. Nothing was started. If nothing in it matters, git worktree remove --force \(path) removes it. Then Wake Now."
    }
}
