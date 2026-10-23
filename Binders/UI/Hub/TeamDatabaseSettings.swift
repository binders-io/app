import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BindersKit

/// Settings → Team's team database (lane DB2): the status line, with what to check when it's offline; an update the
/// team's database needs, which an admin runs (lane DB5); the members and their agents, which an admin adds, gives new
/// one-time passwords and removes, with each of your headless agents' Auto; and the binders shared through it, with
/// everyone or with some members. A Mac shares through a team folder or a team database, never both. Setting one up and
/// joining with an invite lead Settings → Team on a Mac with no team yet (lane DB7: TeamJoinSheet, TeamSetUpChoiceSheet,
/// TeamInviteQuestion).
struct TeamDatabaseSection: View {
    @Environment(DictationController.self) private var controller
    @State private var updating = false
    @State private var adding = false
    @State private var shown: ShownInvite?
    @State private var sharing: BinderRecord?
    @State private var removing: TeamDirectory.Member?
    @State private var stopping: BinderRecord?
    @State private var leavingBinder: BinderRecord?
    @State private var leaving = false
    @State private var said: String?
    @State private var problem: String?
    /// Copies of notes an earlier Binders made when teammates joined, as an admin's Mac found them (lane DB9).
    @State private var copies: TeamNotes.CopiesFound?
    @State private var showingCopies = false

    var body: some View {
        let team = controller.teamBoard
        Section {
            if team.server == nil {
                notSetUp(team)
            } else {
                setUp(team)
            }
            if let said { StatusLabel(said, .done).font(.caption) }
            if let problem { StatusLabel(problem, .problem).font(.caption) }
        } header: {
            Text("Team database")
        } footer: {
            // What a team database is and what goes to it is Settings → Team's footer, above (lane DB7).
            Text("Every change to a shared board reaches your teammates' Macs in about a second, and two agents can never hold the same card. Each Mac keeps its own copy, so Binders works offline. Your agents run only on this Mac: teammates see their names, what they're for and what they're doing, never how Binders starts them.")
        }
        // The default turned on while Binders runs: a database already set up connects now, not at the next launch.
        .onAppear { team.start() }
        // An admin's Mac looks for copies an earlier Binders made, once it's connected (lane DB9). Reading only.
        .task(id: team.isConnected && team.isAdmin) {
            guard team.isConnected, team.isAdmin else { return }
            copies = try? await team.notes.findCopies()
        }
        .sheet(isPresented: $showingCopies) {
            if let copies { TeamNoteCopiesSheet(found: copies) { self.copies = $0 } }
        }
        .sheet(isPresented: $updating) { TeamDatabaseUpdateSheet { said = $0 } }
        .sheet(isPresented: $adding) { TeamAddMemberSheet { shown = $0 } }
        .sheet(item: $shown) { TeamInviteSheet(shown: $0) }
        .sheet(item: $sharing) { TeamShareSheet(binder: $0) }
        .confirmationDialog("Remove \(removing?.name ?? "them") from the team?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { member in
            Button("Remove", role: .destructive) { act { try await controller.teamBoard.removeMember(member); return "Removed \(member.name) from the team." } }
        } message: { member in
            Text("\(member.name)'s login stops working, and they see nothing of the team's binders from now on.")
        }
        .confirmationDialog("Stop sharing “\(stopping?.name ?? "")”?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            presenting: stopping) { binder in
            Button("Stop Sharing", role: .destructive) {
                controller.teamBoard.stopSharing(binder)
                said = "“\(binder.name)” is shared with no one now."
            }
        } message: { _ in
            Text("Teammates lose its board. It stays on this Mac, and in the team database with only you in it, so sharing it again brings everyone back to the same board.")
        }
        .confirmationDialog("Leave “\(leavingBinder?.name ?? "")”?", isPresented: Binding(get: { leavingBinder != nil }, set: { if !$0 { leavingBinder = nil } }),
                            presenting: leavingBinder) { binder in
            Button("Leave", role: .destructive) {
                controller.teamBoard.leave(binder)
                said = "You left “\(binder.name)”: its board goes from this Mac."
            }
        } message: { binder in
            Text("Its board goes from this Mac. \(binder.teamMadeBy.isEmpty ? "An admin" : binder.teamMadeBy) can share it with you again.")
        }
        .confirmationDialog("Leave the team database on this Mac?", isPresented: $leaving) {
            Button("Leave", role: .destructive) { Task { await controller.teamBoard.leaveDatabase(); said = "This Mac left the team database." } }
        } message: {
            Text("Binders made on this Mac stay here with their boards as they are. Teammates' binders go from this Mac. Changes still waiting to be sent are let go.")
        }
    }

