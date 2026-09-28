import Foundation

/// A starting point for a note: Markdown with {{date}}, {{time}}, {{today}} (the date as the day's note is titled, for
/// [[{{today}}]]) and {{binder}} filled in when it's used.
public struct NoteTemplate: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let body: String

    public init(name: String, body: String) {
        self.name = name
        self.body = body
    }

    /// The note it starts, for a day and a binder.
    public func filled(date: Date, binder: String, locale: Locale = .current) -> String {
        let long = date.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: locale))
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
        let today = date.formatted(.iso8601.year().month().day())
        return body.replacingOccurrences(of: "{{date}}", with: long)
            .replacingOccurrences(of: "{{time}}", with: time)
            .replacingOccurrences(of: "{{today}}", with: today)
            .replacingOccurrences(of: "{{binder}}", with: binder)
    }

    /// The ones Binders comes with.
    public static let builtIn: [NoteTemplate] = [
        NoteTemplate(name: "1:1", body: """
        # 1:1 · {{date}}

        ## How things are going
        -\u{20}

        ## Updates
        -\u{20}

        ## Blockers
        -\u{20}

        ## Action items
        - [ ]\u{20}
        """),
        NoteTemplate(name: "Project kickoff", body: """
        # Kickoff:\u{20}

        Started {{date}} in {{binder}}.

        ## Goal
        What does done look like?

        ## Scope
        - In:\u{20}
        - Out:\u{20}

        ## People
        -\u{20}

        ## Risks
        -\u{20}

        ## Next steps
        - [ ]\u{20}
        """),
        NoteTemplate(name: "Interview", body: """
        # Interview:\u{20}

        {{date}} · Role:\u{20}

        ## Background
        -\u{20}

        ## Strengths
        -\u{20}

        ## Concerns
        -\u{20}

        ## Their questions
        -\u{20}

        ## Decision
        - [ ] Send feedback
        """),
        NoteTemplate(name: "Reading notes", body: """
        # Reading notes:\u{20}

        Source:\u{20}
        Read {{date}}

        ## Main claim

        ## Key points
        -\u{20}

        ## Evidence and numbers
        -\u{20}

        ## What I think

        ## Open questions
        -\u{20}

        ## To do
        - [ ]\u{20}
        """),
        NoteTemplate(name: "Weekly review", body: """
        # Week of {{date}}

        ## What got done
        -\u{20}

        ## What didn't, and why
        -\u{20}

        ## Next week
        - [ ]\u{20}

        ## Notes
        """),
    ]

    /// The "## " headings of a note, in order: its sections, when it follows a template.
    public static func sections(of text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("## ") else { return nil }
            let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return heading.isEmpty ? nil : heading
        }
    }
}
