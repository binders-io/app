import SwiftData
import SwiftUI
import BindersKit

/// One day, filled in by itself: its meetings and their action items, the notes you worked on, promises made and to-dos
/// due, cards that moved on the boards, and what you dictated, next to a note of your own for the day. ‹ and › go back
/// through the days; yesterday's page is a record of yesterday.
struct TodayView: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(CommitmentService.self) private var commitmentService
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var meetings: [MeetingRecord]
    @Query(sort: \NoteItem.updatedAt, order: .reverse) private var notes: [NoteItem]
    @Query(sort: \CommitmentRecord.createdAt, order: .reverse) private var commitments: [CommitmentRecord]
    @Query(sort: \TranscriptRecord.createdAt, order: .reverse) private var records: [TranscriptRecord]
    @Query(sort: \TaskEvent.createdAt, order: .reverse) private var events: [TaskEvent]
    @Query private var cards: [TaskCard]
    @Query private var binders: [BinderRecord]
    @State private var day = Calendar.current.startOfDay(for: Date())

    private var calendar: Calendar { .current }
    private var isToday: Bool { calendar.isDateInToday(day) }
    private func onDay(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: day) }

    // MARK: The day's things

    /// The note for the day, titled by its date as Obsidian does, so [[2026-09-28]] links to it.
    private var dailyTitle: String { TodayView.dailyTitle(for: day) }
    static func dailyTitle(for day: Date) -> String { day.formatted(.iso8601.year().month().day()) }

    private var dailyNote: NoteItem? { notes.first { $0.title == dailyTitle } }
    private var dayMeetings: [MeetingRecord] { meetings.filter { onDay($0.createdAt) }.sorted { $0.createdAt < $1.createdAt } }
    private var dayNotes: [NoteItem] { notes.filter { onDay($0.updatedAt) && $0.title != dailyTitle } }
    private var dictations: [TranscriptRecord] { records.filter { onDay($0.createdAt) && $0.mode == "dictation" && $0.status == "inserted" } }

    /// Promises made that day; on today's page, also whatever is still open and due by the end of it.
    private var dayCommitments: [CommitmentRecord] {
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return commitments.filter { record in
            guard record.status != "dismissed" else { return false }
            if onDay(record.createdAt) { return true }
            return isToday && record.status == "open" && (record.dueAt.map { $0 < end } ?? false)
        }
    }

    /// Cards with something on their timeline that day, the latest first, each with its last event.
    private var movedCards: [(card: TaskCard, event: TaskEvent)] {
        var seen = Set<UUID>()
        return events.filter { onDay($0.createdAt) }.compactMap { event in
            guard seen.insert(event.taskID).inserted, let card = cards.first(where: { $0.id == event.taskID }) else { return nil }
            return (card, event)
        }
    }

    private var tasks: [TaskEntry] {
        TaskCollector.collect(meetings: dayMeetings, notes: [], commitments: dayCommitments,
                              openMeeting: { open(meeting: $0) }, openNote: { _ in },
                              commitmentActions: CommitmentActions(toggle: { commitmentService.toggle($0) },
                                                                   dismiss: { commitmentService.setStatus($0, "dismissed") },
                                                                   open: { record in
                                                                       navigation.pendingWritingSearch = record.quote ?? record.task
                                                                       navigation.selection = .writing
                                                                   }))
    }

    // MARK: The page

    var body: some View {
        let tasks = tasks
        let moved = movedCards
        let dictations = dictations
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(dictations: dictations, moved: moved.count)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        journal
                        if !dayMeetings.isEmpty || !tasks.isEmpty {
                            section(dayMeetings.isEmpty ? "Promises and to-dos" : "Meetings, promises and to-dos") {
                                TaskBoard(tasks: tasks, binderName: { id in binders.first { $0.id == id }?.name })
                            }
                        }
                        if !dayNotes.isEmpty {
                            section("Notes you worked on") {
                                ForEach(dayNotes) { note in
                                    row(symbol: "note.text", title: note.title, detail: binderName(note.binderID)) { open(note: note) }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 16) {
                        if !moved.isEmpty {
                            section("On the boards") {
                                ForEach(moved, id: \.card.id) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Button(item.card.title) { open(card: item.card) }
                                            .buttonStyle(.link)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        EventRow(event: item.event)
                                    }
                                }
                            }
                        }
                        if !dictations.isEmpty {
                            section("You dictated") {
                                ForEach(dictations.prefix(6)) { record in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.finalText).lineLimit(2).font(.callout)
                                        Text([record.appName, record.createdAt.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if dictations.count > 6 { Text("and \(dictations.count - 6) more").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if moved.isEmpty, dictations.isEmpty, dayMeetings.isEmpty, dayNotes.isEmpty, tasks.isEmpty {
                            Text(isToday ? "Meetings, notes, promises, cards and dictations from today show up here as they happen."
                                 : "Nothing was recorded on this day.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .paperCard(padding: 16)
                        }
                    }
                    .frame(width: 340, alignment: .topLeading)
                }
            }
            .padding(28)
        }
    }

    private func header(dictations: [TranscriptRecord], moved: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(isToday ? "Today" : (calendar.isDateInYesterday(day) ? "Yesterday" : day.formatted(.dateTime.weekday(.wide))))
                    .font(BindersTheme.title(32))
                Text(summary(dictations: dictations, moved: moved)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("The day before")
                if !isToday {
                    Button("Today") { day = calendar.startOfDay(for: Date()) }
                }
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isToday)
                    .help("The day after")
            }
            .controlSize(.large)
        }
    }

    /// "Monday, September 28 · 2 meetings · 340 words dictated · 3 cards moved"
    private func summary(dictations: [TranscriptRecord], moved: Int) -> String {
        var parts = [day.formatted(.dateTime.weekday(.wide).month(.wide).day())]
        if !dayMeetings.isEmpty { parts.append(dayMeetings.count == 1 ? "1 meeting" : "\(dayMeetings.count) meetings") }
        let words = dictations.reduce(0) { $0 + $1.wordCount }
        if words > 0 { parts.append("\(words.formatted()) words dictated") }
        if moved > 0 { parts.append(moved == 1 ? "1 card moved" : "\(moved) cards moved") }
        return parts.joined(separator: " · ")
    }

    /// Your own note for the day. It's only made once you write something, so quiet days leave no empty notes.
    private var journal: some View {
        let title = dailyTitle
        let text = Binding<String>(get: { dailyNote?.text ?? "# \(title)\n\n" }, set: { newValue in
            if let note = dailyNote {
                NoteHistory.changed(note.id, previous: note.text)
                note.text = newValue
                note.updatedAt = Date()
            } else if newValue.trimmingCharacters(in: .whitespacesAndNewlines) != "# \(title)" {
                let note = NoteItem(text: newValue)
                note.binderID = Store.shared.defaultBinder().id
                Store.shared.insert(note)
            }
        })
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(isToday ? "Your notes for today" : "Your notes for the day").font(BindersTheme.columnTitle)
                Spacer()
                if let note = dailyNote {
                    Button("Open as Note") { open(note: note) }.buttonStyle(.link).font(.callout)
                }
            }
            MarkdownNoteEditor(text: text, fontSize: 14, placeholder: "", inset: NSSize(width: 8, height: 8), compactToolbar: true,
                               links: LinkTargets.forEditor(in: Store.shared.defaultBinder().id))
                .frame(height: 220)
                .id(title)
        }
        .paperCard(padding: 14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(BindersTheme.columnTitle)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(padding: 16)
    }

    private func row(symbol: String, title: String, detail: String, open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Button(title, action: open).buttonStyle(.link).lineLimit(1)
            Spacer(minLength: 0)
            if !detail.isEmpty { Badge(text: detail, color: .secondary) }
        }
    }

    // MARK: Going places

    private func step(_ days: Int) {
        guard let next = calendar.date(byAdding: .day, value: days, to: day) else { return }
        day = min(calendar.startOfDay(for: next), calendar.startOfDay(for: Date()))
    }

    private func binderName(_ id: UUID?) -> String { binders.first { $0.id == id }?.name ?? "" }

    private func show(binder id: UUID?, tab: BinderTab, then: (HubNavigation) -> Void) {
        navigation.binderID = id ?? Store.shared.defaultBinder().id
        navigation.pendingBinderTab = tab
        then(navigation)
        navigation.selection = .binder
    }

    private func open(meeting: MeetingRecord) { show(binder: meeting.binderID, tab: .meetings) { $0.pendingMeetingID = meeting.id } }
    private func open(note: NoteItem) { show(binder: note.binderID, tab: .notes) { $0.pendingNoteID = note.id } }
    private func open(card: TaskCard) { show(binder: card.binderID, tab: .board) { $0.pendingCardID = card.id } }
}
