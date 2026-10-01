import AppKit
import SwiftData
import UniformTypeIdentifiers
import BindersKit

/// Pictures, videos and files added to notes. They're kept in an attachments folder next to the database, and notes
/// refer to them as "attachments/<name>": the same place they sit next to a note in a team folder or an Obsidian vault.
@MainActor
enum Attachments {
    static var folder: URL { AppPaths.support.appendingPathComponent(MarkdownMedia.folder, isDirectory: true) }

    /// The file a note's picture or link points to: in the attachments folder, a file elsewhere, or a web address.
    static func url(for source: String) -> URL? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("file://") { return URL(string: source) }
        if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
        if source.hasPrefix("~/") { return URL(fileURLWithPath: (source as NSString).expandingTildeInPath) }
        var name = source
        if name.hasPrefix(MarkdownMedia.folder + "/") { name = String(name.dropFirst(MarkdownMedia.folder.count + 1)) }
        // Only ever inside the folder.
        name = (name as NSString).lastPathComponent
        guard !name.isEmpty, name != "..", name != "." else { return nil }
        return folder.appendingPathComponent(name)
    }

    /// Copies a file in, and gives the Markdown that shows it.
    static func add(_ file: URL) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = freeName(for: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
        let caption = MarkdownMedia.kind(of: name) == .other ? name : ""
        return MarkdownMedia.markdown(forFile: name, caption: caption)
    }

    /// Saves a picture that came as data, from a paste or a drag, and gives the Markdown that shows it.
    static func add(imageData data: Data, type: UTType) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = data
        var ext = type.preferredFilenameExtension ?? "png"
        // TIFF is what screenshots and other apps often put on the clipboard: big, and not for the web. PNG keeps it sharp.
        if type.conforms(to: .tiff) || !MarkdownMedia.imageExtensions.contains(ext) {
            guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            data = png
            ext = "png"
        }
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        let name = freeName(for: "Pasted image \(stamp).\(ext)")
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        return MarkdownMedia.markdown(forFile: name, caption: "")
    }

    /// The name itself when it's free, else "name 2.png", "name 3.png"…
    private static func freeName(for wanted: String) -> String {
        var cleaned = wanted.replacingOccurrences(of: "[/:\\\\\\n\\r\\t\\[\\]]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        if cleaned.isEmpty { cleaned = "Attachment" }
        let base = (cleaned as NSString).deletingPathExtension, ext = (cleaned as NSString).pathExtension
        var name = cleaned
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        return name
    }

    // MARK: Tidying up

    /// Moves to the Trash the attachments nothing refers to any more: no note, meeting, card or earlier version of a
    /// note. Only once they've gone unused a week, so Undo, a restore or a slow sync can still find them.
    static func trashUnused(olderThan age: TimeInterval = 7 * 86_400, deleting: Bool = false) {
        let manager = FileManager.default
        // The empty store used when the database won't open says nothing about what's used.
        guard !Store.shared.isFallback,
              let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]), !files.isEmpty,
              let notes = try? Store.shared.context.fetch(FetchDescriptor<NoteItem>()),
              let meetings = try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>()),
              let cards = try? Store.shared.context.fetch(FetchDescriptor<TaskCard>()) else { return }
        var used = Set<String>()
        for text in notes.map(\.text) + meetings.flatMap({ [$0.userNotes, $0.summary] }) + cards.map(\.details) {
            used.formUnion(MarkdownMedia.attachmentNames(in: text))
        }
        if let histories = manager.enumerator(at: NoteHistory.folder, includingPropertiesForKeys: nil) {
            while let url = histories.nextObject() as? URL {
                guard url.pathExtension == "md", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                used.formUnion(MarkdownMedia.attachmentNames(in: text))
            }
        }
        for file in files where !used.contains(file.lastPathComponent) && !file.lastPathComponent.hasPrefix(".") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            guard Date().timeIntervalSince(modified) > age else { continue }
            if deleting { try? manager.removeItem(at: file) } else { try? manager.trashItem(at: file, resultingItemURL: nil) }
        }
    }

    // MARK: Team folders

    /// Puts each attachment a shared note uses on both sides: next to the note's file in the team folder, and here.
    static func sync(_ text: String, noteFile: URL) {
        let names = MarkdownMedia.attachmentNames(in: text)
        guard !names.isEmpty else { return }
        let manager = FileManager.default
        let remoteFolder = noteFile.deletingLastPathComponent().appendingPathComponent(MarkdownMedia.folder, isDirectory: true)
        for name in names {
            let local = folder.appendingPathComponent(name), remote = remoteFolder.appendingPathComponent(name)
            let here = manager.fileExists(atPath: local.path), there = manager.fileExists(atPath: remote.path)
            if here, !there {
                try? manager.createDirectory(at: remoteFolder, withIntermediateDirectories: true)
                try? manager.copyItem(at: local, to: remote)
            } else if there, !here {
                try? manager.startDownloadingUbiquitousItem(at: remote)
                try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try? manager.copyItem(at: remote, to: local)
            }
        }
    }
}
