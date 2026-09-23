import AppKit
import SwiftData
import SwiftUI

enum HubSection: String, CaseIterable, Identifiable {
    case home, binder, writing, knowledge, dictionary, snippets, style, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .binder: "Binder"
        case .writing: "Writing"
        case .knowledge: "Knowledge"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .style: "Style"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .binder: "books.vertical"
        case .writing: "pencil.line"
        case .knowledge: "point.3.connected.trianglepath.dotted"
        case .dictionary: "book.closed"
        case .snippets: "text.badge.plus"
        case .style: "paintbrush"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class HubNavigation {
    var selection: HubSection? = .home
    /// The binder the binder page shows.
    var binderID: UUID?
    /// Deep links from search results and spoken answers, consumed by the destination page.
    var pendingBinderTab: BinderTab?
    var pendingMeetingID: UUID?
    var pendingNoteID: UUID?
    var pendingHistorySearch: String?
    var pendingWritingSearch: String?
    var pendingKnowledgeQuery: String?
}

@MainActor
final class HubWindowController: NSObject, NSWindowDelegate {
    static let shared = HubWindowController()

    var controller: DictationController?
    let navigation = HubNavigation()
    private var window: NSWindow?

    func show(section: HubSection? = nil) {
        guard let controller else { return }
        if let section { navigation.selection = section }
        if window == nil {
            let root = HubView()
                .environment(controller)
                .environment(controller.meetings)
                .environment(controller.knowledge)
                .environment(controller.team)
                .environment(controller.capture)
                .environment(controller.commitments)
                .environment(navigation)
                .environment(AppSettings.shared)
                .modelContainer(Store.shared.container)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Binders"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 840, height: 560)
            window.contentView = NSHostingView(rootView: root)
            window.center()
            window.setFrameAutosaveName("BindersHub")
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The views go with the window. Kept alive, they would carry on observing, polling and rendering unseen.
        window?.contentView = nil
        window = nil
    }
}

struct HubView: View {
    @Environment(HubNavigation.self) private var navigation

    var body: some View {
        NavigationSplitView {
            HubSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 290)
        } detail: {
            switch navigation.selection ?? .home {
            case .home: HomeView()
            case .binder: BinderPage(binderID: navigation.binderID).id(navigation.binderID)
            case .writing: WritingView()
            case .knowledge: KnowledgeView()
            case .dictionary: DictionaryView()
            case .snippets: SnippetsView()
            case .style: StyleView()
            case .settings: SettingsView()
            }
        }
    }
}

/// The binder's spine: the brand at the top, the sections grouped by what they hold, and what the app is doing at
/// the bottom. Quiet by design: a barely-tinted surface, with the indigo kept for the icon and the selection.
struct HubSidebar: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Query private var allBinders: [BinderRecord]
    @State private var hovered: HubSection?
    @State private var hoveredBinder: UUID?
    @State private var creating = false
    @State private var newName = ""
    @State private var showArchived = false
    @State private var renamingBinder: BinderRecord?
    @State private var renameDraft = ""