    // MARK: Before there's one

    /// A Mac in a team folder; or one with a team database saved, a moment before it starts. With no team at all, Settings
    /// → Team leads with Join a Team… and Set Up a Team… instead, and this part doesn't show (lane DB7).
    @ViewBuilder
    private func notSetUp(_ team: TeamBoard) -> some View {
        if team.hasFolderTeam {
            Text("This Mac shares through a team folder. A Mac shares one way: leave the team folder first to use a team database.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            StatusLabel("Connecting to the team database…", .waiting)
        }
    }

    // MARK: Once there is one

    @ViewBuilder
    private func setUp(_ team: TeamBoard) -> some View {
        let status = team.status
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 4) {
                // Connected, but not answering (lane DB8): said as a problem, with what waits.
                if status.isConnected, team.database?.stalledSince != nil {
                    StatusLabel(TeamBoardWrites.notAnswering, .problem)
                } else {
                    StatusLabel(status.summary(now: context.date), status.isConnected ? .ready : status == .connecting ? .waiting : .problem)
                }
                if let check = status.check { Text(check).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let waiting = team.database?.waiting, waiting > 0 {
                    Text(waiting == 1 ? "1 change waits on this Mac to go." : "\(waiting) changes wait on this Mac to go.").font(.caption).foregroundStyle(.secondary)
                }
                // The team's knowledge (lane DB4): whose embedding model, and whether meanings go both ways.
                if let line = team.content.knowledge.line {
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let update = team.database?.update {
            updateNeeded(update)
        }
        if let server = team.server {
            LabeledContent("Database") {
                Text("\(server.database) on \(server.host)\(server.port == 5432 ? "" : ":\(server.port)")").textSelection(.enabled)
            }
            LabeledContent("You") {
                Text("\(team.directory.myName ?? "…") (\(server.login))\(team.isAdmin ? ", an admin" : "")").foregroundStyle(.secondary)
            }
        }
        members(team)
        binders(team)
        if team.isAdmin, let copies, !copies.found.copies.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(copies.found.copies.count == 1 ? "Binders found a copy of a note, made when a teammate joined or this Mac connected."
                     : "Binders found \(copies.found.copies.count) copies of notes, made when teammates joined or this Mac connected.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Remove Copies Made When Teammates Joined…") { showingCopies = true }
                    .fitProbe("team.copies")
            }
            .padding(.vertical, 2)
        }
        HStack {
            if team.isAdmin { Button("Add Member…") { adding = true }.disabled(!team.isConnected) }
            Spacer()
            Button("Leave This Team Database…", role: .destructive) { leaving = true }
        }
    }

    /// The team's database needs an update this Binders brings: an admin runs it here; anyone else is told who can.
    @ViewBuilder
    private func updateNeeded(_ update: TeamDatabase.UpdateNeeded) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The team's database needs an update that this version of Binders brings. Until it has it, this Mac doesn't connect: your changes wait here, and teammates' changes arrive once it's updated.")
                .fixedSize(horizontal: false, vertical: true)
            if update.youAreAdmin {
                Button("Update the Team Database…") { updating = true }
                    .buttonStyle(.borderedProminent)
                    .fitProbe("team.update")
                Text("It asks for the server's admin login once, and doesn't keep it. Teammates on an earlier Binders can't connect until they update Binders too.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Self.askAdmins(update.otherAdmins)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// "Ask Sam or Dana to update it: …", for someone who isn't an admin.
    static func askAdmins(_ admins: [String]) -> String {
        guard !admins.isEmpty else { return "Ask an admin of the team to update it: they run it once, from Settings → Team." }
        return "Ask \(admins.formatted(.list(type: .or))) to update it: an admin runs it once, from Settings → Team."
    }

    @ViewBuilder
    private func members(_ team: TeamBoard) -> some View {
        let directory = team.directory
        let people = directory.members.values.filter { !$0.removed }.sorted { a, b in
            a.id == directory.me ? true : b.id == directory.me ? false : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        ForEach(people) { member in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.id == directory.me ? "\(member.name) (you)" : member.name)
                    Text(Self.memberLine(member, me: directory.me)).font(.caption).foregroundStyle(.secondary)
                    let agents = directory.agents.values.filter { !$0.removed && $0.owner == member.id && $0.kind != "session" }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    ForEach(agents) { agent in
                        Text(Self.agentLine(agent, directory: directory)).font(.caption).foregroundStyle(.secondary)
                        // Your headless agents' Auto: only you, their owner, turn it on (migration 8).
                        if agent.isHeadless, directory.isMine(agent) {
                            autoSwitch(agent, directory: directory, team: team)
                        }
                    }
                }
                Spacer()
                if team.isAdmin, member.id != directory.me {
                    Menu("Manage") {
                        Button("Reset Password…") { act { shown = ShownInvite(invite: try await controller.teamBoard.resetPassword(member), who: member.name); return nil } }
                        Button("Remove…", role: .destructive) { removing = member }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!team.isConnected)
                }
            }
        }
    }

    /// The Auto switch on one of your headless agents, with what it lets the agent do.
    private func autoSwitch(_ agent: TeamDirectory.Agent, directory: TeamDirectory, team: TeamBoard) -> some View {
        let name = directory.name(of: agent)
        return Toggle(isOn: Binding(get: { agent.auto ?? false }, set: { on in
            act {
                try await controller.teamBoard.setAuto(agent, on: on)
                return on ? "Auto is on for \(name): it takes cards on its own now." : "Auto is off for \(name): it takes no card until you turn it on."
            }
        })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto").font(.caption)
                Text(Self.autoLine(name)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!team.isConnected)
        .padding(.leading, 12)
        .fitProbe("team.auto")
    }

    /// What a headless agent's Auto lets it do, in one line.
    static func autoLine(_ name: String) -> String {
        "Lets \(name) take cards on its own, in the binders shared with it. Off, it can read, report and ask, but take no card."
    }

    /// "Admin · seen 10:42", "A headless agent's login · not seen yet".
    static func memberLine(_ member: TeamDirectory.Member, me: UUID?) -> String {
        var parts = [member.kind == "agent" ? "A headless agent's login" : member.isAdmin ? "Admin" : "Member"]
        if member.id != me {
            parts.append(member.seenAt.map { "seen \(Self.when($0))" } ?? "not seen yet")
        }
        return parts.joined(separator: " · ")
    }

    /// "Claude Code (Dana): working on a card · online", "Grok Bot (Sam): ready · online 2 hours ago", and for a headless
    /// agent whether its owner turned its Auto on: "Build bot (Dana) · online · Auto on".
    static func agentLine(_ agent: TeamDirectory.Agent, directory: TeamDirectory) -> String {
        let status = agent.status.isEmpty ? "" : ": \(agent.runningCard != nil ? "working on a card" : agent.status)"
        let online = agent.isOnline() ? "online" : agent.onlineAt.map { "online \(Self.when($0))" } ?? "not online yet"
        let starts = agent.isHeadless
            ? ((agent.auto ?? false) ? " · Auto on: takes cards on its own" : " · Auto off: takes no cards")
            : (agent.takesTeamCards ? " · starts on teammates' cards" : "")
        return "\(directory.name(of: agent))\(status) · \(online)\(starts)"
    }

    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private func binders(_ team: TeamBoard) -> some View {
        let all = Store.shared.binders().filter { !$0.isTeamCopy }
        if !all.isEmpty {
            Text("Binders").font(.headline).padding(.top, 4)
            ForEach(all) { binder in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(binder.name)
                        Text(Self.sharingLine(binder, team: team)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if Self.keptByFolder(binder, team: team) {
                        EmptyView()
                    } else if !team.covers(binder.id) {
                        Menu("Share") {
                            Button("With Everyone") { share(binder, everyone: true) }
                            Button("With…") { sharing = binder }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else if binder.teamMadeBy.isEmpty {
                        Menu("Sharing") {
                            Button("Change Who…") { sharing = binder }
                            Button("Stop Sharing…", role: .destructive) { stopping = binder }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else {
                        Button("Leave…") { leavingBinder = binder }
                    }
                }
            }
        }
    }

    /// A binder the team folder this Mac still syncs shares: it stays the folder's until the move (lane DB9).
    static func keptByFolder(_ binder: BinderRecord, team: TeamBoard) -> Bool {
        AppSettings.shared.teamFolderPath != nil && (binder.sharedWithTeam || binder.isTeamCopy)
    }

    /// "Not shared", "Shared with everyone", "Shared with Dana and Robin", "From Dana".
    static func sharingLine(_ binder: BinderRecord, team: TeamBoard) -> String {
        if keptByFolder(binder, team: team) { return "Shared through the team folder, until Move This Team to a Database… brings it over" }
        guard team.covers(binder.id) else { return "Not shared" }
        if !binder.teamMadeBy.isEmpty { return "From \(binder.teamMadeBy)" }
        if team.state.binders[binder.id]?.everyone == true { return "Shared with everyone" }
        let names = (team.state.binderMembers[binder.id] ?? []).filter { $0 != team.directory.me }.compactMap { team.directory.memberName($0) }.sorted()
        return names.isEmpty ? "Shared with no one but you" : "Shared with \(names.formatted(.list(type: .and)))"
    }

    private func share(_ binder: BinderRecord, everyone: Bool) {
        controller.teamBoard.share(binder, everyone: everyone, with: [])
        said = "Shared “\(binder.name)” with everyone. Its board goes to the team as it is."
    }

    /// Runs an admin's step, saying what came of it.
    private func act(_ work: @escaping @MainActor () async throws -> String?) {
        Task { @MainActor in
            do {
                if let words = try await work() { said = words }
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// An invite to show once, with whom it's for.
struct ShownInvite: Identifiable {
    let id = UUID()
    let invite: TeamInvite
    let who: String
}

// MARK: Sheets

/// Set Up a Team Database: the server, its admin login (used for this once and never kept), the team's name and yours.
struct TeamDatabaseSetUpSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let done: (String) -> Void
    @State private var host = ""
    @State private var port = "5432"
    @State private var database = "binders_team"
    @State private var serverName = ""
    @State private var adminLogin = ""
    @State private var adminPassword = ""
    @State private var teamName = ""
    @State private var yourName = AppSettings.shared.teamMemberName.isEmpty ? NSFullUserName() : AppSettings.shared.teamMemberName
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                StackedField(label: "Server", text: $host, prompt: "team-db.postgres.database.azure.com", probe: "field.teamdb.server")
                TextField("Port", text: $port)
                StackedField(label: "Database", text: $database, probe: "field.teamdb.database")
                if Self.isAddress(host) {
                    StackedField(label: "Name on its certificate", text: $serverName, prompt: "The server's name, which its certificate carries",
                                 probe: "field.teamdb.serverName")
                }
            } header: {
                Text("The server")
            } footer: {
                Text("Postgres 15 or later with pgvector, reachable from this Mac inside your VPN. Binders connects only with TLS, and checks the server's certificate.")
            }
            Section {
                StackedField(label: "Admin login", text: $adminLogin, probe: "field.teamdb.adminLogin")
                StackedField(label: "Admin password", text: $adminPassword, secure: true, probe: "field.teamdb.adminPassword")
            } header: {
                Text("The server's admin login")
            } footer: {
                Text("Used once, to make the team's roles and tables, and never kept. Members get logins of their own.")
            }
            Section {
                StackedField(label: "Team name", text: $teamName, probe: "field.teamdb.teamName")
                StackedField(label: "Your name in the team", text: $yourName, probe: "field.teamdb.yourName")
            } footer: {
                Text("You become the team's first member, and an admin. This Mac makes your password and keeps it in its Keychain.")
            }
            if let problem { StatusLabel(problem, .problem).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Setting Up…" : "Set Up") { setUp() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || host.isEmpty || adminLogin.isEmpty || adminPassword.isEmpty || teamName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func setUp() {
        working = true
        Task { @MainActor in
            do {
                let words = try await controller.teamBoard.setUp(host: host, port: Int(port) ?? 0, database: database, serverName: serverName, adminLogin: adminLogin,
                                                                 adminPassword: adminPassword, teamName: teamName, yourName: yourName)
                adminPassword = ""
                done(words)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }

    static func isAddress(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespaces)
        return !host.isEmpty && (host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":"))
    }
}

/// Update the Team Database…: the server's admin login (used for this once and never kept), to bring the team's database
/// up to date with what this Binders brings, as Set Up does it.
struct TeamDatabaseUpdateSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let done: (String) -> Void
    @State private var adminLogin = ""
    @State private var adminPassword = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                if let server = controller.teamBoard.server {
                    LabeledContent("Database") { Text("\(server.database) on \(server.host)").textSelection(.enabled) }
                }
                StackedField(label: "Admin login", text: $adminLogin, probe: "field.teamdb.update.adminLogin")
                StackedField(label: "Admin password", text: $adminPassword, secure: true, probe: "field.teamdb.update.adminPassword")
            } header: {
                Text("The server's admin login")
            } footer: {
                Text("Used once, to bring the team's database up to date, and never kept. Everything in it stays as it is. Teammates on an earlier Binders can't connect until they update Binders too.")
            }
            if let problem { StatusLabel(problem, .problem).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Updating…" : "Update") { update() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || adminLogin.trimmingCharacters(in: .whitespaces).isEmpty || adminPassword.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private func update() {
        working = true
        Task { @MainActor in
            do {
                let words = try await controller.teamBoard.updateDatabase(adminLogin: adminLogin, adminPassword: adminPassword)
                adminPassword = ""
                done(words)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }
}

/// Paste Invite Link…: a binders://team/join link a teammate sent privately.
struct TeamInviteLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let opened: (TeamInvite) -> Void
    @State private var link = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste the invite link a teammate sent you").font(.headline)
            TextField("binders://team/join?…", text: $link).textFieldStyle(.roundedBorder).frame(width: 440)
            if let problem { StatusLabel(problem, .problem).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open") {
                    guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), let invite = TeamInvite(link: url) else {
                        problem = "That isn't a Binders invite link."
                        return
                    }
                    opened(invite)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}

// MARK: Joining and setting up (lane DB7)

/// Where Settings → Team goes once Join a Team… or Set Up a Team… closes.
enum TeamNextStep: Equatable {
    /// Set Up a Team Database….
    case database
    /// A shared folder: Create team space…, or Join through a shared folder….
    case createFolder, joinFolder
}

/// An invite opened on this Mac (a link, or a file from Finder), asking before it joins. While team databases are off it
/// asks once whether to turn them on too: Turn On and Join, or Cancel, which changes nothing. A Mac in a team folder goes
/// on to Move This Team to a Database…, where the invite waits.
struct TeamInviteQuestion: View {
    @Environment(DictationController.self) private var controller
    let invite: TeamInvite
    let featureOn: Bool
    let folderTeam: Bool
    /// What came of it, and what went wrong.
    let said: (String) -> Void
    let failed: (String) -> Void
    /// Opens Move This Team to a Database….
    let move: () -> Void
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TeamDatabaseFeature.question(invite, turningOn: !featureOn)).font(.headline)
            Text(TeamDatabaseFeature.detail(invite, turningOn: !featureOn, folderTeam: folderTeam))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(featureOn ? "Join" : "Turn On and Join") { accept() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                    .fitProbe(featureOn ? "team.invite.join" : "team.invite.turnOn")
                Button(featureOn ? "Not Now" : "Cancel") { controller.teamBoard.declineInvite() }
            }
        }
        .padding(.vertical, 2)
    }

    private func accept() {
        working = true
        Task { @MainActor in
            do {
                switch try await controller.teamBoard.acceptInvite(invite) {
                case .joined(let words): said(words)
                case .move: move()
                }
            } catch {
                failed(error.localizedDescription)
            }
            working = false
        }
    }
}

/// Join a Team…: the invite a teammate sent, its link pasted or its file chosen, joined straight to the team's database.
/// A team that shares a folder is the second way, at the bottom: Join through a shared folder….
struct TeamJoinSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let joined: (String) -> Void
    /// Join through a shared folder…: Settings → Team asks for the folder once this closes.
    let throughFolder: () -> Void
    @State private var link: String
    @State private var invite: TeamInvite?
    @State private var problem: String?
    @State private var working = false

    /// `link`: an invite link already in the field (the self-tests draw it so).
    init(link: String = "", joined: @escaping (String) -> Void, throughFolder: @escaping () -> Void) {
        _link = State(initialValue: link)
        _invite = State(initialValue: Self.invite(in: link))
        self.joined = joined
        self.throughFolder = throughFolder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join a team").font(.headline)
            Text("Open the invite a teammate sent you, and this Mac joins your team's database. Paste its link, or choose its file.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Invite link", text: $link, prompt: Text("binders://team/join?…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onChange(of: link) { read() }
                Text("or").foregroundStyle(.secondary)
                Button("Choose Invite File…") { choose() }
            }
            if let invite {
                VStack(alignment: .leading, spacing: 3) {
                    Text(TeamDatabaseFeature.question(invite, turningOn: false)).font(.body.weight(.semibold))
                    Text(TeamDatabaseFeature.detail(invite, turningOn: false, folderTeam: false))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(BindersTheme.surface))
            }
            if let problem { StatusLabel(problem, .problem).font(.caption).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Button("Join through a shared folder…") {
                    throughFolder()
                    dismiss()
                }
                .help("For a team that shares a folder synced by OneDrive, Dropbox, Google Drive or iCloud Drive")
                .fitProbe("team.join.folder")
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Joining…" : "Join") { join() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(invite == nil || working)
                    .fitProbe("team.join.join")
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// The invite in what was pasted, if it is one.
    static func invite(in text: String) -> TeamInvite? {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(TeamInvite.init(link:))
    }

    /// What the field holds, read as it changes.
    private func read() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        invite = Self.invite(in: text)
        problem = text.isEmpty || invite != nil ? nil : Self.notALink
    }

    static let notALink = "That isn't a Binders invite link. One starts with binders://team/join."

    /// Choose Invite File…: a .binders-invite file a teammate sent. Its link goes in the field, so what's joined is shown.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: TeamInvite.fileExtension) ?? .json, .json]
        panel.message = "Choose the invite a teammate sent you privately."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let found = TeamInvite(fileData: data), let text = found.link?.absoluteString else {
            problem = "That file isn't a Binders invite."
            return
        }
        link = text
        invite = found
        problem = nil
    }

    private func join() {
        guard let invite else { return }
        working = true
        Task { @MainActor in
            do {
                let words = try await controller.teamBoard.join(invite)
                joined(words)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }
}

/// Set Up a Team…: on a team database (Set Up a Team Database…) or in a shared folder (Create team space…), the database
/// first. Choosing one closes this and goes on to it.
struct TeamSetUpChoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chose: (TeamNextStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up a team").font(.headline)
            choice("A team database", detail: "A server your team runs, which Binders reaches through your own network or VPN. Changes reach your teammates' Macs in about a second, and you invite each of them from Settings → Team.",
                   button: "Set Up a Team Database…", step: .database, probe: "team.setUp.database")
            Divider()
            choice("A shared folder", detail: "A folder in OneDrive, Dropbox, Google Drive or iCloud Drive that you share with your team. There's no server: teammates join by choosing the folder.",
                   button: "Create team space…", step: .createFolder, probe: "team.setUp.folder")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func choice(_ title: String, detail: String, button: String, step: TeamNextStep, probe: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Group {
                if step == .database {
                    Button(button) { go(step) }.buttonStyle(.borderedProminent)
                } else {
                    Button(button) { go(step) }
                }
            }
            .fitProbe(probe)
        }
    }

    private func go(_ step: TeamNextStep) {
        chose(step)
        dismiss()
    }
}

/// Add Member…: a person, or a headless agent with its own login and an owner. The invite follows, shown once.
struct TeamAddMemberSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let added: (ShownInvite) -> Void
    @State private var headless = false
    @State private var name = ""
    @State private var login = ""
    @State private var loginEdited = false
    @State private var agentName = ""
    @State private var owner: UUID?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        let directory = controller.teamBoard.directory
        Form {
            Picker("Add", selection: $headless) {
                Text("A person").tag(false)
                Text("A headless agent").tag(true)
            }
            .pickerStyle(.segmented)
            StackedField(label: headless ? "Its login's name, such as Build server" : "Their name", text: $name, probe: "field.teamdb.member.name")
                .onChange(of: name) { _, typed in if !loginEdited { login = TeamNames.login(for: typed, taken: Set(directory.members.values.map(\.login))) } }
            StackedField(label: "Login", text: Binding(get: { login }, set: { login = $0; loginEdited = true }), probe: "field.teamdb.member.login")
            if headless {
                StackedField(label: "The agent's name on the boards", text: $agentName, probe: "field.teamdb.member.agentName")
                Picker("Its owner", selection: Binding(get: { owner ?? directory.me }, set: { owner = $0 })) {
                    ForEach([directory.me].compactMap { $0 } + directory.teammates.map(\.id), id: \.self) { id in
                        Text(id == directory.me ? "You" : directory.memberName(id) ?? "A teammate").tag(Optional(id))
                    }
                }
                Text("It acts on the team's boards under its own login, only in the binders shared with it. Its Auto starts off: it takes no card until its owner turns Auto on, here in Settings → Team.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { StatusLabel(problem, .problem).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Adding…" : "Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || login.isEmpty || (headless && agentName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private func add() {
        working = true
        Task { @MainActor in
            do {
                let invite = try await controller.teamBoard.addMember(login: login, name: name, agentName: headless ? agentName : nil,
                                                                      owner: headless ? owner : nil)
                added(ShownInvite(invite: invite, who: name))
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }
}

/// An invite, shown once: Copy Invite (the link) or Save Invite… (the file), and to send it privately.
struct TeamInviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let shown: ShownInvite
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("An invite for \(shown.who) (\(shown.invite.server.login))").font(.headline)
            Text(TeamInvite.sendPrivately + " Binders doesn't keep it: copy or save it now.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(shown.invite.link?.absoluteString ?? "").font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(BindersTheme.surface))
            if copied { StatusLabel("Copied. Paste it into a private message.", .done).font(.caption) }
            HStack {
                Button("Copy Invite") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.invite.link?.absoluteString ?? "", forType: .string)
                    copied = true
                }
                Button("Save Invite…") { save() }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = shown.invite.fileName
        panel.message = TeamInvite.sendPrivately
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? shown.invite.fileData().write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Share with…, or Change Who…: everyone in the team, or the members ticked. You stay in it.
struct TeamShareSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let binder: BinderRecord
    @State private var everyone = false
    @State private var chosen: Set<UUID> = []

    var body: some View {
        let team = controller.teamBoard
        VStack(alignment: .leading, spacing: 10) {
            Text("Share “\(binder.name)”").font(.headline)
            Toggle("Everyone in the team, and whoever joins", isOn: $everyone)
            if !everyone {
                ForEach(team.directory.teammates) { member in
                    Toggle(member.name, isOn: Binding(get: { chosen.contains(member.id) }, set: { if $0 { chosen.insert(member.id) } else { chosen.remove(member.id) } }))
                }
                if team.directory.teammates.isEmpty {
                    Text("No one else is in the team yet. Add Member… makes an invite.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(team.covers(binder.id) ? "Those you take out lose its board." : "Its board goes to the team as it is: every card, who has it and what it waits for. A card made from what your iPhone heard stays on this Mac until you share it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(team.covers(binder.id) ? "Change" : "Share") {
                    team.share(binder, everyone: everyone, with: chosen)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            everyone = team.state.binders[binder.id]?.everyone ?? false
            chosen = (team.state.binderMembers[binder.id] ?? []).subtracting(team.directory.me.map { [$0] } ?? [])
        }
    }
}

/// Remove Copies Made When Teammates Joined… (lane DB9): every copy it would remove, with who made it, when and where, and
/// every note it leaves that shares a title with another's but not its words, for you to look at yourself. Remove asks
/// once, then removes them for everyone.
struct TeamNoteCopiesSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State var found: TeamNotes.CopiesFound
    var done: (TeamNotes.CopiesFound) -> Void
    @State private var confirming = false
    @State private var working = false
    @State private var said: String?
    @State private var problem: String?

    var body: some View {
        let copies = found.found.copies
        VStack(alignment: .leading, spacing: 12) {
            Text("Copies made when teammates joined").font(.headline)
            Text("When this Mac connected to the team database, or a teammate joined from their team-folder copies, an earlier Binders shared some notes again as new notes. Each copy here has the same title and the same words, to the character, as a note that stays. Removing them removes them for everyone: each teammate's Mac follows as it catches up.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let refusal = found.refusal {
                StatusLabel(refusal, .problem).font(.callout).fixedSize(horizontal: false, vertical: true)
            } else if let caution = found.caution, said == nil {
                Text(caution).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            List {
                Section("To remove (\(copies.count))") {
                    ForEach(copies) { copy in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(copy.note.title.isEmpty ? "Untitled" : copy.note.title)
                            Text(found.line(copy.note)).font(.caption).foregroundStyle(.secondary)
                            Text("The one that stays: \(found.line(copy.keeps))").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !found.found.near.isEmpty {
                    Section("Left as they are: the same title, other words (\(found.found.near.count))") {
                        ForEach(found.found.near) { note in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title.isEmpty ? "Untitled" : note.title)
                                Text(found.line(note)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(height: 320)
            if found.changing > 0 {
                Text(found.changing == 1 ? "One more is left for now: it's changing on this Mac. Look again once Settings → Team says nothing waits to go."
                     : "\(found.changing) more are left for now: they're changing on this Mac. Look again once Settings → Team says nothing waits to go.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let said { StatusLabel(said, .done).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let problem { StatusLabel(problem, .problem).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(said == nil ? "Cancel" : "Done") { dismiss() }
                if said == nil {
                    Button(working ? "Removing…" : copies.count == 1 ? "Remove 1 Copy…" : "Remove \(copies.count) Copies…") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || copies.isEmpty || found.refusal != nil)
                        .fitProbe("team.copies.remove")
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .confirmationDialog(copies.count == 1 ? "Remove 1 copy for everyone in the team?" : "Remove \(copies.count) copies for everyone in the team?",
                            isPresented: $confirming) {
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("Each has the same title and words as a note that stays. Teammates' Macs remove them as they catch up.")
        }
    }

    private func remove() {
        working = true
        problem = nil
        Task { @MainActor in
            let notes = controller.teamBoard.notes
            do {
                let count = try await notes.removeCopies()
                said = count == 1 ? "Removed 1 copy. Teammates' Macs remove it as they catch up." : "Removed \(count) copies. Teammates' Macs remove them as they catch up."
                found.found.copies = []
                done(found)
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }
}
