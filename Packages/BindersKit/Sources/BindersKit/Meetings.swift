import Foundation

// MARK: - Transcript model

public enum AudioChannel: String, Codable, Sendable {
    /// The user's microphone.
    case microphone
    /// Everything other apps play: remote meeting participants.
    case system
}

public struct TranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var channel: AudioChannel
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var speaker: String

    public init(id: UUID = UUID(), channel: AudioChannel, start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
        self.id = id
        self.channel = channel
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker ?? (channel == .microphone ? TranscriptSegment.you : TranscriptSegment.others)
    }

    public static let you = "You"
    public static let others = "Others"
}

// MARK: - Live chunking

/// Splits continuous audio into transcription chunks at natural pauses.
public enum SpeechChunker {
    /// Returns how many samples from the start of `samples` form the next chunk, or nil to wait for more audio.
    public static func nextBoundary(_ samples: ArraySlice<Float>, sampleRate: Int = 16_000, minSeconds: Double = 3,
                                    maxSeconds: Double = 25, silenceSeconds: Double = 0.7, silenceDB: Float = -42,
                                    isFinal: Bool = false) -> Int? {
        let count = samples.count
        guard count > 0 else { return nil }
        let frame = sampleRate * 30 / 1000
        let minSamples = Int(minSeconds * Double(sampleRate))
        let maxSamples = Int(maxSeconds * Double(sampleRate))
        let neededFrames = max(1, Int(silenceSeconds * 1000 / 30))
        if count < minSamples { return isFinal ? count : nil }

        let base = samples.startIndex
        let scanEnd = min(count, maxSamples)
        let quietWindowStart = max(0, maxSamples - 5 * sampleRate)
        var runStart: Int?
        var runFrames = 0
        var quietest = (offset: scanEnd, level: Float.greatestFiniteMagnitude)
        var offset = 0
        while offset + frame <= scanEnd {
            let level = AudioMath.decibels(AudioMath.rms(samples[(base + offset)..<(base + offset + frame)]))
            if offset >= quietWindowStart, level < quietest.level {
                quietest = (offset + frame / 2, level)
            }
            if level < silenceDB {
                if runStart == nil { runStart = offset }
                runFrames += 1
                if runFrames >= neededFrames, let runStart {
                    let middle = runStart + (offset + frame - runStart) / 2
                    if middle >= minSamples { return middle }
                }
            } else {
                runStart = nil
                runFrames = 0
            }
            offset += frame
        }
        if count >= maxSamples { return quietest.offset }
        return isFinal ? count : nil
    }
}

// MARK: - Post-processing

/// Drops microphone segments that are just the remote participants leaking from the speakers into the mic.
public enum EchoFilter {
    public static func removeEcho(from segments: [TranscriptSegment], tolerance: TimeInterval = 2) -> [TranscriptSegment] {
        let system = segments.filter { $0.channel == .system }
        guard !system.isEmpty else { return segments }
        return segments.filter { segment in
            guard segment.channel == .microphone else { return true }
            let micWords = TextNorm.normalizedWords(segment.text)
            guard !micWords.isEmpty else { return false }
            let overlapping = system.filter { $0.start - tolerance < segment.end && $0.end + tolerance > segment.start }
            guard !overlapping.isEmpty else { return true }
            let systemWords = Set(overlapping.flatMap { TextNorm.normalizedWords($0.text) })
            let shared = micWords.filter { systemWords.contains($0) }.count
            if micWords.count < 3 {
                // "Yeah" said over someone else isn't necessarily echo; only drop exact short repeats.
                return shared < micWords.count || overlapping.allSatisfy { TextNorm.normalizedWords($0.text).count > micWords.count + 4 }
            }
            return Double(shared) / Double(micWords.count) < 0.6
        }
    }
}

public struct SpeakerTurn: Equatable, Sendable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

