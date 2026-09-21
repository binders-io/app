import Foundation
import SQLite3
import BindersKit

struct KnowledgeDocument: Sendable {
    var id: String
    var kind: KnowledgeKind
    var sourceID: String
    var title: String
    var createdAt: Date
    var contentHash: String
    /// The teammate who shared it; nil for your own items.
    var author: String? = nil
    /// The binder the meeting or note is filed in; nil for dictations and commands.
    var binderID: String? = nil
}

struct KnowledgeHit: Identifiable, Hashable, Sendable {
    let chunkID: Int64
    let documentID: String
    let kind: KnowledgeKind
    let sourceID: String
    let title: String
    let createdAt: Date
    let text: String
    /// Matched terms wrapped in « » when the hit came from keyword search.
    var snippet: String
    let startTime: TimeInterval?
    let speaker: String?
    let author: String?
    let binderID: String?
    var score: Double

    var id: Int64 { chunkID }
}

enum KnowledgeOwner: String, CaseIterable, Sendable {
    case everyone, mine, team

    var displayName: String {
        switch self {
        case .everyone: "Everyone's"
        case .mine: "Mine"
        case .team: "From teammates"
        }
    }

    func includes(_ hit: KnowledgeHit) -> Bool {
        switch self {
        case .everyone: true
        case .mine: hit.author == nil
        case .team: hit.author != nil
        }
    }
}

struct KnowledgeEntity: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let type: String
    let mentions: Int
    let documents: Int
}

struct KnowledgeRelation: Hashable, Sendable {
    let label: String
    let other: String
    let otherID: Int64
    let outgoing: Bool
}

struct KnowledgeGraphData: Sendable {
    struct Node: Hashable, Sendable {
        let id: String
        let label: String
        /// A document kind ("meeting", "note", …) or an entity type ("person", "topic", …).
        let kind: String
        let weight: Double
        let entityID: Int64?
        let sourceID: String?

        var isDocument: Bool { entityID == nil }
    }

    var nodes: [Node] = []
    var edges: [GraphEdge] = []
}

struct EntityJob: Sendable {
    let documentID: String
    let title: String
    let contentHash: String
    let chunks: [(id: Int64, text: String)]
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Search index and knowledge graph, kept in its own SQLite file (FTS5 + embeddings + entities).
actor KnowledgeStore {
    private let db: OpaquePointer?
    private var vectorCache: [(id: Int64, vector: [Float])]?

    init(url: URL) {
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) != SQLITE_OK {
            Log.app.error("Couldn't open knowledge index at \(url.path)")
            handle = nil
        }
        db = handle
        sqlite3_exec(handle, """
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=OFF;
            CREATE TABLE IF NOT EXISTS documents(
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, source_id TEXT NOT NULL, title TEXT NOT NULL,
                created_at REAL NOT NULL, content_hash TEXT NOT NULL, entities_hash TEXT);
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY AUTOINCREMENT, document_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
                text TEXT NOT NULL, start_time REAL, speaker TEXT, embedding BLOB);
            CREATE INDEX IF NOT EXISTS chunks_document ON chunks(document_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(text, title, tokenize='unicode61 remove_diacritics 2');
            CREATE TABLE IF NOT EXISTS entities(
                id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, normalized TEXT NOT NULL UNIQUE, type TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS mentions(
                entity_id INTEGER NOT NULL, document_id TEXT NOT NULL, chunk_id INTEGER NOT NULL,
                PRIMARY KEY(entity_id, document_id, chunk_id));
            CREATE INDEX IF NOT EXISTS mentions_document ON mentions(document_id);
            CREATE TABLE IF NOT EXISTS relations(from_id INTEGER NOT NULL, to_id INTEGER NOT NULL, label TEXT NOT NULL, document_id TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS relations_document ON relations(document_id);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS ignored_entities(normalized TEXT PRIMARY KEY, name TEXT NOT NULL, type TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS entity_aliases(normalized TEXT PRIMARY KEY, name TEXT NOT NULL, entity_id INTEGER NOT NULL);
            """, nil, nil, nil)
        // Added with team spaces, then binders; each fails harmlessly when the column exists.
        sqlite3_exec(handle, "ALTER TABLE documents ADD COLUMN author TEXT", nil, nil, nil)
        sqlite3_exec(handle, "ALTER TABLE documents ADD COLUMN binder_id TEXT", nil, nil, nil)
    }

