import AppKit
import SwiftUI

/// The Binders look (lane UI2, after the founder's "F" mockups): graphite in the dark and white in the light, the sidebar a
/// shade off the page, opaque surfaces for cards, and a vivid violet as the accent. Primary buttons are the page's ink
/// (white in the dark, black in the light). Four colours each mean one thing, and always come with their glyph: amber
/// needs you, red is the live microphone, lavender with the sparkle is an agent's doing, green is done. Agents wear a
/// colour of their own on their avatar (`AgentAvatar`). Titles and counts are semibold in the system face, your own words
/// are quoted in New York italic, and times have monospaced digits.
enum BindersTheme {
    // MARK: Grounds and surfaces

    /// The window and page background.
    static let ground = Color(nsColor: NS.ground)
    /// The sidebar and other secondary ground, a shade off the page's.
    static let ground2 = Color(nsColor: NS.ground2)
    /// Opaque cards and panels on the ground.
    static let surface = Color(nsColor: NS.surface)
    /// A well or a raised fill inside a surface.
    static let surface2 = Color(nsColor: NS.surface2)
    /// The note page, with `paperInk` words: light paper in the light appearance, and in the dark a dark page, the surface,
    /// with the dark's ink, muted words and lines.
    static let paper = Color(nsColor: NS.paper)
    static let paperInk = Color(nsColor: NS.paperInk)
    static let paperMuted = Color(nsColor: NS.paperMuted)
    static let paperLine = Color(nsColor: NS.paperLine)

    // MARK: Words and lines

    /// Primary text.
    static let ink = Color(nsColor: NS.ink)
    /// Secondary text.
    static let muted = Color(nsColor: NS.muted)
    /// Tertiary text and placeholders.
    static let faint = Color(nsColor: NS.faint)
    /// Hairlines.
    static let line = Color(nsColor: NS.line)
    static let lineStrong = Color(nsColor: NS.lineStrong)

    // MARK: The brand

    /// Buttons, selection, links: the icon's indigo.
    static let accent = Color(nsColor: NS.accent)
    /// Accent-coloured words on the ground, light enough to read in the dark.
    static let accentText = Color(nsColor: NS.accentText)

    // MARK: One meaning each, always with a glyph

    /// Amber: it needs you, and nothing else.
    static let needsYou = Color(nsColor: NS.needsYou)
    /// Red: the microphone is live, and nothing else.
    static let live = Color(nsColor: NS.live)
    /// Lavender, with the sparkle: an agent did it, and nothing else.
    static let agent = Color(nsColor: NS.agent)
    /// Green: done, and nothing else.
    static let done = Color(nsColor: NS.done)
    /// Lines an edit took out, in a diff, and nothing else.
    static let removed = Color(nsColor: NS.removed)
    /// The warm brand stroke: a run's plan, the activity chart's lead line.
    static let brandWarm = Color(nsColor: NS.brandWarm)
    /// Under code: a diff, a command's output.
    static let codeGround = Color(nsColor: NS.codeGround)
    /// A primary button's fill, the page's ink, and its words.
    static let primaryFill = Color(nsColor: NS.primaryFill)
    static let onPrimary = Color(nsColor: NS.onPrimary)
    /// What's picked in a list: a faint wash of ink.
    static let selection = Color(nsColor: NS.selection)

