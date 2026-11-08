#if DEBUG
import Foundation
import OSLog

extension Outbox {
    /// Checks, in a folder of its own, that every build's outbox still reads, and that nothing this build can't read
    /// takes anything else with it: what failed, or nothing. The iPhone has no unit-test target, so each debug run does
    /// this as the app starts (Outbox.load): a change that would lose testers' outboxes stops a debug run at once.
    static func selfCheck() -> [String] {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("outbox-check-\(UUID().uuidString)", isDirectory: true)
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return [] }
        defer { try? manager.removeItem(at: folder) }
        let quiet = Logger(OSLog.disabled)
        let outbox = folder.appendingPathComponent("outbox.json")
        let encoder = JSONEncoder()
        var failed: [String] = []
        func check(_ condition: Bool, _ label: String) { if !condition { failed.append(label) } }
        func put(_ data: Data?, in url: URL) { try? data?.write(to: url) }
        func load() -> [PendingSave] { Outbox.load(in: folder, log: quiet) }
        func files() -> [String] { ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
        func clear() { for name in files() { try? manager.removeItem(at: folder.appendingPathComponent(name)) } }
        func json(_ item: PendingSave) -> String { (try? encoder.encode(item)).map { String(decoding: $0, as: UTF8.self) } ?? "null" }
        func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: 782_300_000 + seconds) }

        // As iPhone 2.0 (6) wrote it (6b7379e): a note for a binder, a to-do, and a dictation with its words as heard.
        let note = Six(id: UUID(), tool: "add_note", text: "Ignite booth plan\n\nTables by the door", binder: "Events", created: date(0.25))
        let todo = Six(id: UUID(), tool: "add_todo", text: "Call Sam tomorrow at 3 pm", binder: nil, created: date(60))
        let dictated = Six(id: UUID(), tool: PendingSave.dictation, text: "Book the dentist for Friday.", binder: nil, created: date(120.5),
                           raw: "um book the dentist for friday", app: "Binders on iPhone", model: "Apple Intelligence")
        put(try? encoder.encode([note, todo, dictated]), in: outbox)
        check(load() == [note, todo, dictated].map(\.current), "an outbox from iPhone 2.0 (6) reads")
        check(load().allSatisfy { $0.folder == nil }, "and its notes have no folder: they go to their binder's top")
        check(load().allSatisfy { $0.brainFor == nil && $0.isFor("mac") }, "and, from before the brain switch, they're for the Mac")
        clear()

        // As 2.0 (10) wrote it (07fe0ab), the first with All-day capture: a keyboard dictation and a conversation in two parts.
        let conversation = UUID()
        let spoken = Ten(id: UUID(), tool: PendingSave.dictation, text: "Send the deck by Thursday.", binder: nil, created: date(300),
                         raw: "send the deck by thursday", app: "iPhone keyboard")
        let parts = (0..<2).map { part in
            Ten(id: UUID(), tool: PendingSave.conversation, text: "", binder: nil, created: date(600 + Double(part) * 600), conversation: conversation,
                payload: Data(#"{"part":\#(part),"segments":[{"speaker":"Sam","text":"The booth is ready."}]}"#.utf8))
        }
        put(try? encoder.encode([spoken] + parts), in: outbox)
        check(load() == ([spoken] + parts).map(\.current), "an outbox from iPhone 2.0 (10) reads, a conversation's parts and all")
        clear()

        // An item with fields this build doesn't know (a newer build's), between two it does.
        let known = [PendingSave(id: UUID(), tool: "add_todo", text: "Call Sam", binder: nil, created: date(900)),
                     PendingSave(id: UUID(), tool: "add_note", text: "Booth plan", binder: "Events", created: date(960))]
        let newer = PendingSave(id: UUID(), tool: "add_todo", text: "Water the plants", binder: nil, created: date(930))
        let withMore = json(newer).dropLast() + #","attempts":2,"handoff":{"to":"Claude Code","note":"after lunch"}}"#
        put(Data("[\(json(known[0])),\(withMore),\(json(known[1]))]".utf8), in: outbox)
        check(load() == [known[0], newer, known[1]], "an item with fields this build doesn't know reads, and so does the rest")

        // Items this build can't read, among good ones: each is left out on its own.
        put(Data("""
        [\(json(known[0])),
         {"id":"\(UUID().uuidString)","tool":"add_note","created":782301000},
         {"id":"\(UUID().uuidString)","tool":"add_note","text":"Booth plan","created":"yesterday"},
         {"id":"not an id","tool":"add_todo","text":"Call Sam","created":782301000},
         "not an item",
         null,
         \(json(known[1]))]
        """.utf8), in: outbox)
        check(load() == known, "a damaged item takes nothing else with it")
        put(Data("[{\"id\":".utf8), in: outbox)
        check(load().isEmpty, "a file that isn't a list loads nothing, and nothing fails")
        clear()

        // This build's items, every field set: back as they were, an answer and a Give to each in a file of their own, the
        // answer first.
        let full = PendingSave(id: UUID(), tool: PendingSave.dictation, text: "Book the dentist.", binder: "Personal", created: date(1200),
                               raw: "um book the dentist", app: "All-day capture", model: "Apple Intelligence", conversation: UUID(),
                               payload: Data(#"{"text":"Book the dentist."}"#.utf8), card: UUID().uuidString, question: "2026-10-16T09:00:00Z",
                               folder: UUID().uuidString)
        let answer = PendingSave(id: UUID(), tool: PendingSave.answer, text: "Dark, please.", binder: nil, created: date(1260),
                                 card: UUID().uuidString, question: "2026-10-16T09:00:00-04:00")
        let handOff = PendingSave(id: UUID(), tool: PendingSave.handOff, text: "Fix the login bug", binder: nil, created: date(1320),
                                  card: UUID().uuidString, agent: "Claude Code", moment: UUID(), fromBacklog: true)
        check(Outbox.save([full, answer, handOff], in: folder), "this build's items are written")
        check(load() == [answer, full, handOff], "and read back as they were, every field, the answer first")
        check(files() == ["answers.json", "handoffs.json", "outbox.json"], "an answer and a Give to each wait in a file of their own")
        // iPhone 2.0 (6) and (10) read outbox.json all at once: what this build writes there still reads that way.
        let written = try? Data(contentsOf: outbox)
        check(written.flatMap { try? JSONDecoder().decode([Six].self, from: $0) }?.map(\.id) == [full.id]
              && written.flatMap { try? JSONDecoder().decode([Ten].self, from: $0) }?.first?.conversation == full.conversation,
              "iPhone 2.0 (6) and (10) still read what this build writes")
        // Each item once, however it was saved: one in both files loads once.
        put(try? encoder.encode([answer, full]), in: outbox)
        check(load().map(\.id) == [answer.id, full.id, handOff.id], "an item in both files loads once")
        clear()

        // A file that can't be opened (the iPhone locked, and the file an older build kept for an unlocked iPhone only) is
        // set aside rather than written over, and what's in it comes back once it opens, once.
        let waiting = [note, todo].map(\.current)
        put(try? encoder.encode(waiting), in: outbox)
        try? manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: outbox.path)
        // Where a file can't be closed to its owner, there's nothing to check.
        guard !manager.isReadableFile(atPath: outbox.path) else { return failed }
        let setAside = { files().filter { $0.contains(Outbox.setAsideMark) } }
        check(load().isEmpty && !manager.fileExists(atPath: outbox.path) && setAside().count == 1, "a file that can't be opened is set aside")
        let later = PendingSave(id: UUID(), tool: "add_todo", text: "Water the plants", binder: nil, created: date(1500))
        var items = [later]
        check(Outbox.save(items, in: folder) && !Outbox.recover(into: &items, in: folder, log: quiet) && items == [later]
              && setAside().count == 1, "while it can't be opened, the outbox goes on beside it")
        for name in setAside() { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent(name).path) }
        check(Outbox.recover(into: &items, in: folder, log: quiet) && items == [later] + waiting, "once it opens, what was in it comes back")
        check(setAside().isEmpty && load() == items, "into the outbox's own file, and the file set aside goes")
        check(!Outbox.recover(into: &items, in: folder, log: quiet) && items == [later] + waiting, "and it comes back once")
        return failed
    }

    /// PendingSave as iPhone 2.0 (6) had it (6b7379e).
    private struct Six: Codable {
        let id: UUID
        let tool: String
        let text: String
        let binder: String?
        let created: Date
        var raw: String? = nil
        var app: String? = nil
        var model: String? = nil

        /// As this build reads it: with no brain stamped, which means the Mac.
        var current: PendingSave {
            PendingSave(id: id, tool: tool, text: text, binder: binder, created: created, raw: raw, app: app, model: model, brainFor: nil)
        }
    }

    /// And as 2.0 (10) had it (07fe0ab), with a conversation's id and part.
    private struct Ten: Codable {
        let id: UUID
        let tool: String
        let text: String
        let binder: String?
        let created: Date
        var raw: String? = nil
        var app: String? = nil
        var model: String? = nil
        var conversation: UUID? = nil
        var payload: Data? = nil

        var current: PendingSave {
            PendingSave(id: id, tool: tool, text: text, binder: binder, created: created, raw: raw, app: app, model: model,
                        conversation: conversation, payload: payload, brainFor: nil)
        }
    }
}
#endif