public enum SpeakerTurns {
    /// Cleans raw diarization output into readable turns: drops blips, merges consecutive turns by the same
    /// speaker and removes overlaps so no audio is transcribed twice.
    public static func merge(_ turns: [SpeakerTurn], maxGap: TimeInterval = 1.0, minDuration: TimeInterval = 0.6) -> [SpeakerTurn] {
        let sorted = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var kept = sorted.filter { $0.end - $0.start >= minDuration }
        if kept.isEmpty { kept = sorted }
        var merged: [SpeakerTurn] = []
        for var turn in kept {
            if var last = merged.last {
                if last.speakerID == turn.speakerID, turn.start - last.end <= maxGap {
                    last.end = max(last.end, turn.end)
                    merged[merged.count - 1] = last
                    continue
                }
                if turn.start < last.end {
                    turn.start = last.end
                    if turn.end - turn.start < minDuration { continue }
                }
            }
            merged.append(turn)
        }
        return merged
    }

    /// Stable "Speaker N" labels in order of first appearance.
    public static func labels(for turns: [SpeakerTurn]) -> [String: String] {
        var labels: [String: String] = [:]
        for turn in turns.sorted(by: { $0.start < $1.start }) where labels[turn.speakerID] == nil {
            labels[turn.speakerID] = "Speaker \(labels.count + 1)"
        }
        return labels
    }
}

/// Labels transcript segments with diarized speakers ("Speaker 1", "Speaker 2"…) by time overlap.
public enum SpeakerAssigner {
    public static func assign(_ segments: [TranscriptSegment], turns: [SpeakerTurn], channel: AudioChannel) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        var labels: [String: String] = [:]
        return segments.sorted { $0.start < $1.start }.map { segment in
            guard segment.channel == channel else { return segment }
            var overlap: [String: Double] = [:]
            for turn in turns where turn.start < segment.end && turn.end > segment.start {
                overlap[turn.speakerID, default: 0] += min(turn.end, segment.end) - max(turn.start, segment.start)
            }
            guard let best = overlap.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key else {
                return segment
            }
            if labels[best] == nil { labels[best] = "Speaker \(labels.count + 1)" }
            var labeled = segment
            labeled.speaker = labels[best]!
            return labeled
        }
    }
}

/// Labels a rescued mic track (an outside recording that may also have picked up the other participants).
public enum RescuedTrack {
    /// Diarized segments of the outside recording arrive labeled "Speaker 1…" on their own; the voice that overlaps the
    /// other side's speech the least is the user and becomes "You". The rest get fresh labels numbered after the ones in
    /// `others`, so they never collide with speakers labeled from the meeting's own audio.
    public static func label(_ mine: [TranscriptSegment], others: [TranscriptSegment]) -> [TranscriptSegment] {
        var total: [String: TimeInterval] = [:]
        var overlap: [String: TimeInterval] = [:]
        for segment in mine {
            total[segment.speaker, default: 0] += segment.end - segment.start
            for other in others where other.start < segment.end && other.end > segment.start {
                overlap[segment.speaker, default: 0] += min(other.end, segment.end) - max(other.start, segment.start)
            }
        }
        guard !total.isEmpty else { return mine }
        let substantial = total.filter { $0.value >= 10 }
        let candidates = substantial.isEmpty ? total : substantial
        let user = candidates.min { a, b in
            let ratioA = overlap[a.key, default: 0] / a.value, ratioB = overlap[b.key, default: 0] / b.value
            return ratioA == ratioB ? a.value > b.value : ratioA < ratioB
        }!.key
        var next = others.map(\.speaker).compactMap { label -> Int? in
            guard label.lowercased().hasPrefix("speaker ") else { return nil }
            return Int(label.dropFirst("speaker ".count).trimmingCharacters(in: .whitespaces))
        }.max() ?? 0
        var mapping: [String: String] = [user: TranscriptSegment.you]
        for label in total.keys.sorted() where mapping[label] == nil {
            next += 1
            mapping[label] = "Speaker \(next)"
        }
        return mine.map { segment in
            var labeled = segment
            labeled.speaker = mapping[segment.speaker] ?? segment.speaker
            return labeled
        }
    }
}