    /// The tokens as AppKit colours, for windows, menus and the note editor. Each follows the appearance it's drawn in.
    enum NS {
        static let ground = dynamic("ground", dark: 0x1C1C1E, light: 0xFFFFFF)
        static let ground2 = dynamic("ground2", dark: 0x141415, light: 0xF3F3F5)
        static let surface = dynamic("surface", dark: 0x262628, light: 0xF5F5F7)
        static let surface2 = dynamic("surface2", dark: 0x313134, light: 0xEBEBEF)
        // The note page. In the dark these are the page's ground, ink, muted, faint and line.
        static let paper = dynamic("paper", dark: 0x1C1C1E, light: 0xFFFFFF)
        static let paperInk = dynamic("paperInk", dark: 0xF2F2F3, light: 0x111113)
        static let paperMuted = dynamic("paperMuted", dark: 0xA1A1A8, light: 0x5E5E66)
        static let paperFaint = dynamic("paperFaint", dark: 0x7C7C83, light: 0x5E5E66, lightAlpha: 0.6)
        static let paperLine = dynamic("paperLine", dark: 0xFFFFFF, light: 0xEAEAEE, darkAlpha: 0.09)
        static let ink = dynamic("ink", dark: 0xF2F2F3, light: 0x111113)
        static let muted = dynamic("muted", dark: 0xA1A1A8, light: 0x5E5E66)
        static let faint = dynamic("faint", dark: 0x7C7C83, light: 0x8B8B93)
        static let line = dynamic("line", dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.09, lightAlpha: 0.08)
        static let lineStrong = dynamic("lineStrong", dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.17, lightAlpha: 0.15)
        static let accent = srgb(0x6446F5)
        static let accentText = dynamic("accentText", dark: 0xA996FF, light: 0x5639E6)
        static let needsYou = dynamic("needsYou", dark: 0xF5A524, light: 0xB86A00)
        static let live = dynamic("live", dark: 0xFF5A52, light: 0xD93A34)
        static let agent = dynamic("agent", dark: 0xC4B5FF, light: 0x6A4BF0)
        static let done = dynamic("done", dark: 0x4ADE80, light: 0x15803D)
        static let removed = dynamic("removed", dark: 0xF87171, light: 0xC81E1E)
        static let brandWarm = dynamic("brandWarm", dark: 0xE8875B, light: 0xD2602F)
        static let codeGround = dynamic("codeGround", dark: 0x151517, light: 0xF5F5F7)
        static let primaryFill = dynamic("primaryFill", dark: 0xF2F2F3, light: 0x111113)
        static let onPrimary = dynamic("onPrimary", dark: 0x111113, light: 0xFFFFFF)
        static let selection = dynamic("selection", dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.08, lightAlpha: 0.06)
    }

    /// The dark values whatever the appearance: the Flow bar, dark over any app, and the graph's night sky.
    enum Dark {
        static let ground = Color(nsColor: srgb(0x0B0A17))
        static let surface2 = Color(nsColor: srgb(0x1F1C3A))
        static let accentText = Color(nsColor: srgb(0xA996FF))
        static let live = Color(nsColor: srgb(0xFF5A52))
    }

    /// An agent's terminal on the Agents page: dark whatever the appearance, as a terminal is, a shade deeper than the
    /// dark page so it reads as its own pane in both. Its words in the code face; brand warmth for your words and the
    /// working star, green and red only for how a tool went and an edit's lines.
    enum Terminal {
        static let ground = Color(nsColor: srgb(0x111114))
        static let bar = Color(nsColor: srgb(0x17171B))
        static let edge = Color(nsColor: dynamic("terminalEdge", dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.10, lightAlpha: 0.10))
        static let ink = Color(nsColor: srgb(0xE8E8EC))
        static let muted = Color(nsColor: srgb(0xA0A0A9))
        static let faint = Color(nsColor: srgb(0x6B6B74))
        static let line = Color(nsColor: srgb(0xFFFFFF, alpha: 0.08))
        static let yours = Color(nsColor: srgb(0xFFFFFF, alpha: 0.05))
        static let warm = Color(nsColor: srgb(0xE8875B))
        static let ok = Color(nsColor: srgb(0x4ADE80))
        static let failed = Color(nsColor: srgb(0xF87171))
        static let going = Color(nsColor: srgb(0xF5A524))
        static let added = Color(nsColor: srgb(0x9BE9B4))
        static let addedGround = Color(nsColor: srgb(0x163322))
        static let removed = Color(nsColor: srgb(0xFDB0B0))
        static let removedGround = Color(nsColor: srgb(0x3C1A1D))

        static func font(_ size: CGFloat = 12.5, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    }

    /// The light values whatever the appearance.
    enum Light {
        static let accentText = Color(nsColor: srgb(0x5639E6))
        static let done = Color(nsColor: srgb(0x15803D))
        static let agent = Color(nsColor: srgb(0x6A4BF0))
    }

