import AppKit
import SwiftUI
import BindersKit

enum EntityStyle {
    static let typeOrder = ["person", "project", "product", "company", "team", "place", "topic"]

    /// A colour for each kind, from those that mean nothing else: no red, amber, green or lavender. People, projects and
    /// topics get the brighter ones; meetings, captures, notes and commands, which the graph draws as squares with their
    /// glyph, quieter ones. They read on the graph's night sky and on either ground.
    static func color(_ kind: String) -> Color {
        switch kind {
        case "person": palette.person
        case "project": palette.project
        case "product": palette.product
        case "company": palette.company
        case "team": palette.team
        case "place": palette.place
        case "topic": palette.topic
        case "meeting": palette.meeting
        case "conversation": palette.conversation
        case "note": palette.note
        case "command": palette.command
        default: palette.other
        }
    }

    private static let palette = (
        person: Color(nsColor: BindersTheme.srgb(0x4299E6)), project: Color(nsColor: BindersTheme.srgb(0x6A58F6)),
        product: Color(nsColor: BindersTheme.srgb(0xE65C94)), company: Color(nsColor: BindersTheme.srgb(0x29A09F)),
        team: Color(nsColor: BindersTheme.srgb(0x38B2CC)), place: Color(nsColor: BindersTheme.srgb(0xB07D56)),
        topic: Color(nsColor: BindersTheme.srgb(0xB565D6)), meeting: Color(nsColor: BindersTheme.srgb(0x7184B5)),
        conversation: Color(nsColor: BindersTheme.srgb(0x5E9AA6)), note: Color(nsColor: BindersTheme.srgb(0xA3967A)),
        command: Color(nsColor: BindersTheme.srgb(0x7A73B8)), other: Color(nsColor: BindersTheme.srgb(0x8A8F99))
    )

    static func title(_ type: String) -> String {
        switch type {
        case "person": "People"
        case "project": "Projects"
        case "product": "Products"
        case "company": "Companies"
        case "team": "Teams"
        case "place": "Places"
        default: "Topics"
        }
    }
}

/// Turns «matched» markers from keyword search into highlighted text, the matches in `color`: the accent's words, or
/// ink on a binder's pages, whose colour is the only one there.
func highlightedSnippet(_ snippet: String, color: Color = BindersTheme.accentText) -> AttributedString {
    var output = AttributedString()
    var buffer = ""
    var emphasized = false
    func flush() {
        guard !buffer.isEmpty else { return }
        var run = AttributedString(buffer)
        if emphasized {
            run.font = .body.weight(.semibold)
            run.foregroundColor = color
        }
        output += run
        buffer = ""
    }
    for character in snippet {
        switch character {
        case "«":
            flush()
            emphasized = true
        case "»":
            flush()
            emphasized = false
        default:
            buffer.append(character)
        }
    }
    flush()
    return output
}

// MARK: - Knowledge page

struct KnowledgeView: View {
    enum Mode: String, CaseIterable {
        case search = "Search", graph = "Graph"
    }

    /// When set, everything on the page is limited to one binder.
    var binderID: UUID? = nil
    /// The folder you're in, in that binder: search and Ask can be limited to it and the folders inside it.
    var folderID: UUID? = nil
    /// Search and Ask only in that folder: on while you're in one, until you widen it.
    @State private var onlyInFolder = true
    @Environment(KnowledgeService.self) private var knowledge
    @Environment(HubNavigation.self) private var navigation
    @State private var query = ""
    @State private var mode: Mode = .search
    @State private var kindFilter: KnowledgeKind?
    @State private var ownerFilter: KnowledgeOwner = .everyone
    @State private var hits: [KnowledgeHit] = []
    @State private var searching = false
    /// The question asked, answered as it goes.
    @State private var run: AskRun?
    @State private var asking: Task<Void, Never>?
    @State private var entities: [KnowledgeEntity] = []
    @State private var selectedEntityID: Int64?
    @State private var entityFilter = ""
    @State private var removing: KnowledgeEntity?
    @State private var renamingEntity: KnowledgeEntity?
    @State private var renameDraft = ""
    @State private var dropMerge: (source: KnowledgeEntity, target: KnowledgeEntity)?

    private var entityGroups: [(type: String, entities: [KnowledgeEntity])] {
        let filter = entityFilter.trimmed
        let visible = filter.isEmpty ? entities : entities.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        let grouped = Dictionary(grouping: visible, by: \.type)
        return EntityStyle.typeOrder.compactMap { type in grouped[type].map { (type, $0) } }
    }

