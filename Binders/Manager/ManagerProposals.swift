import Foundation
import BindersKit

/// Distill's proposals as the Manager reads and reviews them: what still waits for a person, and its place or dismiss,
/// as the review sheet does, each kept for Undo.
@MainActor
enum ManagerProposals {
    /// The proposals waiting for review: of one note, or of every note.
    static func list(note: UUID?) -> [String: Any] {
        let store = DistillStore.shared
        let notes: [UUID]
        if let note {
            notes = [note]
        } else {
            let files = (try? FileManager.default.contentsOfDirectory(at: DistillStore.folder, includingPropertiesForKeys: nil)) ?? []
            notes = files.filter { $0.pathExtension == "json" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
        }
        var listed: [[String: Any]] = []
        for id in notes {
            guard let item = Store.shared.note(id) else { continue }
            let waiting = store.file(for: id).distills.filter { $0.status == .proposed && !$0.waiting.isEmpty }
            guard !waiting.isEmpty else { continue }
            listed.append([
                "note": ["id": id.uuidString, "title": item.title],
                "proposals": waiting.map { proposal(of: $0, text: item.text) },
            ])
        }
        return ["notes": listed, "waiting_items": listed.reduce(0) { $0 + (($1["proposals"] as? [[String: Any]]) ?? []).reduce(0) { $0 + (($1["items"] as? [Any])?.count ?? 0) } }]
    }

    private static func proposal(of record: DistillRecord, text: String) -> [String: Any] {
        [
            "id": record.id.uuidString,
            "at": AutomationPayload.iso(record.at),
            "read_by": record.readByLine,
            "items": record.waiting.map { item -> [String: Any] in
                var entry: [String: Any] = ["id": item.id.uuidString, "title": item.title, "brief": String(item.brief.prefix(300)),
                                            "section_in_note": DistillSections.section(item.section, in: text) != nil]
                if let section = item.section { entry["section"] = section }
                if let size = item.size { entry["size"] = size.rawValue }
                if let who = item.meantFor { entry["for"] = who }
                return entry
            },
        ]
    }

    /// Places or puts aside a note's waiting proposals (`proposals`, every waiting one when empty), their `items` (every
    /// waiting one when empty). Each change is kept with the request.
    static func review(note: UUID, action: String, proposals: Set<UUID>, items: Set<UUID>, column: BoardColumn,
                       request: UUID, controller: DictationController) -> InboxResult {
        guard let item = Store.shared.note(note) else { return .failure("No note with that id") }
        let distill = controller.distill
        let manager = controller.manager
        let waiting = DistillStore.shared.file(for: note).distills.filter {
            $0.status == .proposed && !$0.waiting.isEmpty && (proposals.isEmpty || proposals.contains($0.id))
        }
        guard !waiting.isEmpty else { return .failure("“\(item.title)” has no proposal waiting\(proposals.isEmpty ? "" : " with those ids"). list_proposals shows them.") }
        var count = 0, made: [TaskCard] = []
        for record in waiting {
            let chosen = record.waiting.filter { items.isEmpty || items.contains($0.id) }
            guard !chosen.isEmpty else { continue }
            count += chosen.count
            if action == "place" {
                let cards = distill.place(record, items: Set(chosen.map(\.id)), column: column, by: .you)
                for card in cards {
                    manager.record(ManagerChange(kind: .madeCard, id: card.id, line: "Placed “\(card.title)” from “\(item.title)”"), for: request)
                }
                made += cards
            } else if items.isEmpty {
                let before = record.status
                distill.dismiss(record)
                manager.record(ManagerChange(kind: .dismissedProposal, id: record.id, line: "Put aside \(chosen.count) proposed item\(chosen.count == 1 ? "" : "s") of “\(item.title)”",
                                             before: before.rawValue, note: note, snapshot: ""), for: request)
            } else {
                var updated = DistillStore.shared.distill(record.id, of: note) ?? record
                let dropping = Set(chosen.map(\.id))
                for index in updated.items.indices where dropping.contains(updated.items[index].id) { updated.items[index].dropped = true }
                let before = updated.status
                DistillService.finishIfReviewed(&updated)
                distill.save(updated)
                distill.boardRevision += 1
                manager.record(ManagerChange(kind: .dismissedProposal, id: record.id, line: "Dropped \(chosen.count) proposed item\(chosen.count == 1 ? "" : "s") of “\(item.title)”",
                                             before: before.rawValue, note: note, snapshot: dropping.map(\.uuidString).joined(separator: ",")), for: request)
            }
        }
        guard count > 0 else { return .failure("None of those items waits in “\(item.title)”. list_proposals shows them.") }
        if action == "place" {
            return InboxResult(ok: true, id: note.uuidString, message: "Placed \(made.count) of \(count) item\(count == 1 ? "" : "s") from “\(item.title)” in \(column == .ready ? "Ready" : "Backlog").")
        }
        return InboxResult(ok: true, id: note.uuidString, message: "Put aside \(count) item\(count == 1 ? "" : "s") of “\(item.title)”.")
    }

    /// Undo of a put-aside proposal: waiting again, its dropped items back.
    static func undoDismiss(_ change: ManagerChange) -> String? {
        guard let note = change.note, var record = DistillStore.shared.distill(change.id, of: note) else { return "“\(change.line)”: the proposal is gone." }
        let dropped = Set((change.snapshot ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        for index in record.items.indices where dropped.contains(record.items[index].id) { record.items[index].dropped = false }
        record.status = DistillRecord.Status(rawValue: change.before ?? "") ?? .proposed
        if record.status != .proposed, record.waitsForReview { record.status = .proposed }
        DistillStore.shared.save(record)
        return nil
    }

    /// A card made from a proposal and taken away by Undo: its item waits in the proposal again.
    static func unplace(_ card: TaskCard) {
        guard let from = card.distilledFrom, var record = DistillStore.shared.distill(from.distill, of: from.note) else { return }
        guard let index = record.items.firstIndex(where: { $0.id == from.item }) else { return }
        record.items[index].card = nil
        record.status = .proposed
        DistillStore.shared.save(record)
    }
}
