import SwiftData
import SwiftUI
import BindersKit

/// One day, filled in by itself: its meetings and their action items, the conversations your iPhone heard, the notes you
/// worked on, promises made and to-dos due, cards that moved on the boards, and what you dictated, next to a note of your
/// own for the day. ‹ and › go back
/// through the days; yesterday's page is a record of yesterday.
struct TodayView: View {
    @State private var day = Calendar.current.startOfDay(for: Date())

    // A page per day: going to another day reads that day afresh.
    var body: some View { TodayPage(day: $day).id(day) }

    /// The note for the day, titled by its date as Obsidian does, so [[2026-09-28]] links to it.
    /// In the time zone you're in: ISO 8601 alone would date it in UTC, and east of it give yesterday's date.
    static func dailyTitle(for day: Date) -> String { day.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()) }
}

/// The page for one day. It reads only that day's meetings, notes, dictations and card moves (and what's due by its end,
/// and the promises still open), in a model kept up to date by saves, so a long history doesn't slow it down and drawing
/// it works nothing out.
private struct TodayPage: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(CommitmentService.self) private var commitmentService
    @Query private var binders: [BinderRecord]
    @Binding private var day: Date
    @State private var data = TodayData()

    init(day: Binding<Date>) {
        _day = day
    }

    private var calendar: Calendar { .current }
    /// The page's width from which the day's two columns go side by side: room for the note for the day and its
    /// toolbar beside the 340-point column.
    static let sideBySide: CGFloat = 772
    private var isToday: Bool { calendar.isDateInToday(day) }

    // MARK: The day's things

    private var dailyTitle: String { TodayView.dailyTitle(for: day) }

    private var taskActions: TaskActions {
        let commitmentService = commitmentService, navigation = navigation
        return TaskActions(openMeeting: { navigation.open(meeting: $0) }, openNote: { navigation.open(note: $0) }, commitments: CommitmentActions(
            toggle: { commitmentService.toggle($0) }, dismiss: { commitmentService.setStatus($0, "dismissed") }, open: { record in
                navigation.pendingWritingSearch = record.quote ?? record.task
                navigation.selection = .writing
            }))
    }

    // MARK: The page

    var body: some View {
        let tasks = data.tasks
        let moved = data.moved
        let dictations = data.dictations
        // Side by side while there's room for both columns; on a narrow page the second goes under the first.
        GeometryReader { proxy in
            let sideBySide = proxy.size.width >= Self.sideBySide
            let columns = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(dictations: dictations, moved: moved.count)
                    if isToday { NeedsYouStrip() }
                    columns {
                        VStack(alignment: .leading, spacing: 16) {
                            journal
                            if !data.meetings.isEmpty || !tasks.isEmpty {
                                // To-dos are cards now: the ones made this day, promises and all.
                                section("Cards made this day") {
                                    OpenCardsList(madeOn: day)
                                }
                                .transition(.filed)
                            }
                            if !data.conversations.isEmpty {
                                section("Captures") {
                                    ForEach(data.conversations) { conversation in
                                        ConversationRow(conversation: conversation, binder: binderName(conversation.binderID)) { open(meeting: conversation) }
                                            .transition(.filed)
                                    }
                                }
                                .transition(.filed)
                            }
                            if !data.dueNotes.isEmpty {
                                section("Notes due") {
                                    ForEach(data.dueNotes) { note in
                                        let late = (note.dueAt ?? day) < day
                                        row(symbol: late ? "clock" : "calendar", tint: late ? BindersTheme.needsYou : nil, title: note.title,
                                            detail: [note.status, late ? note.dueAt.map { "was due \($0.formatted(.dateTime.month(.abbreviated).day()))" } : nil,
                                                     note.owner].compactMap { $0 }.joined(separator: " · ")) { open(note: note) }
                                            .transition(.filed)
                                    }
                                }
                                .transition(.filed)
                            }
                            if !data.notes.isEmpty {
                                section("Notes you worked on") {
                                    ForEach(data.notes) { note in
                                        row(symbol: "note.text", title: note.title, detail: binderName(note.binderID)) { open(note: note) }
                                            .transition(.filed)
                                    }
                                    if data.moreNotes > 0 { Text("and \(data.moreNotes) more").font(.caption).foregroundStyle(.secondary).rollingCount(data.moreNotes) }
                                }
                                .transition(.filed)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 16) {
                            if isToday { WorkStreamsSection() }
                            if !moved.isEmpty {
                                section("On the boards") {
                                    ForEach(moved) { item in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Button(item.card.title) { open(card: item.card) }
                                                .themedLink()
                                                .font(.callout.weight(.medium))
                                                .lineLimit(1)
                                            EventRow(event: item.event, cardColumn: item.card.column)
                                        }
                                        .transition(.filed)
                                    }
                                }
                                .transition(.filed)
                            }
                            if !dictations.isEmpty {
                                section("You dictated") {
                                    ForEach(dictations.prefix(6)) { record in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(record.finalText).lineLimit(2).font(BindersTheme.quote(.callout))
                                            Text([record.appName, record.createdAt.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                                                .font(BindersTheme.time()).foregroundStyle(.secondary)
                                        }
                                        .transition(.filed)
                                    }
                                    if dictations.count > 6 { Text("and \(dictations.count - 6) more").font(.caption).foregroundStyle(.secondary).rollingCount(dictations.count - 6) }
                                }
                                .transition(.filed)
                            }
                            if data.loaded, moved.isEmpty, dictations.isEmpty, data.meetings.isEmpty, data.conversations.isEmpty, data.notes.isEmpty,
                               tasks.isEmpty, data.dueNotes.isEmpty {
                                Text(isToday ? "Meetings, notes, promises, cards and dictations from today show up here as they happen."
                                     : "Nothing was recorded on this day.")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .paperCard(padding: 16)
                                    .transition(.filed)
                            }
                        }
                        .frame(width: sideBySide ? 340 : nil, alignment: .topLeading)
                        .frame(maxWidth: sideBySide ? nil : .infinity, alignment: .topLeading)
                    }
                    // A new item files in and the sections around it make room.
                    .filing(filingKeys(tasks: tasks, moved: moved, dictations: dictations))
                }
                .padding(28)
            }
        }
        .onAppear { data.show(day, actions: taskActions) }
        .followingWorkStreams()
        // The day as first read just shows; what arrives after files in, and counts roll.
        .settlesAfterAppearing()
    }

    /// Everything the day lists, in order: when one is added, it files in.
    private func filingKeys(tasks: [TaskEntry], moved: [TodayData.Move], dictations: [TranscriptRecord]) -> [String] {
        data.meetings.map { "m" + $0.id.uuidString } + tasks.filter { !$0.done }.map { "t" + $0.id }
            + data.conversations.map { "c" + $0.id.uuidString } + data.dueNotes.map { "d" + $0.id.uuidString }
            + data.notes.map { "n" + $0.id.uuidString } + moved.map { "b" + $0.id.uuidString }
            + dictations.prefix(6).map { "s" + $0.id.uuidString }
    }

    private func header(dictations: [TranscriptRecord], moved: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(isToday ? "Today" : (calendar.isDateInYesterday(day) ? "Yesterday" : day.formatted(.dateTime.weekday(.wide))))
                    .font(BindersTheme.title(32))
                Text(summary(dictations: dictations, moved: moved)).foregroundStyle(.secondary)
                    .rollingCount(summary(dictations: dictations, moved: moved))
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
                    .fitProbe("today.header.last")
            }
            .controlSize(.large)
        }
    }

    /// "Monday, September 28 · 2 meetings · 340 words dictated · 3 cards moved"
    private func summary(dictations: [TranscriptRecord], moved: Int) -> String {
        var parts = [day.formatted(.dateTime.weekday(.wide).month(.wide).day())]
        let meetings = data.meetings.count, captures = data.conversations.count
        if meetings > 0 { parts.append(meetings == 1 ? "1 meeting" : "\(meetings) meetings") }
        if captures > 0 { parts.append(captures == 1 ? "1 capture" : "\(captures) captures") }
        let words = dictations.reduce(0) { $0 + $1.wordCount }
        if words > 0 { parts.append("\(words.formatted()) words dictated") }
        if moved > 0 { parts.append(moved == 1 ? "1 card moved" : "\(moved) cards moved") }
        return parts.joined(separator: " · ")
    }

    /// Your own note for the day. It's only made once you write something, so quiet days leave no empty notes.
    private var journal: some View {
        let title = dailyTitle
        let data = data
        let text = Binding<String>(get: { data.dailyNote?.text ?? "# \(title)\n\n" }, set: { newValue in
            if let note = data.dailyNote {
                NoteHistory.changed(note.id, previous: note.text)
                note.text = newValue
                note.updatedAt = Date()
            } else if newValue.trimmingCharacters(in: .whitespacesAndNewlines) != "# \(title)", Store.shared.allowsSave() {
                let note = NoteItem(text: newValue)
                note.binderID = Store.shared.defaultBinder().id
                Store.shared.insert(note)
                data.made(note)
            }
        })
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(isToday ? "Your notes for today" : "Your notes for the day").font(BindersTheme.columnTitle)
                Spacer()
                if let note = data.dailyNote {
                    Button("Open as Note") { open(note: note) }.themedLink().font(.callout)
                }
            }
            MarkdownNoteEditor(text: text, fontSize: 14, placeholder: "", inset: NSSize(width: 8, height: 8), compactToolbar: true,
                               links: LinkTargets.forEditor(in: Store.shared.defaultBinder().id), paper: true)
                .paperSheet(radius: 10)
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

    private func row(symbol: String, tint: Color? = nil, title: String, detail: String, open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)).frame(width: 16)
            Button(title, action: open).themedLink().lineLimit(1)
            Spacer(minLength: 0)
            if !detail.isEmpty { Badge(text: detail).filingChip() }
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

    private func open(meeting: MeetingRecord) { show(binder: meeting.binderID, tab: .listing(meeting)) { $0.pendingMeetingID = meeting.id } }
    private func open(note: NoteItem) { show(binder: note.binderID, tab: .notes) { $0.pendingNoteID = note.id } }
    private func open(card: TaskCard) { navigation.open(card: card) }
}

/// One conversation on the Today page: when, what it was about, where it went, and the gist.
private struct ConversationRow: View {
    @Environment(MeetingService.self) private var service
    let conversation: MeetingRecord
    let binder: String
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: conversation.symbol).font(.caption).foregroundStyle(.secondary).frame(width: 16)
                Button(conversation.title, action: open).themedLink().lineLimit(1)
                Spacer(minLength: 0)
                // Its binder's chip slides in as the capture files in.
                if !binder.isEmpty { Badge(text: binder).filingChip() }
            }
            Text(times + (gist.map { " · \($0)" } ?? ""))
                .font(BindersTheme.time())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.leading, 24)
        }
    }

    private var times: String {
        let start = conversation.createdAt.formatted(date: .omitted, time: .shortened)
        let range = conversation.endedAt.map { start + "–" + $0.formatted(date: .omitted, time: .shortened) } ?? start
        if service.busyMeetingIDs.contains(conversation.id) || conversation.status == "processing" { return range + " · writing notes…" }
        return range
    }

    /// The first line of its summary.
    private var gist: String? {
        conversation.summary.components(separatedBy: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
    }
}
