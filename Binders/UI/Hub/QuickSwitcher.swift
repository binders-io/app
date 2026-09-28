import SwiftData
import SwiftUI
import BindersKit

/// What the switcher looks through: places to go (⌘O), or things to do (⌘P, or ">" first).
enum SwitcherMode {
    case open, commands
}

/// One row in the switcher: a binder, note, meeting, card, person or page to open, or a command to run.
struct SwitcherItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var date: Date? = nil
    /// Nudges the order when two titles match as well: binders first, pages last.
    var boost = 0
    let run: @MainActor () -> Void

    /// The items that match `query`, best first, ties going to the most recent.
    static func ranked(_ items: [SwitcherItem], for query: String, limit: Int = 12) -> [SwitcherItem] {
        items.compactMap { item in FuzzyMatch.score(query, in: item.title).map { (item: item, score: $0 + item.boost) } }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return (a.item.date ?? .distantPast) > (b.item.date ?? .distantPast)
            }
            .prefix(limit)
            .map(\.item)
    }
}

/// ⌘O: jump to any binder, note, meeting, card, person or page by typing a few letters. ⌘P, or ">" first: run a command.
/// ↑ and ↓ choose, Return opens, Esc closes.
struct QuickSwitcher: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @Environment(KnowledgeService.self) private var knowledge
    @Environment(TeamSyncService.self) private var team
    @Query private var binders: [BinderRecord]
    @Query(sort: \NoteItem.updatedAt, order: .reverse) private var notes: [NoteItem]
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var meetings: [MeetingRecord]
    @Query(sort: \TaskCard.updatedAt, order: .reverse) private var cards: [TaskCard]
    @State private var query: String
    @State private var selected = 0
    @State private var entities: [KnowledgeEntity] = []
    @FocusState private var focused: Bool
    let mode: SwitcherMode

    init(mode: SwitcherMode, query: String = "") {
        self.mode = mode
        _query = State(initialValue: query)
    }

    private var commandsOnly: Bool { mode == .commands || query.hasPrefix(">") }
    private var typed: String { (query.hasPrefix(">") ? String(query.dropFirst()) : query).trimmingCharacters(in: .whitespaces) }

    private var results: [SwitcherItem] {
        if typed.isEmpty { return commandsOnly ? Array(commands.prefix(12)) : recents }
        return SwitcherItem.ranked(commandsOnly ? commands : places, for: typed)
    }

    var body: some View {
        let results = results
        // The list can shrink under the selection, as more comes in; keep it on a row.
        let current = min(selected, max(results.count - 1, 0))
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: commandsOnly ? "chevron.right.2" : "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                TextField(commandsOnly ? "Type a command" : "Jump to a binder, note, meeting, card or person", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { open(results, at: current) }
                    .onKeyPress(.downArrow) { move(1, from: current, in: results) }
                    .onKeyPress(.upArrow) { move(-1, from: current, in: results) }
                    .onExitCommand { close() }
                Text(commandsOnly ? "⌘O to find" : "> for commands")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()
            if results.isEmpty {
                Text(commandsOnly ? "No command matches “\(typed)”." : "Nothing matches “\(typed)”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else if results.count > 8 {
                ScrollViewReader { scroller in
                    ScrollView { list(results, current: current) }
                        .frame(height: 380)
                        .onChange(of: current) { scroller.scrollTo(current) }
                }
            } else {
                list(results, current: current)
            }
        }
        .frame(width: 600)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
        .task { entities = await knowledge.store.entities(limit: 400) }
    }

    /// The rows, with the keyboard's choice highlighted. A click opens a row; the pointer doesn't move the choice, so it
    /// can rest over the list while you type.
    private func list(_ results: [SwitcherItem], current: Int) -> some View {
        VStack(spacing: 2) {
            if typed.isEmpty, !commandsOnly {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                row(item, selected: index == current)
                    .id(index)
                    .onTapGesture { run(item) }
            }
        }
        .padding(6)
    }

    private func row(_ item: SwitcherItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if selected { Image(systemName: "return").font(.caption).foregroundStyle(.white.opacity(0.8)) }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
    }

    // MARK: Keys

    private func move(_ step: Int, from current: Int, in results: [SwitcherItem]) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        selected = (current + step + results.count) % results.count
        return .handled
    }

    private func open(_ results: [SwitcherItem], at index: Int) {
        guard results.indices.contains(index) else { return }
        run(results[index])
    }

    private func run(_ item: SwitcherItem) {
        close()
        item.run()
    }

    private func close() {
        navigation.switcher = nil
    }

    // MARK: Places

    private func binderName(_ id: UUID?) -> String {
        binders.first { $0.id == id }?.name ?? ""
    }

    private var places: [SwitcherItem] {
        var items: [SwitcherItem] = binders.map { binder in
            SwitcherItem(id: "b:\(binder.id)", title: binder.name, subtitle: binder.archived ? "Binder · archived" : "Binder",
                         symbol: "books.vertical", date: binder.updatedAt, boost: binder.archived ? -3 : 3) { show(binder: binder.id, tab: .overview) }
        }
        items += notes.prefix(500).map { note in
            SwitcherItem(id: "n:\(note.id)", title: note.title, subtitle: ["Note", binderName(note.binderID)].filter { !$0.isEmpty }.joined(separator: " · "),
                         symbol: "note.text", date: note.updatedAt) { show(binder: note.binderID, tab: .notes) { $0.pendingNoteID = note.id } }
        }
        items += meetings.prefix(400).map { meeting in
            SwitcherItem(id: "m:\(meeting.id)", title: meeting.title,
                         subtitle: ["Meeting", binderName(meeting.binderID), meeting.createdAt.formatted(date: .abbreviated, time: .omitted)]
                            .filter { !$0.isEmpty }.joined(separator: " · "),
                         symbol: "person.2.wave.2", date: meeting.createdAt) { show(binder: meeting.binderID, tab: .meetings) { $0.pendingMeetingID = meeting.id } }
        }
        items += cards.prefix(400).map { card in
            SwitcherItem(id: "c:\(card.id)", title: card.title, subtitle: ["Card", card.column.title, binderName(card.binderID)].filter { !$0.isEmpty }.joined(separator: " · "),
                         symbol: "rectangle.split.3x1", date: card.updatedAt, boost: card.column == .done ? -2 : 0) {
                show(binder: card.binderID, tab: .board) { $0.pendingCardID = card.id }
            }
        }
        items += entities.map { entity in
            let kind = entity.type.prefix(1).uppercased() + entity.type.dropFirst()
            return SwitcherItem(id: "e:\(entity.id)", title: entity.name,
                                subtitle: "\(kind) · \(entity.mentions == 1 ? "1 mention" : "\(entity.mentions) mentions")",
                                symbol: entity.type == "person" ? "person" : (entity.type == "project" ? "folder" : "tag"), boost: -1) {
                navigation.pendingEntityID = entity.id
                navigation.selection = .knowledge
            }
        }
        items += HubSection.allCases.filter { $0 != .binder }.map { section in
            SwitcherItem(id: "p:\(section.rawValue)", title: section.title, subtitle: "Page", symbol: section.symbol, boost: -2) {
                navigation.selection = section
            }
        }
        return items
    }

    /// With nothing typed: what changed last, then the binders.
    private var recents: [SwitcherItem] {
        let recent = places.filter { $0.id.hasPrefix("n:") || $0.id.hasPrefix("m:") || $0.id.hasPrefix("c:") }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(8)
        let shelf = places.filter { $0.id.hasPrefix("b:") && $0.boost > 0 }.prefix(4)
        return Array(recent) + Array(shelf)
    }

    /// Opens a binder's page on a tab; `then` sets what to open there.
    private func show(binder id: UUID?, tab: BinderTab, then: ((HubNavigation) -> Void)? = nil) {
        navigation.binderID = id ?? Store.shared.defaultBinder().id
        navigation.pendingBinderTab = tab
        then?(navigation)
        navigation.selection = .binder
    }

    // MARK: Commands

    /// The binder new things go into: the one open, or the current one.
    private var here: BinderRecord {
        let id = navigation.selection == .binder ? navigation.binderID : AppSettings.shared.currentBinderID
        return binders.first { $0.id == id } ?? Store.shared.defaultBinder()
    }

    private var commands: [SwitcherItem] {
        let binder = here
        func command(_ title: String, _ symbol: String, _ subtitle: String = "", run: @escaping @MainActor () -> Void) -> SwitcherItem {
            SwitcherItem(id: "x:\(title)", title: title, subtitle: subtitle, symbol: symbol, run: run)
        }
        var items = [
            command("New Note", "square.and.pencil", "In \(binder.name)") {
                let note = NoteItem()
                note.binderID = binder.id
                note.sharedWithTeam = binder.sharedWithTeam
                Store.shared.insert(note)
                show(binder: binder.id, tab: .notes) { $0.pendingNoteID = note.id }
            },
            command("Open Scratchpad", "note.text.badge.plus") { ScratchpadController.shared.show() },
            command(controller.meetings.isRecording ? "Stop Meeting Notes" : "Start Meeting Notes", "record.circle") {
                Task { await controller.meetings.toggle() }
            },
            command(controller.capture.isOn ? "Turn Off Writing Capture" : "Turn On Writing Capture", "pencil.line") { controller.capture.toggle() },
            command("Ask Your Work", "sparkles", "Search and ask everything in Binders") { navigation.selection = .knowledge },
        ]
        items += BinderTab.allCases.map { tab in
            command("Show \(binder.name): \(tab.rawValue)", "books.vertical") { show(binder: binder.id, tab: tab) }
        }
        if team.isConfigured, !binder.isTeamCopy {
            items.append(command(binder.sharedWithTeam ? "Stop Sharing \(binder.name)" : "Share \(binder.name) with the Team", "person.2") {
                team.setShared(binder, !binder.sharedWithTeam)
            })
        }
        items += SettingsPage.visible.map { page in
            command("Settings: \(page.title)", "gearshape") {
                navigation.pendingSettingsPage = page
                navigation.selection = .settings
            }
        }
        items.append(command("Check for Updates", "arrow.down.circle") { UpdateService.shared.checkNow() })
        return items
    }
}
