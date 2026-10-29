import Foundation
import BindersKit

/// Where Binders keeps what the command-line coding tools' runs need: ~/.binders (worktrees, each run's temp folder,
/// Copilot's settings folder for runs) and the agents' logs folder, where each run's log, run file and record live. Run
/// against a throwaway data folder (the self-tests), all of it sits beside that folder instead, so a test never touches
/// yours. Everything under the root is made 0700, and Binders' own files there 0600.
enum AgentPlaces {
    /// ~/.binders, or <data>-agents beside a throwaway data folder.
    static var root: URL {
        if AppPaths.isDemo {
            // As the folder was given, never with /private taken off: the paths a run is given are the ones it sees.
            let data = URL(fileURLWithPath: real(AppPaths.support.path), isDirectory: true)
            return data.deletingLastPathComponent().appendingPathComponent(data.lastPathComponent + "-agents", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".binders", isDirectory: true)
    }

    static var worktrees: URL { root.appendingPathComponent("worktrees", isDirectory: true) }
    /// Binders' record of the worktrees it made.
    static var records: URL { worktrees.appendingPathComponent("worktrees.json") }
    static var temporary: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    static var copilotHome: URL { root.appendingPathComponent("copilot", isDirectory: true) }

    /// Where the runs Binders starts write what they say: outside the data folder, which they may not read. In a throwaway
    /// folder, the same layout under the root.
    static var logs: URL {
        if AppPaths.isDemo { return root.appendingPathComponent("Logs/Binders/Agents", isDirectory: true) }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Binders/Agents", isDirectory: true)
    }

    /// Codex's folder of settings from an administrator, as Codex looks for it; under the root in a throwaway folder, so a
    /// self-test can plant something in it.
    static var managedCodexFolder: String {
        AppPaths.isDemo ? root.path + CodexManaged.folder : CodexManaged.folder
    }

    /// Claude Code's folder of an organization's managed settings, as Claude Code looks for it (`ClaudeCodeManaged`); under
    /// the root in a throwaway folder, so a self-test can plant something in it, and never touches the real one.
    static var managedClaudeFolder: String {
        AppPaths.isDemo ? root.path + ClaudeCodeManaged.folder : ClaudeCodeManaged.folder
    }

    /// Where a configuration profile puts them (`ClaudeCodeManaged.preferencesFolder`); under the root in a throwaway folder.
    static var managedPreferencesFolder: String {
        AppPaths.isDemo ? root.path + ClaudeCodeManaged.preferencesFolder : ClaudeCodeManaged.preferencesFolder
    }

    /// The organization's settings files for Claude Code on this Mac (`ClaudeCodeManaged.settingsFiles`).
    static var managedClaudeSettings: [URL] {
        ClaudeCodeManaged.settingsFiles(folder: managedClaudeFolder, preferences: managedPreferencesFolder)
    }

    /// Makes a folder (and its parents under the root) 0700, whoever made it first.
    @discardableResult
    static func ensure(_ folder: URL) -> URL {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var place = folder.standardizedFileURL
        let top = root.standardizedFileURL.path
        while place.path.hasPrefix(top) {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: place.path)
            if place.path == top { break }
            place = place.deletingLastPathComponent()
        }
        return folder
    }

    /// Writes one of Binders' own files, 0600, atomically.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The realpath of a path (realpath(3): every link resolved, /private kept, as a process sees its own folder and as a
    /// sandbox matches paths), for comparing places and for what goes into a run's sandbox. The path as given, without a
    /// trailing slash, when it isn't there.
    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// git, run for the worktrees: /usr/bin/git with argument arrays (never a shell), off the main thread, with a small
/// environment of its own.
enum AgentGit {
    struct Result: Sendable {
        var status: Int32
        var output: String
        var errors: String
        var ok: Bool { status == 0 }
        /// git's first line of complaint, for the card.
        var firstLine: String {
            let text = errors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? output : errors
            return text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "exit \(status)"
        }
    }

    /// HOME, USER, LOGNAME, LANG, the run's TMPDIR, the login shell's PATH (so git-lfs's filters run) and no prompts. In a
    /// throwaway folder, git's system and global settings stay out too, so a self-test never depends on yours.
    static func environment(path: String, temporary: String?) -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        var environment: [String: String] = ["HOME": NSHomeDirectory(), "GIT_TERMINAL_PROMPT": "0",
                                             "PATH": path.isEmpty ? "/usr/bin:/bin:/usr/sbin:/sbin" : path,
                                             "LANG": base["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8"]
        for key in ["USER", "LOGNAME"] { environment[key] = base[key] }
        if let temporary { environment["TMPDIR"] = temporary }
        if AppPaths.isDemo {
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        }
        return environment
    }