    // MARK: Documents

    func documentHashes() -> [String: String] {
        var result: [String: String] = [:]
        select("SELECT id, content_hash FROM documents") { row in
            if let id = Self.text(row, 0) { result[id] = Self.text(row, 1) ?? "" }
        }
        return result
    }

    func upsert(_ document: KnowledgeDocument, chunks: [KnowledgeChunk]) {
        run("BEGIN")
        deleteContent(of: document.id)
        run("INSERT OR REPLACE INTO documents(id, kind, source_id, title, created_at, content_hash, entities_hash, author, binder_id) VALUES(?,?,?,?,?,?,NULL,?,?)",
            [document.id, document.kind.rawValue, document.sourceID, document.title, document.createdAt.timeIntervalSince1970, document.contentHash,
             document.author, document.binderID])
        for (ordinal, chunk) in chunks.enumerated() {
            run("INSERT INTO chunks(document_id, ordinal, text, start_time, speaker) VALUES(?,?,?,?,?)",
                [document.id, ordinal, chunk.text, chunk.startTime, chunk.speaker])
            run("INSERT INTO chunks_fts(rowid, text, title) VALUES(?,?,?)", [sqlite3_last_insert_rowid(db), chunk.text, document.title])
        }
        run("COMMIT")
        vectorCache = nil
    }

    func remove(documentIDs: [String]) {
        guard !documentIDs.isEmpty else { return }
        run("BEGIN")
        for id in documentIDs {
            deleteContent(of: id)
            run("DELETE FROM documents WHERE id = ?", [id])
        }
        run("DELETE FROM entities WHERE id NOT IN (SELECT entity_id FROM mentions)")
        run("COMMIT")
        vectorCache = nil
    }

    func reset() {
        run("BEGIN")
        for table in ["chunks_fts", "chunks", "mentions", "relations", "entities", "documents", "meta"] {
            run("DELETE FROM \(table)")
        }
        run("COMMIT")
        vectorCache = nil
    }

    func stats() -> (documents: Int, chunks: Int, embedded: Int, entities: Int) {
        var result = (documents: 0, chunks: 0, embedded: 0, entities: 0)
        select("""
            SELECT (SELECT COUNT(*) FROM documents), (SELECT COUNT(*) FROM chunks),
                   (SELECT COUNT(*) FROM chunks WHERE embedding IS NOT NULL), (SELECT COUNT(*) FROM entities)
            """) { row in
            result = (Int(sqlite3_column_int64(row, 0)), Int(sqlite3_column_int64(row, 1)),
                      Int(sqlite3_column_int64(row, 2)), Int(sqlite3_column_int64(row, 3)))
        }
        return result
    }

    private func deleteContent(of documentID: String) {
        run("DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE document_id = ?)", [documentID])
        run("DELETE FROM chunks WHERE document_id = ?", [documentID])
        run("DELETE FROM mentions WHERE document_id = ?", [documentID])
        run("DELETE FROM relations WHERE document_id = ?", [documentID])
    }

    // MARK: Embeddings

    /// Clears stored vectors when the embedding model changes, since vectors from different models aren't comparable.
    func useEmbeddingModel(_ model: String) {
        var current: String?
        select("SELECT value FROM meta WHERE key = 'embedding_model'") { current = Self.text($0, 0) }
        guard current != model else { return }
        run("UPDATE chunks SET embedding = NULL")
        run("INSERT OR REPLACE INTO meta(key, value) VALUES('embedding_model', ?)", [model])
        vectorCache = nil
    }

    func chunksNeedingEmbedding(limit: Int) -> [(id: Int64, text: String, title: String)] {
        var result: [(id: Int64, text: String, title: String)] = []
        select("SELECT c.id, c.text, d.title FROM chunks c JOIN documents d ON d.id = c.document_id WHERE c.embedding IS NULL LIMIT ?", [limit]) { row in
            result.append((sqlite3_column_int64(row, 0), Self.text(row, 1) ?? "", Self.text(row, 2) ?? ""))
        }
        return result
    }