    /// One colour for the dark appearance and another for the light, picked as it's drawn.
    static func dynamic(_ name: String, dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: "Binders." + name) { appearance in
            appearance.isDark ? srgb(dark, alpha: darkAlpha) : srgb(light, alpha: lightAlpha)
        }
    }

    static func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    // MARK: Type

    /// Page titles: the system face, a large one lighter than a small one, as a Mac app's titles are.
    static func title(_ size: CGFloat = 30) -> Font { .system(size: size, weight: size >= 26 ? .medium : .semibold) }
    /// A section's title on a page: "Agents", "Waiting for you".
    static let columnTitle = Font.system(size: 15, weight: .semibold)
    /// A title inside a card, a panel or a sheet: a binder's name, an agent's, a board column's, "Digest".
    static let cardTitle = Font.system(size: 13.5, weight: .semibold)
    /// A count on its own, with digits that keep their width as it changes.
    static func count(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .medium).monospacedDigit() }
    /// Your own words, quoted: what you said, a transcript's lines, a moment, a snippet's trigger. New York italic.
    static func quote(_ style: Font.TextStyle = .body) -> Font { .system(style, design: .serif).italic() }
    /// Times and durations, with monospaced digits so they don't jitter.
    static func time(_ style: Font.TextStyle = .caption) -> Font { .system(style).monospacedDigit() }

    // MARK: Glyphs that go with a meaning

    /// The problem style's glyph: something went wrong, said in ink, never in red or orange.
    static let problemSymbol = "exclamationmark.circle"
    /// An agent did it: with lavender, and nowhere else.
    static let agentSymbol = "sparkles"
    /// Done: with green.
    static let doneSymbol = "checkmark.circle.fill"
    /// Ready, connected, granted, on: a check in the accent's text colour, where done isn't meant.
    static let readySymbol = "checkmark.circle"
    /// Waiting: paused or queued, muted.
    static let waitingSymbol = "pause.circle"
    /// Ask, which searches and answers from your binders. No agent does it, so not the sparkle.
    static let askSymbol = "text.magnifyingglass"
    /// The language model writing something for you, such as a digest. Not an agent either.
    static let modelSymbol = "wand.and.rays"

    /// A small ring binder for the menu bar, drawn as a template so it follows the bar's appearance.
    static func binderGlyph(size: CGFloat = 18, capturing: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width
            let stroke = s * 0.085
            NSColor.black.setStroke()
            let cover = NSBezierPath(roundedRect: NSRect(x: s * 0.16, y: s * 0.13, width: s * 0.68, height: s * 0.74),
                                     xRadius: s * 0.13, yRadius: s * 0.13)
            cover.lineWidth = stroke
            cover.stroke()
            let ringRadius = s * 0.085
            let rings: [CGFloat] = [0.36, 0.64]
            // Spine, drawn in pieces so it stops at each ring.
            let spine = NSBezierPath()
            spine.lineWidth = stroke * 0.8
            let stops = [s * 0.13] + rings.flatMap { [s * $0 - ringRadius, s * $0 + ringRadius] } + [s * 0.87]
            for pair in stride(from: 0, to: stops.count, by: 2) {
                spine.move(to: NSPoint(x: s * 0.5, y: stops[pair]))
                spine.line(to: NSPoint(x: s * 0.5, y: stops[pair + 1]))
            }
            spine.stroke()
            for fy in rings {
                let ring = NSBezierPath(ovalIn: NSRect(x: s * 0.5 - ringRadius, y: s * fy - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
                ring.lineWidth = stroke * 0.8
                ring.stroke()
            }
            if capturing {
                // A pen nib at the corner while writing capture is on.
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: s * 0.72, y: s * 0.02, width: s * 0.26, height: s * 0.26)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension NSAppearance {
    /// Dark Aqua, or its high-contrast cousin.
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Applies the appearance setting to every window the app owns.
enum AppAppearance {
    static func apply(_ setting: String) {
        switch setting {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "system": NSApp.appearance = nil
        default: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Binder colours

/// Colours a binder can wear on its spine. Orange, Green and Amber equal a semantic colour, and that's fine: a binder's
/// colour is who it is, and a semantic state always comes with its glyph.
enum BinderPalette {
    static let nsColors: [NSColor] = [
        BindersTheme.NS.accent,
        NSColor(srgbRed: 0.16, green: 0.62, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.52, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.36, blue: 0.58, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.66, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.26, green: 0.60, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.68, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.50, green: 0.54, blue: 0.62, alpha: 1),
    ]
    static let colors: [Color] = nsColors.map { Color(nsColor: $0) }
    static let names = ["Indigo", "Teal", "Orange", "Pink", "Green", "Sky", "Amber", "Slate"]

    static func color(_ index: Int) -> Color { colors[slot(index)] }
    static func nsColor(_ index: Int) -> NSColor { nsColors[slot(index)] }

    /// Its colour for the words and glyphs you act on, on its pages (a link, a toggle that's on): mixed with ink, a third
    /// of it or more, until its words read at 4.5:1 or better on its own chips, and so on its page and a note's page too.
    static func textColor(_ index: Int) -> Color { textColors[slot(index)] }
    static func nsTextColor(_ index: Int) -> NSColor { nsTextColors[slot(index)] }

    /// Words on it, such as a selected chip's: white on Indigo, the accent's own colour, and dark ink on the others, which
    /// are too light for white words. Either reads at 4.5:1 or better.
    static func wordsOn(_ index: Int) -> Color { slot(index) == 0 ? .white : darkWordsColor }
    static func nsWordsOn(_ index: Int) -> NSColor { slot(index) == 0 ? .white : darkWords }
    /// A count beside those words, a little lighter: 90%, which still reads at 4.5:1 on every binder colour.
    static let countOpacity = 0.9

    /// Its colour on what you press that it fills (a prominent button such as a card's Done, a switch that's on): white
    /// words read on it at 4.5:1 or better. Indigo as it is; the others darkened with ink until white reads.
    static func controlColor(_ index: Int) -> Color { controlColors[slot(index)] }

    /// The page ground with a trace of it, 3% in both appearances: enough to tell which binder you're in, and no more.
    static func wash(_ index: Int) -> Color { washes[slot(index)] }

    private static func slot(_ index: Int) -> Int { abs(index) % nsColors.count }

    /// The light appearance's ink, in both: dark words on a binder's colour.
    private static let darkWords = BindersTheme.srgb(0x16132E)
    private static let darkWordsColor = Color(nsColor: darkWords)
    private static let washFraction: CGFloat = 0.03

    private static let nsTextColors: [NSColor] = nsColors.enumerated().map { index, color in
        let dark = readableWords(color, in: NSAppearance(named: .darkAqua)!)
        let light = readableWords(color, in: NSAppearance(named: .aqua)!)
        return NSColor(name: "Binders.binderText\(index)") { $0.isDark ? dark : light }
    }
    private static let textColors: [Color] = nsTextColors.map { Color(nsColor: $0) }

    private static let controlColors: [Color] = nsColors.enumerated().map { index, color in
        guard index != 0 else { return Color(nsColor: color) }
        var fraction: CGFloat = 0.1
        var shade = color.blended(withFraction: fraction, of: darkWords) ?? color
        while shade.contrast(with: .white) < 4.5, fraction < 0.9 {
            fraction += 0.02
            shade = color.blended(withFraction: fraction, of: darkWords) ?? color
        }
        return Color(nsColor: shade)
    }

    /// `color` mixed with the appearance's ink: a third of it, or more for a light colour such as Amber in the light,
    /// until its words read at 4.5:1 on its own chips, 16% of it over its page's ground, the faintest place they sit.
    private static func readableWords(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        let ink = BindersTheme.NS.ink.resolved(for: appearance)
        let ground = BindersTheme.NS.ground.resolved(for: appearance)
        let page = ground.blended(withFraction: washFraction, of: color) ?? ground
        let chip = color.composited(over: page, opacity: 0.16)
        var fraction: CGFloat = 0.35
        var words = color.blended(withFraction: fraction, of: ink) ?? color
        while words.contrast(with: chip) < 4.5, fraction < 0.9 {
            fraction += 0.01
            words = color.blended(withFraction: fraction, of: ink) ?? color
        }
        return words
    }

    private static let washes: [Color] = nsColors.enumerated().map { index, color in
        Color(nsColor: NSColor(name: "Binders.binderWash\(index)") { appearance in
            let ground = BindersTheme.NS.ground.resolved(for: appearance)
            return ground.blended(withFraction: washFraction, of: color) ?? ground
        })
    }
}

extension NSColor {
    /// This colour as it's drawn in `appearance`, in sRGB.
    func resolved(for appearance: NSAppearance) -> NSColor {
        var resolved = self
        appearance.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        return resolved
    }

    /// This colour with `alpha`, still following the appearance it's drawn in.
    func withAlpha(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in self.resolved(for: appearance).withAlphaComponent(alpha) }
    }

    /// This colour at `opacity` drawn over an opaque `background`, mixed in sRGB as a window draws it (`blended` mixes in
    /// another colour space and comes out a few steps off).
    func composited(over background: NSColor, opacity: CGFloat) -> NSColor {
        guard let front = usingColorSpace(.sRGB), let back = background.usingColorSpace(.sRGB) else { return background }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { b + (a - b) * opacity }
        return NSColor(srgbRed: mix(front.redComponent, back.redComponent), green: mix(front.greenComponent, back.greenComponent),
                       blue: mix(front.blueComponent, back.blueComponent), alpha: 1)
    }

    /// WCAG 2 contrast between this colour and `other`, both opaque.
    func contrast(with other: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB) ?? color
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let (a, b) = (luminance(self), luminance(other))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// A binder's colour as its pages wear it, lightly, and the only colour on them besides the semantic ones: on its own
/// header and chips, in place of the accent on what you act on (primary buttons, switches, the selected tab or chip,
/// the selection, links), and a trace of it in the page's ground. Titles and words stay ink and muted; what only tells
/// you something, which wears the accent elsewhere, is neutral there (`.infoText`, `.infoFill`); small borderless
/// controls are grey (`quietControl()`); semantic colours stay semantic.
struct BinderTint: Equatable {
    let index: Int

    var fill: Color { BinderPalette.color(index) }
    var text: Color { BinderPalette.textColor(index) }
    var wash: Color { BinderPalette.wash(index) }
    /// The tint of what you press that it fills, which white words read on.
    var control: Color { BinderPalette.controlColor(index) }
    /// Words on its fill, such as a selected chip's.
    var onFill: Color { BinderPalette.wordsOn(index) }
}

private struct BinderTintKey: EnvironmentKey {
    static let defaultValue: BinderTint? = nil
}

extension EnvironmentValues {
    /// The binder whose pages these are; nil outside a binder, where the accent is the accent.
    var binderTint: BinderTint? {
        get { self[BinderTintKey.self] }
        set { self[BinderTintKey.self] = newValue }
    }
}

/// The accent's fill on what you act on or have chosen (a selected chip, a drop target), or the binder's colour on its
/// pages. A fill that only tells you something is `.infoFill`.
struct TintFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { environment.binderTint?.fill ?? BindersTheme.accent }
}

/// Words on `.tintFill`, such as a selected chip's: white on the accent, and on a binder's pages the words that read on
/// its colour (white on Indigo, dark ink on the others). `secondary` is a count beside them, a little lighter: 85% white
/// on the accent, as it always was, and 90% on a binder's colour.
struct OnTintFill: ShapeStyle {
    var secondary = false

    func resolve(in environment: EnvironmentValues) -> Color {
        guard let tint = environment.binderTint else { return secondary ? .white.opacity(0.85) : .white }
        return secondary ? tint.onFill.opacity(BinderPalette.countOpacity) : tint.onFill
    }
}

/// Accent-coloured words and glyphs on what you act on (a link, a toggle that's on, a filter that's applied): the
/// accent's text colour, or the binder's on its pages. Words and glyphs that only tell you something are `.infoText`.
struct TintText: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { environment.binderTint?.text ?? BindersTheme.accentText }
}

/// Words and glyphs that only tell you something and wear the accent for it (a status, a count's glyph, a timeline's
/// glyphs): the accent's text colour, and muted on a binder's pages, whose colour is the only one there. What waits on
/// you, "Ready for you to check" among it, is amber instead (`BindersTheme.needsYou`).
struct InfoText: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.binderTint == nil ? BindersTheme.accentText : BindersTheme.muted
    }
}

/// The fill behind something that only tells you something (the "You" chip, your bubble in a meeting's chat, an answer's
/// card): the accent at `opacity`, and on a binder's pages a faint ink, as its other chips have, never more than 7%.
struct InfoFill: ShapeStyle {
    var opacity: Double

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.binderTint == nil ? BindersTheme.accent.opacity(opacity) : BindersTheme.ink.opacity(min(opacity, 0.07))
    }
}

/// A section's title: ink, on a binder's pages too, where only the binder's own name and mark wear its colour.
struct SectionInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { BindersTheme.ink }
}

extension ShapeStyle where Self == TintFill {
    static var tintFill: TintFill { TintFill() }
}

extension ShapeStyle where Self == OnTintFill {
    static var onTintFill: OnTintFill { OnTintFill() }
}

extension ShapeStyle where Self == TintText {
    static var tintText: TintText { TintText() }
}

extension ShapeStyle where Self == InfoText {
    static var infoText: InfoText { InfoText() }
}

extension ShapeStyle where Self == InfoFill {
    static func infoFill(_ opacity: Double) -> InfoFill { InfoFill(opacity: opacity) }
}

extension ShapeStyle where Self == SectionInk {
    static var sectionInk: SectionInk { SectionInk() }
}

extension View {
    /// What you act on inside wears this binder's colour in place of the accent (the controls' tint, `.tintFill` and
    /// `.tintText`), what only tells you something turns neutral (`.infoText`, `.infoFill`), small borderless controls
    /// turn grey (`quietControl()`), and a `pageGround()` inside has a trace of it. Nil leaves the accent.
    func binderTint(_ colorIndex: Int?) -> some View {
        let tint = colorIndex.map(BinderTint.init(index:))
        return environment(\.binderTint, tint)
            .tint(tint?.control ?? BindersTheme.accent)
    }

    /// A small borderless control, such as a toolbar's menu, a panel's copy button or a column's +: grey on a binder's
    /// pages, where its colour is for primary buttons, switches, what's selected and links. Elsewhere it's as it was.
    /// `words` is for one labelled with words, such as "Delete Card…": muted, which reads at 4.5:1 where the system's
    /// grey for glyphs doesn't.
    func quietControl(words: Bool = false) -> some View {
        modifier(QuietControl(words: words))
    }

    /// The page's ground: plain, or with a trace of its binder's colour on a binder's pages.
    func pageGround() -> some View {
        modifier(PageGround())
    }

    /// A link: the accent's words, or the binder's on its pages.
    func themedLink() -> some View {
        buttonStyle(.link).foregroundStyle(.tintText)
    }

    func paperCard(padding: CGFloat = 14, radius: CGFloat = 12) -> some View {
        modifier(PaperCard(padding: padding, radius: radius))
    }

    /// The note page, in the app's appearance: light paper with paperInk words in the light, a dark page (the surface)
    /// with ink in the dark. Raised, it's a sheet on the ground, with an edge and a shadow; otherwise it fills its
    /// window, title bar and all (`radius` is the raised sheet's).
    func paperSheet(radius: CGFloat = 12, raised: Bool = true) -> some View {
        modifier(PaperSheet(radius: radius, raised: raised))
    }
}

private struct PageGround: ViewModifier {
    @Environment(\.binderTint) private var tint

    func body(content: Content) -> some View {
        content.background((tint?.wash ?? BindersTheme.ground).ignoresSafeArea())
    }
}

private struct QuietControl: ViewModifier {
    var words: Bool
    @Environment(\.binderTint) private var tint

    func body(content: Content) -> some View {
        if tint == nil {
            content
        } else {
            // A button's label takes the foreground style; a menu's ignores it and draws in the tint. Glyphs are the
            // system's secondary grey, as the toolbar's other buttons and the menus beside them are.
            content
                .foregroundStyle(words ? AnyShapeStyle(BindersTheme.muted) : AnyShapeStyle(.secondary))
                .tint(Color.secondary)
        }
    }
}

/// An opaque card on the ground: the surface colour with a hairline edge. Content sits on these, never on glass.
struct PaperCard: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(BindersTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(BindersTheme.line))
    }
}

