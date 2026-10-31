import SwiftData
import SwiftUI
import BindersKit

/// One task from a meeting's notes or a note, with a way to tick it and a way back to where it lives.
struct TaskEntry: Identifiable {
    enum Kind { case meeting, note, commitment }

    let id: String
    let kind: Kind
    /// The to-do's id as list_todos gives it, which is also what links it to a card.
    let ref: String
    let owner: String?
    let text: String
    let done: Bool
    let sourceID: UUID
    let sourceTitle: String
    let sourceDate: Date
    let binderID: UUID?
    let toggle: () -> Void
    let open: () -> Void
    var due: Date? = nil
    /// Commitments the model got wrong can be waved away.
    var dismiss: (() -> Void)? = nil
    /// An agent added it ("Added by Claude Code"): its group wears the agent's sparkle.
    var byAgent = false
    /// Said to yourself: your own words, quoted in New York italic.
    var quoted = false

    var todo: TodoItem {
        let kind = switch kind {
        case .meeting: "meeting"
        case .note: "note"
        case .commitment: "commitment"
        }
        return TodoItem(id: ref, text: text, owner: owner, done: done, due: due, binderID: binderID, sourceKind: kind,
                        sourceID: sourceID, sourceTitle: sourceTitle)
    }
}

/// What the board may do with a commitment.
struct CommitmentActions {
    var toggle: (CommitmentRecord) -> Void
    var dismiss: (CommitmentRecord) -> Void
    var open: (CommitmentRecord) -> Void
}

@MainActor
enum TaskCollector {
    /// Every task line in the meetings' notes and in the notes' digests and bodies, in the order given.
    static func collect(meetings: [MeetingRecord], notes: [NoteItem], commitments: [CommitmentRecord] = [],
                        openMeeting: @escaping (MeetingRecord) -> Void, openNote: @escaping (NoteItem) -> Void,
                        commitmentActions: CommitmentActions? = nil) -> [TaskEntry] {
        var entries: [TaskEntry] = []
        // Promises come first: they carry deadlines and are the freshest.
        let live = commitments.filter { $0.status != "dismissed" }.sorted { a, b in
            if (a.dueAt == nil) != (b.dueAt == nil) { return a.dueAt != nil }
            if let x = a.dueAt, let y = b.dueAt, x != y { return x < y }
            return a.createdAt > b.createdAt
        }
        for record in live {
            entries.append(TaskEntry(id: "c:\(record.id.uuidString)", kind: .commitment, ref: record.id.uuidString, owner: record.owner, text: record.task,
                                     done: record.status == "done", sourceID: record.sourceWritingID ?? record.id, sourceTitle: record.sourceTitle,
                                     sourceDate: record.createdAt, binderID: record.binderID,
                                     toggle: { commitmentActions?.toggle(record) }, open: { commitmentActions?.open(record) },
                                     due: record.dueAt, dismiss: { commitmentActions?.dismiss(record) }, byAgent: record.todoOrigin == .agent,
                                     quoted: record.todoOrigin == .moment || record.todoOrigin == .suggestion))
        }
        let reader = TeamSyncService.myName
        /// `author` is the teammate who shared it, whose "You" is them; nil for your own.
        func scan(_ markdown: String, id: String, kind: TaskEntry.Kind, place: BoardTaskReference.Place, sourceID: UUID, title: String, date: Date,
                  binderID: UUID?, author: String?, write: @escaping (String) -> Void, open: @escaping () -> Void) {
            for (index, task, ref) in lines(of: markdown, place: place, sourceID: sourceID) {
                entries.append(TaskEntry(id: "\(id):\(index)", kind: kind, ref: ref,
                                         owner: NotesEditing.owner(task.owner, author: author, reader: reader), text: task.text, done: task.done,
                                         sourceID: sourceID, sourceTitle: title, sourceDate: date, binderID: binderID,
                                         toggle: { write(NotesEditing.toggleCheckbox(in: markdown, line: index)) }, open: open))
            }
        }
        for meeting in meetings {
            scan(meeting.summary, id: "m:\(meeting.id.uuidString)", kind: .meeting, place: .meeting, sourceID: meeting.id, title: meeting.title,
                 date: meeting.createdAt, binderID: meeting.binderID, author: meeting.isTeamCopy ? meeting.teamAuthorName : nil, write: { meeting.summary = $0 }, open: { openMeeting(meeting) })
        }
        for note in notes {
            scan(note.digest, id: "d:\(note.id.uuidString)", kind: .note, place: .digest, sourceID: note.id, title: note.title,
                 date: note.updatedAt, binderID: note.binderID, author: note.isTeamCopy ? note.teamAuthorName : nil, write: { note.digest = $0 }, open: { openNote(note) })
            scan(note.text, id: "n:\(note.id.uuidString)", kind: .note, place: .note, sourceID: note.id, title: note.title,
                 date: note.updatedAt, binderID: note.binderID, author: note.isTeamCopy ? note.teamAuthorName : nil, write: {
                NoteHistory.willChange(note, to: $0)
                note.text = $0
            }, open: { openNote(note) })
        }
        return entries
    }