    static func run(_ arguments: [String], path: String, temporary: String?, timeout: TimeInterval = 120) async -> Result {
        do {
            let result = try await AutomationService.runProcess("/usr/bin/git", arguments, stdin: nil,
                                                                environment: environment(path: path, temporary: temporary), timeout: timeout)
            return Result(status: result.status, output: result.stdout, errors: result.stderr)
        } catch {
            return Result(status: -1, output: "", errors: error.localizedDescription)
        }
    }
}

/// Making, checking and committing the CLI tools' worktrees, as AgentWorktree (BindersKit) works them out.
enum AgentWorktrees {
    /// worktrees.json as it is: none there holds no records; nil when it's there but can't be read, so nothing is saved
    /// over it.
    static func file() -> AgentWorktreeFile? {
        guard let data = try? Data(contentsOf: AgentPlaces.records) else {
            return FileManager.default.fileExists(atPath: AgentPlaces.records.path) ? nil : AgentWorktreeFile()
        }
        return AgentWorktreeFile.decode(data)
    }

    /// Binders' records of its worktrees.
    static func records() -> [AgentWorktreeRecord] { file()?.records ?? [] }

    /// One change to the records at a time, made to the file as it is right then, so two runs made ready at once (each
    /// first wake waits on git for seconds) never save over each other's record. Entries a later Binders wrote are kept.
    /// False when the file can't be read: nothing is saved over it.
    @discardableResult
    static func update(_ change: (inout [AgentWorktreeRecord]) -> Void) -> Bool {
        lock.withLock {
            guard var current = file() else { return false }
            change(&current.records)
            AgentPlaces.ensure(AgentPlaces.worktrees)
            guard let data = try? current.encoded() else { return false }
            return (try? AgentPlaces.write(data, to: AgentPlaces.records)) != nil
        }
    }

    private static let lock = NSLock()

    /// What the card says when worktrees.json can't be read.
    static var unreadable: String {
        "Binders couldn't read its record of worktrees, \(display(AgentPlaces.records.path)), so it won't save over it. Nothing was started. Fix it or move it away, then Wake Now."
    }

    /// The worktree for a card and tool, ready for a run: the one Binders made for them before, checked as it was left, or
    /// a new one from the commit you have checked out. Never touches your checkout. A failure says why, for the card.
    static func prepare(repository: String, card: UUID, tool: CLIAgent, path: String, temporary: String) async -> Swift.Result<AgentWorktreeRecord, Failure> {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: repository, isDirectory: &isFolder), isFolder.boolValue else {
            return .failure(Failure("\(repository) isn't there any more. Nothing was started."))
        }
        // 1. The repository, as git sees it.
        let check = await AgentGit.run(AgentWorktree.checkRepository(repository), path: path, temporary: temporary, timeout: 30)
        let answer = check.output.split(whereSeparator: \.isNewline).map(String.init)
        guard check.ok, answer.count >= 2 else {
            return .failure(Failure("Couldn't make a worktree for this card in \(display(repository)): \(check.firstLine). Nothing was started."))
        }
        let top = AgentPlaces.real(answer[0]), common = AgentPlaces.real(answer[1])
        let place = AgentWorktree.path(root: AgentPlaces.root.path, repository: top, card: card, tool: tool)
        let branch = AgentWorktree.branch(card: card, tool: tool)
        // What's at this card and tool's path is this wake's alone (a card's next wake waits for this one): a look now holds.
        guard let all = file()?.records else { return .failure(Failure(unreadable)) }
        let exists = manager.fileExists(atPath: place)
        // 2. Something already at the path.
        if let problem = AgentWorktree.placeProblem(path: place, records: all, card: card, tool: tool, folderExists: exists) {
            return .failure(Failure(problem))
        }
        if exists, let record = all.first(where: { $0.path == place && $0.ready && $0.card == card && $0.tool == tool }) {
            // Later wakes: as Binders left it.
            let pointsTo = pointer(of: place)
            let head = await AgentGit.run(AgentWorktree.head(gitDir: record.gitDir, workTree: place), path: path, temporary: temporary, timeout: 30)
            if let problem = AgentWorktree.reuseProblem(record, pointsTo: pointsTo, head: head.ok ? head.output : nil) { return .failure(Failure(problem)) }
            return .success(record)
        }
        // 3. Your worktrees, as git lists them.
        let list = await AgentGit.run(AgentWorktree.list(top), path: path, temporary: temporary, timeout: 30)
        let listed = AgentWorktree.listed(list.output)
        if let other = listed.first(where: { $0.branch == "refs/heads/\(branch)" && AgentPlaces.real($0.path) != AgentPlaces.real(place) }),
           manager.fileExists(atPath: other.path) {
            return .failure(Failure("\(branch) is checked out at \(display(other.path)). Nothing was started."))
        }
        AgentPlaces.ensure(URL(fileURLWithPath: place).deletingLastPathComponent())
        // Binders' own entry whose folder you deleted: replace that one entry. Never `git worktree prune`.
        let stale = listed.contains { AgentPlaces.real($0.path) == AgentPlaces.real(place) || $0.path == place }
        let branchExists = await AgentGit.run(AgentWorktree.branchExists(top, branch: branch), path: path, temporary: temporary, timeout: 30).ok
        let arguments = stale ? AgentWorktree.addReplacing(top, path: place, branch: branch)
            : branchExists ? AgentWorktree.addExisting(top, path: place, branch: branch)
            : AgentWorktree.addNew(top, path: place, branch: branch)
        // git-lfs downloads during the checkout can take a while.
        let added = await AgentGit.run(arguments, path: path, temporary: temporary, timeout: 600)
        guard added.ok else {
            // Made in this attempt: taken back, and the folder too if git left it.
            if !exists {
                _ = await AgentGit.run(AgentWorktree.remove(top, path: place), path: path, temporary: temporary, timeout: 60)
                if manager.fileExists(atPath: place) { try? manager.removeItem(atPath: place) }
            }
            return .failure(Failure("Couldn't make a worktree for this card in \(display(top)): \(added.firstLine). Nothing was started."))
        }
        // 5. Its own git folder, read before any run has touched it.
        let gitDir = await AgentGit.run(AgentWorktree.absoluteGitDir(place), path: path, temporary: temporary, timeout: 30)
        guard gitDir.ok, let folder = gitDir.output.split(whereSeparator: \.isNewline).first.map(String.init) else {
            return .failure(Failure("Couldn't make a worktree for this card in \(display(top)): \(gitDir.firstLine). Nothing was started."))
        }
        let record = AgentWorktreeRecord(card: card, tool: tool, repository: top, commonDir: common, path: place, branch: branch,
                                         gitDir: AgentPlaces.real(folder), ready: true, made: Date())
        // Saved into the file as it is now, not as it was read before git ran: another card's first wake may have saved
        // its record meanwhile.
        guard update({ records in
            records.removeAll { $0.path == place }
            records.append(record)
        }) else {
            // Without its record it would look half made next time: taken back, as no run has touched it.
            if !exists {
                _ = await AgentGit.run(AgentWorktree.remove(top, path: place), path: path, temporary: temporary, timeout: 60)
                if manager.fileExists(atPath: place) { try? manager.removeItem(atPath: place) }
            }
            return .failure(Failure(unreadable))
        }
        return .success(record)
    }

