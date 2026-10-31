import AppKit
import Foundation
import BindersKit

/// The team database (lanes DB1–DB4) is held back from Binders 0.10.0 behind a default, off until it's turned on with
/// `defaults write io.binders.mac teamDatabase -bool YES`, or with Turn On and Join on an invite. Off, nothing of it shows
/// or runs: Settings → Team is the shared folder alone; nothing connects at launch; Binders' MCP server names no
/// teammates; and a Mac that has a team database set up keeps it, its settings and its outbox as they are, unconnected,
/// until the default is on again. An invite (a binders://team/join link or a .binders-invite file) opened while it's off
/// asks once, in Settings → Team, whether to turn team databases on and join (lane DB7). On, everything is as lanes
/// DB2–DB4 built it. Read each time it's asked: a page opened or a link that arrives after it changed goes by the new
/// value. While Binders runs (lane DB5), turning it off disconnects at once and hides everything, as at launch, and
/// turning it on again connects to the database set up here (`Watcher`).
enum TeamDatabaseFeature {
    static let key = "teamDatabase"

    static var isOn: Bool { AppDefaults.store.bool(forKey: key) }

    /// Turn On and Join on an invite: team databases are on from now on, on this Mac.
    static func turnOn() {
        AppDefaults.store.set(true, forKey: key)
    }

    /// Hears the default change while Binders runs, set in this app or with `defaults write` in Terminal (key-value
    /// observing of the defaults hears both), and looks again whenever Binders comes to the front, in case one was
    /// missed. Tells `changed` only when it goes from off to on, or on to off.
    @MainActor
    final class Watcher: NSObject {
        private let changed: @MainActor (Bool) -> Void
        private var last: Bool

        init(changed: @escaping @MainActor (Bool) -> Void) {
            self.changed = changed
            last = TeamDatabaseFeature.isOn
            super.init()
            AppDefaults.store.addObserver(self, forKeyPath: TeamDatabaseFeature.key, options: [.new], context: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        }

        deinit {
            AppDefaults.store.removeObserver(self, forKeyPath: TeamDatabaseFeature.key)
        }

        nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                               context: UnsafeMutableRawPointer?) {
            Task { @MainActor [weak self] in self?.look() }
        }

        @objc private func becameActive() { look() }

        /// The default as it is now, told when it changed.
        func look() {
            let now = TeamDatabaseFeature.isOn
            guard now != last else { return }
            last = now
            changed(now)
        }
    }
}

extension BinderRecord {
    /// Shared through a team database, as pages say it: never while the team database is off.
    var shownSharedThroughDatabase: Bool { sharedThroughDatabase && TeamDatabaseFeature.isOn }
}

// MARK: Settings → Team's words (lane DB7)

extension TeamDatabaseFeature {
    /// How this Mac shares, which Settings → Team's subtitle and footer say.
    enum Way: String, Equatable {
        /// Team databases are off, or on with no team here: a shared folder, beside a hub. A team starting now goes to
        /// a hub rather than a new team database.
        case folderOnly
        /// In a team folder.
        case folder
        /// On a team database.
        case database
    }

    /// `hasFolder`: whether this Mac is in a team folder.
    @MainActor
    static func way(hasFolder: Bool) -> Way {
        guard isOn else { return .folderOnly }
        if hasFolder { return .folder }
        return TeamBoard.savedServer() != nil ? .database : .folderOnly
    }

    @MainActor static var way: Way { way(hasFolder: AppSettings.shared.teamFolderPath != nil) }

    /// The line under Settings → Team's name.
    static func subtitle(_ way: Way) -> String {
        switch way {
        case .folderOnly: "Sharing binders through a hub, or a folder you already sync."
        case .folder: "Sharing binders through a folder you already sync."
        case .database: "Sharing binders through a team database."
        }
    }

    /// The shared folder, as Settings → Team has always said it.
    static let folderWords = "Share meetings and notes with your team through a folder synced by OneDrive, Dropbox, Google Drive or iCloud Drive. There's no server. Only the notes and meetings in binders you share leave this Mac, with the files attached to those notes; captures and the audio Binders records never do. They're stored as Markdown, so the folder also opens as an Obsidian vault."

    /// A team database: what it is and what goes to it (TeamNotes, TeamContentSend, TeamKnowledgePublish and the boards).
    /// Notes made from what you said to yourself stay unshared (`NoteItem.staysUnshared`); a capture goes only once you
    /// put it in a shared binder or choose Share It; no meeting row has a field for audio.
    static let databaseWords = "Share binders with your team through a team database: a Postgres server your team runs, which Binders reaches directly, through your own network or VPN. Only the binders you share go to it: their notes, meetings, cards, to-dos and what Binders learned from them, and captures only when you put them in a shared binder. The audio Binders records never goes to it, and neither do notes made from what you said to yourself."

    /// The words under Settings → Team's first part.
    static func footer(_ way: Way) -> String {
        switch way {
        case .folderOnly, .folder: folderWords
        case .database: databaseWords
        }
    }

    /// The question an invite opened on this Mac asks before it joins: "Join “Harbor” as robin?", and while team databases
    /// are off, "Turn on team databases and join “Harbor”?".
    static func question(_ invite: TeamInvite, turningOn: Bool) -> String {
        let team = invite.teamName.isEmpty ? "the team" : "“\(invite.teamName)”"
        return turningOn ? "Turn on team databases and join \(team)?" : "Join \(team) as \(invite.server.login)?"
    }

    /// What it says under the question: who invited (when the invite says), that team databases are a preview while
    /// they're off, where its database is, and on a Mac with a team folder, where it joins.
    static func detail(_ invite: TeamInvite, turningOn: Bool, folderTeam: Bool) -> String {
        let from = invite.invitedBy?.trimmingCharacters(in: .whitespacesAndNewlines)
        let by = (from?.isEmpty ?? true) ? nil : from
        var parts: [String] = []
        if turningOn {
            parts.append(by.map { "\($0) invited you, as \(invite.server.login)." } ?? "You were invited as \(invite.server.login).")
            parts.append("Team databases are a preview in this version of Binders, off until you turn them on.")
        } else if let by {
            parts.append("\(by) invited you.")
        }
        parts.append("Its database is \(invite.server.database) on \(invite.server.host).")
        if folderTeam {
            parts.append("This Mac shares through a team folder, so it joins in Move This Team to a Database…, which opens next.")
        }
        return parts.joined(separator: " ")
    }
}
