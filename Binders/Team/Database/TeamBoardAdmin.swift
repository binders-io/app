import Foundation
import SwiftData
import BindersKit

/// Settings → Team's team database (lane DB2): setting one up, joining with an invite, leaving, and an admin's members.
/// Two ways to share, never both on one Mac: a team folder (TeamSyncService) or this.
extension TeamBoard {
    enum AdminProblem: LocalizedError {
        case folderTeam, otherDatabase(String), offline, notAdmin, invalid(String)

        var errorDescription: String? {
            switch self {
            case .folderTeam: "This Mac shares through a team folder. Leave the team folder first: one Mac shares one way."
            case .otherDatabase(let team): "This Mac is in another team database (\(team)). Leave it first."
            case .offline: "This Mac isn't connected to the team database now. Try again once Settings → Team says Connected."
            case .notAdmin: "Only an admin of the team can do that."
            case .invalid(let what): what
            }
        }
    }

    /// Whether this Mac shares through a team folder, which rules a database out.
    var hasFolderTeam: Bool { AppSettings.shared.teamFolderPath != nil }

    // MARK: Setting up

    /// Set Up a Team Database: with the server's admin login, used for this call only and never kept, Binders applies its
    /// schema, records the team and makes you its first member, an admin, with a password this Mac makes and keeps in the
    /// Keychain; then this Mac connects as you. Run again on a database this Mac already uses, it applies only what's
    /// missing and keeps your login. Returns what to say.
    func setUp(host: String, port: Int, database: String, serverName: String?, adminLogin: String, adminPassword: String,
               teamName: String, yourName: String) async throws -> String {
        guard !hasFolderTeam || movingFolderTeam else { throw AdminProblem.folderTeam }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines), databaseName = database.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !databaseName.isEmpty else { throw AdminProblem.invalid("Give the server and the database.") }
        guard (1...65535).contains(port) else { throw AdminProblem.invalid("A port is a number from 1 to 65,535.") }
        let current = Self.savedServer()
        let same = current.map { $0.host.lowercased() == host.lowercased() && $0.port == port && $0.database == databaseName } ?? false
        if let current, !same { throw AdminProblem.otherDatabase("\(current.database) on \(current.host)") }
        let request = TeamDatabaseSetup.Request(host: host, port: port, database: databaseName,
                                                serverName: serverName?.trimmingCharacters(in: .whitespaces).nilIfEmpty, adminLogin: adminLogin,
                                                adminPassword: adminPassword, teamName: teamName, firstLogin: current?.login ?? TeamNames.login(for: yourName),
                                                firstName: yourName, embedding: .default, trust: trust)
        let outcome = try await TeamDatabaseSetup.run(request)
        if let member = outcome.member {
            Self.save(member)
            await stop()
            run(member)
            return "Set up “\(teamName.trimmingCharacters(in: .whitespaces))”. You're its first member, and an admin."
        }
        let updated = outcome.applied.isEmpty ? "It was up to date." : "Binders brought it up to date."
        if same {
            // Brought up to date: this Mac connects again now, rather than when it next tries.
            if !outcome.applied.isEmpty, let current { await stop(); run(current) }
            return "The team database is set up. \(updated)"
        }
        throw AdminProblem.invalid("That database already has a team. \(updated) Ask one of its admins for an invite.")
    }

    // MARK: Updating

    /// Update the Team Database… (lane DB5): the team's database lacks an update this Binders brings. With the server's
    /// admin login, used for this call only and never kept, it applies what's missing as Set Up does, in one transaction;
    /// then this Mac connects again. Returns what to say.
    func updateDatabase(adminLogin: String, adminPassword: String) async throws -> String {
        guard let server else { throw AdminProblem.offline }
        let login = adminLogin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty, !adminPassword.isEmpty else { throw AdminProblem.invalid("Give the server's admin login and its password.") }
        let request = TeamDatabaseSetup.UpdateRequest(host: server.host, port: server.port, database: server.database, serverName: server.serverName,
                                                      adminLogin: login, adminPassword: adminPassword, trust: trust)
        let applied = try await TeamDatabaseSetup.update(request)
        await stop()
        run(server)
        return applied.isEmpty
            ? "The team's database was already up to date. This Mac is connecting again."
            : "Updated the team's database. This Mac is connecting again, and teammates' Macs on this version of Binders connect too."
    }

    // MARK: A headless agent's Auto

    /// One of your headless agents' Auto, on or off (migration 8): on, it takes cards on its own in the binders shared with
    /// its login; off, it can't take one. Only its owner can, so only yours show the switch.
    func setAuto(_ agent: TeamDirectory.Agent, on: Bool) async throws {
        guard let database, database.status == .connected else { throw AdminProblem.offline }
        guard agent.isHeadless, state.directory.isMine(agent) else {
            throw AdminProblem.invalid("Only \(state.directory.ownerName(of: agent)), its owner, turns \(agent.name)'s Auto on or off.")
        }
        let result = try await database.call(.setAgentAuto(agent.id, on: on))
        if let refusal = result.refusal { throw refusal }
        if let row = result.body["agent"]?.object { state.directory.take(agent: row) }
        saveState()
    }

    // MARK: Joining

    /// Joins with an invite: its one-time password goes in the Keychain, and the first connection changes it for one only
    /// this Mac knows. An invite for the login this Mac already uses changes nothing (and never puts its used password back).
    /// Returns what to say.
    func join(_ invite: TeamInvite) async throws -> String {
        guard !hasFolderTeam || movingFolderTeam else { throw AdminProblem.folderTeam }
        let team = invite.teamName.isEmpty ? "the team" : "“\(invite.teamName)”"
        if let current = Self.savedServer() {
            if current.key == invite.server.key {
                pendingInvite = nil
                return "This Mac is already in \(team) as \(current.login)."
            }
            throw AdminProblem.otherDatabase("\(current.database) on \(current.host)")
        }
        TeamDatabase.keep(password: invite.oneTimePassword, for: invite.server)
        Self.save(invite.server)
        pendingInvite = nil
        run(invite.server)
        return "Joined \(team) as \(invite.server.login). Binders changes the one-time password the first time it connects."
    }

    /// What came of an invite you said yes to.
    enum InviteStep: Equatable {
        /// Joined: what to say.
        case joined(String)
        /// This Mac shares through a team folder, so it joins from Move This Team to a Database…, where the invite waits.
        case move
    }

    /// Join, or Turn On and Join, on an invite opened on this Mac (lane DB7). With team databases off (TeamDatabaseFeature)
    /// they go on first, as you chose; then it joins as Join always did. A Mac with a team folder joins from Move This Team
    /// to a Database…, so the invite waits there for it.
    func acceptInvite(_ invite: TeamInvite) async throws -> InviteStep {
        if !TeamDatabaseFeature.isOn { TeamDatabaseFeature.turnOn() }
        if hasFolderTeam && !movingFolderTeam {
            pendingInvite = invite
            return .move
        }
        return .joined(try await join(invite))
    }

    /// Not Now, or Cancel, on an invite: it's let go, and nothing else changes.
    func declineInvite() {
        pendingInvite = nil
    }

    /// Leave the team database on this Mac: it disconnects and forgets its password; binders made here stay as local
    /// binders with their boards as they are, and teammates' binders go from this Mac. What waits in the outbox is let go.
    func leaveDatabase() async {
        guard let server else { return }
        for id in sharedBinders { binderGone(id) }
        await stop()
        TeamDatabase.forget(server)
        if let folder { try? FileManager.default.removeItem(at: folder) }
        Self.save(nil)
        self.server = nil
        state = TeamBoardState()
        sharedChanged()
        if Self.current === self { Self.current = nil }
    }

    /// Moved to a hub (HubMove): this Mac leaves the team database as Leave does, but every binder it shared stays here,
    /// teammates' included, with everything in it, for the hub to keep from now on. Teammates' notes are ordinary notes
    /// here now, as they are on the hub; teammates' meetings and captures stay on this Mac as the copies they were. The
    /// database keeps everything as it is, for teammates who haven't moved yet.
    func leaveDatabaseKeepingBinders() async {
        guard let server else { return }
        let ids = sharedBinders
        await stop()
        for id in ids {
            guard let binder = store.binder(id) else { continue }
            binder.teamDatabaseKey = ""
            binder.teamMadeBy = ""
            for card in controller?.board.cards(in: id) ?? [] { card.teamShadow = "" }
            let binderID: UUID? = id
            for note in (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID && $0.isTeamCopy }))) ?? [] {
                note.isTeamCopy = false
            }
        }
        store.save()
        TeamDatabase.forget(server)
        if let folder { try? FileManager.default.removeItem(at: folder) }
        Self.save(nil)
        self.server = nil
        state = TeamBoardState()
        sharedChanged()
        if Self.current === self { Self.current = nil }
    }

    // MARK: Members

    private func connectedAdmin() throws -> TeamDatabase {
        guard let database, database.status == .connected else { throw AdminProblem.offline }
        guard let me = state.directory.me, state.directory.members[me]?.isAdmin == true else { throw AdminProblem.notAdmin }
        return database
    }

    /// Whether this Mac's member is an admin (every person is one, as the team set it up).
    var isAdmin: Bool {
        state.directory.me.flatMap { state.directory.members[$0]?.isAdmin } ?? false
    }

    /// Add Member…: a person, or a headless agent with its own login and an owner (you, unless another person is chosen).
    /// Returns the invite, to show once.
    func addMember(login: String, name: String, agentName: String? = nil, owner: UUID? = nil) async throws -> TeamInvite {
        let database = try connectedAdmin()
        let login = login.trimmingCharacters(in: .whitespaces).lowercased()
        guard TeamSchema.isValidRoleName(login) else {
            throw AdminProblem.invalid("A login is 2 to 63 lower-case letters, digits or underscores, starting with a letter.")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AdminProblem.invalid("Give them a name.") }
        var agent: (id: UUID, name: String)?
        if let agentName = agentName?.trimmingCharacters(in: .whitespacesAndNewlines), !agentName.isEmpty {
            let ownerName = owner.flatMap { state.directory.members[$0]?.name } ?? state.directory.myName ?? ""
            agent = (UUID(), TeamNames.published(agentName, owner: ownerName))
        }
        var invite = try await database.addMember(login: login, name: name, agent: agent)
        // Who invited, for the question on the Mac that opens it (lane DB7).
        invite.invitedBy = state.directory.myName
        if let agent, let owner, owner != state.directory.me {
            let handed = try await database.call(.handAgent(agent.id, to: owner))
            if let refusal = handed.refusal { throw refusal }
        }
        await readDirectory(database)
        return invite
    }

    /// Reset Password: a new one-time password, and a new invite; the old password stops working.
    func resetPassword(_ member: TeamDirectory.Member) async throws -> TeamInvite {
        let database = try connectedAdmin()
        var invite = try await database.resetPassword(member: member.id, login: member.login)
        invite.invitedBy = state.directory.myName
        await readDirectory(database)
        return invite
    }

    /// Remove: their login stops working, and they see nothing at once. Not yourself.
    func removeMember(_ member: TeamDirectory.Member) async throws {
        let database = try connectedAdmin()
        let result = try await database.call(.removeMember(member.id))
        if let refusal = result.refusal { throw refusal }
        await readDirectory(database)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
