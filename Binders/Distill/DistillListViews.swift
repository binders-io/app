import AppKit
import SwiftUI
import BindersKit

// MARK: - The Distill list

/// Lane DS9: the Distill list beside the note: what's being read and how far it's got (with Cancel), then a row per item in
/// the note's order. ↑/↓ moves, Return accepts (places it on the board as Place on Board does), Delete dismisses, Space
/// opens it to edit, ⌘Return accepts every one left; Undo puts either back. A row's menu has Split, Merge, Move and the
/// lines in the note. Built from the Work panel's pieces: its title, rows, pills and colours.
struct DistillListPanel: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.undoManager) private var undoManager
    let note: NoteItem
    /// Over the note, where there's no room beside it: its close button.
    var onClose: (() -> Void)? = nil
    @FocusState private var focused: Bool
    @State private var reviewing: DistillRecord?
    @State private var confirmOff: NoteItem?
    @State private var tick = 0
    @ReducedMotion private var reduceMotion

    var body: some View {
        let service = controller.distill
        let list = service.list(for: note.id)
        let _ = (DistillStore.shared.revision, service.boardRevision, tick)
        let rows = list.rows(service, text: note.text)
        VStack(alignment: .leading, spacing: 10) {
            header(rows: rows, list: list)
            statusLine(rows: rows, list: list)
            ForEach(list.placed) { placed in placedLine(placed, list: list) }
            if rows.isEmpty {
                emptyState(list: list)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(rows) { row in
                                DistillRowView(row: row, note: note, rows: rows, list: list, accept: { accept([row.id]) }, dismiss: { dismiss([row.id]) })
                                    .id(row.id)
                                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .trailing))))
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 1)
                        .animation(BindersTheme.motion(BoardDesign.settle, reduced: reduceMotion), value: rows.map(\.id))
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: DistillViewportFrame.self, value: proxy.frame(in: .named(DistillStage.space)))
                    })
                    .onChange(of: list.selected) { _, id in
                        guard let id else { return }
                        withAnimation(BindersTheme.motion(BoardDesign.settle, reduced: reduceMotion)) { proxy.scrollTo(id, anchor: nil) }
                    }
                    // While a reading you started runs, the newest row is kept in sight, so its card lands where you see it.
                    .onChange(of: list.launches.last?.id) { _, id in
                        guard let id, list.selected == nil else { return }
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                    // Read: back to the first item.
                    .onChange(of: controller.distill.reading.contains(note.id)) { _, reading in
                        guard !reading, list.selected == nil, let first = rows.first?.id else { return }
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
                footer(rows: rows)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in key(press, rows: rows, list: list) }
        .onChange(of: list.focusRequest) { focused = true }
        .onAppear {
            list.looked()
            if list.focusRequest > 0 { focused = true }
        }
        .sheet(item: $reviewing) { proposal in
            DistillReviewSheet(distill: proposal, note: note).environment(controller)
                .onAppear { controller.teamBoard.notes.reviewing(note.id, distill: proposal.id) }
                .onDisappear { controller.teamBoard.notes.reviewing(note.id, distill: nil) }
        }
        .confirmsStopDistilling($confirmOff, controller: controller)
        .teamConsent(Binding(get: { list.asking }, set: { list.asking = $0 })) { consent in
            TeamBoard.current?.agree(to: consent.agent)
            accept(list.askingItems)
        }
        // "Up to date · read 2 minutes ago" keeps its minutes.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                tick += 1
            }
        }
    }

    // MARK: Parts

    private func header(rows: [DistillListRow], list: DistillListModel) -> some View {
        HStack(spacing: 7) {
            Image(systemName: BindersTheme.modelSymbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.tintText)
            Text("Distill").font(BoardDesign.panelTitle).foregroundStyle(.sectionInk)
            if !rows.isEmpty {
                Text("\(rows.count)")
                    .font(BoardDesign.columnCount)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(BindersTheme.ink.opacity(0.07)))
                    .foregroundStyle(.secondary)
                    .rollingCount(rows.count)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Accept All") { accept(rows.map(\.id)) }
                    .disabled(rows.isEmpty)
                Button("Distill Again") { DistillActions.start(note, controller: controller, full: true) }
                    .disabled(controller.distill.reading.contains(note.id))
                Button("Review All…") { reviewing = DistillStore.shared.file(for: note.id).proposal }
                    .disabled(DistillStore.shared.file(for: note.id).proposal == nil)
                Divider()
                Button("Turn Off Distill for This Note…") {
                    if controller.distill.openCards(of: note).isEmpty { controller.distill.setDistill(false, for: note) } else { confirmOff = note }
                }
                if let onClose {
                    Divider()
                    Button("Close", action: onClose)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .quietControl()
            .help("Accept All, Distill Again (reads the whole note once more), Review All in the review sheet, or turn Distill off for this note")
            .accessibilityLabel("More for Distill")
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .quietControl()
                    .help("Close the Distill list")
                    .accessibilityLabel("Close")
            }
        }
        .fitProbe("distill.list")
    }

    /// What's being read and how far it's got, with Cancel; or Up to date; or what went wrong. Every wait says why.
    @ViewBuilder
    private func statusLine(rows: [DistillListRow], list: DistillListModel) -> some View {
        let service = controller.distill
        if service.reading.contains(note.id), !service.quietReading.contains(note.id) {
            HStack(spacing: 7) {
                DistillReadingDot()
                Text(service.readingLine(note.id))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .rollingCount(service.readingLine(note.id))
                Spacer(minLength: 4)
                Button("Cancel") { service.stopReading(note.id) }
                    .controlSize(.small)
                    .disabled(service.stopping.contains(note.id))
                    .help("Stop reading: the items found so far stay in the list, and Distill reads the rest next time.")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.infoFill(0.08)))
        } else if let why = service.problems[note.id] {
            StatusLabel(why, .problem).font(.system(size: 11.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        } else if let until = list.upToDateUntil, until > Date().addingTimeInterval(-60), let line = DistillActions.upToDateLine(note.id) {
            Label(line, systemImage: "checkmark.circle")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Nothing in the note changed since it was last read, so the model wasn't asked. Distill Again, in the ⋯ menu, reads it all once more.")
        } else if let said = service.said[note.id] {
            Text(said).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func placedLine(_ placed: DistillListModel.Placed, list: DistillListModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: BindersTheme.readySymbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(BindersTheme.done)
            Text(placed.line).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text("·").foregroundStyle(.tertiary)
            Button("Undo") { list.unplace(placed, service: controller.distill) }
                .buttonStyle(.borderless)
                .themedLink()
                .font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func emptyState(list: DistillListModel) -> some View {
        let service = controller.distill
        let reading = service.reading.contains(note.id) && !service.quietReading.contains(note.id)
        if !reading {
            VStack(alignment: .leading, spacing: 8) {
                Text(DistillStore.shared.file(for: note.id).distills.isEmpty
                     ? "Distill reads the note into work items, each with who it's for. They show here as they're found, and nothing reaches the board until you accept it."
                     : "Nothing waits for you here. As you write, Distill reads what changed, and new items show here.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.surface))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(BindersTheme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
    }

    private func footer(rows: [DistillListRow]) -> some View {
        HStack(spacing: 8) {
            Text("↩ Accept  ⌫ Dismiss  Space Edit")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(BindersTheme.faint)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("↑ and ↓ move between items. Return accepts one, Delete dismisses it, Space opens it to edit, ⌘Return accepts every one left. Undo puts it back.")
            Spacer(minLength: 4)
            Button { accept(rows.map(\.id)) } label: {
                Text(rows.count == 1 ? "Accept" : "Accept All").font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .help("Place every item left on the board, each as Place on Board would (⌘Return)")
        }
        .padding(.top, 2)
    }

    // MARK: Keys

    private func key(_ press: KeyPress, rows: [DistillListRow], list: DistillListModel) -> KeyPress.Result {
        let key: DistillListModel.Key
        switch press.key {
        case .downArrow: key = .down
        case .upArrow: key = .up
        case .return: key = press.modifiers.contains(.command) ? .acceptAll : .accept
        case .delete, .deleteForward: key = .dismiss
        case .space: key = .edit
        case .escape: key = .escape
        default: return .ignored
        }
        switch list.key(key, rows: rows) {
        case nil: return .ignored
        case .handled: return .handled
        case .accept(let ids): accept(ids)
        case .dismiss(let ids): dismiss(ids)
        }
        return .handled
    }

    private func accept(_ ids: [UUID]) {
        controller.distill.list(for: note.id).accept(ids, service: controller.distill, undo: undoManager)
    }

    private func dismiss(_ ids: [UUID]) {
        controller.distill.list(for: note.id).dismiss(ids, service: controller.distill, undo: undoManager)
    }
}

/// A small light that breathes while the note is read: never a spinner on its own, always beside what's being read.
struct DistillReadingDot: View {
    @ReducedMotion private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * 3.2) + 1) / 2
            ZStack {
                Circle().fill(TintFill().opacity(0.22 + 0.2 * phase)).frame(width: 12, height: 12).scaleEffect(0.8 + 0.35 * phase)
                Circle().fill(TintFill()).frame(width: 6, height: 6)
            }
            .frame(width: 14, height: 14)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - A row

/// One item of the Distill list: its title, who it's for and how big, and its section, in the Work panel's look; the colour
/// of who it's for down its edge. Selected, its lines light in the note; open (Space), its title, who, size and column
/// can be changed.
struct DistillRowView: View {
    @Environment(DictationController.self) private var controller
    let row: DistillListRow
    let note: NoteItem
    let rows: [DistillListRow]
    let list: DistillListModel
    let accept: () -> Void
    let dismiss: () -> Void
    @State private var hovering = false
    @ReducedMotion private var reduceMotion

    var body: some View {
        let item = row.item
        let selected = list.selected == item.id
        let accent = row.offer != nil ? BindersTheme.needsYou : DistillListModel.color(for: item)
        let editing = list.editing == item.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                if list.newItems.contains(item.id) {
                    Circle().fill(TintFill()).frame(width: 6, height: 6).padding(.top, 6).accessibilityLabel("New")
                }
                if editing {
                    TextField("What to do", text: binding(\.title))
                        .textFieldStyle(.plain)
                        .font(BoardDesign.panelRowTitle)
                        .onSubmit { list.editing = nil }
                } else {
                    Text(item.title)
                        .font(BoardDesign.panelRowTitle)
                        .foregroundStyle(BindersTheme.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if hovering, !editing, !row.live {
                    HStack(spacing: 2) {
                        Button(action: accept) { Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)) }
                            .help("Accept: place it on the board (Return)")
                            .accessibilityLabel("Accept")
                        Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)) }
                            .help("Dismiss: leave it out, and Distill won't propose it again (Delete)")
                            .accessibilityLabel("Dismiss")
                    }
                    .buttonStyle(.borderless)
                    .quietControl()
                    .transition(.opacity)
                }
            }
            if editing {
                DistillRowEditor(item: item, note: note, list: list)
            } else {
                Wrapping(spacing: 4, lineSpacing: 4) {
                    if let offer = row.offer {
                        BoardPill(text: offer.kind == .brief ? "Update its brief" : "Close the card",
                                  symbol: offer.kind == .brief ? "arrow.triangle.2.circlepath" : "xmark.circle", color: BindersTheme.needsYou, strong: true)
                            .help(offer.kind == .brief ? "Its section changed. Accept brings the card's brief up to date with it; Dismiss leaves the card as it is."
                                  : "Its section is gone from the note. Accept closes the card (Done, counted as closed); Dismiss leaves it.")
                    } else {
                        whoPill(item, accent: accent)
                    }
                    if let size = item.size {
                        BoardPill(text: size.title, symbol: "gauge.with.dots.needle.33percent", color: BindersTheme.muted)
                    }
                    if list.columns[item.id] == .backlog {
                        BoardPill(text: "Backlog", symbol: "tray", color: BindersTheme.muted)
                    }
                    if list.pendingAccept[item.id] != nil {
                        BoardPill(text: "Accepted once read", symbol: BindersTheme.readySymbol, color: BindersTheme.done)
                    }
                }
                Label(item.section ?? DistillSections.openingTitle, systemImage: "text.alignleft")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected || hovering ? BindersTheme.surface2 : BindersTheme.surface))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(TintFill().opacity(0.85)) : AnyShapeStyle(hovering ? BindersTheme.lineStrong : BindersTheme.line),
                              style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: row.live ? [4, 3] : []))
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent.opacity(selected ? 1 : 0.85))
                .frame(width: 2.5)
                .padding(.vertical, 9)
                .padding(.leading, 1)
        }
        .shadow(color: .black.opacity(hovering || selected ? 0.10 : 0), radius: 7, y: 2)
        .opacity(list.inFlight(item.id) && !reduceMotion ? 0 : 1)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: DistillRowFrames.self, value: [item.id: proxy.frame(in: .named(DistillStage.space))])
        })
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { list.selected = selected ? nil : item.id }
        .onHover { inside in
            withAnimation(BoardDesign.settle) { hovering = inside }
            list.hovered = inside ? item.id : (list.hovered == item.id ? nil : list.hovered)
        }
        .contextMenu { menu(item) }
        .animation(BoardDesign.settle, value: hovering)
        .animation(BoardDesign.settle, value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), for \(DistillListModel.who(item))\(item.size.map { ", \($0.title.lowercased())" } ?? ""), \(item.section ?? DistillSections.openingTitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func whoPill(_ item: DistillItem, accent: Color) -> some View {
        let who = DistillListModel.who(item)
        let agent = item.meantFor.map { AgentRegistry.shared.agent(named: $0) != nil || TeamBoard.current?.teammatesAgent(named: $0) != nil } ?? (item.hint == .agent)
        // No one picked yet: what the reader said it needs, until someone is.
        return BoardPill(text: item.meantFor == nil ? (item.hint == .agent ? "For an agent" : item.hint == .person ? "For a person" : who) : who,
                         symbol: agent ? BindersTheme.agentSymbol : item.meantFor == nil ? "person.crop.circle.dashed" : "person.fill",
                         color: accent, strong: item.meantFor != nil)
    }

    @ViewBuilder
    private func menu(_ item: DistillItem) -> some View {
        Button("Accept") { accept() }
        Button("Dismiss") { dismiss() }
        Button("Edit") { list.editing = item.id }.disabled(row.live || row.offer != nil)
        Divider()
        Button("Split") { list.split(item.id) }.disabled(row.live || row.offer != nil)
        if let next = list.neighbour(of: item.id, offset: 1, in: rows, sameSection: false) {
            Button("Merge with Next") { list.merge(item.id, with: next) }
        } else {
            Button("Merge with Next") {}.disabled(true)
        }
        Button("Move Up") { if let other = list.neighbour(of: item.id, offset: -1, in: rows, sameSection: true) { list.move(item.id, with: other) } }
            .disabled(list.neighbour(of: item.id, offset: -1, in: rows, sameSection: true) == nil)
        Button("Move Down") { if let other = list.neighbour(of: item.id, offset: 1, in: rows, sameSection: true) { list.move(item.id, with: other) } }
            .disabled(list.neighbour(of: item.id, offset: 1, in: rows, sameSection: true) == nil)
        Divider()
        Button("Show in the Note") { list.selected = item.id }
        Button("Drop", role: .destructive) { dismiss() }
    }

    private func binding(_ path: WritableKeyPath<DistillItem, String>) -> Binding<String> {
        Binding(get: { row.item[keyPath: path] }, set: { value in list.edit(row.id) { $0[keyPath: path] = value } })
    }
}

