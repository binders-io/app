import Foundation
import Observation
import BindersKit

/// Each note's distills, kept as Distills/<note id>.json next to the database (`DistillFile`): the proposals, what was
/// placed from them, and when you last looked at the note's report. Read again whenever its file changed, so the app and
/// `Binders --mcp` read the same; only the app writes.
@MainActor
@Observable
final class DistillStore {
    static let shared = DistillStore()

    /// Bumped on every write, for the views that show a note's distills.
    private(set) var revision = 0
    @ObservationIgnored private var cache: [UUID: (modified: Date?, file: DistillFile)] = [:]

    static var folder: URL { AppPaths.support.appendingPathComponent("Distills", isDirectory: true) }
    static func url(for note: UUID) -> URL { folder.appendingPathComponent(note.uuidString).appendingPathExtension("json") }

    /// The note's file, or an empty one.
    func file(for note: UUID) -> DistillFile {
        let url = Self.url(for: note)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached = cache[note], cached.modified == modified { return cached.file }
        let file = (try? Data(contentsOf: url)).flatMap { try? DistillFile.decoder().decode(DistillFile.self, from: $0) } ?? DistillFile(note: note)
        cache[note] = (modified, file)
        return file
    }

    /// Changes the note's file and writes it.
    func update(_ note: UUID, _ change: (inout DistillFile) -> Void) {
        var file = file(for: note)
        change(&file)
        write(file)
    }

    private func write(_ file: DistillFile) {
        guard Store.shared.canSave else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let url = Self.url(for: file.note)
        if let data = try? DistillFile.encoder().encode(file) { try? data.write(to: url, options: .atomic) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        cache[file.note] = (modified, file)
        revision += 1
    }

    func distill(_ id: UUID, of note: UUID) -> DistillRecord? {
        file(for: note).distills.first { $0.id == id }
    }

    /// Replaces one distill, as the review sheet left it.
    func save(_ distill: DistillRecord) {
        update(distill.note) { file in
            if let index = file.distills.firstIndex(where: { $0.id == distill.id }) {
                file.distills[index] = distill
            } else {
                file.distills.append(distill)
            }
        }
    }

    /// A deleted note's distills go with it.
    func forget(_ note: UUID) {
        cache[note] = nil
        try? FileManager.default.removeItem(at: Self.url(for: note))
        revision += 1
    }
}