/// The note page in the window's own appearance, as are the controls and words drawn on it.
private struct PaperSheet: ViewModifier {
    var radius: CGFloat
    var raised: Bool

    func body(content: Content) -> some View {
        let page = content.foregroundStyle(BindersTheme.paperInk)
        if raised {
            page
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(BindersTheme.paper))
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(BindersTheme.line))
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        } else {
            // A window that's all page, under its title bar too.
            page.background(BindersTheme.paper.ignoresSafeArea())
        }
    }
}

// MARK: - Status

/// A short status line in the glyph and colour its meaning wears. `.problem` is the problem style: ink words beside an
/// exclamation, used for every error and failure instead of red or orange.
struct StatusLabel: View {
    enum Tone {
        /// Ready, connected, granted, on: where done isn't meant.
        case ready
        /// Something went wrong.
        case problem
        /// Paused, queued, off for now.
        case waiting
        /// It waits on you.
        case needsYou
        /// Done.
        case done
        /// The microphone is live.
        case live
    }

    let text: String
    let tone: Tone
    var symbol: String? = nil

    init(_ text: String, _ tone: Tone, symbol: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(text).foregroundStyle(tone == .waiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        } icon: {
            Image(systemName: symbol ?? Self.symbol(tone)).foregroundStyle(Self.color(tone))
        }
    }

