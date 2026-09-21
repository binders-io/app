import SwiftData
import SwiftUI
import BindersKit

/// One task from a meeting's notes or a note, with a way to tick it and a way back to where it lives.
struct TaskEntry: Identifiable {
    enum Kind { case meeting, note, commitment }

    let id: String
    let kind: Kind
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
}

/// What the board may do with a commitment.
struct CommitmentActions {
    var toggle: (CommitmentRecord) -> Void
    var dismiss: (CommitmentRecord) -> Void
    var open: (CommitmentRecord) -> Void
}

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
            entries.append(TaskEntry(id: "c:\(record.id.uuidString)", kind: .commitment, owner: record.owner, text: record.task,
                                     done: record.status == "done", sourceID: record.sourceWritingID ?? record.id, sourceTitle: record.sourceTitle,
                                     sourceDate: record.createdAt, binderID: record.binderID,
                                     toggle: { commitmentActions?.toggle(record) }, open: { commitmentActions?.open(record) },
                                     due: record.dueAt, dismiss: { commitmentActions?.dismiss(record) }))
        }
        func scan(_ markdown: String, id: String, kind: TaskEntry.Kind, sourceID: UUID, title: String, date: Date, binderID: UUID?,
                  write: @escaping (String) -> Void, open: @escaping () -> Void) {
            for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
                guard let task = NotesEditing.task(from: line), !task.text.isEmpty else { continue }
                entries.append(TaskEntry(id: "\(id):\(index)", kind: kind, owner: task.owner, text: task.text, done: task.done,
                                         sourceID: sourceID, sourceTitle: title, sourceDate: date, binderID: binderID,
                                         toggle: { write(NotesEditing.toggleCheckbox(in: markdown, line: index)) }, open: open))
            }
        }
        for meeting in meetings {
            scan(meeting.summary, id: "m:\(meeting.id.uuidString)", kind: .meeting, sourceID: meeting.id, title: meeting.title,
                 date: meeting.createdAt, binderID: meeting.binderID, write: { meeting.summary = $0 }, open: { openMeeting(meeting) })
        }
        for note in notes {
            scan(note.digest, id: "d:\(note.id.uuidString)", kind: .note, sourceID: note.id, title: note.title,
                 date: note.updatedAt, binderID: note.binderID, write: { note.digest = $0 }, open: { openNote(note) })
            scan(note.text, id: "n:\(note.id.uuidString)", kind: .note, sourceID: note.id, title: note.title,
                 date: note.updatedAt, binderID: note.binderID, write: { note.text = $0 }, open: { openNote(note) })
        }
        return entries
    }
}

/// Open to-dos with their owners, grouped by where they came from and filterable by person; done ones fold away underneath.
struct TaskBoard: View {
    let tasks: [TaskEntry]
    /// Show at most this many open tasks (Home shows a handful).
    var limit: Int? = nil
    /// Names the binder a task lives in, when tasks come from several binders.
    var binderName: ((UUID?) -> String?)? = nil
    @State private var ownerFilter: String?

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
                                           binderID: task.binderID, open: task.open, tasks: [task]))
            }
        }
        return ordered
    }

    var body: some View {
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
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: group.kind == .meeting ? "person.2.wave.2" : (group.kind == .commitment ? "hand.raised" : "note.text"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(group.title, action: group.open)
                            .buttonStyle(.link)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(group.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let name = binderName?(group.binderID) { Badge(text: name, color: .secondary) }
                    }
                    ForEach(group.tasks) { row($0) }
                }
            }
            if let limit, openTasks.count > limit {
                Text("and \(openTasks.count - limit) more").font(.caption).foregroundStyle(.secondary)
            }
            if !doneTasks.isEmpty, limit == nil {
                DisclosureGroup("Done (\(doneTasks.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(doneTasks) { row($0) }
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ task: TaskEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: task.toggle) {
                Image(systemName: task.done ? "checkmark.square.fill" : "square").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(task.done ? Color.accentColor : Color.secondary)
            .help(task.done ? "Mark as not done" : "Mark as done")
            if let owner = task.owner { OwnerChip(name: owner) }
            Text(task.text)
                .strikethrough(task.done, color: .secondary)
                .foregroundStyle(task.done ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let due = task.due, !task.done {
                let overdue = due < Date()
                Badge(text: CommitmentService.dueLabel(due), color: overdue ? .red : (Calendar.current.isDateInToday(due) ? .orange : .secondary))
            }
            Spacer(minLength: 0)
            if let dismiss = task.dismiss, !task.done {
                Button(action: dismiss) { Image(systemName: "xmark.circle").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Not a to-do")
            }
        }
        .padding(.leading, 4)
    }

    private func chip(_ label: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                Text("\(count)").foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// A small name tag; "You" wears the accent.
struct OwnerChip: View {
    let name: String

    var body: some View {
        let mine = name == TranscriptSegment.you
        Text(name)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(mine ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07)))
            .foregroundStyle(mine ? Color.accentColor : Color.secondary)
            .lineLimit(1)
    }
}

/// Words dictated per day over the last two weeks.
struct ActivityChart: View {
    let days: [(date: Date, words: Int)]

    private var total: Int { days.reduce(0) { $0 + $1.words } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last two weeks").font(.headline)
                Spacer()
                Text("\(total.formatted()) words").font(.caption).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                let peak = max(days.map(\.words).max() ?? 1, 1)
                let slot = size.width / CGFloat(max(days.count, 1))
                let width = slot * 0.6
                for (index, day) in days.enumerated() {
                    let height = max(3, CGFloat(day.words) / CGFloat(peak) * (size.height - 4))
                    let rect = CGRect(x: CGFloat(index) * slot + (slot - width) / 2, y: size.height - height, width: width, height: height)
                    let today = index == days.count - 1
                    let color: Color = day.words == 0 ? Color.primary.opacity(0.08) : Color.accentColor.opacity(today ? 1 : 0.55)
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

/// A binder at a glance: its colour on the spine, what's in it, what's open, and when it was last touched.
struct BinderCard: View {
    let binder: BinderRecord
    let openCount: Int
    let meetingCount: Int
    let noteCount: Int
    let lastActivity: Date?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(binder.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    if binder.isTeamCopy || binder.sharedWithTeam {
                        Image(systemName: binder.isTeamCopy ? "person.2.fill" : "person.2").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(meetingCount) \(meetingCount == 1 ? "meeting" : "meetings") · \(noteCount) \(noteCount == 1 ? "note" : "notes")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if openCount > 0 { Badge(text: "\(openCount) open", color: .accentColor) }
                    if let lastActivity {
                        Text(lastActivity, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
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
        .onHover { hovering = $0 }
    }
}
