import AppKit
import SwiftData
import SwiftUI
import BindersKit

// MARK: - The Work panel

/// Beside a Distill note, or any note with cards (lane DS6): every card of it, with its column, who has it, what its agent
/// says it's doing (its own words), its last update and what it waits for. Each opens its card; each card's section opens
/// in the note.
struct WorkPanel: View {
    @Environment(DictationController.self) private var controller
    let note: NoteItem

    var body: some View {
        let _ = (controller.distill.boardRevision, AgentDoingFeed.shared.lines.count)
        let progress = DistillBoard.progress(of: note, doing: AgentDoingFeed.shared.lines)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Work").font(BindersTheme.cardTitle).foregroundStyle(.sectionInk)
                Spacer()
                Text(progress.counts.total == 0 ? "" : "\(progress.counts.done) of \(progress.counts.total) done").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .fitProbe("workpanel")
            // Lane DS5: the note's cards chosen on the board, to act on them all at once.
            if progress.counts.total > 0 {
                Button { Self.selectOnBoard(note) } label: { Label("Select on Board", systemImage: "square.on.square") }
                    .buttonStyle(.borderless)
                    .themedLink()
                    .font(.caption)
                    .help("Open the board with every card from this note selected, to move, assign or delete them at once")
            }
            if progress.items.isEmpty {
                Text(note.distill ? "Distill the note, review the items and place them on the board: each card shows here as it goes."
                     : "Put the note, or words in it, on the board: each card shows here as it goes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(progress.items, id: \.card) { item in
                WorkItemRow(item: item, note: note)
            }
        }
        .followingAgentDoing()
    }

    /// Select on Board (lane DS5): the board of the note's binder, or of its cards when none is there, with the note's
    /// cards on it selected.
    static func selectOnBoard(_ note: NoteItem) {
        let cards = DistillBoard.groupCards(of: note.id)
        let board = cards.contains { $0.binderID == note.binderID } ? note.binderID : cards.first?.binderID
        guard let board else { return }
        let navigation = HubWindowController.shared.navigation
        navigation.binderID = board
        navigation.pendingBoardSelection = Set(cards.filter { $0.binderID == board }.map(\.id))
        navigation.pendingBinderTab = .board
        navigation.selection = .binder
        HubWindowController.shared.show()
    }
}