    static func symbol(_ tone: Tone) -> String {
        switch tone {
        case .ready: BindersTheme.readySymbol
        case .problem: BindersTheme.problemSymbol
        case .waiting: BindersTheme.waitingSymbol
        case .needsYou: "exclamationmark.bubble"
        case .done: BindersTheme.doneSymbol
        case .live: "record.circle"
        }
    }

    static func color(_ tone: Tone) -> AnyShapeStyle {
        switch tone {
        // A status only tells you something: the accent's own, and neutral on a binder's pages.
        case .ready: AnyShapeStyle(.infoText)
        case .problem: AnyShapeStyle(.primary)
        case .waiting: AnyShapeStyle(.secondary)
        case .needsYou: AnyShapeStyle(BindersTheme.needsYou)
        case .done: AnyShapeStyle(BindersTheme.done)
        case .live: AnyShapeStyle(BindersTheme.live)
        }
    }
}

// MARK: - Motion

/// How Binders moves. Filing is the signature: a new item drops into its list with a short spring while its binder's
/// chip slides in. Counts roll to their new value. Under Reduce Motion every spring and move becomes a short crossfade.
/// What a page first reads just shows; only what changes after it has settled moves (`settlesAfterAppearing()`).
extension BindersTheme {
    /// A new item dropping into its list: about a third of a second, with a slight bounce.
    static let filing = Animation.spring(duration: 0.35, bounce: 0.2)
    /// A count rolling to its new value.
    static let rolling = Animation.snappy(duration: 0.3)
    /// What springs and moves become under Reduce Motion.
    static let crossfade = Animation.easeInOut(duration: 0.2)