/// A row opened with Space: who it's for, how big, and where it goes; its brief and done when, which are written once it's
/// placed (lane DS8) or as read.
struct DistillRowEditor: View {
    @Environment(DictationController.self) private var controller
    let item: DistillItem
    let note: NoteItem
    let list: DistillListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("For", selection: Binding(get: { item.meantFor ?? "" }, set: { value in
                list.edit(item.id) {
                    $0.meantFor = value.isEmpty ? nil : value
                    $0.meantForHow = "you"
                }
            })) {
                Text("No one yet").tag("")
                ForEach(people, id: \.self) { Text($0 == BoardActor.you.name ? "You" : $0).tag($0) }
            }
            Picker("Size", selection: Binding(get: { item.size }, set: { value in list.edit(item.id) { $0.size = value } })) {
                Text("No size").tag(DistillItem.Size?.none)
                ForEach(DistillItem.Size.allCases, id: \.self) { Text($0.title).tag(DistillItem.Size?.some($0)) }
            }
            Picker("Goes to", selection: Binding(get: { list.columns[item.id] ?? .ready }, set: { list.columns[item.id] = $0 })) {
                Text("\(Store.shared.binder(note.binderID)?.name ?? "Board") · Ready").tag(BoardColumn.ready)
                Text("\(Store.shared.binder(note.binderID)?.name ?? "Board") · Backlog").tag(BoardColumn.backlog)
            }
            .help("Ready hands it to who it's for once what it waits for is done. Backlog keeps it for later.")
            VStack(alignment: .leading, spacing: 3) {
                Text("Brief and done when").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Text(item.briefPending == true ? "Written when placed" : [item.brief, item.doneWhen].filter { !$0.isEmpty }.joined(separator: "\n"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(item.briefPending == true ? AnyShapeStyle(BindersTheme.faint) : AnyShapeStyle(.secondary))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { list.editing = nil }.controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .font(.system(size: 11.5))
    }

    private var people: [String] {
        var names = controller.distill.people(for: note.binderID)
        if let current = item.meantFor, !names.contains(current) { names.append(current) }
        return names
    }
}

// MARK: - Where the list is

/// Each row's frame, and the list's, in the stage's space, for the cards that fly into them.
struct DistillRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct DistillViewportFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

struct DistillButtonFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
