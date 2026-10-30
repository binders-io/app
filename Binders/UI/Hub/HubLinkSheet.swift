import SwiftUI
import BindersKit

/// Link to Hub…, from a binder's menu (HubLinks): which of the hub's Binders, and a project in it or a new one named as
/// this binder is; what goes up the first time; then Link, which sends it and says what arrived. A link that didn't
/// finish shows here with Send Again.
struct HubLinkSheet: View {
    let binder: BinderRecord
    @Environment(\.dismiss) private var dismiss
    private var links: HubLinks { .shared }
    @State private var spaces: [HubLink.Space] = []
    @State private var space: String = ""
    @State private var projects: [HubLink.Project] = []
    /// The project chosen; empty for a new one.
    @State private var project: String = ""
    @State private var loading = false
    @State private var loadProblem: String?
    @State private var changes: [HubLink.Outgoing] = []

    private var place: HubLink.Place? { HubLinks.place(of: binder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Link “\(binder.name)” to a Hub").font(BindersTheme.cardTitle)
                Text("Its notes, folders and cards go up to a project on \(HubAccount.shared.address.map(HubSignInSection.shown) ?? "your hub"), where your team sees them in the web app and the hub's agents can take its cards. Notes from what you said to yourself, meetings and captures stay on this Mac.")
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
                if spaces.count > 1 {
                    Picker("Binder on the hub", selection: $space) {
                        ForEach(spaces) { Text($0.name).tag($0.id) }
                    }
                    .fitProbe("hubLink.space")
                }
                Picker("Project", selection: $project) {
                    Text("New project “\(binder.name)”").tag("")
                    if !projects.isEmpty { Divider() }
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }
                .disabled(loading)
                .fitProbe("hubLink.project")
            }
            .formStyle(.columns)
            if loading {
                StatusLabel("Asking the hub…", .waiting)
            } else if let loadProblem {
                StatusLabel(loadProblem, .problem).fixedSize(horizontal: false, vertical: true).fitProbe("hubLink.problem")
            } else {
                Text(project.isEmpty ? "\(HubLink.counted(changes).capitalizedFirst) go up to a new project."
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
                    .disabled(loading || loadProblem != nil || space.isEmpty || links.working[binder.id] != nil)
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
                Text("\(place.binderName) in \(place.spaceName)").textSelection(.enabled)
            }
            if let working = links.working[binder.id] {
                StatusLabel(working, .waiting)
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
                        .disabled(links.working[binder.id] != nil)
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
            space = found.current ?? found.spaces.first?.id ?? ""
            if space.isEmpty { loadProblem = "You're not in a Binder on this hub yet. Ask one of its admins to add you." }
            await loadProjects()
        } catch {
            loadProblem = (error as? HubLinks.Problem)?.words ?? error.localizedDescription
        }
        recount()
    }

    private func loadProjects() async {
        guard !space.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            projects = try await links.projects(in: space)
            if !project.isEmpty, !projects.contains(where: { $0.id == project }) { project = "" }
            loadProblem = nil
        } catch {
            loadProblem = (error as? HubLinks.Problem)?.words ?? error.localizedDescription
        }
    }

    private func recount() {
        changes = links.firstUpload(binder, to: project.isEmpty ? "new" : project, newName: nil)
    }

    private func link() async {
        guard let chosen = spaces.first(where: { $0.id == space }) else { return }
        await links.link(binder, space: chosen, to: projects.first { $0.id == project })
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