/// One card of the Work panel.
struct WorkItemRow: View {
    @Environment(DictationController.self) private var controller
    let item: DistillProgress.Item
    let note: NoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if let id = UUID(uuidString: item.card), let card = controller.board.card(id) { CardWindows.shared.open(card) }
            } label: {
                Text(item.title).font(.callout.weight(.medium)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open the card")
            HStack(spacing: 6) {
                Badge(text: Self.stateWord(item), symbol: Self.symbol(item.state), color: Self.color(item.state))
                // Its column on the board, where its state doesn't already say it.
                if item.columnTitle != Self.stateWord(item) {
                    Text(item.columnTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        .help("In \(item.columnTitle) on the board")
                }
                if let who = item.who {
                    if item.whoIsAgent {
                        Label(who.shortAgentName, systemImage: BindersTheme.agentSymbol).font(.caption).foregroundStyle(BindersTheme.agent).lineLimit(1)
                    } else {
                        Text(item.meant ? "For \(who == BoardActor.you.name ? "you" : who)" : who).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if let doing = item.doing {
                // The agent's own words: information, quoted.
                Text("Says: \(doing)").font(.caption).foregroundStyle(BindersTheme.agent).lineLimit(2)
            }
            if let last = Self.lastUpdateLine(item) {
                Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !item.waitsFor.isEmpty {
                Label("Waits for " + item.waitsFor.prefix(3).map { "“\($0)”" }.joined(separator: ", "), systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                if let section = item.section {
                    Button { Self.open(section: section, of: note) } label: {
                        Label(section, systemImage: "text.alignleft").font(.caption).lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .themedLink()
                    .help("Show this section in the note")
                }
                if item.sectionChanged {
                    Badge(text: "Section changed", symbol: "arrow.triangle.2.circlepath", color: BindersTheme.needsYou)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BindersTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BindersTheme.line))
        .accessibilityElement(children: .contain)
    }

    /// The note, opened at a section, in the Binders window; with a card's words (lane DS4), at those words, flashed, when
    /// they can still be found (else at the section). `section` nil with words: the note's opening.
    static func open(section: String?, of note: NoteItem, quote: String? = nil) {
        let navigation = HubWindowController.shared.navigation
        navigation.open(note: note)
        navigation.pendingNotePlace = section
        navigation.pendingNoteQuote = quote
        HubWindowController.shared.show()
    }

    static func stateWord(_ item: DistillProgress.Item) -> String {
        switch item.state {
        case .done: "Done"
        case .inProgress: "In progress"
        case .waitsOnYou:
            item.column == BoardColumn.review.rawValue ? (item.waitsOn.map { "For \($0) to check" } ?? "To check")
                : (item.waitsOn.map { "Waits on \($0)" } ?? "Waits on you")
        case .heldUp: "Held up"
        case .notStarted: "Not started"
        }
    }

    /// "Last update 5 minutes ago: Halfway through the tests · Echo": its last report, when and by whom. Nil without one.
    static func lastUpdateLine(_ item: DistillProgress.Item, now: Date = Date()) -> String? {
        guard let last = item.lastUpdate?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty, last != item.doing else { return nil }
        let when = item.lastUpdateAt.flatMap { AutomationPayload.date(fromISO: $0) }.map { " " + WorkBar.ago($0, now: now) } ?? ""
        return "Last update\(when): \(last)" + (item.lastUpdateBy.map { " · \($0.shortAgentName)" } ?? "")
    }

    static func symbol(_ state: DistillProgress.State) -> String {
        switch state {
        case .done: BindersTheme.doneSymbol
        case .inProgress: "arrow.triangle.turn.up.right.circle"
        case .waitsOnYou: "exclamationmark.bubble"
        case .heldUp: "hourglass"
        case .notStarted: "circle.dashed"
        }
    }

    static func color(_ state: DistillProgress.State) -> Color {
        switch state {
        case .done: BindersTheme.done
        case .inProgress: BindersTheme.agent
        case .waitsOnYou: BindersTheme.needsYou
        case .heldUp, .notStarted: BindersTheme.muted
        }
    }
}

// MARK: - The report

/// How the work from a note is going, worked out from the board alone, the same every time: what finished since you last
/// looked and who did it, what's in progress and what each agent says, what waits on whom, what's held up and by what,
/// what's not started and for whom, and the sections changed since their cards were made. Copy as Markdown, or have your
/// model write it up as a paragraph, kept only when it keeps to the report's numbers.
struct DistillReportSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let note: NoteItem
    @State private var report: DistillProgress.Report?
    @State private var paragraph: String?
    @State private var writing = false
    @State private var writeUpProblem: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("How “\(note.title)” is going").font(BindersTheme.cardTitle).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                if let report {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(report.line).font(.title3.weight(.semibold)).monospacedDigit()
                        WorkProgressBar(counts: report.counts).frame(maxWidth: 360)
                        if let paragraph {
                            Text(paragraph).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(BindersTheme.surface))
                        }
                        if let writeUpProblem { StatusLabel(writeUpProblem, .problem).font(.callout) }
                        part(report.since == nil ? "Finished" : "Finished since you last looked", report.finished.map { entry in
                            "“\(entry.title)”" + (entry.who.map { ", by \($0)" } ?? "")
                        }, empty: report.since == nil ? nil : "Nothing was finished since you last looked.")
                        part("In progress", report.inProgress.map { entry in
                            "“\(entry.title)”: \(entry.who ?? "someone")" + (entry.detail.map { ", who says: \($0)" } ?? "")
                        })
                        part("Waits on someone", report.waiting.map { "“\($0.title)” waits on \($0.who ?? "you"): \($0.detail ?? "")" })
                        part("Held up", report.heldUp.map { "“\($0.title)” \($0.detail ?? "")" })
                        part("Not started", report.notStarted.map { entry in
                            "“\(entry.title)”" + (entry.who.map { ", for \($0)" } ?? ", for no one yet") + (entry.detail.map { " (\($0))" } ?? "")
                        })
                        part("Sections changed since their cards were made", report.sections.map { section in
                            "\(section.section)\(section.gone ? ", gone" : ""), by \(section.by): "
                                + [section.caughtUp.isEmpty ? nil : "caught up: " + section.caughtUp.map { "“\($0)”" }.joined(separator: ", "),
                                   section.behind.isEmpty ? nil : "not yet: " + section.behind.map { "“\($0)”" }.joined(separator: ", ")]
                                .compactMap { $0 }.joined(separator: "; ")
                        })
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
            Divider()
            HStack {
                Button(copied ? "Copied" : "Copy as Markdown") {
                    guard let report else { return }
                    TextInserter.copyToClipboard(report.markdown)
                    copied = true
                }
                Button {
                    writeUp()
                } label: {
                    if writing { ProgressView().controlSize(.small) } else { Label("Write It Up", systemImage: BindersTheme.modelSymbol) }
                }
                .disabled(writing || report == nil)
                .help("Your model writes the report as a paragraph. It's kept only if every number in it is the report's.")
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
        .pageGround()
        .onAppear { report = DistillBoard.progress(of: note, doing: AgentDoingFeed.shared.lines).report }
        // What you saw counts as looked at from now.
        .onDisappear { controller.distill.looked(at: note) }
        .followingAgentDoing()
    }

    @ViewBuilder
    private func part(_ title: String, _ lines: [String], empty: String? = nil) -> some View {
        if !lines.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.sectionInk)
                if lines.isEmpty, let empty { Text(empty).foregroundStyle(.secondary) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text("• " + line).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }

    /// The model's paragraph, from the report's Markdown alone: shown only if it keeps to the report's numbers.
    private func writeUp() {
        guard let report, let client = controller.distill.model() else {
            writeUpProblem = "Choose a language model in Settings → AI to write it up."
            return
        }
        writing = true
        writeUpProblem = nil
        Task {
            defer { writing = false }
            let system = "Write the progress report you're given as one short paragraph for a teammate. Use only what it says. Keep every number exactly as it is, and add no numbers of your own. Quote what agents say as theirs."
            let text = (try? await client.complete(system: system, user: report.markdown, maxTokens: 400, temperature: 0.2, timeout: 120)) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, DistillProgress.numbersHold(trimmed, report: report) {
                paragraph = trimmed
            } else {
                paragraph = nil
                writeUpProblem = trimmed.isEmpty ? "The model didn't write anything. The report stands as it is."
                    : "The model's paragraph had numbers the report doesn't, so the report stands as it is."
            }
        }
    }
}

// MARK: - The Work list

/// A binder's Work list, on its overview: every note with Distill on or with cards on the board (lane DS6), with its
/// progress bar and numbers.
struct WorkListSection: View {
    @Environment(DictationController.self) private var controller
    let binder: BinderRecord
    let openNote: (UUID) -> Void

    var body: some View {
        let _ = (controller.distill.boardRevision, DistillStore.shared.revision)
        let list = DistillBoard.workList(in: binder.id)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Work").font(BindersTheme.columnTitle).foregroundStyle(.sectionInk)
                    Spacer()
                    Text(list.count == 1 ? "1 note" : "\(list.count) notes").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                ForEach(list, id: \.note) { entry in
                    Button { if let id = UUID(uuidString: entry.note) { openNote(id) } } label: {
                        HStack(spacing: 12) {
                            Text(entry.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            if let proposed = entry.proposed { Badge(text: "\(proposed) to review", symbol: "tray.full", color: BindersTheme.needsYou) }
                            WorkProgressBar(counts: entry.counts).frame(width: 120)
                            Text(entry.counts.total == 0 ? "Nothing placed" : "\(entry.counts.done) of \(entry.counts.total) done")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(entry.line)
                    .accessibilityLabel("\(entry.title): \(entry.line)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperCard(padding: 16)
        }
    }
}

// MARK: - On the card

/// On a card Distill placed: the note it was distilled from and its section, opened with a click, and what changed in
/// that section since the card was made, with Looked at It · Tell when the change was an agent's and waits for a person.
/// The same on a card made with Put on Board (lane DS6): the words it was made from, and its section's changes.
struct DistilledFromPanel: View {
    @Environment(DictationController.self) private var controller
    @Bindable var card: TaskCard

    var body: some View {
        // One you put in the note's group by hand (lane DS5) says so in its Part of line alone.
        if let from = card.distilledFrom, from.byHand != true {
            let note = Store.shared.note(from.note)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(BindersTheme.muted)
                    Button(from.request == true ? "Asks to distill “\(card.sourceTitle ?? "a note")”"
                           : from.put == true ? "Put on the board from “\(note?.title ?? card.sourceTitle ?? "a note")”"
                           : "Distilled from “\(card.sourceTitle ?? "a note")”") {
                        guard let note else { return }
                        // At the words it came from, flashed, when the note still has them (lane DS4); else its section.
                        if from.section != nil || from.quote != nil {
                            WorkItemRow.open(section: from.section, of: note, quote: from.quote)
                        } else {
                            HubWindowController.shared.navigation.open(note: note)
                            HubWindowController.shared.show()
                        }
                    }
                    .buttonStyle(.borderless)
                    .themedLink()
                    .disabled(note == nil)
                    .help(from.quote != nil ? "Open the note at the words this card came from"
                          : from.section.map { "Open the note at its “\($0)” section" } ?? "Open the note")
                }
                .font(.caption)
                if let quote = from.quote {
                    // The note's words, as Distill read them, or as you selected them (Put on Board, lane DS6).
                    Text("“\(quote)”")
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel("From the note: \(quote)")
                }
                if let section = from.section {
                    Text("Section “\(section)”").font(.caption).foregroundStyle(BindersTheme.muted)
                }
                if let change = from.change {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(change.gone ? "Its section is gone from the note since this card was made, by \(change.by)."
                              : "Its section changed after this card was made, by \(change.by): \(NoteVersions.counts(added: change.added, removed: change.removed).lowercased()).",
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(BindersTheme.needsYou)
                            .fixedSize(horizontal: false, vertical: true)
                        if from.held == true {
                            let holder = card.assigneeIsAgent && BoardRules.isClaimed(card.state, at: .now) ? card.assignee : nil
                            Button(holder.map { "Looked at It · Tell \($0.shortAgentName)" } ?? "Looked at It") { controller.distill.passOn(card) }
                                .controlSize(.small)
                                .help("An agent changed the section, so the agent on this card hasn't been told yet. Look at the change in the note first.")
                        }
                    }
                }
            }
        }
    }
}

/// What a card waits for, with where each stands: an agent can't take it until they're all done.
struct CardWaitsPanel: View {
    @Environment(DictationController.self) private var controller
    @Bindable var card: TaskCard

    var body: some View {
        let waits = controller.board.waits(of: card)
        VStack(alignment: .leading, spacing: 3) {
            Text("Waits for").font(.caption.weight(.semibold)).foregroundStyle(BindersTheme.muted)
            ForEach(waits, id: \.id) { wait in
                Button {
                    if let id = UUID(uuidString: wait.id), let other = controller.board.card(id) { CardWindows.shared.open(other) }
                } label: {
                    Label("“\(wait.title)” · \(wait.column.title)", systemImage: wait.done ? BindersTheme.doneSymbol : "hourglass")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(wait.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            if !CardWaits.open(waits).isEmpty {
                Text("An agent can't take it until these are done. You still can.").font(.caption).foregroundStyle(BindersTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