public struct TranscriptBlock: Equatable, Sendable {
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
}

public enum TranscriptFormatter {
    /// Merges consecutive segments from the same speaker for reading.
    public static func blocks(_ segments: [TranscriptSegment], names: [String: String] = [:], maxGap: TimeInterval = 4) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = displayName(segment.speaker, names: names)
            if var last = blocks.last, last.speaker == speaker, segment.start - last.end <= maxGap {
                last.text += " " + text
                last.end = max(last.end, segment.end)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(TranscriptBlock(speaker: speaker, start: segment.start, end: segment.end, text: text))
            }
        }
        return blocks
    }

    public static func displayName(_ speaker: String, names: [String: String]) -> String {
        let name = names[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? speaker : name
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%02d:%02d", minutes, secs)
    }

    /// Compact transcript for prompts and exports: "[02:03] Alice: text".
    public static func plainText(_ segments: [TranscriptSegment], names: [String: String] = [:]) -> String {
        blocks(segments, names: names).map { "[\(timestamp($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// Splits a long transcript into parts no longer than `maxSeconds` or `maxWords`, so each can be summarized on its own.
    public static func parts(_ segments: [TranscriptSegment], maxSeconds: TimeInterval = 20 * 60, maxWords: Int = 2_500) -> [[TranscriptSegment]] {
        let sorted = segments.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return [] }
        var parts: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var partStart = first.start
        var words = 0
        for segment in sorted {
            let segmentWords = TextNorm.words(segment.text).count
            if !current.isEmpty, segment.end - partStart > maxSeconds || words + segmentWords > maxWords {
                parts.append(current)
                current = []
                partStart = segment.start
                words = 0
            }
            current.append(segment)
            words += segmentWords
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

// MARK: - Summaries

public struct MeetingTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let sections: String

    public static let general = MeetingTemplate(id: "general", name: "General", sections: """
        ## Summary
        Two to four sentences on what the meeting was about and where it landed.
        ## Key points
        ## Decisions
        ## Action items
        - [ ] Owner — task (due date if mentioned)
        ## Open questions
        """)
    public static let oneOnOne = MeetingTemplate(id: "one-on-one", name: "1:1", sections: """
        ## Summary
        ## Updates and wins
        ## Challenges and blockers
        ## Feedback
        ## Action items
        - [ ] Owner — task
        ## For next time
        """)
    public static let standup = MeetingTemplate(id: "standup", name: "Standup", sections: """
        ## Updates by person
        For each person: done, doing next, blockers.
        ## Blockers that need help
        ## Action items
        - [ ] Owner — task
        """)
    public static let sales = MeetingTemplate(id: "sales", name: "Sales call", sections: """
        ## Summary
        ## Customer and context
        ## Pain points
        ## Requirements
        ## Objections and concerns
        ## Budget, timeline and decision process
        ## Next steps
        - [ ] Owner — task
        """)
    public static let interview = MeetingTemplate(id: "interview", name: "Interview", sections: """
        ## Candidate summary
        ## Experience highlights
        ## Strengths
        ## Concerns
        ## Notable answers
        ## Recommendation and next steps
        """)
    public static let lecture = MeetingTemplate(id: "lecture", name: "Lecture or talk", sections: """
        ## Overview
        ## Key concepts
        ## Details and examples
        ## Questions raised
        ## Follow-ups
        """)

    public static let all: [MeetingTemplate] = [.general, .oneOnOne, .standup, .sales, .interview, .lecture]

    public static func template(id: String) -> MeetingTemplate {
        all.first { $0.id == id } ?? .general
    }
}

public enum MeetingPrompts {
    public static func summarySystemPrompt(template: MeetingTemplate) -> String {
        """
        You write meeting notes from a transcript recorded on the user's computer. "You" is the user.

        Output Markdown in exactly this shape:
        - First line: "# " and a short, specific title for the meeting (at most 8 words).
        - Then these sections, leaving out any section that would be empty:
        \(template.sections)

        Rules:
        - Use only what is in the transcript and the user's notes. Never invent facts, names, numbers, dates or commitments.
        - The user's notes show what they cared about: cover those topics first and in more depth.
        - Refer to people by name when known, otherwise by their speaker label.
        - Be concise: short bullets, no filler, no preamble.
        - Every action item once, owned by the person who said they would do it. Only tasks someone actually agreed to; merge duplicates.
        - Write in the language the meeting was held in.
        - Speech recognition can mishear words; correct obvious errors from context.

        After the notes, if the conversation or the attendee list makes clear who a generic label such as "Speaker 1" is, add one final line:
        SPEAKERS: Speaker 1=Name; Speaker 2=Name
        Leave that line out when you are not sure.
        """
    }

    public static func summaryUserPrompt(title: String?, date: String?, appName: String?, attendees: [String], userNotes: String,
                                         transcript: String, partNotes: [String] = []) -> String {
        var parts: [String] = []
        var details: [String] = []
        if let title, !title.isEmpty { details.append("Calendar title: \(title)") }
        if let date { details.append("Date: \(date)") }
        if let appName { details.append("App: \(appName)") }
        if !attendees.isEmpty { details.append("Attendees: \(attendees.joined(separator: ", "))") }
        if !details.isEmpty { parts.append(details.joined(separator: "\n")) }
        let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("The user's notes:\n<notes>\n\(notes.isEmpty ? "(none)" : notes)\n</notes>")
        if !partNotes.isEmpty {
            let notes = partNotes.enumerated().map { "### Part \($0.offset + 1)\n\($0.element)" }.joined(separator: "\n\n")
            parts.append("Raw notes taken on each part of the call, a checklist so nothing is missed (the transcript is the source of truth):\n<part_notes>\n\(notes)\n</part_notes>")
        }
        parts.append("Transcript:\n<transcript>\n\(transcript)\n</transcript>")
        return parts.joined(separator: "\n\n")
    }

    /// Works out who "Speaker 1", "Speaker 2"… are before the notes are written, so action items get real owners.
    public static func speakerSystemPrompt() -> String {
        """
        You identify who the generic speaker labels in a meeting transcript are. "You" is the user, who recorded the meeting.
        Use the attendee list, the user's notes and clues in the transcript: people addressing each other by name, introductions, who is asked to do what.
        Reply with exactly one line and nothing else:
        SPEAKERS: Speaker 1=Name; Speaker 2=Name
        Write unknown as the name when you are not confident. Never guess from the order of the attendee list alone.
        """
    }

    public static func speakerUserPrompt(attendees: [String], userNotes: String, transcript: String) -> String {
        var parts: [String] = []
        if !attendees.isEmpty { parts.append("Attendees: \(attendees.joined(separator: ", "))") }
        let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("The user's notes:\n<notes>\n\(notes)\n</notes>") }
        parts.append("Transcript:\n<transcript>\n\(transcript)\n</transcript>")
        return parts.joined(separator: "\n\n")
    }

    /// Raw notes on one part of a long meeting; the final notes are written from these plus the transcript.
    public static func partNotesSystemPrompt() -> String {
        """
        You take raw notes on one part of a longer meeting transcript recorded on the user's computer. "You" is the user.
        Output Markdown with these sections, leaving out any that would be empty:
        ## Key points
        ## Decisions
        ## Commitments
        - Name — what they said they would do [mm:ss]

        Rules: only what is said in this part, short bullets, each point once, no preamble, keep the speakers' names as given.
        """
    }

    public static func partNotesUserPrompt(index: Int, count: Int, transcript: String) -> String {
        "Part \(index) of \(count) of the transcript:\n<transcript>\n\(transcript)\n</transcript>"
    }

    /// Fallback when a summary came back without its title line.
    public static func titleSystemPrompt() -> String {
        "Write a short, specific title (3 to 8 words) for the meeting described by these notes. Reply with the title only: no quotes, labels or final punctuation."
    }

    public static func cleanTitle(_ output: String) -> String? {
        var line = OutputGuard.sanitize(output).components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.lowercased().hasPrefix("title:") { line = String(line.dropFirst(6)) }
        let title = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*\"“”'. ").union(.whitespaces))
        return title.isEmpty || title.count > 80 ? nil : title
    }

    public static func chatSystemPrompt() -> String {
        """
        You answer questions about one meeting, using its transcript, the user's notes and the summary. "You" in the transcript is the user.
        Be direct and concise. Quote or cite timestamps like [12:34] when helpful. If the meeting doesn't contain the answer, say so plainly.
        When asked to draft something (a follow-up email, a message, a task list), write it ready to paste.
        """
    }

    public static func chatUserPrompt(question: String, transcript: String, notes: String, summary: String,
                                      history: [(role: String, text: String)]) -> String {
        var parts = ["Summary:\n\(summary.isEmpty ? "(not generated yet)" : summary)",
                     "The user's notes:\n\(notes.isEmpty ? "(none)" : notes)",
                     "Transcript:\n<transcript>\n\(transcript)\n</transcript>"]
        if !history.isEmpty {
            parts.append("Conversation so far:\n" + history.suffix(12).map { "\($0.role): \($0.text)" }.joined(separator: "\n"))
        }
        parts.append("Question: \(question)")
        return parts.joined(separator: "\n\n")
    }
}

