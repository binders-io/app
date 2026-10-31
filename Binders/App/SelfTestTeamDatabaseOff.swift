import AppKit
import CryptoKit
import SwiftUI
import BindersKit

extension SelfTest {
    /// The team database held back from 0.10.0 behind its default, `teamDatabase` (TeamDatabaseFeature), in a throwaway
    /// folder (BINDERS_DATA_DIR), on a Mac with a team database already set up (a saved server that's never reached). Off,
    /// the default: Settings → Team shows no database part, nothing connects at launch, Settings → Agents has no "Take cards
    /// from teammates", Binders' MCP server names no teammates and its instructions are as they always were, and a binder
    /// shared through the database doesn't say so. On: each of those as lanes DB2–DB4 built them, and the MCP instructions
    /// say binders shared with a team are on its database. Turned off while Binders runs (lane DB5), it disconnects at once
    /// and hides everything, as at launch; on again, it connects. Then a teammate's Mac with no team (lane DB7,
    /// `teammateJoinsChecks`), offered a hub's Sign In rather than a new team database. Draws Settings → Team in each state
    /// to `directory`, when one is given.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-team-database-off [dir] -notesShowMarkdown NO
    @MainActor
    static func teamDatabaseOffSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test saves a team database's address there")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        FitProbe.isOn = true
        defer { FitProbe.isOn = false }
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let controller = DictationController()
        // A team database set up on this Mac, as Settings → Team saves it: an address on a reserved test network nothing
        // answers on.
        let server = TeamDatabaseServer(host: "192.0.2.10", port: 5432, database: "binders", login: "sam", serverName: "Harbor team")
        TeamBoard.save(server)
        let shared = BinderRecord(name: "Harbor shared", colorIndex: 4)
        shared.teamDatabaseKey = server.key
        Store.shared.insert(shared)
        let invite = TeamInvite(server: TeamDatabaseServer(host: "192.0.2.11", database: "binders", login: "robin"), oneTimePassword: "one-time-pass-123",
                                teamName: "Harbor team", invitedBy: "Sam")
        AppSettings.shared.teamMemberName = "Sam"

