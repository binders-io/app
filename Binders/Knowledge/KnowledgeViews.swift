import AppKit
import SwiftUI
import BindersKit

enum EntityStyle {
    static let typeOrder = ["person", "project", "product", "company", "team", "place", "topic"]

    static func color(_ kind: String) -> Color {
        switch kind {
        case "person": .blue
        case "project": .purple
        case "product": .orange
        case "company": .green
        case "team": .teal
        case "place": .brown
        case "topic": .pink
        case "meeting": .red
        case "note": .yellow
        case "command": .indigo
        default: .gray
        }
    }

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

/// Turns «matched» markers from keyword search into highlighted text.
func highlightedSnippet(_ snippet: String) -> AttributedString {
    var output = AttributedString()
    var buffer = ""
    var emphasized = false
    func flush() {
        guard !buffer.isEmpty else { return }
        var run = AttributedString(buffer)
        if emphasized {
            run.font = .body.weight(.semibold)
            run.foregroundColor = .accentColor
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
    @Environment(KnowledgeService.self) private var knowledge
    @Environment(HubNavigation.self) private var navigation
    @State private var query = ""
    @State private var mode: Mode = .search
    @State private var kindFilter: KnowledgeKind?
    @State private var ownerFilter: KnowledgeOwner = .everyone
    @State private var hits: [KnowledgeHit] = []
    @State private var searching = false
    @State private var answer: KnowledgeService.Answer?
    @State private var asking = false
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
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                statusBar
            }
            .padding(24)
        }
        .task(id: "\(knowledge.revision)|\(binderID?.uuidString ?? "")") {
            entities = await knowledge.store.entities(limit: 500, binder: binderID?.uuidString)
        }
        .task(id: "\(query)|\(kindFilter?.rawValue ?? "all")|\(ownerFilter.rawValue)") {
            await runSearch()
        }
        .onAppear(perform: consumePendingQuery)
        .onChange(of: navigation.pendingKnowledgeQuery) { consumePendingQuery() }
        .onChange(of: selectedEntityID) {
            if selectedEntityID != nil {
                query = ""
                mode = .search
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People & topics").font(BindersTheme.columnTitle).padding(.top, 24)
            TextField("Filter", text: $entityFilter).textFieldStyle(.roundedBorder)
            List(selection: $selectedEntityID) {
                ForEach(entityGroups, id: \.type) { group in
                    Section(EntityStyle.title(group.type)) {
                        ForEach(group.entities) { entity in
                            HStack(spacing: 6) {
                                Circle().fill(EntityStyle.color(entity.type)).frame(width: 7, height: 7)
                                Text(entity.name).lineLimit(1)
                                Spacer()
                                Text("\(entity.documents)").font(.caption).foregroundStyle(.secondary)
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
            PageHeader(title: binderID == nil ? "Knowledge" : "Knowledge in this binder",
                       subtitle: binderID == nil ? "Everything said in meetings, written in notes and dictated — searchable and linked."
                                                : "Search, ask and explore what's in this binder's meetings and notes.")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search, or ask “what did we decide about pricing?”", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit(ask)
                if searching { ProgressView().controlSize(.small) }
                Button(action: ask) {
                    Label("Ask", systemImage: "sparkles")
                }
                .disabled(query.trimmed.isEmpty || asking)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
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
                Spacer()
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
                    if asking {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Reading your sources…").foregroundStyle(.secondary)
                        }
                    } else if let answer {
                        KnowledgeAnswerView(answer: answer)
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
                Text("· \(issue)").foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    static func removalMessage(for entity: KnowledgeEntity) -> String {
        "\(entity.name) and its mentions and relationships are removed, and it won't be picked up again. Your meetings, notes and dictations are not changed. Restore it later in Settings → Knowledge."
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
        answer = nil
        guard !text.isEmpty else {
            hits = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        let results = await knowledge.search(text, kinds: kindFilter.map { [$0] }, owner: ownerFilter, binder: binderID)
        guard !Task.isCancelled else { return }
        hits = results
        searching = false
    }

    private func ask() {
        let question = query.trimmed
        guard !question.isEmpty, !asking else { return }
        asking = true
        Task {
            let result = await knowledge.ask(question, binder: binderID)
            if query.trimmed == question { answer = result }
            asking = false
        }
    }
}

struct KnowledgeHitRow: View {
    let hit: KnowledgeHit
    var emphasis: String?
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
                        Spacer()
                        Text(hit.metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(displayText)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var displayText: AttributedString {
        if !hit.snippet.isEmpty { return highlightedSnippet(hit.snippet) }
        let text = hit.text.replacingOccurrences(of: "\n", with: " ")
        if let emphasis, let range = text.range(of: emphasis, options: [.caseInsensitive, .diacriticInsensitive]) {
            let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
            let marked = (start > text.startIndex ? "…" : "") + text[start..<range.lowerBound] + "«" + text[range] + "»" + text[range.upperBound..<end]
            return highlightedSnippet(marked)
        }
        return AttributedString(String(text.prefix(260)))
    }
}

struct KnowledgeAnswerView: View {
    let answer: KnowledgeService.Answer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Answer", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            MarkdownBlocks(markdown: answer.text)
            if !answer.sources.isEmpty {
                Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(Array(answer.sources.enumerated()), id: \.element.id) { index, hit in
                    Button {
                        KnowledgeNavigator.open(hit)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("[\(index + 1)]").monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: hit.kind.symbol).foregroundStyle(.secondary)
                            Text(hit.title).lineLimit(1)
                            Text(hit.metaLine).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.08)))
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
                            Label("Ask about \(entity.name)", systemImage: "sparkles")
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
                        Text("Relationships").font(.headline)
                        ForEach(relations, id: \.self) { relation in
                            HStack(spacing: 6) {
                                if relation.outgoing {
                                    Text(entity.name).fontWeight(.medium)
                                    Text(relation.label).foregroundStyle(.secondary)
                                    Button(relation.other) { onSelect(relation.otherID) }.buttonStyle(.link)
                                } else {
                                    Button(relation.other) { onSelect(relation.otherID) }.buttonStyle(.link)
                                    Text(relation.label).foregroundStyle(.secondary)
                                    Text(entity.name).fontWeight(.medium)
                                }
                            }
                        }
                    }

                    if !related.isEmpty {
                        Text("Often comes up with").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(related) { other in
                                Button {
                                    onSelect(other.id)
                                } label: {
                                    HStack(spacing: 5) {
                                        Circle().fill(EntityStyle.color(other.type)).frame(width: 6, height: 6)
                                        Text(other.name).lineLimit(1)
                                        Text("\(other.documents)").foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Text("Mentions").font(.headline)
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
            mentions = await knowledge.store.mentions(of: entityID, limit: 100)
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
            Text("Merge \(entity.name) into…").font(.headline)
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
                        Text("\(option.documents)").font(.caption).foregroundStyle(.secondary)
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

/// The knowledge graph as a living thing: a force simulation that blooms out from the centre, floats gently once
/// settled, lights up a node's neighbours on hover, pulses the selection and lets you drag nodes around.
struct KnowledgeGraphView: View {
    @Environment(KnowledgeService.self) private var knowledge
    @Binding var selectedEntityID: Int64?
    var binder: String? = nil
    @State private var graph = KnowledgeGraphData()
    @State private var simulation = GraphSimulation(nodes: [], edges: [])
    @State private var hoveredID: String?
    @State private var hoverAmount: [String: Double] = [:]
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var panAtGestureStart: CGSize?
    @State private var draggingIndex: Int?
    @State private var loading = true
    @State private var loadedAt = Date()

    private static let field = [Color(red: 0.13, green: 0.11, blue: 0.31), Color(red: 0.05, green: 0.045, blue: 0.11)]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
                Canvas { context, canvasSize in
                    draw(in: &context, size: canvasSize, time: timeline.date.timeIntervalSince(loadedAt))
                }
                .onChange(of: timeline.date) { tick() }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if panAtGestureStart == nil, draggingIndex == nil,
                       let node = node(at: value.startLocation, size: size), let index = simulation.index(of: node.id) {
                        draggingIndex = index
                    }
                    if let index = draggingIndex {
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
                switch phase {
                case .active(let location): hoveredID = node(at: location, size: size)?.id
                case .ended: hoveredID = nil
                }
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
    }

    private var legend: some View {
        let kinds = EntityStyle.typeOrder.filter { kind in graph.nodes.contains { $0.kind == kind } }
            + ["meeting", "note", "command"].filter { kind in graph.nodes.contains { $0.kind == kind } }
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
            Button { simulation.scatter(); loadedAt = Date() } label: { Image(systemName: "sparkles") }
                .help("Shake it up: replay the bloom")
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
        var fresh = GraphSimulation(nodes: data.nodes.map { GraphNode(id: $0.id, weight: $0.weight) }, edges: data.edges)
        // A few frames ahead so the first thing on screen is already a shape, then the bloom continues live.
        for _ in 0..<12 { fresh.step() }
        graph = data
        simulation = fresh
        loadedAt = Date()
        loading = false
    }

    /// One frame: advance the physics and ease the hover highlight.
    private func tick() {
        if !simulation.isSettled { simulation.step() }
        var next = hoverAmount
        for id in Set(next.keys).union(hoveredID.map { [$0] } ?? []) {
            let target = id == hoveredID ? 1.0 : 0.0
            let eased = (next[id] ?? 0) + (target - (next[id] ?? 0)) * 0.22
            if eased < 0.01, target == 0 { next[id] = nil } else { next[id] = eased }
        }
        if next != hoverAmount { hoverAmount = next }
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
        (node.isDocument ? 8 : 4 + min(10, CGFloat(node.weight).squareRoot() * 2.8)) * (1 + 0.35 * CGFloat(hoverAmount[node.id] ?? 0))
    }

    /// A tiny drift per node so the settled graph still breathes.
    private func drift(_ node: KnowledgeGraphData.Node, time: TimeInterval) -> CGSize {
        let phase = Double(node.id.hashValue % 628) / 100
        return CGSize(width: cos(time * 0.7 + phase) * 1.6, height: sin(time * 0.9 + phase * 1.3) * 1.6)
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

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
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
            let base = point(position, size)
            let drift = drift(node, time: time)
            centers[node.id] = CGPoint(x: base.x + drift.width, y: base.y + drift.height)
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
                context.stroke(path, with: .color(color.opacity(0.95)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 7], dashPhase: -time * 30))
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
            let hover = hoverAmount[node.id] ?? 0
            // Glow, then the body.
            let glow = r * (2.2 + hover * 0.8)
            context.fill(Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
                         with: .color(color.opacity((0.08 + hover * 0.16) * alpha)))
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            if node.isDocument {
                context.fill(Path(roundedRect: rect, cornerRadius: r * 0.35), with: .color(color.opacity(0.8 * alpha)))
                var glyph = context.resolve(Image(systemName: node.kind == "meeting" ? "person.2.fill" : (node.kind == "note" ? "note.text" : "terminal")))
                glyph.shading = .color(.white.opacity(alpha))
                let g = r * 1.1
                context.draw(glyph, in: CGRect(x: center.x - g / 2, y: center.y - g / 2, width: g, height: g))
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity((0.82 + hover * 0.16) * alpha)))
                context.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.55, dy: r * 0.55).offsetBy(dx: -r * 0.15, dy: -r * 0.15)),
                             with: .color(.white.opacity(0.35 * alpha)))
            }
            if node.id == selectedEntityID.map({ "e:\($0)" }) {
                let ring = r + 6 + CGFloat(sin(time * 3) * 2)
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

@MainActor
final class AnswerPanelController {
    static let shared = AnswerPanelController()
    private var panel: NSPanel?

    /// Shows the question with a spinner when `answer` is nil.
    func show(question: String, answer: KnowledgeService.Answer?) {
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
            if !panel.setFrameUsingName("BindersAnswer"), let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 500, y: screen.maxY - 470))
            }
            panel.setFrameAutosaveName("BindersAnswer")
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: AnswerPanelView(question: question, answer: answer, onClose: { [weak self] in
            self?.close()
        }))
        panel?.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }
}

private struct AnswerPanelView: View {
    let question: String
    let answer: KnowledgeService.Answer?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question).font(.headline).lineLimit(3)
            if let answer {
                ScrollView {
                    KnowledgeAnswerView(answer: answer)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Searching your meetings, notes and dictations…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                if let answer {
                    Button("Copy") { TextInserter.copyToClipboard(answer.text) }
                }
                Button("Open in Knowledge") {
                    HubWindowController.shared.navigation.pendingKnowledgeQuery = question
                    HubWindowController.shared.show(section: .knowledge)
                    onClose()
                }
                Button("Close", action: onClose)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 34)
        .padding(.bottom, 14)
    }
}