public struct ParsedSummary: Equatable, Sendable {
    public var title: String?
    public var body: String
    public var speakerNames: [String: String]
    /// Lines dropped because the model got stuck repeating itself.
    public var droppedRepeats: Int

    public init(title: String?, body: String, speakerNames: [String: String], droppedRepeats: Int = 0) {
        self.title = title
        self.body = body
        self.speakerNames = speakerNames
        self.droppedRepeats = droppedRepeats
    }
}

public enum SummaryParser {
    public static func parse(_ output: String) -> ParsedSummary {
        var lines = OutputGuard.sanitize(output).components(separatedBy: "\n")
        var title: String?
        if let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("# ") {
            title = String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.remove(at: index)
        }
        var names: [String: String] = [:]
        lines.removeAll { line in
            guard let parsed = speakerNames(inLine: line) else { return false }
            names.merge(parsed) { current, _ in current }
            return true
        }
        let cleaned = removeRepeats(lines)
        let body = cleaned.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedSummary(title: title?.isEmpty == true ? nil : title, body: body, speakerNames: names,
                             droppedRepeats: cleaned.dropped)
    }

    /// Names from every "SPEAKERS: Speaker 1=Dana; Speaker 2=Lee" line in `output`.
    public static func speakerNames(in output: String) -> [String: String] {
        var names: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            if let parsed = speakerNames(inLine: line) { names.merge(parsed) { current, _ in current } }
        }
        return names
    }

    private static func speakerNames(inLine line: String) -> [String: String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.range(of: "SPEAKERS:", options: .caseInsensitive),
              trimmed[..<marker.lowerBound].allSatisfy({ "*_#> ".contains($0) }) else { return nil }
        var names: [String: String] = [:]
        for pair in trimmed[marker.upperBound...].split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*_ ")) }
            guard parts.count == 2, parts[0].lowercased().hasPrefix("speaker"), !parts[1].isEmpty else { continue }
            let name = parts[1]
            let lowered = name.lowercased()
            guard lowered != "unknown", lowered != "unsure", !lowered.hasPrefix("speaker"), !name.contains("?") else { continue }
            names[parts[0].capitalized] = name
        }
        return names
    }

    /// Drops what a model stuck in a loop produces: repeated lines, near-identical bullets and a bullet cut off mid-way.
    public static func removeRepeats(_ lines: [String]) -> (lines: [String], dropped: Int) {
        var kept: [String] = []
        var seen = Set<String>()
        var sectionKeys = Set<String>()
        var sectionBullets: [String] = []
        var dropped = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                kept.append(line)
                continue
            }
            if trimmed.hasPrefix("#") {
                sectionKeys.removeAll()
                sectionBullets.removeAll()
                kept.append(line)
                continue
            }
            let key = LoopGuard.normalize(trimmed)
            let bullet = LoopGuard.isBullet(trimmed)
            let repeated = sectionKeys.contains(key) || (key.count >= 12 && seen.contains(key))
                || (bullet && key.count >= 20 && sectionBullets.contains { TextNorm.similarity($0, key) >= 0.94 })
            if key.isEmpty || (bullet && LoopGuard.isCutOff(key)) || repeated {
                dropped += 1
                continue
            }
            seen.insert(key)
            sectionKeys.insert(key)
            if bullet { sectionBullets.append(key) }
            kept.append(line)
        }
        return (kept, dropped)
    }
}