        /// Settings → Team in a window as tall as the page, so every part of it is drawn; whether the database part showed.
        func teamPage(_ name: String) async -> Bool {
            await teamSettingsDrawn(controller: controller, name: name, directory: directory).contains("team.database")
        }
        /// Settings → Agents' editor for a Claude Code agent, drawn whole; whether "Take cards from teammates" showed.
        func agentEditor() async -> Bool {
            let agent = AgentProfile(name: "Claude Code · app", wake: .claudeCode(ClaudeCodeWake(repository: "/tmp/app", permissionMode: "plan")), preset: "claude-code")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 3200), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: AgentEditor(agent: agent, isNew: false).modelContainer(Store.shared.container))
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1_500))
            let shown = !FitProbe.frames("agents.takeTeammatesCards", in: window).isEmpty
            window.close()
            return shown
        }
        func openInvite() {
            if let link = invite.link { URLCommands.handle(link, controller: controller) }
        }
        func eventually(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }
        /// Binders' MCP instructions as they were before the team database had words in them (lane DB5 keeps them).
        func asBefore(_ text: String) -> Bool {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                == "5b5648f7544a791ce2844a2c90636519285a881a28bdfa02f9a6d44606d4305b"
        }

        // Off, the default.
        AppDefaults.store.removeObject(forKey: TeamDatabaseFeature.key)
        check(!TeamDatabaseFeature.isOn, "the team database is off unless its default is set")
        check(AppSettings.shared.teamDatabase != nil && TeamBoard.savedServer() == nil && TeamBoard.savedDirectory() == nil,
              "a team database set up on this Mac stays saved, and is left alone")
        controller.teamBoard.start()
        check(controller.teamBoard.database == nil && controller.teamBoard.status == .off && !controller.teamBoard.covers(shared.id),
              "nothing connects at launch, and no board goes through it")
        check(!(await teamPage("team-database-off")), "Settings → Team shows only the shared-folder way: no team database part")
        check(!(await agentEditor()), "Settings → Agents has no Take cards from teammates")
        // An invite asks before anything changes (lane DB7): checked whole on a Mac with no team, at the end.
        openInvite()
        check(controller.teamBoard.pendingInvite == invite && controller.flowBar.model.toastText.isEmpty && !TeamDatabaseFeature.isOn,
              "a binders://team/join link waits in Settings → Team for a yes, and turns nothing on")
        controller.teamBoard.declineInvite()
        URLCommands.openInvite(invite, controller: controller)
        check(controller.teamBoard.pendingInvite == invite && !TeamDatabaseFeature.isOn, "so does a .binders-invite file, which goes the same way")
        controller.teamBoard.declineInvite()
        check(controller.teamBoard.pendingInvite == nil && !TeamDatabaseFeature.isOn && controller.teamBoard.database == nil,
              "Cancel lets it go: still off, nothing connected")
        check(shared.sharedThroughDatabase && !shared.shownSharedThroughDatabase, "a binder shared through it doesn't say so")
        check(asBefore(MCPServer.instructions) && MCPServer.instructions == MCPServer.instructions(team: false),
              "Binders' MCP instructions are exactly as they were")

        // The switch and the saved database are kept apart: turning it on leaves the address as it was.
        let savedText = AppDefaults.store.string(forKey: AppSettings.teamDatabaseServerKey)
        check(savedText != nil && AppDefaults.store.object(forKey: TeamDatabaseFeature.key) == nil, "the saved database has a key of its own")
        // One an earlier build saved under the switch's key moves to its own, once; a switch that's set stays.
        if let scratch = UserDefaults(suiteName: AppPaths.support.appendingPathComponent("defaults-move").path) {
            scratch.set(savedText, forKey: TeamDatabaseFeature.key)
            AppSettings.moveTeamDatabaseServer(in: scratch)
            check(scratch.string(forKey: AppSettings.teamDatabaseServerKey) == savedText && scratch.object(forKey: TeamDatabaseFeature.key) == nil,
                  "a database an earlier build saved under teamDatabase moves to its own key, and the team database stays off")
            scratch.set(true, forKey: TeamDatabaseFeature.key)
            AppSettings.moveTeamDatabaseServer(in: scratch)
            check(scratch.bool(forKey: TeamDatabaseFeature.key) && scratch.string(forKey: AppSettings.teamDatabaseServerKey) == savedText, "a switch that's set stays set")
        }

        // On, as the founder turns it on at home.
        AppDefaults.store.set(true, forKey: TeamDatabaseFeature.key)
        check(AppDefaults.store.string(forKey: AppSettings.teamDatabaseServerKey) == savedText, "turning it on leaves the saved database as it was")
        check(TeamDatabaseFeature.isOn && TeamBoard.savedServer() == server, "on: its saved server is there again, read as the default changed")
        check(shared.shownSharedThroughDatabase, "the binder says it's shared through it")
        check(await agentEditor(), "Settings → Agents has Take cards from teammates")
        openInvite()
        check(controller.teamBoard.pendingInvite == invite, "a binders://team/join link opens in Settings → Team, waiting for Join")
        controller.teamBoard.pendingInvite = nil
        check(await teamPage("team-database-on"), "Settings → Team shows the team database part")
        check(TeamDatabaseFeature.way == .database && SettingsPage.team.summary == "Sharing binders through a team database.",
              "on a team database, Settings → Team's subtitle says so: \(SettingsPage.team.summary)")
        // Settings → Team's database part connects one already set up, as a launch would.
        check(controller.teamBoard.database != nil && controller.teamBoard.server == server, "the database already set up is connected to as Settings → Team opens")
        // Binders' MCP instructions say so, worked out from what Settings → Team saved, without connecting (lane DB5).
        let instructions = MCPServer.instructions
        check(instructions.contains("Binders keeps it on this Mac, and binders the user shares with a team are on the team's database too, but")
                && instructions.contains("Say who you are with `agent`. On a board the user shares with a team, every change you make reaches the team's other Macs")
                && instructions.replacingOccurrences(of: "and binders the user shares with a team are on the team's database too, ", with: "")
                    .replacingOccurrences(of: MCPServer.teamBoardWords + " ", with: "") == MCPServer.instructions(team: false),
              "with a team database set up here, Binders' MCP instructions say binders shared with a team are on its database, and how a shared board works")

        // Turned off while Binders runs (lane DB5): it disconnects at once and hides everything, as at launch with it off.
        let team = controller.teamBoard
        AppDefaults.store.removeObject(forKey: TeamDatabaseFeature.key)
        let off = await eventually(5) { team.database == nil && team.server == nil }
        check(off && team.status == .off && !team.covers(shared.id) && TeamBoard.current == nil && !shared.shownSharedThroughDatabase,
              "turned off while Binders runs, it disconnects at once, and no board goes through it")
        check(!(await teamPage("team-database-turned-off")), "Settings → Team shows only the shared-folder way again")
        check(!(await agentEditor()), "Settings → Agents has no Take cards from teammates again")
        check(TeamBoard.savedDirectory() == nil && asBefore(MCPServer.instructions), "Binders' MCP server names no teammates, and its instructions are as they were")
        check(AppSettings.shared.teamDatabase != nil, "the database set up here stays saved, for when it's on again")
        // On again: it connects to it.
        AppDefaults.store.set(true, forKey: TeamDatabaseFeature.key)
        let on = await eventually(5) { team.database != nil && team.server == server }
        check(on && TeamBoard.current === team && team.covers(shared.id), "on again, it connects to the database set up here")
        await controller.teamBoard.stop()

        AppDefaults.store.removeObject(forKey: TeamDatabaseFeature.key)
        TeamBoard.save(nil)
        failures += await teammateJoinsChecks(controller: controller, invite: invite, directory: directory)
        AppDefaults.store.removeObject(forKey: TeamDatabaseFeature.key)
        TeamBoard.save(nil)
        print(failures == 0 ? "TEAM_DATABASE_OFF_OK" : "TEAM_DATABASE_OFF_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// A teammate's Mac with no team, getting an invite (lane DB7). Off: Settings → Team is the shared folder, as it was;
    /// the invite asks once whether to turn team databases on and join, naming the team and who invited; Cancel changes
    /// nothing; Turn On and Join turns them on and joins as Join does with them on; a Mac in a team folder goes on to Move
    /// This Team to a Database… instead. On, with no team: Join a Team… and Set Up a Team… lead, each with the database
    /// first and a shared folder second. Each state's subtitle and footer say what's true for it. Returns how many checks
    /// failed (each is printed).
    @MainActor
    static func teammateJoinsChecks(controller: DictationController, invite: TeamInvite, directory: URL?) async -> Int {
        var failed = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failed += 1 }
        }
        let team = controller.teamBoard
        AppSettings.shared.teamMemberName = "Robin"
        func page(_ name: String) async -> Set<String> {
            await teamSettingsDrawn(controller: controller, name: name, directory: directory, height: 1100)
        }

        // Off, no team: as it always was.
        check(TeamDatabaseFeature.way == .folderOnly && SettingsPage.team.summary == "Sharing binders through a hub, or a folder you already sync."
                && TeamDatabaseFeature.footer(.folderOnly).hasPrefix("Share meetings and notes with your team through a folder synced by OneDrive"),
              "off: Settings → Team names the shared folder alone, in its subtitle and its footer, as before")
        let off = await page("team-off")
        check(off.contains("team.footer.folderOnly") && off.contains("team.hub.signIn") && !off.contains("team.join") && !off.contains("team.database")
                && !off.contains("team.invite.turnOn"),
              "off: Settings → Team is a hub's Sign In and the shared folder: no Join a Team…, no team database part")

        // An invite while it's off asks once.
        if let link = invite.link { URLCommands.handle(link, controller: controller) }
        let question = TeamDatabaseFeature.question(invite, turningOn: true)
        let detail = TeamDatabaseFeature.detail(invite, turningOn: true, folderTeam: false)
        check(team.pendingInvite == invite && !TeamDatabaseFeature.isOn && controller.flowBar.model.toastText.isEmpty,
              "off: a binders://team/join link opens Settings → Team, waiting for a yes, and turns nothing on yet")
        check(question == "Turn on team databases and join “Harbor team”?"
                && detail == "Sam invited you, as robin. Team databases are a preview in this version of Binders, off until you turn them on. Its database is binders on 192.0.2.11.",
              "it asks with the team's name, who invited, and that team databases are a preview: \(question) \(detail)")
        let asking = await page("team-off-invite")
        check(asking.contains("team.invite.turnOn") && asking.contains("team.footer.folderOnly") && !asking.contains("team.database"),
              "Settings → Team shows the question, with Turn On and Join, and nothing else of the team database")
        let unnamed = TeamInvite(server: invite.server, oneTimePassword: "p", teamName: "")
        check(TeamDatabaseFeature.question(unnamed, turningOn: true) == "Turn on team databases and join the team?"
                && TeamDatabaseFeature.detail(unnamed, turningOn: true, folderTeam: false).hasPrefix("You were invited as robin."),
              "an invite an earlier Binders made, which names no one, still reads plainly")

        // Cancel changes nothing.
        team.declineInvite()
        check(team.pendingInvite == nil && AppDefaults.store.object(forKey: TeamDatabaseFeature.key) == nil && AppSettings.shared.teamDatabase == nil
                && team.database == nil && (Keychain.read(TeamDatabase.passwordKey(invite.server)) ?? "").isEmpty,
              "Cancel changes nothing: still off, no team saved, nothing connected, no password kept")
        check(!(await page("team-off-cancelled")).contains("team.invite.turnOn"), "and the question is gone")

        // A Mac in a team folder goes on to Move This Team to a Database…, where it joins.
        AppSettings.shared.teamFolderPath = AppPaths.support.appendingPathComponent("folder-team").path
        URLCommands.openInvite(invite, controller: controller)
        check(TeamDatabaseFeature.detail(invite, turningOn: true, folderTeam: true)
                .hasSuffix("This Mac shares through a team folder, so it joins in Move This Team to a Database…, which opens next."),
              "in a team folder, the question says where it joins")
        let moving = try? await team.acceptInvite(invite)
        check(moving == .move && TeamDatabaseFeature.isOn && team.pendingInvite == invite && AppSettings.shared.teamDatabase == nil && team.database == nil,
              "in a team folder, Turn On and Join turns team databases on and leaves the invite for Move This Team to a Database…")
        team.declineInvite()
        AppSettings.shared.teamFolderPath = nil
        AppDefaults.store.removeObject(forKey: TeamDatabaseFeature.key)

        // Turn On and Join: on, then joined as Join does with it on.
        URLCommands.openInvite(invite, controller: controller)
        do {
            let step = try await team.acceptInvite(invite)
            check(step == .joined("Joined “Harbor team” as robin. Binders changes the one-time password the first time it connects."),
                  "Turn On and Join joins: \(step)")
        } catch {
            check(false, "Turn On and Join joins (\(error.localizedDescription))")
        }
        check(TeamDatabaseFeature.isOn && TeamBoard.savedServer() == invite.server && team.server == invite.server && team.database != nil
                && team.pendingInvite == nil && Keychain.read(TeamDatabase.passwordKey(invite.server)) == invite.oneTimePassword,
              "team databases are on, the team is saved, this Mac connects with the one-time password, and the question is gone")
        check(TeamDatabaseFeature.way == .database && SettingsPage.team.summary == "Sharing binders through a team database.",
              "this Mac is on a team database now, and the subtitle says so")
        let joined = await page("team-joined")
        check(joined.contains("team.database") && joined.contains("team.footer.database") && !joined.contains("team.join") && !joined.contains("team.invite.join"),
              "Settings → Team shows the team database, with its words in the footer")
        let words = TeamDatabaseFeature.databaseWords
        check(words.hasPrefix("Share binders with your team through a team database: a Postgres server your team runs, which Binders reaches directly, through your own network or VPN.")
                && words.contains("captures only when you put them in a shared binder") && words.contains("The audio Binders records never goes to it")
                && !words.contains("There's no server") && words.components(separatedBy: "Postgres").count == 2,
              "the database's footer says what goes to it and that audio never does, naming the server once")
        await team.leaveDatabase()
        TeamDatabase.forget(invite.server)

        // On, no team yet: a hub leads, and the shared folder; no new team database (the hub's sign-in replaces its
        // server, login and VPN).
        check(TeamDatabaseFeature.isOn && TeamDatabaseFeature.way == .folderOnly
                && SettingsPage.team.summary == "Sharing binders through a hub, or a folder you already sync.",
              "on with no team: the subtitle names the folder, as off")
        let lead = await page("team-on-no-team")
        check(lead.contains("team.hub") && lead.contains("team.hub.signIn") && lead.contains("team.footer.folderOnly")
                && !lead.contains("team.join") && !lead.contains("team.setUp") && !lead.contains("team.database"),
              "on with no team: Settings → Team leads with the hub's Sign In, and offers no Join a Team… or Set Up a Team…")
        URLCommands.openInvite(invite, controller: controller)
        let invited = await page("team-on-invite")
        check(invited.contains("team.invite.join")
                && TeamDatabaseFeature.question(invite, turningOn: false) == "Join “Harbor team” as robin?"
                && TeamDatabaseFeature.detail(invite, turningOn: false, folderTeam: false) == "Sam invited you. Its database is binders on 192.0.2.11.",
              "on: an invite to a team still on its database, opened from a link or Finder, asks “Join “Harbor team” as robin?” at the top")
        team.declineInvite()
        AppSettings.shared.teamMemberName = "Sam"
        return failed
    }

    /// Settings → Team in a window 1020 pt wide (and `height` tall, the whole page by default), drawn to `directory` as
    /// `name`.png when one is given; the controls it showed, by their probes' names.
    @MainActor
    static func teamSettingsDrawn(controller: DictationController, name: String, directory: URL?, height: CGFloat = 2400) async -> Set<String> {
        let wasOn = FitProbe.isOn
        FitProbe.isOn = true
        defer { FitProbe.isOn = wasOn }
        let navigation = HubNavigation()
        navigation.selection = .settings
        navigation.pendingSettingsPage = .team
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: height), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: SettingsView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1_800))
        let shown = Set(FitProbe.all(in: window).map(\.name))
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            capture(hosting, name: name, directory: directory)
        }
        window.close()
        return shown
    }

    /// A sheet drawn on its own, as it shows over Settings; where each of its probes is, by name (from the window's bottom).
    @MainActor
    static func drawnAlone(_ view: some View, controller: DictationController, name: String, size: NSSize, directory: URL?) async -> [String: NSRect] {
        let wasOn = FitProbe.isOn
        FitProbe.isOn = true
        defer { FitProbe.isOn = wasOn }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: view
            .environment(controller).environment(controller.team).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(900))
        var shown: [String: NSRect] = [:]
        for probe in FitProbe.all(in: window) { shown[probe.name] = probe.frame }
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            capture(hosting, name: name, directory: directory)
        }
        window.close()
        return shown
    }
}