    func setEmbeddings(_ items: [(id: Int64, vector: [Float])]) {
        run("BEGIN")
        for item in items {
            let data = VectorMath.normalized(item.vector).withUnsafeBufferPointer { Data(buffer: $0) }
            run("UPDATE chunks SET embedding = ? WHERE id = ?", [data, item.id])
        }
        run("COMMIT")
        vectorCache = nil
    }

    // MARK: Search

    func keywordSearch(_ query: String, limit: Int, kinds: Set<KnowledgeKind>?, owner: KnowledgeOwner = .everyone,
                       binder: String? = nil) -> [KnowledgeHit] {
        guard let match = Self.ftsQuery(query) else { return [] }
        var hits: [KnowledgeHit] = []
        select("""
            SELECT c.id, c.document_id, d.kind, d.source_id, d.title, d.created_at, c.text, c.start_time, c.speaker,
                   snippet(chunks_fts, 0, '«', '»', '…', 18), bm25(chunks_fts, 1.0, 0.4), d.author, d.binder_id
            FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid JOIN documents d ON d.id = c.document_id
            WHERE chunks_fts MATCH ? AND (? IS NULL OR d.binder_id = ?) ORDER BY bm25(chunks_fts, 1.0, 0.4) LIMIT ?
            """, [match, binder, binder, limit * 3]) { row in
            if let hit = Self.hit(row, snippetColumn: 9, authorColumn: 11, binderColumn: 12) { hits.append(hit) }
        }
        return Array(hits.filter { (kinds?.contains($0.kind) ?? true) && owner.includes($0) }.prefix(limit))
    }

