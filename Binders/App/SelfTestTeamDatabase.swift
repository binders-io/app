import Foundation
import PostgresNIO
import BindersKit

/// The team database against a real Postgres: each `--selftest-teamdb-…` makes its own throwaway cluster
/// (ThrowawayPostgres), sets up a team on it as an admin login with Azure's rights (CREATEROLE, not a superuser), and
/// removes the cluster at the end. Run in a new, empty BINDERS_DATA_DIR.
///
///     Binders --selftest-teamdb-schema     migrations, twice; roles, privileges, TLS and SCRAM; a newer database refused
///     Binders --selftest-teamdb-cases      the shared board cases against the SQL functions
///     Binders --selftest-teamdb-live       two clients: LISTEN within a second, a race for one card, retries, an offline change refused
///     Binders --selftest-teamdb-outbox     a dropped connection mid-outbox: nothing lost or doubled
///     Binders --selftest-teamdb-security   row-level security, agents and owners, one-time passwords
///     Binders --selftest-teamdb-vectors    the knowledge vectors at the pinned dimension, and a new pin
///     Binders --selftest-teamdb-boards     lane DB2: the app's boards on the database (names, sharing once, races, offline, MCP, pruning)
///     Binders --selftest-teamdb-agents     lane DB2: agents' public rows, teammates' cards, questions ring, Agents may place work items
///     Binders --selftest-teamdb-team       lane DB2: Settings → Team (setup again, invites, joining, members, leaving)
///     Binders --selftest-teamdb-notes      lane DB3: notes typed in together, agents' edits, presence, versions, sections,
///                                          folders, proposals
///     Binders --selftest-teamdb-move       lane DB3: moving a folder team over: everything once, again a no-op, nothing lost
///     Binders --selftest-teamdb-move-folders  lane DB6: a moved binder's notes in folders and agents' notes, listed after it
///     Binders --selftest-teamdb-meetings   lane DB4: meetings streamed live and written up, captures only when shared
///     Binders --selftest-teamdb-knowledge  lane DB4: an item's index published once and taken by other Macs, corrections
///     Binders --selftest-teamdb-todos      lane DB4: to-dos tick everywhere, a card's to-do, what MCP reads and ticks
///     Binders --selftest-teamdb-update     lane DB5: a database set up at migration 7, as Binders 0.10.0 leaves it,
///                                          brought up to date from Settings → Team: what was there stays as it was
///     Binders --selftest-teamdb-reads      lane DB5: teammates' items from the database kept from a tool that may not
///                                          read them, as a team folder's copies are
///     Binders --selftest-teamdb-reach      lane DB8: board writes while the database is stopped, frozen or turned off on this
///                                          Mac: each answers in time, what's kept arrives once, what's refused changed nothing
///     Binders --selftest-teamdb-open-perf  lane DB10: a shared binder of 400 notes opened at 80 ms a statement, while its
///                                          outbox goes, once it's gone, and while a teammate types: how long the main thread stalls
///     Binders --selftest-teamdb-board-groups  lane DS5: several cards moved, put in a note's group and deleted at once on the
///                                          team's board: what stays, what the database keeps, no Undo for a deletion
///     Binders --selftest-teamdb-join-copies  lane DB9: three Macs from a folder team join; no note copied under a new id, and
///                                          copies an earlier Binders made removed from Settings → Team
extension SelfTest {
    @MainActor
    static func teamDatabaseSelfTest(_ flag: String) async -> Int32 {
        let tests: [String: @MainActor (TeamDBTestBed) async throws -> Void] = [
            "--selftest-teamdb-schema": teamDatabaseSchemaChecks,
            "--selftest-teamdb-cases": teamDatabaseCaseChecks,
            "--selftest-teamdb-live": teamDatabaseLiveChecks,
            "--selftest-teamdb-outbox": teamDatabaseOutboxChecks,
            "--selftest-teamdb-security": teamDatabaseSecurityChecks,
            "--selftest-teamdb-vectors": teamDatabaseVectorChecks,
            "--selftest-teamdb-boards": teamBoardChecks,
            "--selftest-teamdb-agents": teamAgentChecks,
            "--selftest-teamdb-team": teamSettingsChecks,
            "--selftest-teamdb-notes": teamNotesChecks,
            "--selftest-teamdb-move": teamMoveChecks,
            "--selftest-teamdb-move-folders": teamMoveFolderChecks,
            "--selftest-teamdb-meetings": teamMeetingChecks,
            "--selftest-teamdb-knowledge": teamKnowledgeChecks,
            "--selftest-teamdb-todos": teamTodoChecks,
            "--selftest-teamdb-update": teamUpdateChecks,
            "--selftest-teamdb-reads": teamReadChecks,
            "--selftest-teamdb-reach": teamReachChecks,
            "--selftest-teamdb-open-perf": teamOpenPerfChecks,
            "--selftest-teamdb-join-copies": teamJoinCopiesChecks,
            "--selftest-teamdb-board-groups": teamBoardGroupChecks,
        ]
        // The update starts from a database as Binders 0.10.0 sets it up: migrations 1 to 7.
        let known = flag == "--selftest-teamdb-update" ? Array(TeamSchema.migrations.prefix(7)) : TeamSchema.migrations
        guard let test = tests[flag] else {
            print("Usage: \(tests.keys.sorted().joined(separator: " | "))")
            return 2
        }
        guard AppPaths.isDemo else {
            print("FAIL: set BINDERS_DATA_DIR to a new, empty folder: the team database self-tests make a Postgres there")
            return 1
        }
        let bed: TeamDBTestBed
        do {
            bed = try await TeamDBTestBed.start(known: known)
        } catch {
            print("FAIL: no throwaway Postgres: \(error.localizedDescription)")
            return 1
        }
        do {
            try await test(bed)
        } catch {
            bed.check(false, "the test ran to the end (stopped at: \(String(describing: error)))")
        }
        await bed.stop()
        bed.check(bed.postgres.isRemoved, "the throwaway Postgres was stopped and its folder removed")
        print(bed.failures == 0 ? "TEAMDB_DONE: \(bed.passes) passed" : "TEAMDB_DONE: \(bed.failures) failed, \(bed.passes) passed")
        return bed.failures == 0 ? 0 : 1
    }
}