    /// `animation`, or the crossfade under Reduce Motion.
    static func motion(_ animation: Animation, reduced: Bool) -> Animation { reduced ? crossfade : animation }
}

private struct ReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct PageSettledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct FilingArrivalKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Reduce Motion on or off whatever the system says, for self-tests and pictures; nil follows the system.
    var reduceMotionOverride: Bool? {
        get { self[ReduceMotionOverrideKey.self] }
        set { self[ReduceMotionOverrideKey.self] = newValue }
    }

    /// The page has drawn what it first read: from now on a new item files in and a count rolls. Until then they just
    /// show, so opening a page doesn't set everything moving.
    var pageSettled: Bool {
        get { self[PageSettledKey.self] }
        set { self[PageSettledKey.self] = newValue }
    }

    /// Inside an item that is filing in, at the start of its drop: its binder's chip starts a little to the side.
    fileprivate var filingArrival: Bool {
        get { self[FilingArrivalKey.self] }
        set { self[FilingArrivalKey.self] = newValue }
    }
}

/// Reduce Motion, as the system has it or as `reduceMotionOverride` sets it.
@propertyWrapper
struct ReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.reduceMotionOverride) private var override

    var wrappedValue: Bool { override ?? system }
}

/// A new item filing into its list: it drops in from just above, fading in, while its binder's chip slides in from the
/// side (`filingChip()`), and fades as it leaves. Under Reduce Motion it only fades. The list animates it with
/// `filing(_:)`.
struct FiledTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(FiledEffect(phase: phase))
    }
}

