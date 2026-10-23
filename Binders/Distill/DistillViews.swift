import AppKit
import SwiftData
import SwiftUI
import BindersKit

// MARK: - The Work bar

/// Under a Distill note's title: how its work is going ("7 of 12 done · 3 in progress · 1 waits on you · 1 not started"),
/// live from the board, with Distill (by Binders' model, or with one of your agents), the proposal waiting for your review,
/// the report, and sections changed since their cards were made. Lane DS6: under any note with cards on the board too,
/// without Distill's part when it's off.
struct WorkBar: View {
    @Environment(DictationController.self) private var controller
    let note: NoteItem
    /// The Work panel beside the note: shown, or not.
    @Binding var panelShown: Bool
    /// Room for the Work panel beside the note at this width; without it, its button says so and waits.
    var panelRoom = true
    /// In a note's own window: the panel shows in place of the note when there's no room beside it, and the lines under
    /// the bar keep to one each, so the bar fits the window at its smallest.
    var compact = false
    var panelInPlace = false
    @State private var reviewing: DistillRecord?
    @State private var reporting = false
    /// Show Work in the Note (lane DS4): the cards marked in the note at the words they came from.
    @AppStorage(DistillNoteMarks.shownKey, store: AppDefaults.store) private var showWork = true
    @State private var problem: DistillService.Problem?