    /// Puts back a worktree's record that's missing from worktrees.json (a run carries its own), so the next wake finds
    /// the worktree as Binders made it, never as a folder it didn't finish making. Nothing when a record of that path is
    /// there, its own or another's.
    static func restore(_ record: AgentWorktreeRecord) {
        update { records in
            guard !records.contains(where: { $0.path == record.path }) else { return }
            records.append(record)
        }
    }

    /// The first link in a worktree that leads outside it, by its path in the worktree, or nil: every symbolic link in it
    /// (tracked by the repository or not, at any depth), followed to where it ends up, link by link, even where that isn't
    /// there yet, as a write through it would create it. A link that loops counts as leading out. Its .git file isn't
    /// looked at, nor anything under a link (a link to a folder is followed by its own check).
    static func outwardLink(in worktree: String) -> String? {
        let root = AgentPlaces.real(worktree)
        // Paths in it as it names them; a link is listed, never gone into.
        guard let walk = FileManager.default.enumerator(atPath: root) else { return nil }
        while let relative = walk.nextObject() as? String {
            // Git's own folders, at any depth: a workspace run in the folder itself holds several repositories.
            if (relative as NSString).lastPathComponent == ".git" {
                walk.skipDescendants()
                continue
            }
            guard walk.fileAttributes?[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
            guard let leads = leadsTo((root as NSString).appendingPathComponent(relative)), AgentWorktree.isInside(leads, root) else { return relative }
        }
        return nil
    }

    /// Where a path ends up once every link in it is followed, whether or not its end is there: realpath(3) when all of it
    /// is; else a link at its end followed by hand; else its parent's, with its name after it. Nil after 40 links.
    static func leadsTo(_ path: String, links: Int = 0) -> String? {
        guard links < 40, path.hasPrefix("/") else { return nil }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let from = (path as NSString).deletingLastPathComponent
            return leadsTo(target.hasPrefix("/") ? target : (from as NSString).appendingPathComponent(target), links: links + 1)
        }
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard parent != path, !parent.isEmpty, let base = leadsTo(parent, links: links) else { return nil }
        switch name {
        case "", ".": return base
        case "..": return (base as NSString).deletingLastPathComponent
        default: return (base as NSString).appendingPathComponent(name)
        }
    }