/// A team set up on a throwaway Postgres, as Azure would have it: the server's admin login has CREATEROLE but isn't a
/// superuser, owns the database, and pgvector is turned on for it. Sam set the team up and is its first person; Alex was
/// added with a one-time password, which their Mac changed on first connect. Sam shares the Shared binder with Alex and
/// keeps the Private one. Agents A and B are Sam's, agent C is Alex's.
@MainActor
final class TeamDBTestBed {
    let postgres: ThrowawayPostgres
    let database = "binders_team"
    let adminLogin = "team_admin"
    let adminPassword = TeamPassword.generate()
    private(set) var passes = 0
    private(set) var failures = 0

    private(set) var sam: TeamDatabaseServer!
    private(set) var alex: TeamDatabaseServer!
    private(set) var samID: UUID!
    private(set) var alexID: UUID!
    let shared = UUID()
    let personal = UUID()
    let agentA = UUID()
    let agentB = UUID()
    let agentC = UUID()
    private(set) var setupOutcome: TeamDatabaseSetup.Outcome!
    private var links: [TeamDatabaseLink] = []
    private var clients: [TeamDatabase] = []

    private init(postgres: ThrowawayPostgres) {
        self.postgres = postgres
    }

    func check(_ passed: Bool, _ label: String) {
        print("\(passed ? "PASS" : "FAIL"): \(label)")
        if passed { passes += 1 } else { failures += 1 }
    }

    /// `known`: the migrations the team is set up with; all of them, or (lane DB5's update) those an earlier Binders had.
    static func start(known: [TeamMigration] = TeamSchema.migrations) async throws -> TeamDBTestBed {
        let bed = TeamDBTestBed(postgres: try await ThrowawayPostgres.start())
        do {
            try await bed.prepare(known: known)
        } catch {
            await bed.stop()
            throw error
        }
        return bed
    }

    /// The admin login and the database as Azure makes them, then the setup as Settings → Team runs it.
    private func prepare(known: [TeamMigration]) async throws {
        let root = try await postgres.superuserLink()
        try await root.execute("CREATE ROLE \(adminLogin) LOGIN CREATEROLE CREATEDB PASSWORD '\(TeamPassword.verifier(for: adminPassword))'")
        try await root.execute("CREATE DATABASE \(database) OWNER \(adminLogin)")
        await root.close()
        let inDatabase = try await postgres.superuserLink(database: database)
        // Azure's azure.extensions: turned on for the server by its owner, before any setup.
        try await inDatabase.execute("CREATE EXTENSION vector")
        await inDatabase.close()
        setupOutcome = try await TeamDatabaseSetup.run(setupRequest(), known: known)
        sam = setupOutcome.member
        let samLink = try await link(sam)
        samID = try await samLink.json(TeamQueries.whoami)["member"]?["id"]?.uuid
        // Alex: added with a one-time password, which their Mac changes the first time it connects.
        let invite = try await client(sam).addMemberDirect(on: samLink, login: "alex", name: "Alex")
        alex = invite.server
        TeamDatabase.keep(password: invite.oneTimePassword, for: alex)
        if known.count == TeamSchema.migrations.count {
            let alexClient = client(alex)
            try await waitConnected(alexClient)
            alexID = alexClient.member?["id"]?.uuid
            await alexClient.stop()
        } else {
            // A database an earlier Binders set up, which this one's client won't work with until it's updated: Alex's
            // password changed as that Binders changed it.
            let first = try await TeamDatabaseLink.connect(to: alex, password: invite.oneTimePassword, trust: postgres.trust)
            let password = TeamPassword.generate()
            let changed = try await first.call(.changePassword(verifier: TeamPassword.verifier(for: password)))
            await first.close()
            guard changed.ok else { throw TeamDatabase.Problem.refused("Alex's password didn't change") }
            TeamDatabase.keep(password: password, for: alex)
            alexID = try await link(alex).json(TeamQueries.whoami)["member"]?["id"]?.uuid
        }
        try await expectOK(samLink, .createBinder(shared, name: "Shared"))
        try await expectOK(samLink, .createBinder(personal, name: "Private"))
        try await expectOK(samLink, .shareBinder(shared, with: alexID))
        try await expectOK(samLink, .putAgent(agentA, fields: ["name": "Agent A", "kind": "claude-code"]))
        try await expectOK(samLink, .putAgent(agentB, fields: ["name": "Agent B", "kind": "codex"]))
        let alexLink = try await link(alex)
        try await expectOK(alexLink, .putAgent(agentC, fields: ["name": "Agent C", "kind": "claude-code"]))
    }

