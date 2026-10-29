import AppKit
import SwiftUI
import BindersKit

// MARK: - Which folders are open

/// The folders shown open, in a binder's lists and in the sidebar alike, and the binders open in the sidebar: kept as you
/// left them, across launches. Folder ids are never shared between binders, so one set holds every binder's.
@MainActor
@Observable
final class FolderExpansion {
    static let shared = FolderExpansion()

    private static let foldersKey = "openFolders"
    private static let bindersKey = "sidebarOpenBinders"

    private(set) var folders: Set<UUID>
    /// Binders open in the sidebar, with their folders under them.
    private(set) var binders: Set<UUID>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        folders = Self.read(Self.foldersKey, from: defaults)
        binders = Self.read(Self.bindersKey, from: defaults)
    }

    private static func read(_ key: String, from defaults: UserDefaults) -> Set<UUID> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func save() {
        defaults.set(folders.map(\.uuidString).sorted(), forKey: Self.foldersKey)
        defaults.set(binders.map(\.uuidString).sorted(), forKey: Self.bindersKey)
    }

    func isOpen(_ folder: UUID) -> Bool { folders.contains(folder) }

    func toggle(_ folder: UUID) {
        if folders.remove(folder) == nil { folders.insert(folder) }
        save()
    }

    func toggleBinder(_ binder: UUID) {
        if binders.remove(binder) == nil { binders.insert(binder) }
        save()
    }

    /// Opens the folders `folder` is in, so it shows; `itself` opens it too, so what's in it shows (a note in it, say).
    /// `sidebar` opens its binder in the sidebar as well. Nil is the top of the binder.
    func reveal(_ folder: UUID?, in binderID: UUID, itself: Bool = false, sidebar: Bool = true) {
        let nodes = Store.shared.folderNodes(in: binderID)
        var wanted = Set(FolderTree.ancestors(of: folder, in: nodes))
        if itself, let folder, nodes.contains(where: { $0.id == folder }) { wanted.insert(folder) }
        guard !wanted.isSubset(of: folders) || (sidebar && !binders.contains(binderID)) else { return }
        folders.formUnion(wanted)
        if sidebar { binders.insert(binderID) }
        save()
    }

    /// Whether any of a binder's folders is open.
    func hasOpen(in binderID: UUID) -> Bool {
        !folders.isEmpty && Store.shared.folders(in: binderID).contains { folders.contains($0.id) }
    }

    /// Closes every folder in a binder.
    func collapseAll(in binderID: UUID) {
        folders.subtract(Store.shared.folders(in: binderID).map(\.id))
        save()
    }

    /// Opens every folder in a binder.
    func expandAll(in binderID: UUID) {
        folders.formUnion(Store.shared.folders(in: binderID).map(\.id))
        binders.insert(binderID)
        save()
    }

    /// The sidebar's Collapse All: every binder and folder closed.
    func collapseEverything() {
        folders = []
        binders = []
        save()
    }
}

// MARK: - The rows of a tree

/// One row of a binder's notes, meetings or captures drawn as a tree: a folder, one of the list's items, or the quiet
/// line under an open folder with nothing of the list's kind in it.
enum OutlineEntry<Item: AnyObject & Identifiable>: Identifiable where Item.ID == UUID {
    case folder(FolderRecord, depth: Int, count: Int, open: Bool)
    case item(Item, depth: Int)
    case empty(FolderRecord, depth: Int)

    var id: String {
        switch self {
        case .folder(let folder, _, _, _): "folder:" + folder.id.uuidString
        case .item(let item, _): "item:" + item.id.uuidString
        case .empty(let folder, _): "empty:" + folder.id.uuidString
        }
    }

    static func rowID(item id: UUID) -> String { "item:" + id.uuidString }
    static func rowID(folder id: UUID) -> String { "folder:" + id.uuidString }

    /// The binder's folders as a tree (FolderTree.outline), with `items` in them, each with how many of the list's kind
    /// it holds, however deep, and a line under each open one that holds none of them.
    static func tree(folders: [FolderRecord], items: [Item], folderOf: (Item) -> UUID?, open: Set<UUID>) -> [OutlineEntry<Item>] {
        let nodes = folders.map(\.node)
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let counts = FolderTree.counts(nodes, items: items.map(folderOf))
        let rows = FolderTree.outline(nodes, items: items.map { (id: $0.id, folder: folderOf($0)) }, open: open)
        var entries: [OutlineEntry<Item>] = []
        for (index, row) in rows.enumerated() {
            switch row {
            case .folder(let id, let depth):
                guard let folder = byID[id] else { continue }
                let isOpen = open.contains(id)
                entries.append(.folder(folder, depth: depth, count: counts[id] ?? 0, open: isOpen))
                // Open, and the next row isn't inside it: nothing of this kind in it.
                if isOpen, rows.indices.contains(index + 1) ? rows[index + 1].depth <= depth : true {
                    entries.append(.empty(folder, depth: depth + 1))
                }
            case .item(let id, let depth):
                if let item = itemsByID[id] { entries.append(.item(item, depth: depth)) }
            }
        }
        return entries
    }

