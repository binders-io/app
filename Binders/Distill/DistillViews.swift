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
        VStack(alignment: .leading, spacing: 8) {
            // One row while it fits; short of room, what you can do goes under how it's going.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    how(progress, bar: 150)
                    Spacer(minLength: 8)
                    actions(progress)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) { how(progress, bar: 90) }
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        actions(progress)
                    }
                }
            }
            if let proposal {
                HStack(spacing: 8) {
                    // Lane DS9: the count opens the Distill list beside the note, where the items wait.
                    Button { DistillActions.open(note.id, popout: compact) } label: {
                        StatusLabel(Self.waitingLine(proposal), .needsYou, symbol: "tray.full")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(compact ? 1 : nil)
                    }
                    .buttonStyle(.plain)
                    .help("Open the Distill list beside the note")
                    Button("Review") { DistillActions.open(note.id, popout: compact) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Open the Distill list beside the note. Review All…, in its ⋯ menu, opens the review sheet.")
                }
            }
            if let why = service.problems[note.id] {
                StatusLabel(why, .problem).font(.system(size: 12, weight: .medium)).lineLimit(compact ? 1 : nil).fixedSize(horizontal: false, vertical: !compact).help(why)
            }
            // A reading that took long or was cut short: how long, with which model, and a quicker one for Distill (lane DS7).
            if let slow = service.slow[note.id] {
                HStack(spacing: 6) {
                    Label(slow.line, systemImage: "clock").font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : nil)
                    if let offer = slow.offer {
                        Button(offer) {
                            HubWindowController.shared.navigation.pendingSettingsPage = .ai
                            HubWindowController.shared.show(section: .settings)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Opens Settings → AI, where Model for Distill is. Binders doesn't change it for you.")
                    }
                }
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
                StatusLabel(word, .waiting).font(.system(size: 12, weight: .medium)).lineLimit(compact ? 1 : nil).fixedSize(horizontal: false, vertical: !compact).help(word)
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
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BindersTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BindersTheme.line))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(TintFill().opacity(0.45))
                .frame(width: 2)
                .padding(.vertical, 10)
                .padding(.leading, 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .animation(BoardDesign.settle, value: progress.counts)
        .sheet(item: $reviewing) { proposal in
            DistillReviewSheet(distill: proposal, note: note).environment(controller)
        }
        .sheet(isPresented: $reporting) {
            DistillReportSheet(note: note).environment(controller)
        }
        // Lane DS8: the Distill model loads now, when that frees no other, so the first reading doesn't wait for it.
        .onAppear { controller.distill.warm(for: note) }
        .alert("Couldn't distill it", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            // No list from the model: your agents that could read the note instead (lane DS2).
            if case .noList = problem {
                ForEach(service.agentChoices(for: note).prefix(3)) { agent in
                    Button("Distill with \(agent.name)") { DistillMenu.give(note, to: agent, controller: controller) { problem = $0 } }
                }
            }
            Button("OK", role: .cancel) {}
        } message: { Text(alertWords) }
        // Lane DS9: a proposal no longer opens the review sheet; its items are in the Distill list, which opened with Distill.
        // Distill again's offers for cards on the board are still reviewed in the sheet.
        .onReceive(NotificationCenter.default.publisher(for: DistillMenu.proposed)) { notification in
            guard let id = notification.userInfo?["note"] as? UUID, id == note.id,
                  let distill = notification.userInfo?["distill"] as? UUID,
                  let record = DistillStore.shared.distill(distill, of: note.id), !record.openUpdates.isEmpty else { return }
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
        Label("Work", systemImage: "square.stack.3d.down.right")
            .font(.system(size: 14, weight: .heavy, design: .rounded))
            .foregroundStyle(.sectionInk)
            .fixedSize()
            .fitProbe("workbar.first")
        if progress.counts.total > 0 {
            WorkProgressBar(counts: progress.counts).frame(width: bar)
        }
        // In a note's own window there's room for the count and no more: the panel has the rest.
        let line = compact && progress.counts.total > 0
            ? "\(progress.counts.done) of \(progress.counts.total) done"
            : progress.line
        Text(progress.counts.total > 0 ? line : "Nothing placed yet")
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(compact ? 1 : 2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Work: \(progress.counts.total > 0 ? progress.line : "nothing placed yet")")
    }

    private func openReport() {
        MarkdownEditor.flushAll()
        reporting = true
    }

    /// What you can do: Distill, the report, and the Work panel beside the note.
    @ViewBuilder
    private func actions(_ progress: DistillProgress.Progress) -> some View {
        // Lane DS9: what readings in the background found, as a quiet count that opens the list.
        let fresh = controller.distill.list(for: note.id).newItems.count
        if fresh > 0, !controller.distill.reading.contains(note.id) {
            Button { DistillActions.open(note.id, popout: compact) } label: {
                Text(fresh == 1 ? "1 new item" : "\(fresh) new items")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tintText)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Read in the background from what you wrote. Click to see them in the Distill list.")
        }
        // A reading in the background stays quiet here (lane DS9).
        if controller.distill.reading.contains(note.id), !controller.distill.quietReading.contains(note.id) {
            ProgressView().controlSize(.small)
            // A long note is read in parts: which one now, and how many items so far (lane DS7), with Cancel.
            Text(controller.distill.readingLine(note.id))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                .help(controller.distill.readingPart[note.id] == nil ? "" : "The note is long, so Binders' model reads it a few sections at a time.")
            Button("Cancel") { controller.distill.stopReading(note.id) }
                .controlSize(.small)
                .disabled(controller.distill.stopping.contains(note.id))
                .help("Stop reading: the items found so far are kept for your review, and Distill Again reads the rest.")
        } else if note.distill, !controller.distill.agentChoices(for: note).isEmpty {
            // Lane DS9: Distill itself is the note's own button now; here, reading it with one of your agents.
            DistillMenu(note: note, agentsOnly: true) { problem = $0 }
                .controlSize(.small)
        }
        Button(action: openReport) {
            if compact {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 12, weight: .medium))
            } else {
                Label("Report", systemImage: "chart.bar.doc.horizontal")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(progress.counts.total == 0)
        .help("How the work from this note is going, from the board: what finished, what's in progress, what waits on whom")
        Toggle(isOn: $showWork) { Image(systemName: "highlighter") }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(showWork ? "Hide the work in the note: the marks on the words each card came from, and where each card is"
                  : "Show Work in the Note: mark the words each card came from, and say where each card is")
            .accessibilityLabel("Show Work in the Note")
        Toggle(isOn: $panelShown) { Image(systemName: "sidebar.right") }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(!panelRoom)
            .help(!panelRoom ? "No room for the Work panel beside the note at this width. Make the window wider and it comes back."
                  : panelShown ? "Hide the Work panel"
                  : panelInPlace ? "Show every card from this note, in place of the note until you hide it" : "Show every card from this note beside it")
            .accessibilityLabel("Work panel")
            .fitProbe("workbar.last")
    }
}

/// The bar: done, then in progress, then what waits on you, out of the whole, in the colours each part wears. Segments
/// are separate capsules, so each part reads on its own and the bar rolls as the counts change.
struct WorkProgressBar: View {
    let counts: DistillProgress.Counts

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let total = max(1, Double(counts.total))
            let active = [counts.done, counts.inProgress, counts.waitsOnYou].filter { $0 > 0 }.count
            let gaps = CGFloat(max(0, active - 1)) * 1.5
            let room = max(0, width - gaps)
            HStack(spacing: 1.5) {
                if counts.done > 0 {
                    Capsule().fill(BindersTheme.done).frame(width: room * Double(counts.done) / total)
                }
                if counts.inProgress > 0 {
                    Capsule().fill(BindersTheme.agent.opacity(0.85)).frame(width: room * Double(counts.inProgress) / total)
                }
                if counts.waitsOnYou > 0 {
                    Capsule().fill(BindersTheme.needsYou).frame(width: room * Double(counts.waitsOnYou) / total)
                }
                Spacer(minLength: 0)
            }
            .background(Capsule().fill(BindersTheme.ink.opacity(0.08)))
            .clipShape(Capsule())
        }
        .frame(height: 7)
        .animation(BoardDesign.settle, value: counts)
        .accessibilityElement()
        .accessibilityLabel("\(counts.done) of \(counts.total) done")
        .accessibilityValue("\(Int((counts.fraction * 100).rounded())) percent")
    }
}

