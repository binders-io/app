import SwiftUI
import BindersKit

/// Link to Hub…, from a binder's menu (HubLinks): a new binder on the hub named as this one is, or one of the hub's
/// binders you're in; what goes up the first time; then Link, which sends it and says what arrived. A binder on the hub
/// is one notebook, as here; one made there before that may hold several parts, and then which one is asked too. A link
/// that didn't finish shows here with Send Again.
struct HubLinkSheet: View {
    let binder: BinderRecord
    @Environment(\.dismiss) private var dismiss
    private var links: HubLinks { .shared }
    @State private var spaces: [HubLink.Space] = []
    /// The hub the Binders and projects came from: Link goes there, or not at all.
    @State private var hub: URL?
    /// The hub's binder chosen; empty for a new one, named as this one is.
    @State private var space: String = ""
    /// Its parts: one, but for a binder made on the hub before a binder was one notebook.
    @State private var projects: [HubLink.Project] = []
    /// The part chosen; empty for a new one (always so in a new binder).
    @State private var project: String = ""
    @State private var loading = false
    @State private var loadProblem: String?
    @State private var changes: [HubLink.Outgoing] = []

    private var place: HubLink.Place? { HubLinks.place(of: binder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Link “\(binder.name)” to a Hub").font(BindersTheme.cardTitle)
                Text("Its notes, folders and cards go up to a binder on \(HubAccount.shared.address.map(HubSignInSection.shown) ?? "your hub"), where the people in it see them in the web app and the hub's agents can take its cards. It stays on this Mac too, and the two keep each other up to date. Notes from what you said to yourself, meetings and captures stay on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let place {
                linked(place)
            } else if let why = links.whyNot(binder) {
                StatusLabel(why, .problem).fixedSize(horizontal: false, vertical: true).fitProbe("hubLink.whyNot")
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                choosing
            }
        }
        .padding(20)
        .frame(width: 520)
        .pageGround()
        .fitProbe("hubLink")
        .task { await load() }
    }

    // MARK: Choosing where

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("Binder on the hub", selection: $space) {
                    Text("New binder “\(binder.name)”").tag("")
                    if !spaces.isEmpty { Divider() }
                    ForEach(spaces) { Text($0.id.hasPrefix("~") ? "\($0.name) (only you)" : $0.name).tag($0.id) }
                }
                .disabled(loading)
                .fitProbe("hubLink.space")
                if projects.count > 1 {
                    Picker("Part", selection: $project) {
                        ForEach(projects) { Text($0.name).tag($0.id) }
                    }
                    .disabled(loading)
                    .fitProbe("hubLink.project")
                }
            }
            .formStyle(.columns)
            if loading {
                StatusLabel("Asking the hub…", .waiting)
            } else if let loadProblem {
                StatusLabel(loadProblem, .problem).fixedSize(horizontal: false, vertical: true).fitProbe("hubLink.problem")
            } else {
                Text(space.isEmpty ? "\(HubLink.counted(changes).capitalizedFirst) go up to a new binder on the hub, which you own."
                                   : "\(HubLink.counted(changes).capitalizedFirst) go up into it, beside what it has.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fitProbe("hubLink.counts")
            }
            if let working = links.working[binder.id] {
                StatusLabel(working, .waiting)
            }
            if let problem = links.problems[binder.id] {
                StatusLabel(problem, .problem).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Link") { Task { await link() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || loadProblem != nil || hub == nil || links.working[binder.id] != nil)
                    .fitProbe("hubLink.link")
            }
        }
        .onChange(of: space) { _, _ in Task { await loadProjects() } }
        .onChange(of: project) { _, _ in recount() }
    }

    // MARK: Linked

    private func linked(_ place: HubLink.Place) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Linked to") {
                Text(place.binderName == place.spaceName ? place.spaceName : "\(place.binderName) in \(place.spaceName)").textSelection(.enabled)
            }
            if let working = links.working[binder.id] {
                StatusLabel(working, .waiting)
            } else if let why = links.whyNotSendAgain(binder) {
                // Signed in to another hub (or none): what stops Send Again now, before what went wrong last time.
                StatusLabel(why, .problem).fixedSize(horizontal: false, vertical: true).fitProbe("hubLink.whyNotSendAgain")
            } else if let problem = links.problems[binder.id] {
                StatusLabel(problem, .problem).fixedSize(horizontal: false, vertical: true).fitProbe("hubLink.problem")
            } else if let done = links.done[binder.id] {
                StatusLabel(done, .done).fitProbe("hubLink.done")
            } else if !place.uploaded {
                StatusLabel("Not everything reached the hub yet.", .waiting)
            }
            HStack {
                Spacer()
                if !place.uploaded {
                    Button("Send Again") { Task { await links.sendAgain(binder) } }
                        .disabled(links.working[binder.id] != nil || links.whyNotSendAgain(binder) != nil)
                        .fitProbe("hubLink.sendAgain")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Doing

    private func load() async {
        guard place == nil, links.whyNot(binder) == nil else { return }
        loading = true
        defer { loading = false }
        do {
            let found = try await links.spaces()
            spaces = found.spaces
            hub = found.hub
            // A new binder unless one on the hub already goes by this one's name.
            space = found.spaces.first { $0.name.localizedCaseInsensitiveCompare(binder.name) == .orderedSame }?.id ?? ""
            await loadProjects()
        } catch {
            loadProblem = (error as? HubLinks.Problem)?.words ?? error.localizedDescription
        }
        recount()
    }

    private func loadProjects() async {
        guard !space.isEmpty, let hub else {
            projects = []
            project = ""
            recount()
            return
        }
        loading = true
        defer { loading = false }
        do {
            projects = try await links.projects(in: space, on: hub)
            // Its one binder, or the first of its parts.
            if !projects.contains(where: { $0.id == project }) { project = projects.first?.id ?? "" }
            loadProblem = nil
        } catch {
            loadProblem = (error as? HubLinks.Problem)?.words ?? error.localizedDescription
        }
    }

    private func recount() {
        changes = links.firstUpload(binder, to: project.isEmpty ? "new" : project, newName: nil)
    }

    private func link() async {
        guard let hub else { return }
        if space.isEmpty {
            // A new binder on the hub: made first, then linked into its one binder.
            do {
                let made = try await links.newSpace(named: binder.name, on: hub)
                await links.link(binder, on: hub, space: made.space, to: made.project)
            } catch {
                loadProblem = (error as? HubLinks.Problem)?.words ?? error.localizedDescription
            }
            return
        }
        guard let chosen = spaces.first(where: { $0.id == space }) else { return }
        await links.link(binder, on: hub, space: chosen, to: projects.first { $0.id == project })
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
