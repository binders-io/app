import SwiftUI
import BindersKit

/// Move to a Hub…, from Settings → Team on a Mac that was on a team database (HubMove): which of the hub's Binders, the
/// binders that go and whether each makes its project or joins the one a teammate's Mac made; then Move, which sends them
/// and takes them off the team database. One that didn't finish shows here with Move Again.
struct HubMoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var move: HubMove { .shared }
    private var links: HubLinks { .shared }
    private var account: HubAccount { .shared }
    @State private var spaces: [HubLink.Space] = []
    @State private var space: String = ""
    @State private var binders: [BinderRecord] = []
    @State private var existing: [UUID: HubLink.Project] = [:]
    @State private var loading = false
    @State private var loadProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Move to a Hub").font(BindersTheme.cardTitle)
                Text("Each binder this Mac has on the team database goes to a project on \(account.address.map(HubSignInSection.shown) ?? "your hub"), with its notes, folders and cards, and stays linked to it. Then this Mac leaves the team database. The first Mac to move a binder makes its project; teammates' Macs join it. Meetings, captures and to-dos stay on this Mac, and the team database keeps everything for teammates who haven't moved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let done = move.done {
                StatusLabel(done, .done).fixedSize(horizontal: false, vertical: true).fitProbe("hubMove.done")
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else if !account.isSignedIn {
                StatusLabel("Sign in to a hub first, at the top of Settings → Team.", .problem).fitProbe("hubMove.signIn")
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                choosing
            }
        }
        .padding(20)
        .frame(width: 540)
        .pageGround()
        .fitProbe("hubMove")
        .task { await load() }
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 14) {
            if spaces.count > 1 {
                Form {
                    Picker("Binder on the hub", selection: $space) {
                        ForEach(spaces) { Text($0.name).tag($0.id) }
                    }
                    .disabled(move.working != nil)
                    .fitProbe("hubMove.space")
                }
                .formStyle(.columns)
            }
            VStack(alignment: .leading, spacing: 6) {
                if binders.isEmpty {
                    Text("This Mac has no binders on the team database.").foregroundStyle(.secondary)
                }
                ForEach(binders, id: \.id) { binder in
                    HStack(alignment: .firstTextBaseline) {
                        Text(binder.name)
                        Spacer()
                        Text(line(binder)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .fitProbe("hubMove.binders")
            if !binders.isEmpty {
                StatusLabel(caution, .needsYou).font(.caption).fixedSize(horizontal: false, vertical: true).fitProbe("hubMove.caution")
            }
            if loading {
                StatusLabel("Asking the hub…", .waiting)
            } else if let loadProblem {
                StatusLabel(loadProblem, .problem).fixedSize(horizontal: false, vertical: true).fitProbe("hubMove.problem")
            }
            if let working = move.working {
                StatusLabel(working, .waiting)
            } else if let problem = move.problem {
                StatusLabel(problem, .problem).fixedSize(horizontal: false, vertical: true).fitProbe("hubMove.problem")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(move.working != nil)
                Button(move.problem == nil ? "Move" : "Move Again") { Task { await go() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || loadProblem != nil || space.isEmpty || move.working != nil || binders.isEmpty)
                    .fitProbe("hubMove.move")
            }
        }
        .onChange(of: space) { _, _ in Task { await loadMoved() } }
    }

    /// Where a binder goes, in words.
    private func line(_ binder: BinderRecord) -> String {
        if let problem = links.problems[binder.id] { return problem }
        if let place = HubLinks.place(of: binder) { return place.uploaded ? "On the hub" : "Not all there yet" }
        if let project = existing[binder.id] { return "Joins “\(project.name)”, moved by a teammate" }
        return "New project"
    }

    /// This Binders no longer reaches the team database.
    private let caution = "This Binders no longer reaches the team database, so what goes is what this Mac has: teammates' latest changes may not be here yet. A teammate whose Mac moves later joins the same project and sends what the hub doesn't have."

    private func load() async {
        binders = move.binders()
        guard account.isSignedIn, move.done == nil else { return }
        loading = true
        defer { loading = false }
        do {
            let found = try await links.spaces()
            spaces = found.spaces
            space = found.current ?? found.spaces.first?.id ?? ""
            if space.isEmpty { loadProblem = "You're not in a Binder on this hub yet. Ask one of its admins to add you." }
            await loadMoved()
        } catch {
            loadProblem = (error as? HubLinks.Problem)?.words ?? error.localizedDescription
        }
    }

    private func loadMoved() async {
        guard !space.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            existing = try await move.moved(binders, in: space)
            loadProblem = nil
        } catch {
            loadProblem = (error as? HubLinks.Problem)?.words ?? error.localizedDescription
        }
    }

    private func go() async {
        guard let chosen = spaces.first(where: { $0.id == space }) else { return }
        await move.move(to: chosen)
        binders = move.done == nil ? move.binders() : binders
    }
}
