import Foundation
import SQLite3

/// Imports dictionary words and snippets from a local Wispr Flow install.
enum WisprImporter {
    static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite")

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    struct Summary {
        var words = 0
        var snippets = 0
        var skipped = 0
    }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Row {
        let phrase: String
        let replacement: String?
        let isSnippet: Bool
    }

    /// Counts what an import would bring over, without writing anything.
    static func preview() throws -> Summary {
        let rows = try readRows()
        return Summary(words: rows.filter { !$0.isSnippet }.count, snippets: rows.filter(\.isSnippet).count)
    }

    @MainActor
    static func importAll() throws -> Summary {
        var summary = Summary()
        var existingTriggers = Set(Store.shared.snippets().map { $0.trigger.lowercased() })
        for row in try readRows() {
            let phrase = row.phrase.trimmed
            let replacement = row.replacement?.trimmed ?? ""
            guard !phrase.isEmpty else { continue }
            if row.isSnippet {
                guard !replacement.isEmpty, existingTriggers.insert(phrase.lowercased()).inserted else {
                    summary.skipped += 1
                    continue
                }
                Store.shared.insert(SnippetItem(trigger: phrase, expansion: replacement))
                summary.snippets += 1
            } else {
                let added = !replacement.isEmpty && replacement != phrase
                    ? Store.shared.addDictionaryWord(replacement, aliases: [phrase], source: "wispr")
                    : Store.shared.addDictionaryWord(phrase, source: "wispr")
                if added { summary.words += 1 } else { summary.skipped += 1 }
            }
        }
        return summary
    }

    private static func readRows() throws -> [Row] {
        // Work on a copy so Wispr Flow's live database is never touched.
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory.appendingPathComponent("wispr-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }
        let copy = temp.appendingPathComponent("flow.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw ImportError(message: "Couldn't open the Wispr Flow database")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT phrase, replacement, isSnippet FROM Dictionary WHERE isDeleted = 0"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError(message: "Unrecognized Wispr Flow database format")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let phrase = sqlite3_column_text(statement, 0) else { continue }
            rows.append(Row(phrase: String(cString: phrase),
                            replacement: sqlite3_column_text(statement, 1).map { String(cString: $0) },
                            isSnippet: sqlite3_column_int(statement, 2) != 0))
        }
        return rows
    }
}
