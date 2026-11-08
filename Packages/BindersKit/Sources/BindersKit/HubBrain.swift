import Foundation

// The hub's brain, as the Mac and the iPhone read it: a question's answer from a binder's notes and cards on the hub
// (POST /api/brain/ask), with the ones it rests on numbered, and what's captured sent there to become a note
// (POST /api/captures), which the hub sums up when it has a model. Words only: never the sound.

/// A question's answer from the hub's brain, and the notes and cards it rests on.
public struct HubBrainAnswer: Decodable, Equatable, Sendable {
    public struct Part: Decodable, Equatable, Hashable, Sendable {
        public let text: String
        /// The numbers of the sources this stretch rests on, from 1.
        public let sources: [Int]

        public init(text: String, sources: [Int]) {
            self.text = text
            self.sources = sources
        }
    }

    public struct Body: Decodable, Equatable, Sendable {
        public let text: String
        public let parts: [Part]

        public init(text: String, parts: [Part]) {
            self.text = text
            self.parts = parts
        }
    }

    /// A note or card an answer rests on, as numbered in it.
    public struct Source: Decodable, Equatable, Hashable, Identifiable, Sendable {
        public let n: Int
        /// The Binder on the hub it's in, and its name.
        public let binder: String
        public let binderName: String
        /// "note" or "card".
        public let kind: String
        /// Its id on the hub.
        public let item: String
        public let title: String
        public let context: String?
        /// The passage the answer rests on.
        public let text: String
        /// Its address on the hub's web app.
        public let url: String
        public var id: Int { n }

        enum CodingKeys: String, CodingKey { case n, binder, binderName, kind, item = "id", title, context, text, url }
    }

    /// The model's answer; nil when the hub has no model, or it couldn't answer (`problem` says why).
    public let answer: Body?
    public let sources: [Source]
    public let model: String?
    /// "words", or "words and meaning" when the hub has an embeddings model.
    public let searchedBy: String
    public let problem: String?

    /// What to say when there's no answer to show.
    public var noAnswerLine: String {
        if sources.isEmpty { return "Nothing in your binders matches that." }
        if let problem { return "No answer: \(problem) The passages that match best:" }
        return "The hub has no model to answer with yet, so here are the passages that match best."
    }
}

public enum HubBrain {
    /// An answer as words, each stretch followed by the numbers of its sources in brackets: "It ships Friday [2]."
    public static func citedText(_ body: HubBrainAnswer.Body) -> String {
        body.parts.map { part in
            guard !part.sources.isEmpty else { return part.text }
            let core = part.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let tail = String(part.text.dropFirst(core.count))
            return "\(core) [\(part.sources.map(String.init).joined(separator: ", "))]\(tail)"
        }.joined()
    }

    public static func answer(from data: Data) -> HubBrainAnswer? {
        try? JSONDecoder().decode(HubBrainAnswer.self, from: data)
    }
}

/// Something captured, as the hub takes it: one note in a binder, in the folder for its kind unless one is named. Sent
/// again with the same `sourceId`, the hub gives back the note it made the first time.
public struct HubCaptureRequest: Codable, Equatable, Sendable {
    /// "dictation", "conversation" or "meeting".
    public var kind: String
    public var text: String
    public var title: String?
    public var recordedAt: String?
    public var durationSeconds: Double?
    public var device: String?
    public var speakers: [String]?
    public var sourceId: String
    /// The project's id in the hub's state, when not the Binder's first.
    public var binder: String?
    public var folder: String?

    public init(kind: String, text: String, title: String? = nil, recordedAt: Date? = nil, durationSeconds: Double? = nil, device: String? = nil,
                speakers: [String]? = nil, sourceId: String, binder: String? = nil, folder: String? = nil) {
        self.kind = kind
        self.text = text
        self.title = title.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        self.recordedAt = recordedAt.map(HubLink.iso)
        self.durationSeconds = durationSeconds.map { max(0, $0) }
        self.device = device.map { String($0.prefix(120)) }
        self.speakers = speakers.map { Array($0.prefix(20)).map { String($0.prefix(80)) } }
        self.sourceId = String(sourceId.prefix(200))
        self.binder = binder
        self.folder = folder
    }

    /// A transcript as the hub keeps it: who said what, when, a paragraph each.
    public static func transcript(_ segments: [TranscriptSegment], names: [String: String] = [:]) -> String {
        TranscriptFormatter.blocks(segments, names: names)
            .map { "**[\(TranscriptFormatter.timestamp($0.start))] \($0.speaker):** \($0.text)" }
            .joined(separator: "\n\n")
    }
}
