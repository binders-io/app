import Foundation
import Automerge

// Binders' shared notes as Automerge documents (lane DB3), in a framework of its own: Automerge's Rust core can't be
// linked into the app beside FluidAudio's (both carry Rust's standard library). Only Foundation types cross into the app,
// which works out what to splice (BindersKit's TextEdits) and what the props mean (TeamNoteProps).
//
// A note's document holds `text`, its Markdown, and `props`, what travels with it. Text is counted in Unicode scalars, as
// a document loaded from bytes always is. Its first change, the skeleton that makes `text` and `props`, is made the same
// way on every Mac (the note's id as its actor, at time 0), so it's the same change everywhere; every change after it is
// made under an actor of the Mac's own.

/// A value in a note's props.
public enum NoteDocumentValue: Equatable, Sendable {
    case null
    case string(String)
    case bool(Bool)
    case number(Double)
}

/// A splice of a note's text: at `start` in the text as it is when this splice comes, take out `delete` scalars and put
/// `insert` in.
public struct NoteDocumentSplice: Equatable, Sendable {
    public var start: Int
    public var delete: Int
    public var insert: String

    public init(start: Int, delete: Int, insert: String) {
        self.start = start
        self.delete = delete
        self.insert = insert
    }
}

/// A change as the database keeps it: its hash (hex), the hashes it depends on, its bytes.
public struct NoteDocumentChange: Equatable, Sendable {
    public var hash: String
    public var deps: [String]
    public var bytes: Data
}

/// One shared note's Automerge document.
public final class NoteDocument {
    public enum Problem: LocalizedError {
        case notANote
        case unknownHash(String)

        public var errorDescription: String? {
            switch self {
            case .notANote: "That isn't a Binders note's document."
            case .unknownHash(let hash): "This Mac's copy of the note has no change \(hash.prefix(12))."
            }
        }
    }

    public let note: UUID
    /// The actor this copy's changes are made under.
    public let actorID: UUID
    private let document: Document
    private let textObject: ObjId
    private let propsObject: ObjId

    private init(note: UUID, actor: UUID, document: Document) throws {
        self.note = note
        actorID = actor
        self.document = document
        guard case .Object(let text, .Text)? = try document.get(obj: .ROOT, key: "text"),
              case .Object(let props, .Map)? = try document.get(obj: .ROOT, key: "props") else { throw Problem.notANote }
        textObject = text
        propsObject = props
    }

    /// A new note's document: the skeleton, then `actor`, ready for its first words.
    public convenience init(new note: UUID, actor: UUID) throws {
        let document = try Self.skeleton(note)
        document.actor = ActorId(uuid: actor)
        try self.init(note: note, actor: actor, document: document)
    }

    /// A note's document from its saved copy (if any) and changes (each kept once; one whose dependencies haven't come
    /// waits for them), started from the skeleton, so its objects are where every Mac has them.
    public convenience init(note: UUID, saved: Data?, changes: [Data], actor: UUID) throws {
        let document = try Self.skeleton(note)
        if let saved, !saved.isEmpty { try document.applyEncodedChanges(encoded: saved) }
        for change in changes { try document.applyEncodedChanges(encoded: change) }
        document.actor = ActorId(uuid: actor)
        try self.init(note: note, actor: actor, document: document)
    }

    /// A note's document as a hub (the Binders server) saved it, whole: its skeleton is the hub's, made under the note's
    /// own id, which for a note the web app made isn't a UUID, so it isn't started from this Mac's.
    public convenience init(note: UUID, loading saved: Data, actor: UUID) throws {
        let document = try Document(saved)
        document.actor = ActorId(uuid: actor)
        try self.init(note: note, actor: actor, document: document)
    }

    private static func skeleton(_ note: UUID) throws -> Document {
        let document = Document()
        document.actor = ActorId(uuid: note)
        _ = try document.putObject(obj: .ROOT, key: "text", ty: .Text)
        _ = try document.putObject(obj: .ROOT, key: "props", ty: .Map)
        document.commitWith(message: nil, timestamp: Date(timeIntervalSince1970: 0))
        return document
    }

    /// The skeleton's hash: the same for the note on every Mac.
    public static func skeletonHash(_ note: UUID) -> String? {
        (try? skeleton(note))?.heads().first.map(hex)
    }

    // MARK: Reading

    public var text: String { (try? document.text(obj: textObject)) ?? "" }

    public var props: [String: NoteDocumentValue] {
        var values: [String: NoteDocumentValue] = [:]
        for key in document.keys(obj: propsObject) {
            if case .Scalar(let scalar)? = try? document.get(obj: propsObject, key: key) { values[key] = Self.value(scalar) }
        }
        return values
    }