public enum MeetingMarkdown {
    public static func document(title: String, dateText: String, duration: TimeInterval, appName: String?, attendees: [String],
                                summary: String, notes: String, segments: [TranscriptSegment], names: [String: String]) -> String {
        var output = "# \(title)\n\n"
        var meta = [dateText, "\(max(1, Int((duration / 60).rounded()))) min"]
        if let appName { meta.append(appName) }
        output += "*\(meta.joined(separator: " · "))*\n\n"
        if !attendees.isEmpty { output += "**Attendees:** \(attendees.joined(separator: ", "))\n\n" }
        let summaryBody = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryBody.isEmpty { output += summaryBody + "\n\n" }
        let noteBody = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !noteBody.isEmpty { output += "## My notes\n\n\(noteBody)\n\n" }
        let blocks = TranscriptFormatter.blocks(segments, names: names)
        if !blocks.isEmpty {
            output += "## Transcript\n\n"
            output += blocks.map { "**[\(TranscriptFormatter.timestamp($0.start))] \($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
            output += "\n"
        }
        return output
    }
}

// MARK: - Meeting detection

public enum MeetingDetector {
    public static let apps: [String: String] = [
        "us.zoom.xos": "Zoom", "us.zoom.CptHost": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams",
        "com.cisco.webexmeetingsapp": "Webex", "com.webex.meetingmanager": "Webex",
        "com.apple.FaceTime": "FaceTime", "com.apple.avconferenced": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack huddle", "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp call", "desktop.WhatsApp": "WhatsApp call",
        "com.skype.skype": "Skype", "com.logmein.GoToMeeting": "GoTo Meeting", "com.amazon.Amazon-Chime": "Amazon Chime",
        "com.around.Around": "Around", "com.tuple.app": "Tuple", "com.loom.desktop": "Loom", "ru.keepcoder.Telegram": "Telegram call",
    ]

    public static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "com.apple.WebKit": "Safari",
        "company.thebrowser.Browser": "Arc", "company.thebrowser.dia": "Dia", "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Edge", "org.mozilla.firefox": "Firefox", "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// Picks the meeting app among processes currently capturing the microphone. Native apps win over browsers.
    public static func meetingApp(capturingInput bundleIDs: [String]) -> (bundleID: String, name: String)? {
        for id in bundleIDs {
            if let match = lookup(id, in: apps) { return (match.key, match.value) }
        }
        for id in bundleIDs {
            if let match = lookup(id, in: browsers) { return (match.key, "\(match.value) (web meeting)") }
        }
        return nil
    }

    private static func lookup(_ bundleID: String, in table: [String: String]) -> (key: String, value: String)? {
        if let name = table[bundleID] { return (bundleID, name) }
        return table.first { bundleID.hasPrefix($0.key + ".") }.map { ($0.key, $0.value) }
    }
}
