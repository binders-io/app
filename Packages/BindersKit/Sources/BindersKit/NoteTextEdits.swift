import Foundation

// A shared note is edited as text on every Mac, and kept as an Automerge document on the hub. These
// are the pure parts of going between the two: what changed from one text to another, as edits small enough that a
// teammate's typing elsewhere in the note survives; the splices Automerge takes; a three-way merge for an editor that
// still holds typing when a teammate's change lands; and where a cursor goes when the text around it changes.
//
// Automerge counts a text in Unicode scalars (a document loaded from bytes always does), so splices are in scalars. An
// editor's cursor is in UTF-16, so positions can be worked out in either.

/// One change from an old text to a new one: `length` elements of the old text, from `start`, give way to `newLength`
/// elements of the new one, from `newStart`. A list of them is sorted and never overlaps.
public struct TextEdit: Equatable, Sendable {
    public var start: Int
    public var length: Int
    public var newStart: Int
    public var newLength: Int

    public init(start: Int, length: Int, newStart: Int, newLength: Int) {
        self.start = start
        self.length = length
        self.newStart = newStart
        self.newLength = newLength
    }

    public var end: Int { start + length }
    public var isInsertion: Bool { length == 0 }
}

/// A splice as Automerge takes it: at `start` in the text as it is when this splice comes (splices go in order), take
/// out `delete` scalars and put `insert` in.
public struct TextSplice: Equatable, Sendable {
    public var start: Int
    public var delete: Int
    public var insert: String

    public init(start: Int, delete: Int, insert: String) {
        self.start = start
        self.delete = delete
        self.insert = insert
    }
}