    /// The to-do lines of a text, with their references, kept for the texts read lately (lane DB10): a binder's Overview
    /// collects again after every save, and each line is read with regular expressions.
    private static func lines(of markdown: String, place: BoardTaskReference.Place, sourceID: UUID) -> [(Int, TaskLine, String)] {
        let key = ScanKey(markdown: markdown, place: place.rawValue, source: sourceID)
        if let known = scanned[key] { return known }
        var found: [(Int, TaskLine, String)] = []
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            guard let task = NotesEditing.task(from: line), !task.text.isEmpty else { continue }
            found.append((index, task, BoardTaskReference(place: place, id: sourceID, text: task.text).string))
        }
        if scanned.count >= 4000 { scanned.removeAll() }
        scanned[key] = found
        return found
    }

    private struct ScanKey: Hashable {
        var markdown: String
        var place: String
        var source: UUID
    }

    private static var scanned: [ScanKey: [(Int, TaskLine, String)]] = [:]
}

/// Open to-dos with their owners, grouped by where they came from and filterable by person; done ones fold away underneath.
struct TaskBoard: View {
    @Environment(DictationController.self) private var controller
    let tasks: [TaskEntry]
    /// Show at most this many open tasks (Home shows a handful).
    var limit: Int? = nil
    /// Names the binder a task lives in, when tasks come from several binders.
    var binderName: ((UUID?) -> String?)? = nil
    @State private var ownerFilter: String?
    /// The cards made from these to-dos, to show which are on a board. Only open to-dos show it, so only theirs are read,
    /// rather than every card ever made from a to-do.
    @Query private var linkedCards: [TaskCard]
    @State private var hovered: String?

    init(tasks: [TaskEntry], limit: Int? = nil, binderName: ((UUID?) -> String?)? = nil) {
        self.tasks = tasks
        self.limit = limit
        self.binderName = binderName
        _linkedCards = Query(filter: Self.cards(for: tasks.filter { !$0.done }.map(\.ref)))
    }

    /// Cards made from any of these to-dos.
    static func cards(for refs: [String]) -> Predicate<TaskCard> {
        #Predicate<TaskCard> { card in card.sourceRef.flatMap { refs.contains($0) } ?? false }
    }

    private var cardsByTodo: [String: TaskCard] {
        linkedCards.reduce(into: [:]) { cards, card in if let todo = card.sourceRef { cards[todo] = card } }
    }

    private var openTasks: [TaskEntry] { tasks.filter { !$0.done && (ownerFilter == nil || $0.owner == ownerFilter) } }
    private var doneTasks: [TaskEntry] { tasks.filter { $0.done && (ownerFilter == nil || $0.owner == ownerFilter) } }