    /// Its heads, as hex, sorted.
    public var heads: [String] { document.heads().map(Self.hex).sorted() }

    /// How many changes it holds.
    public var changeCount: Int { document.getHistory().count }

    public func has(_ hash: String) -> Bool {
        Self.changeHash(hash).map { document.change(hash: $0) != nil } ?? false
    }

    /// The text as it was at these heads (none: before anything was written).
    public func text(at heads: [String]) throws -> String {
        let hashes = try known(heads)
        guard !hashes.isEmpty else { return "" }
        return try document.textAt(obj: textObject, heads: hashes)
    }

    /// The props as they were at these heads.
    public func props(at heads: [String]) throws -> [String: NoteDocumentValue] {
        let hashes = try known(heads)
        guard !hashes.isEmpty else { return [:] }
        var values: [String: NoteDocumentValue] = [:]
        for key in document.keysAt(obj: propsObject, heads: hashes) {
            if case .Scalar(let scalar)? = try? document.getAt(obj: propsObject, key: key, heads: hashes) { values[key] = Self.value(scalar) }
        }
        return values
    }

    private func known(_ heads: [String]) throws -> Set<ChangeHash> {
        try Set(heads.map { hex -> ChangeHash in
            guard let hash = Self.changeHash(hex), document.change(hash: hash) != nil else { throw Problem.unknownHash(hex) }
            return hash
        })
    }

    /// What a change depends on, as hex; nil for one this copy doesn't have.
    public func deps(of hash: String) -> [String]? {
        Self.changeHash(hash).flatMap { document.change(hash: $0) }?.deps.map(Self.hex).sorted()
    }

    /// A change's bytes; nil for one this copy doesn't have.
    public func changeBytes(_ hash: String) -> Data? {
        Self.changeHash(hash).flatMap { document.change(hash: $0) }?.bytes
    }

    /// The document whole, as Automerge saves it.
    public func save() -> Data { document.save() }

    // MARK: Changing

    /// One change under this copy's actor: the splices, in order, and these props, at `date`. Nil when nothing changed.
    public func change(splices: [NoteDocumentSplice], props: [String: NoteDocumentValue], at date: Date = Date()) throws -> NoteDocumentChange? {
        guard !splices.isEmpty || !props.isEmpty else { return nil }
        let before = Set(document.heads())
        for splice in splices {
            try document.spliceText(obj: textObject, start: UInt64(max(0, splice.start)), delete: Int64(max(0, splice.delete)), value: splice.insert)
        }
        for (key, value) in props.sorted(by: { $0.key < $1.key }) {
            try document.put(obj: propsObject, key: key, value: Self.scalar(value))
        }
        document.commitWith(message: nil, timestamp: date)
        // After a change of its own, a document's only head is that change.
        let heads = document.heads()
        guard heads.count == 1, let head = heads.first, !before.contains(head), let change = document.change(hash: head) else { return nil }
        return NoteDocumentChange(hash: Self.hex(head), deps: change.deps.map(Self.hex).sorted(), bytes: change.bytes)
    }

    /// Changes from elsewhere, in order. Ones it has change nothing.
    public func apply(_ changes: [Data]) throws {
        for change in changes { try document.applyEncodedChanges(encoded: change) }
    }

    /// A copy as it was at these heads (none: just the skeleton), whose changes are made under `actor`: to change an older
    /// version and merge it back, a three-way merge.
    public func fork(at heads: [String], actor: UUID) throws -> NoteDocument {
        let hashes = try known(heads)
        let copy = hashes.isEmpty ? try Self.skeleton(note) : try document.forkAt(heads: hashes)
        copy.actor = ActorId(uuid: actor)
        return try NoteDocument(note: note, actor: actor, document: copy)
    }

    // MARK: Values and hashes

    static func hex(_ hash: ChangeHash) -> String { hash.debugDescription }

    static func changeHash(_ hex: String) -> ChangeHash? {
        guard hex.count == 64 else { return nil }
        var bytes = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes.heads()?.first
    }

    private static func value(_ scalar: ScalarValue) -> NoteDocumentValue {
        switch scalar {
        case .String(let text): .string(text)
        case .Boolean(let value): .bool(value)
        case .Int(let value): .number(Double(value))
        case .Uint(let value): .number(Double(value))
        case .F64(let value): .number(value)
        case .Timestamp(let date): .number(date.timeIntervalSince1970)
        default: .null
        }
    }

    private static func scalar(_ value: NoteDocumentValue) -> ScalarValue {
        switch value {
        case .string(let text): .String(text)
        case .bool(let flag): .Boolean(flag)
        case .number(let number): .F64(number)
        case .null: .Null
        }
    }
}