    private var binders: [BinderRecord] {
        allBinders.filter { showArchived || !$0.archived }.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.isTeamCopy != b.isTeamCopy { return !a.isTeamCopy }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
    private var archivedCount: Int { allBinders.filter(\.archived).count }

    private var dark: Bool { colorScheme == .dark }
    private var surface: Color { dark ? Color(red: 0.11, green: 0.10, blue: 0.16) : Color(red: 0.95, green: 0.945, blue: 0.975) }
    private var edge: Color { dark ? .white.opacity(0.06) : .black.opacity(0.07) }
    private var ink: Color { dark ? .white : Color(red: 0.11, green: 0.10, blue: 0.20) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.18), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Binders")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(ink)
                    Text("Private, on this Mac.")
                        .font(.caption)
                        .foregroundStyle(ink.opacity(0.55))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.home)
                    groupLabel("Binders")
                    ForEach(binders) { binderRow($0) }
                    Button {
                        newName = ""
                        creating = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 20)
                            Text("New binder…").font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(ink.opacity(0.55))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if archivedCount > 0 {
                        Button {
                            showArchived.toggle()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: showArchived ? "archivebox.fill" : "archivebox").font(.system(size: 12)).frame(width: 20)
                                Text(showArchived ? "Hide archived" : "Archived (\(archivedCount))").font(.system(size: 12.5))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(ink.opacity(0.45))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer().frame(height: 12)
                    row(.writing)
                    row(.knowledge)
                    group("Dictation", [.dictionary, .snippets, .style])
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .alert("New binder", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Create") { createBinder() }
                    .disabled(newName.trimmed.isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A binder holds the meetings and notes for one thing you're working on. Share it with the team as a whole, or keep it to yourself.")
            }
            .alert("Rename “\(renamingBinder?.name ?? "")”", isPresented: Binding(get: { renamingBinder != nil }, set: { if !$0 { renamingBinder = nil } }),
                   presenting: renamingBinder) { binder in
                TextField("Name", text: $renameDraft)
                Button("Rename") {
                    let name = renameDraft.trimmed
                    guard !name.isEmpty else { return }
                    binder.name = name
                    binder.updatedAt = Date()
                    Store.shared.save()
                }
                .disabled(renameDraft.trimmed.isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: { binder in
                Text(binder.sharedWithTeam ? "Teammates see the new name on their next sync." : "Only the name changes; everything in the binder stays put.")
            }
            Spacer(minLength: 8)
            row(.settings).padding(.horizontal, 12)
            status
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(surface)
        .overlay(alignment: .trailing) { edge.frame(width: 1) }
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private func group(_ name: String, _ sections: [HubSection]) -> some View {
        groupLabel(name)
        ForEach(sections) { row($0) }
    }

    private func groupLabel(_ name: String) -> some View {
        Text(name.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(ink.opacity(0.42))
            .padding(.leading, 10)
            .padding(.top, 18)
            .padding(.bottom, 5)
    }

    private func createBinder() {
        let name = newName.trimmed
        guard !name.isEmpty else { return }
        let used = Set(allBinders.map(\.colorIndex))
        let binder = BinderRecord(name: name, colorIndex: (0..<BinderRecord.paletteSize).first { !used.contains($0) } ?? allBinders.count % BinderRecord.paletteSize)
        Store.shared.insert(binder)
        navigation.binderID = binder.id
        navigation.selection = .binder
        settings.currentBinderID = binder.id
    }

    private func binderRow(_ binder: BinderRecord) -> some View {
        let selected = navigation.selection == .binder && navigation.binderID == binder.id
        return Button {
            navigation.binderID = binder.id
            navigation.selection = .binder
            settings.currentBinderID = binder.id
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(BinderPalette.color(binder.colorIndex))
                    .frame(width: 10, height: 14)
                    .frame(width: 20)
                Text(binder.name)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(ink.opacity(selected ? 1 : (binder.archived ? 0.5 : 0.82)))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if binder.isTeamCopy || binder.sharedWithTeam {
                    Image(systemName: binder.isTeamCopy ? "person.2.fill" : "person.2")
                        .font(.system(size: 10))
                        .foregroundStyle(ink.opacity(0.45))
                        .help(binder.isTeamCopy ? "Shared by \(binder.teamAuthorName ?? "a teammate")" : "Shared with the team")
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(dark ? 0.28 : 0.16) : (hoveredBinder == binder.id ? ink.opacity(0.06) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredBinder = binder.id } else if hoveredBinder == binder.id { hoveredBinder = nil }
        }
        .contextMenu {
            if !binder.isTeamCopy {
                Button("Rename…") {
                    renameDraft = binder.name
                    renamingBinder = binder
                }
                if !binder.isDefault {
                    Button(binder.archived ? "Unarchive" : "Archive") {
                        binder.archived.toggle()
                        binder.updatedAt = Date()
                    }
                }
            }
        }
    }

    private func row(_ section: HubSection) -> some View {
        let selected = navigation.selection == section
        return Button {
            if section == .binder, navigation.binderID == nil { navigation.binderID = Store.shared.defaultBinder().id }
            navigation.selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.accentColor : ink.opacity(0.7))
                Text(section.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(ink.opacity(selected ? 1 : 0.82))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(dark ? 0.28 : 0.16) : (hovered == section ? ink.opacity(0.06) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = section } else if hovered == section { hovered = nil }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).lineLimit(1)
            }
            Text("Hold \(settings.hotkeys.dictation.displayString()) to dictate · \(settings.hotkeys.meeting?.displayString() ?? "⌥M") for a meeting")
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(ink.opacity(0.55))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusText: String {
        if AppPaths.isDemo { return "Parakeet v3 · local AI, on this Mac" }   // screenshots show the ready state
        switch controller.speech.state {
        case .idle: return "Speech model not loaded"
        case .downloading(let fraction): return "Downloading speech model \(Int(fraction * 100))%"
        case .loading: return "Loading speech model…"
        case .failed: return "Speech model failed"
        case .ready: return settings.aiFormatting ? "\(settings.speechModel.displayName) · \(settings.llmModelName)" : "\(settings.speechModel.displayName) · no AI"
        }
    }

    private var statusColor: Color {
        if AppPaths.isDemo { return .green }
        switch controller.speech.state {
        case .ready: return .green
        case .failed: return .red
        case .idle: return ink.opacity(0.3)
        default: return .orange
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(BindersTheme.title())
            Text(subtitle).foregroundStyle(.secondary).frame(maxWidth: 680, alignment: .leading)
        }
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}