    func semanticSearch(_ vector: [Float], limit: Int, minScore: Float, kinds: Set<KnowledgeKind>?,
                        owner: KnowledgeOwner = .everyone, binder: String? = nil) -> [KnowledgeHit] {
        if vectorCache == nil {
            var loaded: [(id: Int64, vector: [Float])] = []
            select("SELECT id, embedding FROM chunks WHERE embedding IS NOT NULL") { row in
                let count = Int(sqlite3_column_bytes(row, 1)) / MemoryLayout<Float>.size
                guard count > 0, let bytes = sqlite3_column_blob(row, 1) else { return }
                var values = [Float](repeating: 0, count: count)
                values.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, bytes, count * MemoryLayout<Float>.size) }
                loaded.append((sqlite3_column_int64(row, 0), values))
            }
            vectorCache = loaded
        }
        let matches = VectorMath.topMatches(query: vector, candidates: vectorCache ?? [], limit: limit * (binder == nil ? 3 : 8), minScore: minScore)
        let byID = hits(for: matches.map(\.id))
        return Array(matches.compactMap { match -> KnowledgeHit? in
            guard var hit = byID[match.id], kinds?.contains(hit.kind) ?? true, owner.includes(hit),
                  binder == nil || hit.binderID == binder else { return nil }
            hit.score = Double(match.score)
            return hit
        }.prefix(limit))
    }

    private func hits(for ids: [Int64]) -> [Int64: KnowledgeHit] {
        guard !ids.isEmpty else { return [:] }
        var result: [Int64: KnowledgeHit] = [:]
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        select("""
            SELECT c.id, c.document_id, d.kind, d.source_id, d.title, d.created_at, c.text, c.start_time, c.speaker, d.author, d.binder_id
            FROM chunks c JOIN documents d ON d.id = c.document_id WHERE c.id IN (\(placeholders))
            """, ids.map { $0 as Any? }) { row in
            if let hit = Self.hit(row, snippetColumn: nil, authorColumn: 9, binderColumn: 10) { result[hit.chunkID] = hit }
        }
        return result
    }

    /// Prefix-matches every meaningful word; BM25 ranks passages that match more of them higher.
    static func ftsQuery(_ text: String) -> String? {
        let stopwords: Set<String> = [
            "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "what", "did", "we", "i", "about", "is", "was", "were",
            "do", "does", "my", "our", "you", "it", "that", "this", "with", "at", "by", "from", "how", "when", "who", "where", "why",
            "which", "look", "up", "find", "search", "me", "remind", "say", "said", "decide", "decided", "talk", "talked",
        ]
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) }
        guard !tokens.isEmpty else { return nil }
        return Array(Set(tokens)).sorted().map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    // MARK: Entities

    func nextEntityJob(kinds: [KnowledgeKind]) -> EntityJob? {
        let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
        var header: (id: String, title: String, hash: String)?
        select("""
            SELECT id, title, content_hash FROM documents
            WHERE (entities_hash IS NULL OR entities_hash != content_hash) AND kind IN (\(placeholders))
            ORDER BY created_at DESC LIMIT 1
            """, kinds.map { $0.rawValue as Any? }) { row in
            header = (Self.text(row, 0) ?? "", Self.text(row, 1) ?? "", Self.text(row, 2) ?? "")
        }
        guard let header else { return nil }
        return EntityJob(documentID: header.id, title: header.title, contentHash: header.hash, chunks: chunks(of: header.id))
    }

    func saveEntities(job: EntityJob, result: ExtractionResult) {
        run("BEGIN")
        run("DELETE FROM mentions WHERE document_id = ?", [job.documentID])
        run("DELETE FROM relations WHERE document_id = ?", [job.documentID])
        let haystacks = job.chunks.map { (id: $0.id, text: EntityExtraction.haystack($0.text)) }
        let ignored = ignoredKeys()
        let aliases = aliasMap()
        var ids: [String: Int64] = [:]
        for entity in result.entities {
            let key = EntityExtraction.normalize(entity.name)
            let keys = [key] + entity.aliases.map(EntityExtraction.normalize)
            // Names the user removed stay removed, whatever the model says next time.
            guard !keys.contains(where: ignored.contains) else { continue }
            // Names the user merged land on the person they were merged into.
            let entityID = keys.lazy.compactMap { aliases[$0] }.first { entityExists($0) }
                ?? upsertEntity(name: entity.name, key: key, type: entity.type)
            for aliasKey in keys { ids[aliasKey] = entityID }
            var chunkIDs = haystacks.filter { chunk in keys.contains { EntityExtraction.contains(haystack: chunk.text, key: $0) } }.map(\.id)
            if chunkIDs.isEmpty, let first = job.chunks.first?.id { chunkIDs = [first] }
            for chunkID in chunkIDs {
                run("INSERT OR IGNORE INTO mentions(entity_id, document_id, chunk_id) VALUES(?,?,?)", [entityID, job.documentID, chunkID])
            }
        }
        for relation in result.relations {
            guard let from = ids[EntityExtraction.normalize(relation.from)], let to = ids[EntityExtraction.normalize(relation.to)] else { continue }
            run("INSERT INTO relations(from_id, to_id, label, document_id) VALUES(?,?,?,?)", [from, to, relation.label, job.documentID])
        }
        run("UPDATE documents SET entities_hash = content_hash WHERE id = ? AND content_hash = ?", [job.documentID, job.contentHash])
        run("DELETE FROM entities WHERE id NOT IN (SELECT entity_id FROM mentions)")
        run("COMMIT")
    }

    /// Makes short documents (dictations, commands) re-check links, e.g. after new names were learned from a meeting.
    func resetLinks(kinds: [KnowledgeKind]) {
        let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
        run("UPDATE documents SET entities_hash = NULL WHERE kind IN (\(placeholders))", kinds.map { $0.rawValue as Any? })
    }

    /// Links short documents to names already known from meetings and notes, plus their own [[wikilinks]], without the model.
    func linkKnownEntities(kinds: [KnowledgeKind], limit: Int) -> Int {
        let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
        var jobs: [(id: String, hash: String)] = []
        select("""
            SELECT id, content_hash FROM documents
            WHERE (entities_hash IS NULL OR entities_hash != content_hash) AND kind IN (\(placeholders)) LIMIT ?
            """, kinds.map { $0.rawValue as Any? } + [limit]) { row in
            jobs.append((Self.text(row, 0) ?? "", Self.text(row, 1) ?? ""))
        }
        guard !jobs.isEmpty else { return 0 }
        var known: [(id: Int64, key: String)] = []
        select("SELECT id, normalized FROM entities") { row in known.append((sqlite3_column_int64(row, 0), Self.text(row, 1) ?? "")) }
        select("SELECT entity_id, normalized FROM entity_aliases") { row in known.append((sqlite3_column_int64(row, 0), Self.text(row, 1) ?? "")) }
        let ignored = ignoredKeys()

        run("BEGIN")
        for job in jobs {
            run("DELETE FROM mentions WHERE document_id = ?", [job.id])
            for chunk in chunks(of: job.id) {
                let haystack = EntityExtraction.haystack(chunk.text)
                for entity in known where EntityExtraction.contains(haystack: haystack, key: entity.key) {
                    run("INSERT OR IGNORE INTO mentions(entity_id, document_id, chunk_id) VALUES(?,?,?)", [entity.id, job.id, chunk.id])
                }
                for target in WikiLinks.targets(in: chunk.text) where !ignored.contains(EntityExtraction.normalize(target)) {
                    let entityID = upsertEntity(name: target, key: EntityExtraction.normalize(target), type: "topic")
                    run("INSERT OR IGNORE INTO mentions(entity_id, document_id, chunk_id) VALUES(?,?,?)", [entityID, job.id, chunk.id])
                }
            }
            run("UPDATE documents SET entities_hash = content_hash WHERE id = ? AND content_hash = ?", [job.id, job.hash])
        }
        run("COMMIT")
        return jobs.count
    }

    /// Whether the text names a person, project or topic already in the graph.
    func mentionsKnownEntity(_ text: String) -> Bool {
        let haystack = EntityExtraction.haystack(text)
        var found = false
        select("SELECT normalized FROM entities") { row in
            if !found, let key = Self.text(row, 0), key.count > 2, EntityExtraction.contains(haystack: haystack, key: key) { found = true }
        }
        return found
    }

    /// Everyone and everything mentioned, most widely mentioned first; within one binder when `binder` is given.
    func entities(limit: Int, binder: String? = nil) -> [KnowledgeEntity] {
        var result: [KnowledgeEntity] = []
        select("""
            SELECT e.id, e.name, e.type, COUNT(*), COUNT(DISTINCT m.document_id) FROM entities e
            JOIN mentions m ON m.entity_id = e.id JOIN documents d ON d.id = m.document_id
            WHERE (? IS NULL OR d.binder_id = ?) GROUP BY e.id
            ORDER BY COUNT(DISTINCT m.document_id) DESC, COUNT(*) DESC, e.name LIMIT ?
            """, [binder, binder, limit]) { row in
            result.append(Self.entity(row))
        }
        return result
    }

    func entity(id: Int64) -> KnowledgeEntity? {
        var result: KnowledgeEntity?
        select("""
            SELECT e.id, e.name, e.type, COUNT(m.entity_id), COUNT(DISTINCT m.document_id) FROM entities e
            LEFT JOIN mentions m ON m.entity_id = e.id WHERE e.id = ? GROUP BY e.id
            """, [id]) { result = Self.entity($0) }
        return result
    }

    func mentions(of entityID: Int64, limit: Int) -> [KnowledgeHit] {
        var result: [KnowledgeHit] = []
        select("""
            SELECT c.id, c.document_id, d.kind, d.source_id, d.title, d.created_at, c.text, c.start_time, c.speaker, d.author, d.binder_id
            FROM mentions m JOIN chunks c ON c.id = m.chunk_id JOIN documents d ON d.id = m.document_id
            WHERE m.entity_id = ? ORDER BY d.created_at DESC, c.ordinal LIMIT ?
            """, [entityID, limit]) { row in
            if let hit = Self.hit(row, snippetColumn: nil, authorColumn: 9, binderColumn: 10) { result.append(hit) }
        }
        return result
    }

    /// Entities that come up in the same meetings, notes and dictations; `documents` is the number shared.
    func related(to entityID: Int64, limit: Int) -> [KnowledgeEntity] {
        var result: [KnowledgeEntity] = []
        select("""
            SELECT e.id, e.name, e.type, COUNT(*), COUNT(DISTINCT m2.document_id)
            FROM mentions m1 JOIN mentions m2 ON m2.document_id = m1.document_id AND m2.entity_id != m1.entity_id
            JOIN entities e ON e.id = m2.entity_id
            WHERE m1.entity_id = ? GROUP BY e.id ORDER BY COUNT(DISTINCT m2.document_id) DESC, COUNT(*) DESC LIMIT ?
            """, [entityID, limit]) { row in
            result.append(Self.entity(row))
        }
        return result
    }

    func relations(of entityID: Int64) -> [KnowledgeRelation] {
        var result: [KnowledgeRelation] = []
        select("""
            SELECT r.label, e.name, e.id, 1 FROM relations r JOIN entities e ON e.id = r.to_id WHERE r.from_id = ?
            UNION
            SELECT r.label, e.name, e.id, 0 FROM relations r JOIN entities e ON e.id = r.from_id WHERE r.to_id = ?
            """, [entityID, entityID]) { row in
            result.append(KnowledgeRelation(label: Self.text(row, 0) ?? "", other: Self.text(row, 1) ?? "",
                                            otherID: sqlite3_column_int64(row, 2), outgoing: sqlite3_column_int(row, 3) == 1))
        }
        return result
    }

    /// Meetings, notes and commands as nodes, linked to the people, projects and topics they mention.
    func graph(documentLimit: Int, entityLimit: Int, binder: String? = nil) -> KnowledgeGraphData {
        var documents: [KnowledgeGraphData.Node] = []
        select("""
            SELECT d.id, d.title, d.kind, d.source_id, COUNT(DISTINCT m.entity_id) FROM documents d
            JOIN mentions m ON m.document_id = d.id WHERE d.kind IN ('meeting', 'note', 'writing', 'command') AND (? IS NULL OR d.binder_id = ?)
            GROUP BY d.id ORDER BY d.created_at DESC LIMIT ?
            """, [binder, binder, documentLimit]) { row in
            documents.append(KnowledgeGraphData.Node(id: "d:" + (Self.text(row, 0) ?? ""), label: Self.text(row, 1) ?? "",
                                                     kind: Self.text(row, 2) ?? "note", weight: Double(sqlite3_column_int64(row, 4)),
                                                     entityID: nil, sourceID: Self.text(row, 3)))
        }
        guard !documents.isEmpty else { return KnowledgeGraphData() }
        let documentIDs = documents.map { String($0.id.dropFirst(2)) }
        let placeholders = Array(repeating: "?", count: documentIDs.count).joined(separator: ",")
        var links: [(document: String, entity: Int64, name: String, type: String)] = []
        select("""
            SELECT DISTINCT m.document_id, e.id, e.name, e.type FROM mentions m JOIN entities e ON e.id = m.entity_id
            WHERE m.document_id IN (\(placeholders))
            """, documentIDs.map { $0 as Any? }) { row in
            links.append((Self.text(row, 0) ?? "", sqlite3_column_int64(row, 1), Self.text(row, 2) ?? "", Self.text(row, 3) ?? "topic"))
        }
        var counts: [Int64: (name: String, type: String, count: Int)] = [:]
        for link in links {
            counts[link.entity, default: (link.name, link.type, 0)].count += 1
        }
        let kept = counts.sorted { $0.value.count == $1.value.count ? $0.value.name < $1.value.name : $0.value.count > $1.value.count }
            .prefix(entityLimit)
        let keptIDs = Set(kept.map(\.key))
        var graph = KnowledgeGraphData()
        graph.nodes = documents + kept.map {
            KnowledgeGraphData.Node(id: "e:\($0.key)", label: $0.value.name, kind: $0.value.type, weight: Double($0.value.count),
                                    entityID: $0.key, sourceID: nil)
        }
        graph.edges = links.filter { keptIDs.contains($0.entity) }.map { GraphEdge(from: "d:" + $0.document, to: "e:\($0.entity)") }
        return graph
    }

    private func chunks(of documentID: String) -> [(id: Int64, text: String)] {
        var result: [(id: Int64, text: String)] = []
        select("SELECT id, text FROM chunks WHERE document_id = ? ORDER BY ordinal", [documentID]) { row in
            result.append((sqlite3_column_int64(row, 0), Self.text(row, 1) ?? ""))
        }
        return result
    }

    // MARK: Forgetting entities

    struct IgnoredEntity: Identifiable, Hashable, Sendable {
        let key: String
        let name: String
        let type: String
        var id: String { key }
    }

    /// Removes a person, project or topic the model got wrong, with its mentions and relationships, and remembers not to
    /// extract it again. The meetings, notes and dictations themselves are untouched.
    func forget(entityID: Int64) -> Bool {
        var found: (key: String, name: String, type: String)?
        select("SELECT normalized, name, type FROM entities WHERE id = ?", [entityID]) { row in
            found = (Self.text(row, 0) ?? "", Self.text(row, 1) ?? "", Self.text(row, 2) ?? "")
        }
        guard let found else { return false }
        run("BEGIN")
        run("INSERT OR REPLACE INTO ignored_entities(normalized, name, type) VALUES(?,?,?)", [found.key, found.name, found.type])
        run("DELETE FROM mentions WHERE entity_id = ?", [entityID])
        run("DELETE FROM relations WHERE from_id = ? OR to_id = ?", [entityID, entityID])
        run("DELETE FROM entities WHERE id = ?", [entityID])
        run("COMMIT")
        return true
    }

    func ignoredEntities() -> [IgnoredEntity] {
        var result: [IgnoredEntity] = []
        select("SELECT normalized, name, type FROM ignored_entities ORDER BY name COLLATE NOCASE") { row in
            result.append(IgnoredEntity(key: Self.text(row, 0) ?? "", name: Self.text(row, 1) ?? "", type: Self.text(row, 2) ?? ""))
        }
        return result
    }

    /// Lets a removed name come back: the documents that mention it are queued for extraction again.
    func restore(ignoredKey key: String) {
        run("DELETE FROM ignored_entities WHERE normalized = ?", [key])
        var documentIDs = Set<String>()
        select("SELECT document_id, text FROM chunks") { row in
            if let id = Self.text(row, 0), let text = Self.text(row, 1),
               EntityExtraction.contains(haystack: EntityExtraction.haystack(text), key: key) {
                documentIDs.insert(id)
            }
        }
        for id in documentIDs { run("UPDATE documents SET entities_hash = NULL WHERE id = ?", [id]) }
    }

    // MARK: Renaming and merging

    /// Renames an entity. If the new name is already another entity's, the two are merged and that entity's id comes
    /// back; either way the old name is remembered as an alias so future extractions land in the right place.
    func rename(entityID: Int64, to newName: String) -> Int64? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newKey = EntityExtraction.normalize(name)
        guard !newKey.isEmpty, let current = entityRecord(entityID) else { return nil }
        var existing: Int64?
        select("SELECT id FROM entities WHERE normalized = ? AND id != ?", [newKey, entityID]) { existing = sqlite3_column_int64($0, 0) }
        if let existing {
            guard merge(entityID, into: existing) else { return nil }
            run("UPDATE entities SET name = ? WHERE id = ?", [name, existing])
            return existing
        }
        run("BEGIN")
        if current.key != newKey {
            run("INSERT OR REPLACE INTO entity_aliases(normalized, name, entity_id) VALUES(?,?,?)", [current.key, current.name, entityID])
            run("DELETE FROM entity_aliases WHERE normalized = ?", [newKey])
        }
        run("UPDATE entities SET name = ?, normalized = ? WHERE id = ?", [name, newKey, entityID])
        run("COMMIT")
        return entityID
    }

    /// Folds `source` into `target`: mentions and relationships move over, the source's names become aliases of the
    /// target, and the source disappears.
    func merge(_ source: Int64, into target: Int64) -> Bool {
        guard source != target, let from = entityRecord(source), let into = entityRecord(target) else { return false }
        run("BEGIN")
        run("INSERT OR IGNORE INTO mentions(entity_id, document_id, chunk_id) SELECT ?, document_id, chunk_id FROM mentions WHERE entity_id = ?", [target, source])
        run("DELETE FROM mentions WHERE entity_id = ?", [source])
        run("UPDATE relations SET from_id = ? WHERE from_id = ?", [target, source])
        run("UPDATE relations SET to_id = ? WHERE to_id = ?", [target, source])
        run("DELETE FROM relations WHERE from_id = to_id")
        run("DELETE FROM relations WHERE rowid NOT IN (SELECT MIN(rowid) FROM relations GROUP BY from_id, to_id, label, document_id)")
        run("UPDATE entity_aliases SET entity_id = ? WHERE entity_id = ?", [target, source])
        run("INSERT OR REPLACE INTO entity_aliases(normalized, name, entity_id) VALUES(?,?,?)", [from.key, from.name, target])
        if into.type == "topic", from.type != "topic" { run("UPDATE entities SET type = ? WHERE id = ?", [from.type, target]) }
        run("DELETE FROM entities WHERE id = ?", [source])
        run("COMMIT")
        return true
    }

    /// Other names this entity has gone by (renamed or merged away).
    func aliases(of entityID: Int64) -> [String] {
        var names: [String] = []
        select("SELECT name FROM entity_aliases WHERE entity_id = ? ORDER BY name COLLATE NOCASE", [entityID]) { row in
            if let name = Self.text(row, 0) { names.append(name) }
        }
        return names
    }

    private func entityRecord(_ entityID: Int64) -> (name: String, key: String, type: String)? {
        var record: (String, String, String)?
        select("SELECT name, normalized, type FROM entities WHERE id = ?", [entityID]) { row in
            record = (Self.text(row, 0) ?? "", Self.text(row, 1) ?? "", Self.text(row, 2) ?? "")
        }
        return record
    }

    private func entityExists(_ entityID: Int64) -> Bool {
        var found = false
        select("SELECT 1 FROM entities WHERE id = ?", [entityID]) { _ in found = true }
        return found
    }

    private func aliasMap() -> [String: Int64] {
        var map: [String: Int64] = [:]
        select("SELECT normalized, entity_id FROM entity_aliases") { row in
            if let key = Self.text(row, 0) { map[key] = sqlite3_column_int64(row, 1) }
        }
        return map
    }

    private func ignoredKeys() -> Set<String> {
        var keys = Set<String>()
        select("SELECT normalized FROM ignored_entities") { row in
            if let key = Self.text(row, 0) { keys.insert(key) }
        }
        return keys
    }

    private func upsertEntity(name: String, key: String, type: String) -> Int64 {
        run("""
            INSERT INTO entities(name, normalized, type) VALUES(?,?,?)
            ON CONFLICT(normalized) DO UPDATE SET type = CASE WHEN entities.type = 'topic' THEN excluded.type ELSE entities.type END
            """, [name, key, type])
        var id: Int64 = 0
        select("SELECT id FROM entities WHERE normalized = ?", [key]) { id = sqlite3_column_int64($0, 0) }
        return id
    }

    // MARK: SQLite helpers

    private func select(_ sql: String, _ bindings: [Any?] = [], row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Log.app.error("Knowledge query failed: \(String(cString: sqlite3_errmsg(self.db)))")
            return
        }
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, bindings)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    @discardableResult
    private func run(_ sql: String, _ bindings: [Any?] = []) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Log.app.error("Knowledge statement failed: \(String(cString: sqlite3_errmsg(self.db)))")
            return false
        }
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, bindings)
        let result = sqlite3_step(statement)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }

    private static func bind(_ statement: OpaquePointer, _ bindings: [Any?]) {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            guard let value else {
                sqlite3_bind_null(statement, index)
                continue
            }
            switch value {
            case let string as String: sqlite3_bind_text(statement, index, string, -1, transientDestructor)
            case let number as Int64: sqlite3_bind_int64(statement, index, number)
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, index, number)
            case let data as Data:
                data.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transientDestructor)
                }
            default: sqlite3_bind_null(statement, index)
            }
        }
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    private static func optionalDouble(_ row: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : sqlite3_column_double(row, column)
    }

    private static func hit(_ row: OpaquePointer, snippetColumn: Int32?, authorColumn: Int32, binderColumn: Int32) -> KnowledgeHit? {
        guard let kind = text(row, 2).flatMap(KnowledgeKind.init(rawValue:)) else { return nil }
        return KnowledgeHit(chunkID: sqlite3_column_int64(row, 0), documentID: text(row, 1) ?? "", kind: kind, sourceID: text(row, 3) ?? "",
                            title: text(row, 4) ?? "", createdAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 5)),
                            text: text(row, 6) ?? "", snippet: snippetColumn.flatMap { text(row, $0) } ?? "",
                            startTime: optionalDouble(row, 7), speaker: text(row, 8), author: text(row, authorColumn),
                            binderID: text(row, binderColumn), score: 0)
    }

    private static func entity(_ row: OpaquePointer) -> KnowledgeEntity {
        KnowledgeEntity(id: sqlite3_column_int64(row, 0), name: text(row, 1) ?? "", type: text(row, 2) ?? "topic",
                        mentions: Int(sqlite3_column_int64(row, 3)), documents: Int(sqlite3_column_int64(row, 4)))
    }
}
