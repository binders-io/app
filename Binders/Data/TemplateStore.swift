import AppKit
import Foundation
import BindersKit

/// Note templates: the ones Binders comes with, and your own, kept as Markdown files in Templates, next to the database.
/// One of yours with the same name as a built-in one takes its place.
@MainActor
enum TemplateStore {
    static var folder: URL { AppPaths.support.appendingPathComponent("Templates", isDirectory: true) }

    static var all: [NoteTemplate] {
        let yours = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { NoteTemplate(name: url.deletingPathExtension().lastPathComponent, body: $0) } }
        let names = Set(yours.map { $0.name.lowercased() })
        return NoteTemplate.builtIn.filter { !names.contains($0.name.lowercased()) } + yours
    }

    /// Keeps a note as a template, named after its title. Returns the file.
    @discardableResult
    static func save(_ note: NoteItem) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(TeamFiles.safeFileName(note.title))
        do {
            try note.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func showFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// A new note in `binder`, from a template or blank.
    static func newNote(from template: NoteTemplate?, in binder: BinderRecord) -> NoteItem {
        let note = NoteItem(text: template?.filled(date: Date(), binder: binder.name) ?? "")
        note.binderID = binder.id
        note.sharedWithTeam = binder.sharedWithTeam
        Store.shared.insert(note)
        return note
    }
}