    var body: some View {
        let service = controller.distill
        // Redrawn as the board and the note's distills change.
        let _ = (service.boardRevision, DistillStore.shared.revision, AgentDoingFeed.shared.lines.count)
        let progress = DistillBoard.progress(of: note, doing: AgentDoingFeed.shared.lines)
        let proposal = DistillStore.shared.file(for: note.id).proposal
        let changed = progress.report.sections
        VStack(alignment: .leading, spacing: 6) {
            // One row while it fits; short of room, what you can do goes under how it's going.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    how(progress, bar: 140)
                    Spacer(minLength: 8)
                    actions(progress)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) { how(progress, bar: 80) }
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        actions(progress)
                    }
                }
            }
            if let proposal {
                HStack(spacing: 8) {
                    StatusLabel(Self.waitingLine(proposal), .needsYou, symbol: "tray.full")
                        .font(.callout)
                        .lineLimit(compact ? 1 : nil)
                    Button("Review") { reviewing = proposal }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                }
                // A shared note: who else is reviewing it now, so two people don't place the same items (lane DB3).
                if let others = controller.teamBoard.notes.reviewingLine(note.id, distill: proposal.id) {
                    Label(others, systemImage: "person.wave.2").font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : nil)
                }
            }
            if let why = service.problems[note.id] {
                StatusLabel(why, .problem).font(.callout).lineLimit(compact ? 1 : nil).fixedSize(horizontal: false, vertical: !compact).help(why)
            }
            // What the model wrote instead of a list, so you can see why (lane DS2).
            if let start = service.replyStart[note.id] {
                Text("It began: “\(start)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 3)
                    .textSelection(.enabled)
                    .help(start)
            }
            if let word = service.said[note.id] {
                StatusLabel(word, .waiting).font(.callout).lineLimit(compact ? 1 : nil).fixedSize(horizontal: false, vertical: !compact).help(word)
            }
            if !changed.isEmpty {
                // Who changed each, when and how much. In a note's own window, the first, and how many more.
                ForEach(compact ? Array(changed.prefix(1)) : changed, id: \.section) { section in
                    let line = Self.sectionLine(section)
                    Label(line + (compact && changed.count > 1 ? " \(changed.count - 1) more in the report." : ""), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : nil)
                        .help(line)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BindersTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(BindersTheme.line))
        .sheet(item: $reviewing) { proposal in
            DistillReviewSheet(distill: proposal, note: note).environment(controller)
                // The team sees who's reviewing a shared note's proposal.
                .onAppear { controller.teamBoard.notes.reviewing(note.id, distill: proposal.id) }
                .onDisappear { controller.teamBoard.notes.reviewing(note.id, distill: nil) }
        }
        .sheet(isPresented: $reporting) {
            DistillReportSheet(note: note).environment(controller)
        }
        .alert("Couldn't distill it", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            // No list from the model: your agents that could read the note instead (lane DS2).
            if case .noList = problem {
                ForEach(service.agentChoices(for: note).prefix(3)) { agent in
                    Button("Distill with \(agent.name)") { DistillMenu.give(note, to: agent, controller: controller) { problem = $0 } }
                }
            }
            Button("OK", role: .cancel) {}
        } message: { Text(alertWords) }
        .onReceive(NotificationCenter.default.publisher(for: DistillMenu.proposed)) { notification in
            // A proposal just made for this note opens for review.
            guard let id = notification.userInfo?["note"] as? UUID, id == note.id,
                  let distill = notification.userInfo?["distill"] as? UUID,
                  let record = DistillStore.shared.distill(distill, of: note.id), !record.waiting.isEmpty || !record.updates.isEmpty else { return }
            reviewing = record
        }
    }

    /// Why it couldn't distill the note, and for replies with no list, what the model wrote first.
    private var alertWords: String {
        guard let problem else { return "" }
        let why = problem.errorDescription ?? ""
        guard case .noList = problem, let start = controller.distill.replyStart[note.id] else { return why }
        return why + "\n\nIt began: “\(start)”"
    }

    /// "3 proposed items wait for your review", "1 change to a card on the board waits for your review": what a proposal
    /// still holds, and what read the note.
    static func waitingLine(_ proposal: DistillRecord) -> String {
        let items = proposal.waiting.count, changes = proposal.openUpdates.count
        var parts: [String] = []
        if items > 0 { parts.append(items == 1 ? "1 proposed item" : "\(items) proposed items") }
        if changes > 0 { parts.append(changes == 1 ? "1 change to a card on the board" : "\(changes) changes to cards on the board") }
        return parts.joined(separator: " and ") + " \(items + changes == 1 ? "waits" : "wait") for your review, from \(proposal.readByLine)."
    }

    /// A section that changed after its cards were made, as the Work bar says it: who changed it, how long ago, how much,
    /// and whether its cards caught up.
    static func sectionLine(_ section: DistillProgress.SectionEntry, now: Date = Date()) -> String {
        section.barLine(when: AutomationPayload.date(fromISO: section.at).map { ago($0, now: now) })
    }

    /// How long ago, as the Work bar and panel say it: "just now" within a minute, else "5 minutes ago", "yesterday".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        abs(now.timeIntervalSince(date)) < 60 ? "just now" : date.formatted(.relative(presentation: .named))
    }

    /// How it's going: Work, the bar, and the line that says it.
    @ViewBuilder
    private func how(_ progress: DistillProgress.Progress, bar: CGFloat) -> some View {
        Label("Work", systemImage: "square.stack.3d.down.right").font(.callout.weight(.semibold)).foregroundStyle(.sectionInk)
            .fixedSize()
            .fitProbe("workbar.first")
        if progress.counts.total > 0 {
            WorkProgressBar(counts: progress.counts).frame(width: bar)
        }
        Text(progress.counts.total > 0 ? progress.line : "Nothing placed yet")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityLabel("Work: \(progress.counts.total > 0 ? progress.line : "nothing placed yet")")
    }

    /// What you can do: Distill, the report, and the Work panel beside the note.
    @ViewBuilder
    private func actions(_ progress: DistillProgress.Progress) -> some View {
        if controller.distill.reading.contains(note.id) {
            ProgressView().controlSize(.small)
            // A long note is read in parts: which one now.
            Text(controller.distill.readingPart[note.id].map { "Reading part \($0.part) of \($0.of)…" } ?? "Reading the note…")
                .font(.callout).foregroundStyle(.secondary).fixedSize()
                .help(controller.distill.readingPart[note.id] == nil ? "" : "The note is long, so Binders' model reads it a few sections at a time.")
        } else if note.distill {
            DistillMenu(note: note) { problem = $0 }
        }
        Button("Report") {
            MarkdownEditor.flushAll()
            reporting = true
        }
        .disabled(progress.counts.total == 0)
        .help("How the work from this note is going, from the board: what finished, what's in progress, what waits on whom")
        Toggle(isOn: $showWork) { Image(systemName: "highlighter") }
            .toggleStyle(.button)
            .help(showWork ? "Hide the work in the note: the marks on the words each card came from, and where each card is"
                  : "Show Work in the Note: mark the words each card came from, and say where each card is")
            .accessibilityLabel("Show Work in the Note")
        Toggle(isOn: $panelShown) { Image(systemName: "sidebar.right") }
            .toggleStyle(.button)
            .disabled(!panelRoom)
            .help(!panelRoom ? "No room for the Work panel beside the note at this width. Make the window wider and it comes back."
                  : panelShown ? "Hide the Work panel"
                  : panelInPlace ? "Show every card from this note, in place of the note until you hide it" : "Show every card from this note beside it")
            .accessibilityLabel("Work panel")
            .fitProbe("workbar.last")
    }
}

