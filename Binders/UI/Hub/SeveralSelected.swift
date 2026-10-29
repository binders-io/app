import SwiftUI
import BindersKit

// Several notes, meetings or captures selected at once (⌘-click, ⇧-click, ⌘A): what the notes list and the meetings and
// captures lists show and offer for them, the same in each.

/// Beside a list with several selected: how many, a few of their titles, what to do with them all, and what stays as it
/// is (a line each).
struct SeveralSelectedPanel<Actions: View>: View {
    /// "3 notes selected"
    let heading: String
    let titles: [String]
    /// What some of them keep to, and why: "1 is a teammate's note: it stays in their binder…"
    let rules: [String]
    /// The window-fit self-test's name for it.
    let probe: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.on.square")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(heading).font(BindersTheme.cardTitle)
            Text(titles.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + (titles.count > 3 ? " and \(titles.count - 3) more" : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions() }
                VStack(spacing: 8) { actions() }
            }
            // Short of room, the titles give way first: these say what stays as it is.
            ForEach(rules, id: \.self) { rule in
                Text(rule)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .layoutPriority(1)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fitProbe(probe)
    }
}

/// What can be done with several at once, on the panel beside the list: Move to Folder (the binder's folders, or a new
/// one), Move to Binder and Delete…, which asks once for all of them.
struct SeveralButtons: View {
    let count: Int
    /// "notes", "meetings", "captures"
    let noun: String
    /// The binder the list is in, whose folders Move to Folder offers; nil for a list of every binder's.
    let binderID: UUID?
    /// The folder they're all in (nil: the top), or, when `together` is false, where new things go.
    let folderID: UUID?
    var together = true
    let toFolder: (UUID?) -> Void
    let toBinder: (BinderRecord) -> Void
    let delete: () -> Void

    var body: some View {
        if let binderID {
            Menu { SeveralFolderItems(binderID: binderID, folderID: folderID, together: together, move: toFolder) } label: { Label("Move to Folder", systemImage: "folder") }
                .fixedSize()
                .help("Move the \(count) \(noun) into a folder in this binder, or a new one")
        }
        Menu { MoveToBinderItems(current: binderID, move: toBinder) } label: { Label("Move to Binder", systemImage: "books.vertical") }
            .fixedSize()
            .help("Move the \(count) \(noun) to the top of another binder")
        Button(role: .destructive, action: delete) { Label("Delete…", systemImage: "trash") }
            .fixedSize()
            .help("Delete the \(count) \(noun), after one question")
    }
}

/// The same in the list's menu, for the selection: "Move 3 Notes to Folder", "Move 3 Notes to Binder", "Delete 3 Notes…".
struct SeveralMenuItems: View {
    let count: Int
    /// "Notes", "Meetings", "Captures"
    let noun: String
    let binderID: UUID?
    let folderID: UUID?
    var together = true
    let toFolder: (UUID?) -> Void
    let toBinder: (BinderRecord) -> Void
    let delete: () -> Void

    var body: some View {
        if let binderID {
            Menu("Move \(count) \(noun) to Folder") { SeveralFolderItems(binderID: binderID, folderID: folderID, together: together, move: toFolder) }
        }
        Menu("Move \(count) \(noun) to Binder") { MoveToBinderItems(current: binderID, move: toBinder) }
        Divider()
        Button("Delete \(count) \(noun)…", role: .destructive, action: delete)
    }
}

/// The binder's folders, then New Folder…, which makes one where you are and moves them into it.
struct SeveralFolderItems: View {
    let binderID: UUID
    let folderID: UUID?
    var together = true
    let move: (UUID?) -> Void

    var body: some View {
        MoveToFolderItems(binderID: binderID, current: folderID, marksCurrent: together, move: move)
        Divider()
        Button(FolderPrompts.newFolderTitle(in: folderID)) {
            FolderPrompts.shared.create(in: binderID, parent: folderID) { made in move(made) }
        }
    }
}