/// Distill: with Binders' model (the one in Settings → AI), or with one of your agents that takes the binder's cards.
struct DistillMenu: View {
    @Environment(DictationController.self) private var controller
    let note: NoteItem
    /// Only "Distill with" your agents (lane DS9: the note's Distill button reads it with Binders' model).
    var agentsOnly = false
    var failed: (DistillService.Problem) -> Void
    /// Posted when a proposal for a note is made from here, with its "note" and "distill", for the Work bar to open it.
    static let proposed = Notification.Name("BindersDistillProposed")

    var body: some View {
        let agents = AgentRegistry.shared.agents.filter { $0.isEnabled && $0.takesCards(from: note.binderID) }
        let distilledBefore = !DistillStore.shared.file(for: note.id).distills.isEmpty
        if agentsOnly {
            Menu {
                ForEach(agents) { agent in
                    Button(agent.name) { distill(with: agent) }
                }
            } label: {
                Label("Distill with", systemImage: BindersTheme.agentSymbol)
            }
            .fixedSize()
            .help("Have one of your agents read the note into work items for your review, in place of Binders' model")
        } else {
            menu(agents: agents, distilledBefore: distilledBefore)
        }
    }

    private func menu(agents: [AgentProfile], distilledBefore: Bool) -> some View {
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
        // Lane DS9: the Distill list opens, and the items show in it as they're read.
        DistillActions.open(note.id)
        controller.distill.list(for: note.id).readingStarted()
        Task {
            switch await controller.distill.distill(note) {
            case .success(let record):
                NotificationCenter.default.post(name: Self.proposed, object: nil, userInfo: ["note": note.id, "distill": record.id])
            case .failure(let problem):
                switch problem {
                // Busy, or stopped by you (lane DS7), or nothing changed (lane DS8, said on the Work bar): nothing to alert about.
                case .reading, .stopped, .unchanged: break
                default: failed(problem)
                }
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
            Button("Turn Off Distill for This Note…") {
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