    var body: some View {
        // People & topics narrows on a narrow page, so the search beside it keeps its room.
        GeometryReader { proxy in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: proxy.size.width < 700 ? 200 : 250)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    header
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    statusBar
                }
                .padding(24)
            }
        }
        .task(id: "\(knowledge.revision)|\(binderID?.uuidString ?? "")") {
            entities = await knowledge.store.entities(limit: 500, binder: binderID?.uuidString)
        }
        .task(id: "\(query)|\(kindFilter?.rawValue ?? "all")|\(ownerFilter.rawValue)|\(onlyInFolder)|\(folderID?.uuidString ?? "")") {
            await runSearch()
        }
        .onAppear {
            consumePendingQuery()
            consumePendingEntity()
        }
        // An answer nobody can see any more stops, and the model is free for the next one.
        .onDisappear { if run?.isWorking == true { stopAsking() } }
        .onChange(of: navigation.pendingKnowledgeQuery) { consumePendingQuery() }
        .onChange(of: navigation.pendingEntityID) { consumePendingEntity() }
        .onChange(of: selectedEntityID) {
            if selectedEntityID != nil {
                query = ""
                mode = .search
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People & topics").font(BindersTheme.columnTitle).foregroundStyle(.sectionInk).padding(.top, 24)
            TextField("Filter", text: $entityFilter).textFieldStyle(.roundedBorder)
            List(selection: $selectedEntityID) {
                ForEach(entityGroups, id: \.type) { group in
                    Section(EntityStyle.title(group.type)) {
                        ForEach(group.entities) { entity in
                            HStack(spacing: 6) {
                                Circle().fill(EntityStyle.color(entity.type)).frame(width: 7, height: 7)
                                Text(entity.name).lineLimit(1)
                                Spacer()
                                Text("\(entity.documents)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .tag(entity.id)
                            .draggable(String(entity.id))
                            .dropDestination(for: String.self) { items, _ in
                                guard let raw = items.first, let sourceID = Int64(raw), sourceID != entity.id,
                                      let source = entities.first(where: { $0.id == sourceID }) else { return false }
                                dropMerge = (source, entity)
                                return true
                            }
                            .contextMenu {
                                Button("Rename…") {
                                    renameDraft = entity.name
                                    renamingEntity = entity
                                }
                                Button("Remove from Knowledge…", role: .destructive) { removing = entity }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .confirmationDialog("Remove from Knowledge?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                presenting: removing) { entity in
                Button("Remove \(entity.name)", role: .destructive) {
                    Task {
                        await knowledge.forget(entityID: entity.id)
                        if selectedEntityID == entity.id { selectedEntityID = nil }
                    }
                }
            } message: { entity in
                Text(Self.removalMessage(for: entity))
            }
            .alert("Rename \(renamingEntity?.name ?? "")", isPresented: Binding(get: { renamingEntity != nil }, set: { if !$0 { renamingEntity = nil } }),
                   presenting: renamingEntity) { entity in
                TextField("Name", text: $renameDraft)
                Button("Rename") {
                    let name = renameDraft
                    Task {
                        if let survivor = await knowledge.rename(entityID: entity.id, to: name) { selectedEntityID = survivor }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The old name is remembered, so new meetings and notes that use it still link here. Use a name that already exists to merge the two.")
            }
            .confirmationDialog("Merge \(dropMerge?.source.name ?? "") into \(dropMerge?.target.name ?? "")?",
                                isPresented: Binding(get: { dropMerge != nil }, set: { if !$0 { dropMerge = nil } }), presenting: dropMerge) { pair in
                Button("Merge into \(pair.target.name)", role: .destructive) {
                    Task {
                        if await knowledge.merge(pair.source.id, into: pair.target.id) { selectedEntityID = pair.target.id }
                    }
                }
            } message: { pair in
                Text("Every mention and relationship of \(pair.source.name) moves to \(pair.target.name), and \(pair.source.name) is remembered as another name for it. Drag one name onto another to do this any time.")
            }
            .overlay {
                if entities.isEmpty {
                    Text("People, projects and topics appear here as meetings and notes are processed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(binderID == nil ? "Everything said in meetings, written in notes and dictated · all on this Mac"
                                     : "This binder's meetings and notes · all on this Mac")
                    .font(.callout).foregroundStyle(BindersTheme.muted)
                Text(binderID == nil ? "Ask your work anything" : "Ask this binder anything").font(BindersTheme.title(34))
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search, or ask “what did we decide about pricing?”", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit(ask)
                if searching { ProgressView().controlSize(.small) }
                // Ask is the language model answering from your binders; no agent does it, so not the sparkle.
                Button("Ask", action: ask)
                .buttonStyle(.primary)
                .disabled(query.trimmed.isEmpty || (run?.isWorking == true && run?.question == query.trimmed))
            }
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(BindersTheme.line))
            // On one line while they fit; on a narrow page they carry on to the next.
            Wrapping(spacing: 8, lineSpacing: 8) {
                HStack(spacing: 18) {
                    ForEach(Mode.allCases, id: \.self) { choice in
                        Button { mode = choice } label: {
                            Text(choice.rawValue)
                                .font(.system(size: 13.5, weight: mode == choice ? .semibold : .regular))
                                .foregroundStyle(mode == choice ? BindersTheme.ink : BindersTheme.muted)
                                .padding(.vertical, 4)
                                .overlay(alignment: .bottom) {
                                    if mode == choice { Capsule().fill(BindersTheme.ink).frame(height: 2).offset(y: 4) }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(mode == choice ? .isSelected : [])
                    }
                }
                .padding(.trailing, 10)
                Picker("", selection: $kindFilter) {
                    Text("Everything").tag(KnowledgeKind?.none)
                    ForEach(KnowledgeKind.allCases) { Text($0.displayName).tag(KnowledgeKind?.some($0)) }
                }
                .labelsHidden()
                .frame(width: 150)
                if AppSettings.shared.teamFolderPath != nil {
                    Picker("", selection: $ownerFilter) {
                        ForEach(KnowledgeOwner.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                // Inside a folder: it and the folders in it, or the whole binder.
                if let folderID, let folder = Store.shared.folder(folderID) {
                    Toggle("Only in \(folder.name)", isOn: $onlyInFolder)
                        .toggleStyle(.checkbox)
                        .help("Search and Ask only the notes, meetings and captures in \(folder.name) and the folders inside it. Untick for the whole binder.")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if mode == .graph {
            KnowledgeGraphView(selectedEntityID: $selectedEntityID, binder: binderID?.uuidString)
        } else if query.trimmed.isEmpty, let entityID = selectedEntityID {
            EntityDetailView(entityID: entityID, onSelect: { selectedEntityID = $0 }, onAsk: { question in
                selectedEntityID = nil
                query = question
                ask()
            }, onRemoved: { selectedEntityID = nil })
        } else if query.trimmed.isEmpty {
            ContentUnavailableView {
                Label("Search your meetings, notes and dictations", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Try a name, a project or a phrase someone said. Or hold \(AppSettings.shared.hotkeys.command?.displayString() ?? "fn ⌃") and ask out loud.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let run {
                        AskRunView(run: run)
                    }
                    if hits.isEmpty, !searching {
                        Text("No matches yet.").foregroundStyle(.secondary)
                    }
                    ForEach(hits) { hit in
                        KnowledgeHitRow(hit: hit)
                    }
                }
                .padding(.trailing, 6)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if knowledge.status.isIndexing { ProgressView().controlSize(.mini) }
            Text(knowledge.status.summary)
            if let issue = knowledge.status.embeddingIssue ?? knowledge.status.extractionIssue {
                StatusLabel(issue, .problem).lineLimit(1)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    static func removalMessage(for entity: KnowledgeEntity) -> String {
        "\(entity.name) and its mentions and relationships are removed, and it won't be picked up again. Your meetings, notes and dictations are not changed. Restore it later in Settings → Knowledge."
    }

    /// A person, project or topic asked for from elsewhere, such as the quick switcher: its page.
    private func consumePendingEntity() {
        guard let id = navigation.pendingEntityID else { return }
        navigation.pendingEntityID = nil
        query = ""
        mode = .search
        selectedEntityID = id
    }

    private func consumePendingQuery() {
        guard let pending = navigation.pendingKnowledgeQuery else { return }
        navigation.pendingKnowledgeQuery = nil
        selectedEntityID = nil
        mode = .search
        query = pending
        ask()
    }

    private func runSearch() async {
        let text = query.trimmed
        // A new question: the answer to the last one goes, and stops if it's still being written.
        if run?.question != text { stopAsking() }
        guard !text.isEmpty else {
            hits = []
            searching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        // The passages with the words show at once; the search by meaning follows.
        let results = await knowledge.search(text, kinds: kindFilter.map { [$0] }, owner: ownerFilter, binder: binderID, sources: scope,
                                             onKeywordHits: { found in if !Task.isCancelled { hits = found } })
        guard !Task.isCancelled else { return }
        hits = results
        searching = false
    }

    private func ask() {
        let question = query.trimmed
        guard !question.isEmpty, !(run?.isWorking == true && run?.question == question) else { return }
        stopAsking()
        let run = AskRun(question: question)
        self.run = run
        let sources = scope
        asking = Task { _ = await run.run(with: knowledge, binder: binderID, sources: sources) }
    }

    /// What search and Ask keep, inside a folder with Only in ticked: its items and those in the folders inside it.
    private var scope: Set<String>? {
        guard onlyInFolder, let folderID, Store.shared.folder(folderID) != nil else { return nil }
        return Store.shared.itemIDs(inFolder: folderID)
    }

    private func stopAsking() {
        asking?.cancel()
        asking = nil
        run = nil
    }
}

/// An answer on its way, as it goes, then the answer.
struct AskRunView: View {
    let run: AskRun

    var body: some View {
        KnowledgeAnswerView(text: run.text, sources: run.sources, status: run.status, writing: run.isWorking, leftOut: run.answer?.leftOut ?? [])
    }
}

struct KnowledgeHitRow: View {
    let hit: KnowledgeHit
    var emphasis: String?
    @Environment(KnowledgeService.self) private var knowledge: KnowledgeService?
    @Environment(\.binderTint) private var binderTint
    @State private var hovering = false

    var body: some View {
        Button {
            KnowledgeNavigator.open(hit)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: hit.kind.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(hit.title).font(.body.weight(.medium)).lineLimit(1)
                        AgentLabel(hit.agent).font(.caption)
                        // The folder it's in, in its binder.
                        if let names = UUID(uuidString: hit.sourceID).flatMap({ Store.shared.folderNames(ofItem: $0) }) {
                            Label(names.joined(separator: " › "), systemImage: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help("In the folder \(names.joined(separator: " › "))")
                        }
                        Spacer()
                        Text(hit.metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(displayText)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    // Something here was corrected since: say what's right.
                    if let knowledge, let fix = knowledge.correction(for: hit, in: knowledge.currentCorrections()) {
                        Label("Corrected: \(fix.correction.right)", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.infoText)
                            .lineLimit(2)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BindersTheme.ink.opacity(hovering ? 0.04 : 0)))
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BindersTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hovering ? BindersTheme.lineStrong : BindersTheme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var displayText: AttributedString {
        let matches = binderTint == nil ? BindersTheme.accentText : BindersTheme.ink
        if !hit.snippet.isEmpty { return highlightedSnippet(hit.snippet, color: matches) }
        let text = hit.text.replacingOccurrences(of: "\n", with: " ")
        if let emphasis, let range = text.range(of: emphasis, options: [.caseInsensitive, .diacriticInsensitive]) {
            let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
            let marked = (start > text.startIndex ? "…" : "") + text[start..<range.lowerBound] + "«" + text[range] + "»" + text[range.upperBound..<end]
            return highlightedSnippet(marked, color: matches)
        }
        return AttributedString(String(text.prefix(260)))
    }
}

struct KnowledgeAnswerView: View {
    let text: String
    let sources: [KnowledgeHit]
    /// What it's doing while there's no answer to show yet.
    var status: String?
    /// The answer is still on its way.
    var writing = false
    /// Notes with an agent's words in them that matched, which the answer left out.
    var leftOut: [KnowledgeHit] = []

    init(answer: KnowledgeService.Answer) {
        self.init(text: answer.text, sources: answer.sources, leftOut: answer.leftOut)
    }

    init(text: String, sources: [KnowledgeHit], status: String? = nil, writing: Bool = false, leftOut: [KnowledgeHit] = []) {
        self.text = text
        self.sources = sources
        self.status = status
        self.writing = writing
        self.leftOut = leftOut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("Answer", systemImage: BindersTheme.askSymbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if writing, status == nil { ProgressView().controlSize(.mini) }
            }
            if let status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
            }
            if !text.isEmpty { MarkdownBlocks(markdown: text) }
            if !sources.isEmpty {
                Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, hit in
                    Button {
                        KnowledgeNavigator.open(hit)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("[\(index + 1)]").monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: hit.kind.symbol).foregroundStyle(.secondary)
                            Text(hit.title).lineLimit(1)
                            // The folder it's in, in its binder.
                            if let names = UUID(uuidString: hit.sourceID).flatMap({ Store.shared.folderNames(ofItem: $0) }) {
                                Label(names.joined(separator: " › "), systemImage: "folder").foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text(hit.metaLine).foregroundStyle(.secondary).lineLimit(1)
                            AgentLabel(hit.agent)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            AgentNotesLeftOut(hits: leftOut)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.infoFill(0.06)))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BindersTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(BindersTheme.line))
    }
}

// MARK: - Entity page

struct EntityDetailView: View {
    @Environment(KnowledgeService.self) private var knowledge
    let entityID: Int64
    let onSelect: (Int64) -> Void
    let onAsk: (String) -> Void
    let onRemoved: () -> Void
    @State private var entity: KnowledgeEntity?
    @State private var confirmRemove = false
    @State private var aliases: [String] = []
    @State private var renaming = false
    @State private var draftName = ""
    @State private var merging = false
    @State private var mergeFilter = ""
    @State private var candidates: [KnowledgeEntity] = []
    @State private var mergeTarget: KnowledgeEntity?
    @State private var mentions: [KnowledgeHit] = []
    @State private var related: [KnowledgeEntity] = []
    @State private var relations: [KnowledgeRelation] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let entity {
                    HStack(spacing: 10) {
                        Circle().fill(EntityStyle.color(entity.type)).frame(width: 12, height: 12)
                        Text(entity.name).font(BindersTheme.title())
                        Badge(text: entity.type.capitalized, color: EntityStyle.color(entity.type))
                        Button {
                            draftName = entity.name
                            renaming = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .quietControl()
                        .help("Rename. Renaming onto an existing name merges the two.")
                    }
                    if !aliases.isEmpty {
                        Text("Also known as \(aliases.joined(separator: ", "))").font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Mentioned in \(entity.documents) \(entity.documents == 1 ? "place" : "places")").foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            mergeFilter = ""
                            merging = true
                        } label: {
                            Label("Merge into…", systemImage: "arrow.triangle.merge")
                        }
                        .help("Fold this into another entry that's really the same thing")
                        .popover(isPresented: $merging, arrowEdge: .bottom) { mergePopover(for: entity) }
                        Button {
                            onAsk("What do my meetings, notes and dictations say about \(entity.name)?")
                        } label: {
                            Label("Ask about \(entity.name)", systemImage: BindersTheme.askSymbol)
                        }
                        Button(role: .destructive) {
                            confirmRemove = true
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .help("Not a real person or topic? Remove it and keep it from coming back.")
                    }
                    .alert("Rename \(entity.name)", isPresented: $renaming) {
                        TextField("Name", text: $draftName)
                        Button("Rename") {
                            let name = draftName
                            Task {
                                if let survivor = await knowledge.rename(entityID: entity.id, to: name) { onSelect(survivor) }
                            }
                        }
                        .disabled(draftName.trimmed.isEmpty)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The old name is remembered, so new meetings and notes that use it still link here. Use a name that already exists to merge the two.")
                    }
                    .confirmationDialog("Merge \(entity.name) into \(mergeTarget?.name ?? "")?", isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
                                        presenting: mergeTarget) { target in
                        Button("Merge into \(target.name)", role: .destructive) {
                            Task {
                                if await knowledge.merge(entity.id, into: target.id) { onSelect(target.id) }
                            }
                        }
                    } message: { target in
                        Text("Every mention and relationship of \(entity.name) moves to \(target.name), and \(entity.name) is remembered as another name for it.")
                    }
                    .confirmationDialog("Remove \(entity.name) from Knowledge?", isPresented: $confirmRemove) {
                        Button("Remove \(entity.name)", role: .destructive) {
                            Task {
                                await knowledge.forget(entityID: entity.id)
                                onRemoved()
                            }
                        }
                    } message: {
                        Text(KnowledgeView.removalMessage(for: entity))
                    }

                    if !relations.isEmpty {
                        Text("Relationships").font(BindersTheme.cardTitle)
                        ForEach(relations, id: \.self) { relation in
                            HStack(spacing: 6) {
                                if relation.outgoing {
                                    Text(entity.name).fontWeight(.medium)
                                    Text(relation.label).foregroundStyle(.secondary)
                                    Button(relation.other) { onSelect(relation.otherID) }.themedLink()
                                } else {
                                    Button(relation.other) { onSelect(relation.otherID) }.themedLink()
                                    Text(relation.label).foregroundStyle(.secondary)
                                    Text(entity.name).fontWeight(.medium)
                                }
                            }
                        }
                    }

                    if !related.isEmpty {
                        Text("Often comes up with").font(BindersTheme.cardTitle)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(related) { other in
                                Button {
                                    onSelect(other.id)
                                } label: {
                                    HStack(spacing: 5) {
                                        Circle().fill(EntityStyle.color(other.type)).frame(width: 6, height: 6)
                                        Text(other.name).lineLimit(1)
                                        Text("\(other.documents)").monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(BindersTheme.surface))
                                    .overlay(Capsule().strokeBorder(BindersTheme.line))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Notes that [[link]] here, and the ones that only name them, one click from a link.
                    MentionsPanel(title: entity.name, heading: "In your notes and meetings")

                    Text("Mentions").font(BindersTheme.cardTitle)
                    ForEach(mentions) { hit in
                        KnowledgeHitRow(hit: hit, emphasis: entity.name)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
        }
        .task(id: "\(entityID)|\(knowledge.revision)") {
            entity = await knowledge.store.entity(id: entityID)
            mentions = knowledge.labelled(await knowledge.store.mentions(of: entityID, limit: 100))
            related = await knowledge.store.related(to: entityID, limit: 24)
            relations = await knowledge.store.relations(of: entityID)
            aliases = await knowledge.store.aliases(of: entityID)
            candidates = await knowledge.store.entities(limit: 500)
        }
    }

    /// Pick what this entity is really the same as: same type first, then everything else, filtered as you type.
    private func mergePopover(for entity: KnowledgeEntity) -> some View {
        let filter = mergeFilter.trimmed
        let options = candidates
            .filter { $0.id != entity.id && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
            .sorted { a, b in
                if (a.type == entity.type) != (b.type == entity.type) { return a.type == entity.type }
                return a.documents == b.documents ? a.name < b.name : a.documents > b.documents
            }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Merge \(entity.name) into…").font(BindersTheme.cardTitle)
            TextField("Filter", text: $mergeFilter).textFieldStyle(.roundedBorder)
            List(options.prefix(60)) { option in
                Button {
                    merging = false
                    mergeTarget = option
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(EntityStyle.color(option.type)).frame(width: 7, height: 7)
                        Text(option.name).lineLimit(1)
                        Spacer()
                        Text("\(option.documents)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 300, height: 260)
        }
        .padding(12)
    }
}

// MARK: - Graph

/// The knowledge graph as a living thing: a force simulation that blooms out from the centre, lights up a node's
/// neighbours on hover, pulses a node as you select it and lets you drag nodes around. Once the layout settles it holds
/// still and draws nothing more until you hover, drag, zoom or select, or the graph changes, when it moves on from where
/// it was rather than blooming again. With Reduce Motion nothing animates: the layout shows settled, and highlights
/// change at once.
struct KnowledgeGraphView: View {
    @Environment(KnowledgeService.self) private var knowledge
    @Binding var selectedEntityID: Int64?
    var binder: String? = nil
    /// For self-tests, which can't turn Reduce Motion on: stands in for the setting.
    var reduceMotionOverride: Bool? = nil
    @State private var graph = KnowledgeGraphData()
    @State private var simulation = GraphSimulation(nodes: [], edges: [])
    @State private var hoveredID: String?
    @State private var highlight = GraphHighlight()
    /// When the selected node started its pulse; nil once it's done.
    @State private var pulseStart: Date?
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var panAtGestureStart: CGSize?
    @State private var draggingIndex: Int?
    @State private var loading = true
    @State private var loadedAt = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotionSetting

    /// For self-tests: frames drawn since launch.
    nonisolated(unsafe) static var framesDrawn = 0

    /// The night sky the graph is drawn on, dark in both appearances: the dark surface at the centre, the dark ground at
    /// the edge.
    private static let field = [Color(nsColor: BindersTheme.srgb(0x221E48)), BindersTheme.Dark.ground]
    private static let pulseLength: TimeInterval = 1.6

    private var reduceMotion: Bool { reduceMotionOverride ?? reduceMotionSetting }

    /// Frames, at full speed, only while something moves: the layout settling, a node dragged, a highlight easing in or
    /// out, a new selection's pulse. Settled and left alone, the graph isn't drawn again.
    private var animating: Bool {
        !reduceMotion && (!simulation.isSettled || draggingIndex != nil || highlight.isEasing(toward: hoveredID) || pulseStart != nil)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { timeline in
                Canvas { context, canvasSize in
                    Self.framesDrawn += 1
                    draw(in: &context, size: canvasSize, time: timeline.date.timeIntervalSince(loadedAt), now: timeline.date)
                }
                .onChange(of: timeline.date) { tick(at: timeline.date) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if panAtGestureStart == nil, draggingIndex == nil,
                       let node = node(at: value.startLocation, size: size), let index = simulation.index(of: node.id) {
                        draggingIndex = index
                    }
                    if let index = draggingIndex {
                        // With Reduce Motion only the node in hand moves; the rest find their places when it's let go.
                        simulation.pin(index, at: unit(value.location, size))
                    } else {
                        let start = panAtGestureStart ?? pan
                        panAtGestureStart = start
                        pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                    }
                }
                .onEnded { _ in
                    if let index = draggingIndex {
                        simulation.release(index)
                        simulation.reheat(0.3)
                        if reduceMotion { simulation.settle() }
                    }
                    draggingIndex = nil
                    panAtGestureStart = nil
                })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let start = zoomAtGestureStart ?? zoom
                    zoomAtGestureStart = start
                    zoom = min(4, max(0.4, start * value.magnification))
                }
                .onEnded { _ in zoomAtGestureStart = nil })
            .onContinuousHover { phase in
                var hovered: String?
                if case .active(let location) = phase { hovered = node(at: location, size: size)?.id }
                guard hovered != hoveredID else { return }
                hoveredID = hovered
                if reduceMotion { highlight.snap(to: hovered) }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                guard let node = node(at: location, size: size) else { return }
                if let entityID = node.entityID {
                    selectedEntityID = entityID
                } else if let sourceID = node.sourceID, let kind = KnowledgeKind(rawValue: node.kind) {
                    KnowledgeNavigator.openSource(kind: kind, sourceID: sourceID)
                }
            }
            .overlay(alignment: .bottomLeading) { legend }
            .overlay(alignment: .bottomTrailing) { controls }
            .overlay {
                if !loading, graph.nodes.isEmpty {
                    ContentUnavailableView {
                        Label("No connections yet", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("As meetings and notes are processed, the people, projects and topics in them appear here, linked to where they came up.")
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(RadialGradient(colors: Self.field, center: .center, startRadius: 0, endRadius: 720))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: knowledge.revision) { await load() }
        .onChange(of: selectedEntityID) { _, selected in
            pulseStart = selected == nil || reduceMotion ? nil : Date()
        }
        // Reduce Motion turned on mid-bloom: straight to the end of it.
        .onChange(of: reduceMotion) { _, reduced in
            guard reduced else { return }
            simulation.settle()
            highlight.snap(to: hoveredID)
            pulseStart = nil
        }
    }

    private var legend: some View {
        let kinds = EntityStyle.typeOrder.filter { kind in graph.nodes.contains { $0.kind == kind } }
            + ["meeting", "conversation", "note", "command"].filter { kind in graph.nodes.contains { $0.kind == kind } }
        return HStack(spacing: 12) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 5) {
                    Circle().fill(EntityStyle.color(kind)).frame(width: 7, height: 7)
                    Text(KnowledgeKind(rawValue: kind)?.displayName ?? EntityStyle.title(kind)).font(.caption)
                }
            }
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.black.opacity(0.35)))
        .padding(10)
        .opacity(kinds.isEmpty ? 0 : 1)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button { zoom = max(0.4, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoom = min(4, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { zoom = 1; pan = .zero } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Reset the view")
            Button {
                simulation.scatter()
                // With Reduce Motion, a new arrangement at once, without the bloom.
                if reduceMotion { simulation.settle() }
                loadedAt = Date()
            } label: { Image(systemName: "shuffle") }
                .help(reduceMotion ? "Shake it up: a new arrangement" : "Shake it up: replay the bloom")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.35)))
        .padding(10)
    }

    private func load() async {
        let data = await knowledge.store.graph(documentLimit: 60, entityLimit: 140, binder: binder)
        // The index moved on without changing the graph: nothing to draw again.
        if !loading, data.nodes == graph.nodes, data.edges == graph.edges { return }
        var fresh = GraphSimulation(nodes: data.nodes.map { GraphNode(id: $0.id, weight: $0.weight) }, edges: data.edges)
        // New data moves the picture on from where it was; the first load blooms.
        if !graph.nodes.isEmpty { fresh.carryOver(from: simulation) }
        if reduceMotion {
            let start = fresh
            fresh = await Task.detached(priority: .userInitiated) {
                var settled = start
                settled.settle()
                return settled
            }.value
        } else if fresh.alpha >= 1 {
            // A few frames ahead so the first thing on screen is already a shape, then the bloom continues live.
            for _ in 0..<12 { fresh.step() }
        }
        let held = draggingIndex.map { simulation.ids[$0] }
        graph = data
        simulation = fresh
        draggingIndex = held.flatMap { fresh.index(of: $0) }
        loadedAt = Date()
        loading = false
    }

    /// One frame: advance the physics, ease the hover highlight, and end the selection's pulse when it's had its time.
    private func tick(at date: Date) {
        if !simulation.isSettled { simulation.step() }
        if highlight.isEasing(toward: hoveredID) { highlight.step(toward: hoveredID) }
        if let pulseStart, date.timeIntervalSince(pulseStart) >= Self.pulseLength { self.pulseStart = nil }
    }

    private func point(_ position: SIMD2<Double>, _ size: CGSize) -> CGPoint {
        CGPoint(x: (position.x - 0.5) * size.width * zoom + size.width / 2 + pan.width,
                y: (position.y - 0.5) * size.height * zoom + size.height / 2 + pan.height)
    }

    private func unit(_ location: CGPoint, _ size: CGSize) -> SIMD2<Double> {
        SIMD2((location.x - size.width / 2 - pan.width) / (size.width * zoom) + 0.5,
              (location.y - size.height / 2 - pan.height) / (size.height * zoom) + 0.5)
    }

    private func position(of node: KnowledgeGraphData.Node) -> SIMD2<Double>? {
        simulation.index(of: node.id).map { simulation.positions[$0] }
    }

    private func radius(_ node: KnowledgeGraphData.Node) -> CGFloat {
        (node.isDocument ? 8 : 4 + min(10, CGFloat(node.weight).squareRoot() * 2.8)) * (1 + 0.35 * CGFloat(highlight[node.id]))
    }

    private func node(at location: CGPoint, size: CGSize) -> KnowledgeGraphData.Node? {
        var best: (node: KnowledgeGraphData.Node, distance: CGFloat)?
        for node in graph.nodes {
            guard let position = position(of: node) else { continue }
            let center = point(position, size)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance <= radius(node) + 7, distance < (best?.distance ?? .infinity) { best = (node, distance) }
        }
        return best?.node
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval, now: Date) {
        let focus = hoveredID ?? selectedEntityID.map { "e:\($0)" }
        var neighbors = Set<String>()
        if let focus {
            for edge in graph.edges where edge.from == focus || edge.to == focus {
                neighbors.insert(edge.from)
                neighbors.insert(edge.to)
            }
        }
        var centers: [String: CGPoint] = [:]
        for node in graph.nodes {
            guard let position = position(of: node) else { continue }
            centers[node.id] = point(position, size)
        }
        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })

        // Edges: soft curves; the focused node's edges light up in its colour and flow.
        for edge in graph.edges {
            guard let a = centers[edge.from], let b = centers[edge.to] else { continue }
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let length = max(hypot(b.x - a.x, b.y - a.y), 1)
            let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
            let bend = (edge.from < edge.to ? 1 : -1) * min(30, length * 0.12)
            var path = Path()
            path.move(to: a)
            path.addQuadCurve(to: b, control: CGPoint(x: mid.x + normal.x * bend, y: mid.y + normal.y * bend))
            let highlighted = focus != nil && (edge.from == focus || edge.to == focus)
            if highlighted, let focusNode = byID[focus!] {
                let color = EntityStyle.color(focusNode.kind)
                context.stroke(path, with: .color(color.opacity(0.35)), lineWidth: 3)
                // The dashes flow while the graph is drawing anyway, and hold still when it isn't.
                context.stroke(path, with: .color(color.opacity(0.95)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 7], dashPhase: reduceMotion ? 0 : -time * 30))
            } else {
                let opacity = focus == nil ? 0.12 : 0.04
                context.stroke(path, with: .color(.white.opacity(opacity + min(0.1, edge.weight * 0.025))), lineWidth: 0.9)
            }
        }

        let maxWeight = graph.nodes.filter { !$0.isDocument }.map(\.weight).max() ?? 1
        let smallGraph = graph.nodes.count <= 40
        var labelRects: [CGRect] = []
        // The focused node and heavier nodes claim their label space first.
        let ordered = graph.nodes.sorted { a, b in
            if (a.id == focus) != (b.id == focus) { return a.id == focus }
            return a.weight > b.weight
        }
        for node in ordered {
            guard let center = centers[node.id] else { continue }
            let r = radius(node)
            let dimmed = focus != nil && node.id != focus && !neighbors.contains(node.id)
            let color = EntityStyle.color(node.kind)
            let alpha = dimmed ? 0.25 : 1.0
            let hover = highlight[node.id]
            // Glow, then the body.
            let glow = r * (2.2 + hover * 0.8)
            context.fill(Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
                         with: .color(color.opacity((0.08 + hover * 0.16) * alpha)))
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            if node.isDocument {
                context.fill(Path(roundedRect: rect, cornerRadius: r * 0.35), with: .color(color.opacity(0.8 * alpha)))
                var glyph = context.resolve(Image(systemName: node.kind == "meeting" ? "person.2.fill" : node.kind == "conversation" ? "bubble.left.and.bubble.right.fill" : (node.kind == "note" ? "note.text" : "terminal")))
                glyph.shading = .color(.white.opacity(alpha))
                let g = r * 1.1
                context.draw(glyph, in: CGRect(x: center.x - g / 2, y: center.y - g / 2, width: g, height: g))
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity((0.82 + hover * 0.16) * alpha)))
                context.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.55, dy: r * 0.55).offsetBy(dx: -r * 0.15, dy: -r * 0.15)),
                             with: .color(.white.opacity(0.35 * alpha)))
            }
            if node.id == selectedEntityID.map({ "e:\($0)" }) {
                // A pulse as it's selected that dies away, then a ring that holds still.
                let pulse = pulseStart.map { start -> Double in
                    let age = now.timeIntervalSince(start)
                    return age < Self.pulseLength ? sin(age * 6) * 2.5 * (1 - age / Self.pulseLength) : 0
                } ?? 0
                let ring = r + 6 + CGFloat(pulse)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)),
                               with: .color(color.opacity(0.8)), lineWidth: 1.5)
            }
            let showLabel = node.id == focus || neighbors.contains(node.id)
                || (!dimmed && (smallGraph || node.isDocument || node.weight >= max(2, maxWeight * 0.5) || zoom > 1.6))
            if showLabel {
                let label = node.label.count > 28 ? String(node.label.prefix(27)) + "…" : node.label
                let text = context.resolve(Text(label)
                    .font(.system(size: node.isDocument ? 10.5 : 10.5, weight: node.id == focus ? .semibold : .medium))
                    .foregroundColor(.white.opacity(dimmed ? 0.45 : 0.95)))
                let measured = text.measure(in: CGSize(width: 220, height: 40))
                let x = min(max(center.x, measured.width / 2 + 8), size.width - measured.width / 2 - 8)
                // Labels don't pile up: below the node first, above it if that's taken, and only the focus may overlap.
                let candidates = [CGPoint(x: x, y: center.y + r + 11), CGPoint(x: x, y: center.y - r - 11)]
                for origin in candidates {
                    let pill = CGRect(x: origin.x - measured.width / 2 - 6, y: origin.y - measured.height / 2 - 2,
                                      width: measured.width + 12, height: measured.height + 4)
                    let free = !labelRects.contains { $0.intersects(pill.insetBy(dx: -2, dy: -2)) }
                    guard free || node.id == focus else { continue }
                    labelRects.append(pill)
                    context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.black.opacity(dimmed ? 0.2 : 0.42)))
                    context.draw(text, at: origin, anchor: .center)
                    break
                }
            }
        }
    }
}

// MARK: - Spoken answers

/// Command Mode's answers, in a panel that floats over what you're doing: the question at once, then the passages found,
/// then the answer as it's written.
@MainActor
final class AnswerPanelController: NSObject, NSWindowDelegate {
    static let shared = AnswerPanelController()
    private var panel: NSPanel?
    /// What the panel shows.
    private(set) var run: AskRun?
    private var answering: Task<KnowledgeService.Answer, Never>?
    /// Off for self-tests, which read `run` instead: the panel isn't put on screen.
    var showsWindow = true

    /// An answer is being written into the panel right now.
    var isAnswering: Bool { answering != nil }

    /// Shows the question and answers it from the binders as it goes. Nil when the panel was closed, or Esc pressed,
    /// before the answer was done: that stops it.
    func ask(_ question: String, searchQuery: String? = nil, knowledge: KnowledgeService) async -> KnowledgeService.Answer? {
        stopAnswering()
        let run = AskRun(question: question)
        present(run)
        let task = Task { await run.run(with: knowledge, searchQuery: searchQuery) }
        answering = task
        let answer = await task.value
        guard answering == task else { return nil }
        answering = nil
        return answer
    }

    /// Shows the question with its answer when it's already done (the boards' digest), or, with nil, as being looked for.
    func show(question: String, answer: KnowledgeService.Answer?) {
        stopAnswering()
        present(answer.map { AskRun(answer: KnowledgeService.Answer(question: question, text: $0.text, sources: $0.sources)) }
                ?? AskRun(question: question))
    }

    /// Closes the panel. An answer still being written stops, and so does one being read aloud.
    func close() {
        stopAnswering()
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopAnswering()
    }

    private func stopAnswering() {
        answering?.cancel()
        answering = nil
        AnswerSpeaker.shared.stop()
    }

    private func present(_ run: AskRun) {
        self.run = run
        guard showsWindow else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.title = "Binders"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            if !panel.setFrameUsingName("BindersAnswer"), let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 500, y: screen.maxY - 470))
            }
            panel.setFrameAutosaveName(AppDefaults.frameName("BindersAnswer"))
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: AnswerPanelView(run: run, onClose: { [weak self] in
            self?.close()
        }))
        panel?.orderFrontRegardless()
    }
}

struct AnswerPanelView: View {
    let run: AskRun
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // What you asked, quoted.
            Text(run.question).font(BindersTheme.quote(.title3)).lineLimit(3)
            ScrollView {
                AskRunView(run: run)
            }
            HStack {
                Spacer()
                if !run.isWorking {
                    Button("Copy") { TextInserter.copyToClipboard(run.text) }
                }
                Button("Open in Knowledge") {
                    HubWindowController.shared.navigation.pendingKnowledgeQuery = run.question
                    HubWindowController.shared.show(section: .knowledge)
                    onClose()
                }
                Button("Close", action: onClose)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 34)
        .padding(.bottom, 14)
        .pageGround()
    }
}