extension Transition where Self == FiledTransition {
    static var filed: FiledTransition { FiledTransition() }
}

private struct FiledEffect: ViewModifier {
    let phase: TransitionPhase
    @ReducedMotion private var reduceMotion

    func body(content: Content) -> some View {
        let arriving = phase == .willAppear && !reduceMotion
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(y: arriving ? -14 : 0)
            .environment(\.filingArrival, arriving)
    }
}

extension View {
    /// Rows put into or taken out of this list file in and fade out (each wears `.transition(.filed)`): with the filing
    /// spring once the page has settled, a crossfade under Reduce Motion, and not at all before. `ids` are the rows it
    /// shows, in order.
    func filing<ID: Hashable>(_ ids: [ID]) -> some View {
        modifier(FilingList(ids: ids))
    }

    /// A binder's chip on an item that files in: it slides in from the side as the item drops.
    func filingChip() -> some View {
        modifier(FilingChip())
    }

    /// A count that rolls to its new value, up or down, once the page has settled; it crossfades under Reduce Motion.
    func rollingCount(_ value: Int) -> some View {
        modifier(RollingCount(value: value, direction: Double(value)))
    }

    /// A line of counts that rolls to its new wording once the page has settled; it crossfades under Reduce Motion.
    func rollingCount<Value: Hashable>(_ value: Value) -> some View {
        modifier(RollingCount(value: value, direction: nil))
    }