public enum TextEdits {
    /// The edits that turn `a` into `b`: by lines first (so changes far apart stay apart), then each changed run of
    /// lines narrowed to what actually differs. `isBreak` says which element ends a line.
    public static func edits<T: Hashable>(from a: [T], to b: [T], isBreak: (T) -> Bool) -> [TextEdit] {
        if a == b { return [] }
        // What's the same at both ends never takes part.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = Array(a[prefix..<(a.count - suffix)])
        let newMiddle = Array(b[prefix..<(b.count - suffix)])
        // One change in one place (typing, a paste): one edit.
        let breaks = oldMiddle.filter(isBreak).count + newMiddle.filter(isBreak).count
        if breaks <= 2 || oldMiddle.isEmpty || newMiddle.isEmpty {
            return [TextEdit(start: prefix, length: oldMiddle.count, newStart: prefix, newLength: newMiddle.count)]
        }
        // Several lines changed: compare line by line, so an edit here and one three paragraphs down stay two edits.
        let oldLines = lines(oldMiddle, isBreak: isBreak), newLines = lines(newMiddle, isBreak: isBreak)
        var removed = Set<Int>(), inserted = Set<Int>()
        for step in newLines.difference(from: oldLines) {
            switch step {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [TextEdit] = []
        var oldIndex = 0, newIndex = 0
        var oldOffset = prefix, newOffset = prefix
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, newIndex < newLines.count, !removed.contains(oldIndex), !inserted.contains(newIndex) {
                oldOffset += oldLines[oldIndex].count
                newOffset += newLines[newIndex].count
                oldIndex += 1
                newIndex += 1
                continue
            }
            // A run of lines taken out, and the run put in their place.
            var gone: [T] = [], came: [T] = []
            while oldIndex < oldLines.count, removed.contains(oldIndex) {
                gone += oldLines[oldIndex]
                oldIndex += 1
            }
            while newIndex < newLines.count, inserted.contains(newIndex) {
                came += newLines[newIndex]
                newIndex += 1
            }
            if gone.isEmpty, came.isEmpty {
                // Lines the difference neither took out nor put in, out of step: shouldn't happen, but never loop.
                if oldIndex < oldLines.count { gone += oldLines[oldIndex]; oldIndex += 1 }
                if newIndex < newLines.count { came += newLines[newIndex]; newIndex += 1 }
            }
            // Narrowed to what differs inside the run.
            var head = 0
            while head < gone.count, head < came.count, gone[head] == came[head] { head += 1 }
            var tail = 0
            while tail < gone.count - head, tail < came.count - head, gone[gone.count - 1 - tail] == came[came.count - 1 - tail] { tail += 1 }
            if gone.count - head - tail > 0 || came.count - head - tail > 0 {
                result.append(TextEdit(start: oldOffset + head, length: gone.count - head - tail, newStart: newOffset + head,
                                       newLength: came.count - head - tail))
            }
            oldOffset += gone.count
            newOffset += came.count
        }
        return result
    }

    /// Splits into lines, each with the element that ends it (the last may have none).
    static func lines<T>(_ elements: [T], isBreak: (T) -> Bool) -> [[T]] {
        var result: [[T]] = []
        var current: [T] = []
        for element in elements {
            current.append(element)
            if isBreak(element) {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The edits from one text to another, in Unicode scalars, as Automerge counts.
    public static func scalars(from old: String, to new: String) -> [TextEdit] {
        edits(from: Array(old.unicodeScalars), to: Array(new.unicodeScalars), isBreak: { $0 == "\n" })
    }

    /// The same, in UTF-16 code units, as an editor's cursor counts.
    public static func utf16(from old: String, to new: String) -> [TextEdit] {
        edits(from: Array(old.utf16), to: Array(new.utf16), isBreak: { $0 == 10 })
    }

    /// The splices that turn `old` into `new`, in order, in scalars: each is at its place in the text as the splices
    /// before it left it.
    public static func splices(from old: String, to new: String) -> [TextSplice] {
        let newScalars = Array(new.unicodeScalars)
        return scalars(from: old, to: new).map { edit in
            var inserted = String.UnicodeScalarView()
            inserted.append(contentsOf: newScalars[edit.newStart..<(edit.newStart + edit.newLength)])
            return TextSplice(start: edit.newStart, delete: edit.length, insert: String(inserted))
        }
    }

    /// The splices applied to a text, in order, as Automerge would: for checking them.
    public static func apply(_ splices: [TextSplice], to text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        for splice in splices {
            let start = min(max(0, splice.start), scalars.count)
            let end = min(scalars.count, start + max(0, splice.delete))
            scalars.replaceSubrange(start..<end, with: Array(splice.insert.unicodeScalars))
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Where a position in the old text is in the new one: before an edit (or right where one starts) it stays, after it
    /// it moves with it, inside what was replaced it goes to the end of what took its place. So a cursor stays before
    /// words a teammate puts in right where it is.
    public static func map(_ position: Int, through edits: [TextEdit]) -> Int {
        var shift = 0
        for edit in edits {
            if position <= edit.start { break }
            if position >= edit.end {
                shift = edit.newStart + edit.newLength - edit.end
                continue
            }
            return edit.newStart + edit.newLength
        }
        return position + shift
    }
}

/// Merges two texts that both started from `base`: what one side changed where the other didn't is kept as it is; where
/// both changed the same words, the other side's (`theirs`) are kept and what this side typed there goes after them.
/// Nothing either side typed is lost. Used by an editor that still holds typing when a teammate's change lands.
public enum TextMerge {
    public static func merge(base: String, mine: String, theirs: String) -> String {
        if mine == base { return theirs }
        if theirs == base || theirs == mine { return mine }
        let baseScalars = Array(base.unicodeScalars), mineScalars = Array(mine.unicodeScalars), theirScalars = Array(theirs.unicodeScalars)
        let ours = TextEdits.edits(from: baseScalars, to: mineScalars, isBreak: { $0 == "\n" })
        let others = TextEdits.edits(from: baseScalars, to: theirScalars, isBreak: { $0 == "\n" })
        enum Side { case mine, theirs }
        let mineEdits: [(TextEdit, Side)] = ours.map { ($0, Side.mine) }
        let theirEdits: [(TextEdit, Side)] = others.map { ($0, Side.theirs) }
        // By where they start; where two start together, theirs first.
        let all = (theirEdits + mineEdits).sorted { (a: (TextEdit, Side), b: (TextEdit, Side)) -> Bool in
            if a.0.start != b.0.start { return a.0.start < b.0.start }
            return a.1 == .theirs && b.1 == .mine
        }
        // Edits that touch become one cluster: an insertion where the other side replaced words, or two in one place.
        func touches(_ a: TextEdit, _ b: TextEdit) -> Bool {
            if a.isInsertion && b.isInsertion { return a.start == b.start }
            if a.isInsertion { return a.start > b.start && a.start < b.end }
            if b.isInsertion { return b.start > a.start && b.start < a.end }
            return a.start < b.end && b.start < a.end
        }
        var clusters: [[(TextEdit, Side)]] = []
        for item in all {
            if var last = clusters.last, last.contains(where: { touches($0.0, item.0) }) {
                last.append(item)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([item])
            }
        }
        // Where both sides changed the same words, the whole words go both ways: "Tuesday Monday", not "TuesMonday". A
        // cluster widened to its words takes in any edit it then reaches.
        func isWord(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) }
        var widened: [(start: Int, end: Int, edits: [(TextEdit, Side)])] = []
        for cluster in clusters {
            var start = cluster.map(\.0.start).min() ?? 0
            var end = cluster.map(\.0.end).max() ?? 0
            var edits = cluster
            let bothSides = Set(cluster.map { $0.1 == .mine }).count == 2
            if bothSides, !cluster.allSatisfy({ $0.0.isInsertion }) {
                while start > 0, isWord(baseScalars[start - 1]) { start -= 1 }
                while end < baseScalars.count, isWord(baseScalars[end]) { end += 1 }
            }
            // Earlier clusters this one now reaches become part of it.
            while let last = widened.last, last.end > start {
                widened.removeLast()
                start = min(start, last.start)
                end = max(end, last.end)
                edits = last.edits + edits
            }
            widened.append((start, end, edits))
        }
        /// The base from `start` to `end` with one side's edits in it.
        func render(_ edits: [(TextEdit, Side)], from start: Int, to end: Int, using source: [Unicode.Scalar]) -> [Unicode.Scalar] {
            var piece: [Unicode.Scalar] = []
            var at = start
            for (edit, _) in edits.sorted(by: { $0.0.start < $1.0.start }) {
                if edit.start > at { piece += baseScalars[at..<edit.start] }
                piece += source[edit.newStart..<(edit.newStart + edit.newLength)]
                at = max(at, edit.end)
            }
            if end > at { piece += baseScalars[at..<end] }
            return piece
        }
        var output: [Unicode.Scalar] = []
        var position = 0
        for cluster in widened {
            if cluster.start > position { output += baseScalars[position..<cluster.start] }
            let mineHere = cluster.edits.filter { $0.1 == .mine }, theirsHere = cluster.edits.filter { $0.1 == .theirs }
            if mineHere.isEmpty || theirsHere.isEmpty {
                // One side only: its edits, as it made them.
                output += render(cluster.edits, from: cluster.start, to: cluster.end, using: mineHere.isEmpty ? theirScalars : mineScalars)
            } else if cluster.edits.allSatisfy({ $0.0.isInsertion }) {
                // Both typed in one place: theirs first, then what was typed here.
                output += render(theirsHere, from: cluster.start, to: cluster.end, using: theirScalars)
                for (edit, _) in mineHere { output += mineScalars[edit.newStart..<(edit.newStart + edit.newLength)] }
            } else {
                // Both changed the same words: theirs, then these words as they were typed here.
                let theirs = render(theirsHere, from: cluster.start, to: cluster.end, using: theirScalars)
                let mine = render(mineHere, from: cluster.start, to: cluster.end, using: mineScalars)
                output += theirs
                if mine != theirs {
                    if let last = theirs.last, let first = mine.first, isWord(last), isWord(first) { output.append(" ") }
                    output += mine
                }
            }
            position = max(position, cluster.end)
        }
        if position < baseScalars.count { output += baseScalars[position...] }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: output)
        return String(view)
    }
}