/// The bar: done, then in progress, then what waits on you, out of the whole, in the colours each part wears.
struct WorkProgressBar: View {
    let counts: DistillProgress.Counts

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let total = max(1, Double(counts.total))
            HStack(spacing: 0) {
                Rectangle().fill(BindersTheme.done).frame(width: width * Double(counts.done) / total)
                Rectangle().fill(BindersTheme.agent.opacity(0.8)).frame(width: width * Double(counts.inProgress) / total)
                Rectangle().fill(BindersTheme.needsYou).frame(width: width * Double(counts.waitsOnYou) / total)
                Spacer(minLength: 0)
            }
            .background(BindersTheme.line)
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("\(counts.done) of \(counts.total) done")
        .accessibilityValue("\(Int((counts.fraction * 100).rounded())) percent")
    }
}

/// Distill: with Binders' model (the one in Settings → AI), or with one of your agents that takes the binder's cards.
struct DistillMenu: View {
    @Environment(DictationController.self) private var controller
    let note: NoteItem
    var failed: (DistillService.Problem) -> Void
    /// Posted when a proposal for a note is made from here, with its "note" and "distill", for the Work bar to open it.
    static let proposed = Notification.Name("BindersDistillProposed")

    var body: some View {
        let agents = AgentRegistry.shared.agents.filter { $0.isEnabled && $0.takesCards(from: note.binderID) }
        let distilledBefore = !DistillStore.shared.file(for: note.id).distills.isEmpty
        Menu {
            Button("With Binders' Model") { distill() }
            if !agents.isEmpty {
                Section("Distill with") {
                    ForEach(agents) { agent in
                        Button(agent.name) { distill(with: agent) }
                    }
                }
            }
        } label: {
            Label(distilledBefore ? "Distill Again" : "Distill", systemImage: BindersTheme.modelSymbol)
        } primaryAction: {
            distill()
        }
        .fixedSize()
        .help(distilledBefore ? "Read the note again for what's new or changed since it was last distilled. Nothing reaches the board until you place it."
              : "Read the note into work items for you to review. Nothing reaches the board until you place it.")
    }

    private func distill() {
        MarkdownEditor.flushAll()
        Task {
            switch await controller.distill.distill(note) {
            case .success(let record):
                NotificationCenter.default.post(name: Self.proposed, object: nil, userInfo: ["note": note.id, "distill": record.id])
            case .failure(let problem):
                if problem != .reading { failed(problem) }
            }
        }
    }

    private func distill(with agent: AgentProfile) {
        Self.give(note, to: agent, controller: controller, failed: failed)
    }

    /// "Distill with…": the card asking `agent` to read the note, and a word that it's gone.
    static func give(_ note: NoteItem, to agent: AgentProfile, controller: DictationController, failed: (DistillService.Problem) -> Void) {
        switch controller.distill.distill(note, with: agent) {
        case .success(let card):
            controller.flowBar.toast("Gave “\(card.title)” to \(agent.name). Its items wait for your review here.", symbol: "arrow.right.circle", duration: 5)
        case .failure(let problem):
            failed(problem)
        }
    }
}

// MARK: - Turning it on and off

/// Distill This Note, and Stop Distilling…, which asks first while its cards are open (`confirmOff` is given the note): they
/// stay on the board either way.
struct DistillToggleItems: View {
    @Environment(DictationController.self) private var controller
    let note: NoteItem
    var confirmOff: (NoteItem) -> Void

    var body: some View {
        if note.distill {
            Button("Stop Distilling…") {
                if controller.distill.openCards(of: note).isEmpty { controller.distill.setDistill(false, for: note) } else { confirmOff(note) }
            }
        } else {
            Button("Distill This Note") { controller.distill.setDistill(true, for: note) }
                .help("Read this note into work items for the board, follow how they're going, and keep its whole history. Most notes are just documentation and never need it.")
        }
    }
}

extension View {
    /// The question Stop Distilling… asks about `note` while cards from it are open.
    func confirmsStopDistilling(_ note: Binding<NoteItem?>, controller: DictationController) -> some View {
        confirmationDialog("Stop distilling “\(note.wrappedValue?.title ?? "this note")”?",
                           isPresented: Binding(get: { note.wrappedValue != nil }, set: { if !$0 { note.wrappedValue = nil } }),
                           presenting: note.wrappedValue) { item in
            Button("Stop Distilling") { controller.distill.setDistill(false, for: item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            let open = controller.distill.openCards(of: item).count
            Text("\(open == 1 ? "Its 1 open card stays" : "Its \(open) open cards stay") on the board. The Work bar goes, and its history is trimmed after 30 days again.")
        }
    }
}