    /// The items in the order the rows show them.
    static func items(in entries: [OutlineEntry<Item>]) -> [Item] {
        entries.compactMap { if case .item(let item, _) = $0 { item } else { nil } }
    }
}

/// How far a row in a tree sits in: a step for each folder it's inside. An item leaves room for the arrow folders have,
/// so its title lines up with the folders beside it.
enum OutlineIndent {
    static let step: CGFloat = 16
    /// The arrow's width and the gap after it.
    static let arrow: CGFloat = 18

    static func folder(_ depth: Int) -> CGFloat { CGFloat(depth) * step }
    static func item(_ depth: Int) -> CGFloat { CGFloat(depth) * step + arrow }
}

// MARK: - A folder in a list

/// For the self-tests: the buttons in a binder's lists ("folder:<id>", "collapse:<binder id>"), as they last appeared,
/// to press as a click would. Nothing is kept outside the tests.
@MainActor
enum OutlinePresses {
    static var isOn = false
    private static var actions: [String: () -> Void] = [:]

    static func add(_ name: String, _ action: @escaping () -> Void) {
        if isOn { actions[name] = action }
    }

    /// False when nothing by that name has appeared.
    static func press(_ name: String) -> Bool {
        guard let action = actions[name] else { return false }
        action()
        return true
    }
}

/// A folder in a binder's notes, meetings or captures, as Finder and Obsidian show one: click to open or close it in
/// place, which makes it where new things go; drop a note, meeting or folder on it to move it in; drag it onto another
/// folder.
struct FolderTreeRow: View {
    let folder: FolderRecord
    let depth: Int
    /// What it holds that this list shows, however deep, for the count beside it.
    let count: Int
    let open: Bool
    /// Where new things go: the folder you chose last, or the one the note you chose is in.
    let current: Bool
    let action: () -> Void
    @State private var targeted = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: OutlineIndent.arrow - 6)
                Image(systemName: current ? "folder.fill" : "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.tintText)
                    .frame(width: 18)
                Text(folder.name)
                    .fontWeight(current ? .medium : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 { Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary) }
            }
            .padding(.vertical, 3)
            .padding(.leading, OutlineIndent.folder(depth) + 2)
            .padding(.trailing, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(DraggedItem.folder(folder.id).string)
        .dropDestination(for: String.self) { items, _ in
            DraggedItem.drop(items, into: folder.id, binder: folder.binderID, undoManager: undoManager)
        } isTargeted: { targeted = $0 }
        .contextMenu { FolderContextItems(folder: folder) }
        .listRowSeparator(.hidden)
        .onAppear { OutlinePresses.add("folder:" + folder.id.uuidString, action) }
        .accessibilityLabel("Folder \(folder.name)" + (count > 0 ? ", \(count) inside" : ""))
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityHint(open ? "Collapses the folder" : "Expands the folder")
    }

    private var fill: AnyShapeStyle {
        if targeted { return AnyShapeStyle(TintFill().opacity(0.22)) }
        return current ? AnyShapeStyle(TintFill().opacity(0.1)) : AnyShapeStyle(Color.clear)
    }
}

/// The line under an open folder that holds nothing this list shows. What's dropped on it goes into the folder.
struct OutlineEmptyRow: View {
    let folder: FolderRecord
    let depth: Int
    /// "No notes", "No meetings", "No captures"
    let text: String
    @State private var targeted = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 2)
            .padding(.leading, OutlineIndent.item(depth))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(targeted ? AnyShapeStyle(TintFill().opacity(0.22)) : AnyShapeStyle(Color.clear)))
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                DraggedItem.drop(items, into: folder.id, binder: folder.binderID, undoManager: undoManager)
            } isTargeted: { targeted = $0 }
            .listRowSeparator(.hidden)
            .accessibilityLabel("\(text) in \(folder.name)")
    }
}

/// Where an item is, under its title while the list is searched or filtered and so shows no folders: "Platform ›
/// Pipelines".
struct OutlinePlace: View {
    let names: [String]

    var body: some View {
        if !names.isEmpty {
            Label(names.joined(separator: " › "), systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
}

/// Closes every folder in a binder's list: the button in the list's header.
struct CollapseFoldersButton: View {
    let binderID: UUID
    @State private var expansion = FolderExpansion.shared
    @ReducedMotion private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expansion.collapseAll(in: binderID) }
        } label: {
            Image(systemName: "rectangle.compress.vertical")
        }
        .buttonStyle(.borderless)
        .quietControl()
        .disabled(!expansion.hasOpen(in: binderID))
        .help("Collapse all folders")
        .accessibilityLabel("Collapse all folders")
        .onAppear { OutlinePresses.add("collapse:" + binderID.uuidString) { expansion.collapseAll(in: binderID) } }
    }
}