    func setupRequest() -> TeamDatabaseSetup.Request {
        TeamDatabaseSetup.Request(host: "127.0.0.1", port: postgres.port, database: database, serverName: "localhost", adminLogin: adminLogin,
                                  adminPassword: adminPassword, teamName: "Self-test team", firstLogin: "sam", firstName: "Sam",
                                  embedding: .default, trust: postgres.trust)
    }

    func stop() async {
        for client in clients { await client.stop() }
        for link in links { await link.close() }
        if let sam { TeamDatabase.forget(sam) }
        if let alex { TeamDatabase.forget(alex) }
        await postgres.stop()
    }

    /// A connection as a member, with the password their Mac keeps.
    func link(_ server: TeamDatabaseServer) async throws -> TeamDatabaseLink {
        guard let password = Keychain.read(TeamDatabase.passwordKey(server)), !password.isEmpty else { throw TeamDatabaseLink.Problem.noPassword }
        let link = try await TeamDatabaseLink.connect(to: server, password: password, trust: postgres.trust)
        links.append(link)
        return link
    }

    /// The cluster's superuser on the team's database: for putting cards in the state a case starts from.
    func root() async throws -> TeamDatabaseLink {
        let link = try await postgres.superuserLink(database: database)
        links.append(link)
        return link
    }

    /// A member's TeamDatabase client with its own folder in the throwaway data folder, reconnecting quickly.
    func client(_ server: TeamDatabaseServer, folder name: String? = nil) -> TeamDatabase {
        let folder = AppPaths.support.appendingPathComponent("team-\(name ?? server.login)", isDirectory: true)
        let client = TeamDatabase(server: server, trust: postgres.trust, folder: folder)
        client.testHooks.reconnectDelay = 0.2
        clients.append(client)
        return client
    }

    func waitConnected(_ client: TeamDatabase, timeout: TimeInterval = 15) async throws {
        client.start()
        let deadline = Date().addingTimeInterval(timeout)
        while client.status != .connected {
            if case .offline(_, let reason, false) = client.status { throw TeamDatabase.Problem.refused(reason) }
            guard Date() < deadline else { throw TeamDatabase.Problem.refused("not connected after \(Int(timeout)) s: \(client.status)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @discardableResult
    func expectOK(_ link: TeamDatabaseLink, _ call: TeamCall) async throws -> TeamResult {
        let result = try await link.call(call)
        guard result.ok else { throw TeamDatabase.Problem.refused("\(call.function) refused: \(result.refusal?.message ?? "")") }
        return result
    }

    /// The SQLSTATE a statement fails with, or nil when it doesn't fail.
    func failure(_ work: () async throws -> Void) async -> String? {
        do {
            try await work()
            return nil
        } catch let error as PSQLError {
            return error.sqlState ?? "\(error.code)"
        } catch {
            return "\(error)"
        }
    }

    /// Waits until `condition` holds, or `timeout` passes.
    func eventually(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

extension TeamDatabase {
    /// For the test bed: an admin adds a member on a connection of its own, before any client runs.
    func addMemberDirect(on link: TeamDatabaseLink, login: String, name: String) async throws -> TeamInvite {
        let password = TeamPassword.generate()
        let result = try await link.call(.addMember(UUID(), login: login, name: name, verifier: TeamPassword.verifier(for: password)))
        if let refusal = result.refusal { throw refusal }
        return TeamInvite(server: TeamDatabaseServer(host: server.host, port: server.port, database: server.database, login: login,
                                                     serverName: server.serverName),
                          oneTimePassword: password, teamName: "")
    }
}