    /// Lets what's inside move once the page has drawn what it first read, a moment after it appears: new items file
    /// in and counts roll. Home, Today, Work and a binder's board.
    func settlesAfterAppearing() -> some View {
        modifier(SettlingPage())
    }
}

private struct FilingList<ID: Hashable>: ViewModifier {
    let ids: [ID]
    @Environment(\.pageSettled) private var settled
    @ReducedMotion private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(settled ? BindersTheme.motion(BindersTheme.filing, reduced: reduceMotion) : nil, value: ids)
    }
}

private struct FilingChip: ViewModifier {
    @Environment(\.filingArrival) private var arriving

    func body(content: Content) -> some View {
        content.offset(x: arriving ? 18 : 0)
    }
}

private struct RollingCount<Value: Hashable>: ViewModifier {
    let value: Value
    /// The number it rolls toward, so it rolls up for more and down for fewer; nil for a line of words.
    let direction: Double?
    @Environment(\.pageSettled) private var settled
    @ReducedMotion private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : direction.map { .numericText(value: $0) } ?? .numericText())
            .animation(settled ? BindersTheme.motion(BindersTheme.rolling, reduced: reduceMotion) : nil, value: value)
    }
}

private struct SettlingPage: ViewModifier {
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .environment(\.pageSettled, settled)
            .task {
                // Long enough for the page's first read to be drawn still.
                try? await Task.sleep(for: .milliseconds(600))
                settled = true
            }
    }
}