    /// Where a worktree's .git file points, as a realpath; nil when it isn't a file with a gitdir line.
    static func pointer(of worktree: String) -> String? {
        let file = (worktree as NSString).appendingPathComponent(".git")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file, isDirectory: &isFolder), !isFolder.boolValue,
              let text = try? String(contentsOfFile: file, encoding: .utf8), let target = AgentWorktree.pointer(text) else { return nil }
        let absolute = target.hasPrefix("/") ? target : (worktree as NSString).appendingPathComponent(target)
        return AgentPlaces.real(absolute)
    }

    /// What Binders' commit of a run's changes did.
    enum Committed: Sendable {
        /// Committed: the short id and how many files.
        case committed(sha: String, files: Int)
        /// Nothing changed.
        case nothing
        /// Not committed, with the card's line.
        case refused(String)
    }

    /// Commits what the run changed in its worktree on its branch, with your own git name, unsigned, with no hooks, and
    /// with the worktree's git folder named from Binders' record. Refuses a nested repository, a gitlink, far more changes
    /// than a card would make, and a .git file the run rewrote.
    static func commit(_ record: AgentWorktreeRecord, agentName: String, path: String, temporary: String?) async -> Committed {
        let git = record.gitDir, tree = record.path
        let shown = display(tree)
        func run(_ arguments: [String], timeout: TimeInterval = 300) async -> AgentGit.Result {
            await AgentGit.run(arguments, path: path, temporary: temporary, timeout: timeout)
        }
        guard FileManager.default.fileExists(atPath: tree) else { return .nothing }
        // The pointer first: a call that followed a rewritten one could reach your checkout's own index.
        guard pointer(of: tree) == record.gitDir else {
            return .refused(AgentWorktree.describe(.pointerChanged, tool: record.tool, worktree: shown))
        }
        let status = await run(AgentWorktree.status(gitDir: git, workTree: tree))
        guard status.ok else { return .refused("Couldn't commit \(record.tool.name)'s changes: \(status.firstLine). They're still in \(shown).") }
        guard !status.output.isEmpty else { return .nothing }
        if let nested = AgentWorktree.nestedRepository(status: status.output) {
            return .refused(AgentWorktree.describe(.nested(nested), tool: record.tool, worktree: shown))
        }
        let added = await run(AgentWorktree.addAll(gitDir: git, workTree: tree))
        guard added.ok else { return .refused("Couldn't commit \(record.tool.name)'s changes: \(added.firstLine). They're still in \(shown).") }
        let staged = await run(AgentWorktree.staged(gitDir: git, workTree: tree))
        let changes = AgentWorktree.changes(staged.output)
        guard !changes.isEmpty else { return .nothing }
        let tracked = await run(AgentWorktree.tracked(gitDir: git, workTree: tree))
        let count = tracked.output.split(separator: "\0").count
        var bytes = 0
        for change in changes where change.status != "D" {
            let attributes = try? FileManager.default.attributesOfItem(atPath: (tree as NSString).appendingPathComponent(change.path))
            bytes += (attributes?[.size] as? Int) ?? 0
        }
        if let problem = AgentWorktree.stagedProblem(changes, tracked: count, bytes: bytes) {
            _ = await run(AgentWorktree.unstage(gitDir: git, workTree: tree))
            return .refused(AgentWorktree.describe(problem, tool: record.tool, worktree: shown))
        }
        guard pointer(of: tree) == record.gitDir else {
            _ = await run(AgentWorktree.unstage(gitDir: git, workTree: tree))
            return .refused(AgentWorktree.describe(.pointerChanged, tool: record.tool, worktree: shown))
        }
        let commit = await run(AgentWorktree.commit(gitDir: git, workTree: tree, message: AgentWorktree.commitMessage(card: record.card, agent: agentName)))
        guard commit.ok else {
            _ = await run(AgentWorktree.unstage(gitDir: git, workTree: tree))
            let said = (commit.errors + commit.output).lowercased()
            if said.contains("tell me who you are") || said.contains("user.email") || said.contains("author identity unknown") {
                return .refused(AgentWorktree.describe(.noIdentity, tool: record.tool, worktree: shown))
            }
            return .refused("Couldn't commit \(record.tool.name)'s changes: \(commit.firstLine). They're still in \(shown).")
        }
        let sha = await run(AgentWorktree.shortHead(gitDir: git, workTree: tree)).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = await run(AgentWorktree.committedFiles(gitDir: git, workTree: tree)).output.split(whereSeparator: \.isNewline).count
        return .committed(sha: sha, files: files)
    }

    /// A path as the card shows it: with "~" in your home folder, and pastable.
    static func display(_ path: String) -> String {
        CLIAgentLaunches.pastable(path, home: NSHomeDirectory())
    }

    struct Failure: Error, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