    private var owners: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for task in tasks where !task.done {
            if let owner = task.owner { counts[owner, default: 0] += 1 }
        }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { a, b in
            if (a.name == TranscriptSegment.you) != (b.name == TranscriptSegment.you) { return a.name == TranscriptSegment.you }
            return a.count == b.count ? a.name < b.name : a.count > b.count
        }
    }

    private struct SourceGroup: Identifiable {
        let id: UUID
        let kind: TaskEntry.Kind
        let title: String
        let date: Date
        let binderID: UUID?
        let byAgent: Bool
        let open: () -> Void
        var tasks: [TaskEntry]
    }

    private var groups: [SourceGroup] {
        var ordered: [SourceGroup] = []
        var index: [UUID: Int] = [:]
        var shown = 0
        for task in openTasks {
            if let limit, shown >= limit { break }
            shown += 1
            if let at = index[task.sourceID] {
                ordered[at].tasks.append(task)
            } else {
                index[task.sourceID] = ordered.count
                ordered.append(SourceGroup(id: task.sourceID, kind: task.kind, title: task.sourceTitle, date: task.sourceDate,
                                           binderID: task.binderID, byAgent: task.byAgent, open: task.open, tasks: [task]))
            }
        }
        return ordered
    }

    var body: some View {
        let cards = cardsByTodo
        let groups = groups
        VStack(alignment: .leading, spacing: 14) {
            if !owners.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("Everyone", count: tasks.filter { !$0.done }.count, selected: ownerFilter == nil) { ownerFilter = nil }
                        ForEach(owners, id: \.name) { owner in
                            chip(owner.name, count: owner.count, selected: ownerFilter == owner.name) { ownerFilter = owner.name }
                        }
                    }
                }
            }
            if openTasks.isEmpty {
                Text(tasks.isEmpty ? "Nothing here yet. To-dos from meeting notes, note digests, the notes themselves and promises you make in messages collect here."
                     : (ownerFilter == nil ? "All done." : "Nothing open for \(ownerFilter ?? "")."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Drawn as they scroll into view (lane DB10): a binder's Overview can list hundreds.
            if !groups.isEmpty {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 6) {
                                // An agent's to-do wears its sparkle, in lavender.
                                if group.byAgent {
                                    Image(systemName: BindersTheme.agentSymbol).font(.caption).foregroundStyle(BindersTheme.agent)
                                } else {
                                    Image(systemName: group.kind == .meeting ? "person.2.wave.2" : (group.kind == .commitment ? "hand.raised" : "note.text"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button(group.title, action: group.open)
                                    .themedLink()
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(group.date, format: .relative(presentation: .named)).font(BindersTheme.time()).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                // Its binder's chip slides in as a new to-do files in.
                                if let name = binderName?(group.binderID) { Badge(text: name).filingChip() }
                            }
                            ForEach(group.tasks) { row($0, card: cards[$0.ref]).transition(.filed) }
                        }
                        .transition(.filed)
                    }
                }
            }
            if let limit, openTasks.count > limit {
                Text("and \(openTasks.count - limit) more").font(.caption).foregroundStyle(.secondary)
            }
            if !doneTasks.isEmpty, limit == nil {
                DisclosureGroup("Done (\(doneTasks.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(doneTasks) { row($0, card: nil) }
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        // A new to-do files in; a ticked one leaves the open ones.
        .filing(groups.flatMap { $0.tasks.map(\.id) })
    }

    private func row(_ task: TaskEntry, card: TaskCard?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // A ticked to-do is done: green.
            Button(action: task.toggle) {
                Image(systemName: task.done ? "checkmark.square.fill" : "square").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(task.done ? AnyShapeStyle(BindersTheme.done) : AnyShapeStyle(.secondary))
            .help(task.done ? "Mark as not done" : "Mark as done")
            if let owner = task.owner { OwnerChip(name: owner) }
            Text(task.text)
                .font(task.quoted ? BindersTheme.quote() : nil)
                .strikethrough(task.done, color: .secondary)
                .foregroundStyle(task.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
            if let due = task.due, !task.done {
                DueBadge(due: due)
            }
            Spacer(minLength: 0)
            if let card, !task.done {
                // On a hub's board, the badge names it: the card is the team's there, the to-do stays yours here.
                let hubBoard = HubBoard.shared.covers(card) ? Store.shared.binder(card.binderID)?.name : nil
                Button { CardWindows.shared.open(card) } label: {
                    Badge(text: "\(hubBoard.map { "On \($0)" } ?? "On board") · \(card.column.title)", tinted: true)
                }
                .buttonStyle(.plain)
                .help(hubBoard == nil ? "Open the card. The to-do is ticked off when the card is done."
                      : "Open the card, which is on the hub's board. The to-do stays on this Mac and is ticked off when the card is done.")
            } else if !task.done {
                // Shown on hover, so the list stays quiet.
                Button { moveToBoard(task) } label: {
                    Image(systemName: "rectangle.stack.badge.plus").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add to the board")
                .accessibilityLabel("Add to the board")
                .opacity(hovered == task.id ? 1 : 0)
                .allowsHitTesting(hovered == task.id)
            }
            if let dismiss = task.dismiss, !task.done {
                Button(action: dismiss) { Image(systemName: "xmark.circle").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Not a to-do")
            }
        }
        .padding(.leading, 4)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = task.id } else if hovered == task.id { hovered = nil }
        }
        .contextMenu {
            if let card, !task.done {
                Button("Open Card") { CardWindows.shared.open(card) }
                if let address = HubBoard.shared.webAddress(of: card) {
                    Button("Open on the Hub") { NSWorkspace.shared.open(address) }
                }
            } else if !task.done {
                Button("Add to Board") { moveToBoard(task) }
                // A to-do stays on this Mac; a card made from it can go to a binder linked to a hub, for the team.
                let linked = HubBoard.shared.linkedBinders.filter { $0.binder.id != task.todo.binderID }
                if !linked.isEmpty {
                    Menu("Add to a Hub's Board") {
                        ForEach(linked, id: \.binder.id) { link in
                            Button("\(link.binder.name) (\(link.place.spaceName))") { moveToBoard(task, binder: link.binder.id) }
                        }
                    }
                }
            }
            // A to-do of its own (one you said or added, not a checklist item in a note or a meeting) moves with its card.
            if !task.done, task.todo.sourceKind == "commitment", let id = UUID(uuidString: task.todo.id) {
                Menu("Move to") {
                    MoveToBinderItems(current: task.todo.binderID) { target in controller.router.moveTodo(id, to: target, card: card) }
                }
            }
        }
    }

    /// Puts a to-do on its binder's board, or on `binder`'s, in Ready. It stays open here, marked as on the board, until its
    /// card is done. On a binder linked to a hub the card goes up to the hub's board, where the hub's agents take it.
    private func moveToBoard(_ task: TaskEntry, binder: UUID? = nil) {
        let made = controller.board.create(from: task.todo, column: .ready, binderID: binder, by: .you)
        if !made.existed, !HubBoard.shared.covers(made.card) { controller.router.suggestLater(for: made.card, origin: .toBoard) }
    }

    private func chip(_ label: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                Text("\(count)").monospacedDigit().foregroundStyle(selected ? AnyShapeStyle(OnTintFill(secondary: true)) : AnyShapeStyle(.secondary))
                    .rollingCount(count)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? AnyShapeStyle(.tintFill) : AnyShapeStyle(BindersTheme.ink.opacity(0.07))))
            // Words that read on the fill: white on the accent and on Indigo, dark ink on a lighter binder colour.
            .foregroundStyle(selected ? AnyShapeStyle(.onTintFill) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}

/// A small name tag; "You" wears the accent. On a binder's pages it's a neutral chip like the others, with "You" in ink
/// so it still stands out.
struct OwnerChip: View {
    let name: String
    @Environment(\.binderTint) private var binderTint

    var body: some View {
        let mine = name == TranscriptSegment.you
        Text(name)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(mine ? AnyShapeStyle(.infoFill(0.18)) : AnyShapeStyle(BindersTheme.ink.opacity(0.07))))
            .foregroundStyle(mine ? AnyShapeStyle(binderTint == nil ? BindersTheme.accentText : BindersTheme.ink) : AnyShapeStyle(.secondary))
            .lineLimit(1)
    }
}

/// When a to-do or a card is due: amber with a clock once it's today or late, as it needs you; plain otherwise.
struct DueBadge: View {
    let due: Date

    var body: some View {
        let urgent = due < Date() || Calendar.current.isDateInToday(due)
        Badge(text: CommitmentService.dueLabel(due), symbol: urgent ? "clock" : nil, color: urgent ? BindersTheme.needsYou : BindersTheme.muted)
    }
}

/// Words dictated per day over the last two weeks.
struct ActivityChart: View {
    let days: [(date: Date, words: Int)]

    private var total: Int { days.reduce(0) { $0 + $1.words } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last two weeks").font(BindersTheme.cardTitle)
                Spacer()
                Text("\(total.formatted()) words").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Canvas { context, size in
                let peak = max(days.map(\.words).max() ?? 1, 1)
                let slot = size.width / CGFloat(max(days.count, 1))
                let width = slot * 0.6
                for (index, day) in days.enumerated() {
                    let height = max(3, CGFloat(day.words) / CGFloat(peak) * (size.height - 4))
                    let rect = CGRect(x: CGFloat(index) * slot + (slot - width) / 2, y: size.height - height, width: width, height: height)
                    let today = index == days.count - 1
                    let color: Color = day.words == 0 ? BindersTheme.ink.opacity(0.08) : BindersTheme.accent.opacity(today ? 1 : 0.55)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
                }
            }
            .frame(height: 70)
            HStack {
                if let first = days.first?.date { Text(first, format: .dateTime.month(.abbreviated).day()) }
                Spacer()
                Text("Today")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// A binder at a glance: its colour on the spine and on what's open, what's in it, and when it was last touched.
struct BinderCard: View {
    let binder: BinderRecord
    let openCount: Int
    /// What's in it, nil while it's being counted.
    let activity: HomeData.Activity?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let counted = activity ?? HomeData.Activity()
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(binder.name).font(BindersTheme.cardTitle).lineLimit(1)
                    Spacer(minLength: 0)
                    if binder.isTeamCopy || binder.sharedWithTeam {
                        Image(systemName: binder.isTeamCopy ? "person.2.fill" : "person.2").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(counted.meetings) \(counted.meetings == 1 ? "meeting" : "meetings") · \(counted.notes) \(counted.notes == 1 ? "note" : "notes")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .redacted(reason: activity == nil ? .placeholder : [])
                HStack(spacing: 8) {
                    if openCount > 0 { Badge(text: "\(openCount) open", tinted: true).monospacedDigit().rollingCount(openCount) }
                    if let last = activity?.last {
                        Text(last, format: .relative(presentation: .named)).font(BindersTheme.time()).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.ink.opacity(hovering ? 0.04 : 0)))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? BindersTheme.lineStrong : BindersTheme.line))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(BinderPalette.color(binder.colorIndex))
                    .frame(width: 6)
                    .padding(.vertical, 10)
                    .padding(.leading, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .binderTint(binder.colorIndex)
        .onHover { hovering = $0 }
    }
}
