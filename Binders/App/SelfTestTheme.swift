import AppKit
import SwiftUI
import BindersKit

extension SelfTest {
    /// The design tokens (`BindersTheme`): each colour's dark and light value as the design gives them, words that read
    /// on the grounds they sit on (a binder's own words on its page, a note's page and its chips; words on a binder's
    /// colour), colours that follow the appearance they're drawn in (a binder's trace on its page ground, its colour on
    /// links and a note's links but not on titles, statuses or anything else that only tells you something, which turn
    /// neutral there, small controls that turn grey there, a note's page that's dark in a dark window and paper in a
    /// light one), and a sheet of swatches, status labels, badges, the note page and binder tints drawn in both
    /// appearances to `directory`. Nothing is read or written.
    @MainActor
    static func themeSelfTest(directory: URL) async -> Int32 {
        let tally = Tally()
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { tally.failures += 1 }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dark = NSAppearance(named: .darkAqua)!, light = NSAppearance(named: .aqua)!
        typealias NS = BindersTheme.NS

        // The values, as the design's table has them (dark, light; alpha where it's a hairline).
        let table: [(String, NSColor, UInt32, UInt32)] = [
            ("ground", NS.ground, 0x1C1C1E, 0xFFFFFF), ("surface", NS.surface, 0x262628, 0xF5F5F7), ("paper", NS.paper, 0x1C1C1E, 0xFFFFFF),
            ("paperInk", NS.paperInk, 0xF2F2F3, 0x111113), ("paperMuted", NS.paperMuted, 0xA1A1A8, 0x5E5E66),
            ("ink", NS.ink, 0xF2F2F3, 0x111113), ("muted", NS.muted, 0xA1A1A8, 0x5E5E66),
            ("faint", NS.faint, 0x7C7C83, 0x8B8B93), ("accent", NS.accent, 0x6446F5, 0x6446F5), ("accentText", NS.accentText, 0xA996FF, 0x5639E6),
            ("needsYou", NS.needsYou, 0xF5A524, 0xB86A00), ("live", NS.live, 0xFF5A52, 0xD93A34), ("agent", NS.agent, 0xC4B5FF, 0x6A4BF0),
            ("done", NS.done, 0x4ADE80, 0x15803D),
        ]
        for (name, color, darkHex, lightHex) in table {
            let inDark = color.resolved(for: dark), inLight = color.resolved(for: light)
            check(Self.matches(inDark, darkHex) && Self.matches(inLight, lightHex),
                  "\(name) is \(Self.hex(darkHex)) in the dark and \(Self.hex(lightHex)) in the light (\(Self.hex(inDark)), \(Self.hex(inLight)))")
        }
        let line = NS.line.resolved(for: dark), lineLight = NS.line.resolved(for: light)
        check(Self.matches(line, 0xFFFFFF) && abs(line.alphaComponent - 0.09) < 0.01 && Self.matches(lineLight, 0x000000)
              && abs(lineLight.alphaComponent - 0.08) < 0.01, "line is white at 9% in the dark and black at 8% in the light")

        // The note page follows the appearance: in the dark it's the surface, with the dark's own words and lines; in
        // the light it's the paper it always was.
        func same(_ a: NSColor, _ b: NSColor, in appearance: NSAppearance) -> Bool {
            let x = a.resolved(for: appearance), y = b.resolved(for: appearance)
            return Self.close(x, y) && abs(x.alphaComponent - y.alphaComponent) < 0.01
        }
        check([(NS.paper, NS.ground), (NS.paperInk, NS.ink), (NS.paperMuted, NS.muted), (NS.paperFaint, NS.faint), (NS.paperLine, NS.line)]
                .allSatisfy { same($0.0, $0.1, in: dark) },
              "in the dark a note's page is the page's ground, with ink, muted and faint words and the hairline")
        let faintLight = NS.paperFaint.resolved(for: light), lineOnPaper = NS.paperLine.resolved(for: light)
        check(Self.matches(faintLight, 0x5E5E66) && abs(faintLight.alphaComponent - 0.6) < 0.01 && Self.matches(lineOnPaper, 0xEAEAEE)
              && lineOnPaper.alphaComponent > 0.99, "in the light it keeps paper's faint words (#5E5E66 at 60%) and lines (#EAEAEE)")

        // Words that read where they sit: WCAG contrast, in both appearances.
        let pairs: [(String, NSColor, NSColor, Double)] = [
            ("ink on the ground", NS.ink, NS.ground, 7), ("ink on a surface", NS.ink, NS.surface, 7),
            ("muted on the ground", NS.muted, NS.ground, 4.5), ("muted on a surface", NS.muted, NS.surface, 4.5),
            ("faint on the ground", NS.faint, NS.ground, 3), ("accent text on the ground", NS.accentText, NS.ground, 4.5),
            ("accent text on a surface", NS.accentText, NS.surface, 4.5), ("a note's words on its page", NS.paperInk, NS.paper, 7),
            ("a note's muted words on its page", NS.paperMuted, NS.paper, 4.5), ("a note's links on its page", NS.accentText, NS.paper, 4.5),
            ("white on the accent", .white, NS.accent, 4.5),
            ("amber glyphs on the ground", NS.needsYou, NS.ground, 3), ("red glyphs on the ground", NS.live, NS.ground, 3),
            ("lavender glyphs on the ground", NS.agent, NS.ground, 3), ("green glyphs on the ground", NS.done, NS.ground, 3),
        ]
        for (label, front, back, minimum) in pairs {
            let ratios = [dark, light].map { Self.contrast(front.resolved(for: $0), back.resolved(for: $0)) }
            check(ratios.allSatisfy { $0 >= minimum },
                  "\(label) reads (\(ratios.map { String(format: "%.1f", $0) }.joined(separator: " and ")) to 1, at least \(minimum))")
        }
        // The dark page's faint words (placeholders, the Markdown on the line being edited); the light page keeps paper's.
        let faintOnPage = Self.contrast(NS.paperFaint.resolved(for: dark), NS.paper.resolved(for: dark))
        check(faintOnPage >= 3, "a note's faint words read on the dark page (\(String(format: "%.1f", faintOnPage)) to 1, at least 3)")
        // A binder's own words (a link, a toggle that's on, its chips' words, a note's links) read wherever they sit: on
        // its page, on a note's page, and on its chips, 16% of its colour over the page, the faintest of the three.
        for index in 0..<BinderPalette.nsColors.count {
            let ratios = [dark, light].map { appearance in
                let words = BinderPalette.nsTextColor(index).resolved(for: appearance)
                let page = Self.color(BinderPalette.wash(index), in: appearance)
                let chip = BinderPalette.nsColors[index].composited(over: page, opacity: 0.16)
                return [page, NS.paper.resolved(for: appearance), chip].map { Self.contrast(words, $0) }.min() ?? 0
            }
            let words = [dark, light].map { Self.hex(BinderPalette.nsTextColor(index).resolved(for: $0)) }.joined(separator: " and ")
            check(ratios.allSatisfy { $0 >= 4.5 }, "\(BinderPalette.names[index]) binder's words (\(words)) read on its page, a note's page and its "
                  + "chips (at worst \(ratios.map { String(format: "%.1f", $0) }.joined(separator: " and ")) to 1, at least 4.5)")
        }
        // Words on a binder's colour, a selected chip's: white on Indigo, as on the accent, and dark ink on the others,
        // with the count beside them a little lighter.
        for index in 0..<BinderPalette.nsColors.count {
            let fill = BinderPalette.nsColors[index], words = BinderPalette.nsWordsOn(index)
            let label = Self.contrast(words, fill), count = Self.contrast(words.withAlphaComponent(BinderPalette.countOpacity), fill)
            let expected: UInt32 = index == 0 ? 0xFFFFFF : 0x16132E
            check(Self.matches(words, expected) && label >= 4.5 && count >= 4.5,
                  "words on \(BinderPalette.names[index]) are \(Self.hex(expected)) and read (\(String(format: "%.1f", label)) to 1, its count "
                  + "\(String(format: "%.1f", count)), at least 4.5)")
        }

        // Drawn: what a view shows, sampled from its pixels.
        func swatch(_ style: some ShapeStyle) -> some View { Rectangle().fill(style).frame(width: 40, height: 40) }
        let sample = HStack(spacing: 0) {
            swatch(BindersTheme.ground)
            swatch(BindersTheme.ground).environment(\.colorScheme, .light)
            swatch(BindersTheme.ground).environment(\.colorScheme, .dark)
            Color.clear.frame(width: 40, height: 40).paperSheet(radius: 0)
            swatch(.tintFill).binderTint(3)
            swatch(.tintText).binderTint(3)
            Color.clear.frame(width: 40, height: 40).pageGround().binderTint(3)
            swatch(.tintText)
            swatch(.sectionInk).binderTint(3)
            swatch(StatusLabel.color(.ready)).binderTint(3)
            // On the note page, flat so no shadow falls on the swatch beside it: the window's own ground, and the words.
            swatch(BindersTheme.ground).paperSheet(radius: 0, raised: false)
            swatch(.foreground).paperSheet(radius: 0, raised: false)
            // What only tells you something, in a binder and outside one: words, then a chip's fill on a surface.
            swatch(.infoText).binderTint(3)
            swatch(.infoText)
            ZStack { swatch(BindersTheme.surface); swatch(.infoFill(0.18)) }.binderTint(3)
            ZStack { swatch(BindersTheme.surface); swatch(.infoFill(0.18)) }
            // Words on a selected chip: on Pink, on Indigo, and on the accent outside a binder.
            swatch(.onTintFill).binderTint(3)
            swatch(.onTintFill).binderTint(0)
            swatch(.onTintFill)
        }
        let points = (0..<19).map { CGPoint(x: 20 + $0 * 40, y: 20) }
        let darkPixels = await Self.pixels(of: sample, size: NSSize(width: 760, height: 40), appearance: dark, at: points)
        let lightPixels = await Self.pixels(of: sample, size: NSSize(width: 760, height: 40), appearance: light, at: points)
        check(Self.matches(darkPixels[0], 0x1C1C1E) && Self.matches(lightPixels[0], 0xFFFFFF), "the ground draws as itself in a dark window and in a light one")
        check(Self.matches(darkPixels[3], 0x1C1C1E) && Self.matches(lightPixels[3], 0xFFFFFF),
              "a note's page is dark in a dark window (\(Self.hex(darkPixels[3]))) and light paper in a light one (\(Self.hex(lightPixels[3])))")
        check(Self.matches(darkPixels[10], 0x1C1C1E) && Self.matches(lightPixels[10], 0xFFFFFF),
              "what's drawn on a note's page follows the window's appearance (the ground there draws \(Self.hex(darkPixels[10])) in a dark window)")
        check(Self.matches(darkPixels[11], 0xF2F2F3) && Self.matches(lightPixels[11], 0x111113), "a note's words are ink in the dark and paper ink in the light")
        check(Self.matches(darkPixels[4], 0xE65C94), "a binder's fill is its colour, in place of the accent")
        check(Self.close(darkPixels[5], Self.color(BinderPalette.textColor(3), in: dark)) && Self.close(lightPixels[5], Self.color(BinderPalette.textColor(3), in: light)),
              "a link in a binder wears its colour mixed with ink, in each appearance")
        check(Self.matches(darkPixels[8], 0xF2F2F3) && Self.matches(lightPixels[8], 0x111113), "a section's title in a binder is ink, not the binder's colour")
        check(Self.matches(darkPixels[9], 0xA1A1A8) && Self.matches(lightPixels[9], 0x5E5E66), "a status in a binder is muted, not the accent's colour")
        check(Self.matches(darkPixels[12], 0xA1A1A8) && Self.matches(lightPixels[12], 0x5E5E66)
              && Self.matches(darkPixels[13], 0xA996FF) && Self.matches(lightPixels[13], 0x5639E6),
              "what only tells you something is muted in a binder and the accent's words outside one")
        func over(_ fraction: CGFloat, of color: NSColor, in appearance: NSAppearance) -> NSColor {
            color.resolved(for: appearance).composited(over: NS.surface.resolved(for: appearance), opacity: fraction)
        }
        check(Self.close(darkPixels[14], over(0.07, of: NS.ink, in: dark)) && Self.close(lightPixels[14], over(0.07, of: NS.ink, in: light))
              && Self.close(darkPixels[15], over(0.18, of: NS.accent, in: dark)) && Self.close(lightPixels[15], over(0.18, of: NS.accent, in: light)),
              "its chip is a faint ink in a binder (\(Self.hex(lightPixels[14]))) and the accent's outside one (\(Self.hex(lightPixels[15])))")
        check(Self.matches(darkPixels[16], 0x16132E) && Self.matches(lightPixels[16], 0x16132E) && Self.matches(darkPixels[17], 0xFFFFFF)
              && Self.matches(darkPixels[18], 0xFFFFFF) && Self.matches(lightPixels[18], 0xFFFFFF),
              "a selected chip's words are dark ink on Pink, white on Indigo and white on the accent outside a binder")
        let washDark = NS.ground.resolved(for: dark).blended(withFraction: 0.03, of: BinderPalette.nsColors[3])!
        let washLight = NS.ground.resolved(for: light).blended(withFraction: 0.03, of: BinderPalette.nsColors[3])!
        check(Self.close(darkPixels[6], washDark) && Self.close(lightPixels[6], washLight),
              "a binder's page ground has a trace of its colour, 3% in both appearances (\(Self.hex(darkPixels[6])), \(Self.hex(lightPixels[6])))")
        check(Self.matches(darkPixels[7], 0xA996FF) && Self.matches(lightPixels[7], 0x5639E6), "accent-coloured words outside a binder are the accent's text colour")
        // A note's links and #tags wear the binder's colour on its pages, as its own links do, and the accent's elsewhere.
        let inBinder = await Self.editorColors(tint: 3), outside = await Self.editorColors(tint: nil)
        check(inBinder.link.map { same($0, BinderPalette.nsTextColor(3), in: dark) && same($0, BinderPalette.nsTextColor(3), in: light) } == true
              && outside.link.map { same($0, NS.accentText, in: dark) && same($0, NS.accentText, in: light) } == true,
              "a note's links are the binder's words in a binder (\(inBinder.link.map { Self.hex($0.resolved(for: light)) } ?? "none")) and the accent's "
              + "elsewhere (\(outside.link.map { Self.hex($0.resolved(for: light)) } ?? "none"))")
        check(inBinder.tag.map { Self.close($0, BinderPalette.nsColors[3]) && abs($0.alphaComponent - 0.1) < 0.01 } == true
              && outside.tag.map { Self.close($0, NS.accent) && abs($0.alphaComponent - 0.1) < 0.01 } == true,
              "a note's #tags are filled with the binder's colour in a binder and the accent elsewhere")
        // Small borderless controls, a menu and a button: grey on a binder's page, the accent elsewhere, as before.
        for (name, appearance) in [("dark", dark), ("light", light)] {
            let quiet = await Self.controlColour(tint: 3, appearance: appearance), loud = await Self.controlColour(tint: nil, appearance: appearance)
            check(quiet.menu < 0.2 && quiet.button < 0.2,
                  "a small menu and button on a binder's page are grey in the \(name), not its colour (colour \(String(format: "%.2f", quiet.menu)) and \(String(format: "%.2f", quiet.button)))")
            check(loud.menu > 0.3 && loud.button > 0.3,
                  "outside a binder they keep the accent in the \(name) (colour \(String(format: "%.2f", loud.menu)) and \(String(format: "%.2f", loud.button)))")
            // One labelled with words, such as "Delete Card…", is muted, which reads at 4.5:1 on the page.
            let worded = await Self.wordedControl(appearance: appearance)
            check(Self.close(worded, NS.muted.resolved(for: appearance), tolerance: 8),
                  "a small button with words on a binder's page is muted in the \(name) (\(Self.hex(worded)))")
        }
        // How AppKit colours follow a forced colour scheme decides what may be drawn on paper and on the Flow bar.
        print("INFO: the ground in a light colour scheme inside a dark window draws \(Self.hex(darkPixels[1])); in a dark one inside a light window, \(Self.hex(lightPixels[2]))")

        // The sheets to look at.
        for (name, appearance) in [("theme-dark", dark), ("theme-light", light)] {
            await Self.drawSheet(name: name, appearance: appearance, directory: directory)
        }
        print(tally.failures == 0 ? "THEME_OK" : "THEME_FAILED: \(tally.failures)")
        return tally.failures == 0 ? 0 : 1
    }

    /// The checks that failed, counted.
    private final class Tally {
        var failures = 0
    }

    // MARK: Helpers

    private static func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }

    private static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    private static func matches(_ color: NSColor, _ value: UInt32) -> Bool {
        close(color, BindersTheme.srgb(value))
    }

    /// Within a couple of steps in each channel, for colour management's rounding.
    private static func close(_ a: NSColor, _ b: NSColor, tolerance: CGFloat = 3) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        return abs(x.redComponent - y.redComponent) * 255 <= tolerance && abs(x.greenComponent - y.greenComponent) * 255 <= tolerance
            && abs(x.blueComponent - y.blueComponent) * 255 <= tolerance
    }

    /// A SwiftUI colour as it resolves in `appearance`.
    private static func color(_ color: Color, in appearance: NSAppearance) -> NSColor {
        NSColor(color).resolved(for: appearance)
    }

    /// WCAG 2 contrast between two opaque colours, or a translucent one laid over the second as a window draws it.
    private static func contrast(_ front: NSColor, _ back: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB) ?? color
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let over = front.withAlphaComponent(1).composited(over: back, opacity: front.alphaComponent)
        let (a, b) = (luminance(over), luminance(back))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// A note editor's colours as it styles a [[link]] and a #tag: on a binder's pages (`tint`), or elsewhere.
    @MainActor
    private static func editorColors(tint: Int?) async -> (link: NSColor?, tag: NSColor?) {
        let size = NSSize(width: 420, height: 160)
        let editor = MarkdownNoteEditor(text: .constant("See [[Launch]] and #launch"), fontSize: 15, paper: true)
            .paperSheet()
            .binderTint(tint)
            .frame(width: size.width, height: size.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: editor)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(400))
        defer { window.close() }
        func find(_ view: NSView) -> MarkdownTextView? {
            if let text = view as? MarkdownTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let storage = window.contentView.flatMap(find)?.textStorage else { return (nil, nil) }
        let string = storage.string as NSString
        let link = string.range(of: "Launch"), tag = string.range(of: "#launch")
        guard link.location != NSNotFound, tag.location != NSNotFound else { return (nil, nil) }
        return (storage.attribute(.foregroundColor, at: link.location, effectiveRange: nil) as? NSColor,
                storage.attribute(.backgroundColor, at: tag.location, effectiveRange: nil) as? NSColor)
    }

    /// How coloured a borderless menu's glyph and a borderless button's glyph draw, on a surface, on a binder's page
    /// (`tint`) or elsewhere: the widest spread between a pixel's channels, 0 for grey.
    @MainActor
    private static func controlColour(tint: Int?, appearance: NSAppearance) async -> (menu: Double, button: Double) {
        let controls = HStack(spacing: 0) {
            Menu { Button("Heading 1") {} } label: { Image(systemName: "textformat.size") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .quietControl()
                .frame(width: 60, height: 40)
            Button {} label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .quietControl()
                .frame(width: 60, height: 40)
        }
        .font(.system(size: 24, weight: .bold))
        .background(BindersTheme.surface)
        .binderTint(tint)
        let points = (0..<40).flatMap { y in (0..<120).map { x in CGPoint(x: x, y: y) } }
        let drawn = await Self.pixels(of: controls, size: NSSize(width: 120, height: 40), appearance: appearance, at: points)
        func spread(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB) ?? color
            let channels = [c.redComponent, c.greenComponent, c.blueComponent]
            return Double((channels.max() ?? 0) - (channels.min() ?? 0))
        }
        let menu = zip(points, drawn).filter { $0.0.x < 60 }.map { spread($0.1) }.max() ?? 0
        let button = zip(points, drawn).filter { $0.0.x >= 60 }.map { spread($0.1) }.max() ?? 0
        return (menu, button)
    }

    /// The ink of a borderless button labelled with words on a binder's page, on a surface: its most coloured pixel.
    @MainActor
    private static func wordedControl(appearance: NSAppearance) async -> NSColor {
        let control = Button("Delete") {}
            .buttonStyle(.borderless)
            .quietControl(words: true)
            .font(.system(size: 28, weight: .heavy))
            .frame(width: 160, height: 50)
            .background(BindersTheme.surface)
            .binderTint(3)
        let points = (0..<50).flatMap { y in (0..<160).map { x in CGPoint(x: x, y: y) } }
        let drawn = await Self.pixels(of: control, size: NSSize(width: 160, height: 50), appearance: appearance, at: points)
        let surface = BindersTheme.NS.surface.resolved(for: appearance)
        func distance(_ color: NSColor) -> CGFloat {
            guard let a = color.usingColorSpace(.sRGB), let b = surface.usingColorSpace(.sRGB) else { return 0 }
            return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
        }
        return drawn.max { distance($0) < distance($1) } ?? surface
    }

    /// Draws `view` in an offscreen window of `appearance` and reads the colour at each point (top-left origin).
    @MainActor
    private static func pixels<Content: View>(of view: Content, size: NSSize, appearance: NSAppearance, at points: [CGPoint]) async -> [NSColor] {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.appearance = appearance
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        defer { window.close() }
        let width = Int(size.width), height = Int(size.height)
        guard let layer = hosting.layer, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return points.map { _ in .clear } }
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        appearance.performAsCurrentDrawingAppearance { layer.render(in: context) }
        guard let data = context.data else { return points.map { _ in .clear } }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return points.map { point in
            // The context's rows run from the top.
            let row = min(max(Int(point.y), 0), height - 1), column = min(max(Int(point.x), 0), width - 1)
            let offset = (row * width + column) * 4
            let alpha = max(CGFloat(bytes[offset + 3]) / 255, 0.001)
            return NSColor(srgbRed: CGFloat(bytes[offset]) / 255 / alpha, green: CGFloat(bytes[offset + 1]) / 255 / alpha,
                           blue: CGFloat(bytes[offset + 2]) / 255 / alpha, alpha: 1)
        }
    }

    @MainActor
    private static func drawSheet(name: String, appearance: NSAppearance, directory: URL) async {
        let size = NSSize(width: 1180, height: 820)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.appearance = appearance
        let hosting = NSHostingView(rootView: ThemeSheet().frame(width: size.width, height: size.height))
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(900))
        appearance.performAsCurrentDrawingAppearance { capture(hosting, name: name, directory: directory) }
        window.close()
    }
}

/// Every token, the status styles, badges, a card, the note page and each binder's tint, to look at in one picture.
private struct ThemeSheet: View {
    private let tokens: [(String, Color)] = [
        ("ground", BindersTheme.ground), ("ground2", BindersTheme.ground2), ("surface", BindersTheme.surface), ("surface2", BindersTheme.surface2),
        ("paper", BindersTheme.paper), ("ink", BindersTheme.ink), ("muted", BindersTheme.muted), ("faint", BindersTheme.faint),
        ("line", BindersTheme.lineStrong), ("accent", BindersTheme.accent), ("accentText", BindersTheme.accentText),
        ("needsYou", BindersTheme.needsYou), ("live", BindersTheme.live), ("agent", BindersTheme.agent), ("done", BindersTheme.done),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Binders").font(BindersTheme.title(30))
            HStack(spacing: 8) {
                ForEach(tokens, id: \.0) { name, color in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color).frame(width: 62, height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BindersTheme.line))
                        Text(name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Open to-dos").font(BindersTheme.columnTitle)
                    Text("Body text in ink, with muted secondary words.").foregroundStyle(.primary)
                    Text("Secondary, muted").foregroundStyle(.secondary)
                    Text("Tertiary, faint").foregroundStyle(.tertiary)
                    Text("“Remind me to call the dentist on Friday”").font(BindersTheme.quote())
                    Text("09:41 · 12 min").font(BindersTheme.time(.body))
                    Text("15").font(BindersTheme.count(28))
                    HStack(spacing: 6) {
                        Badge(text: "Recording", symbol: "record.circle", color: BindersTheme.live)
                        Badge(text: "overdue", symbol: "clock", color: BindersTheme.needsYou)
                        Badge(text: "Failed", symbol: BindersTheme.problemSymbol, color: BindersTheme.ink)
                        Badge(text: "3 open", color: BindersTheme.accentText)
                        Badge(text: "Imported")
                    }
                }
                .frame(width: 330, alignment: .leading)
                .paperCard(padding: 16)
                VStack(alignment: .leading, spacing: 8) {
                    StatusLabel("Ready", .ready)
                    StatusLabel("Couldn't reach the model server", .problem)
                    StatusLabel("Paused: agents can't take cards", .waiting)
                    StatusLabel("Waiting for your answer", .needsYou, symbol: "questionmark.bubble")
                    StatusLabel("Done", .done)
                    StatusLabel("Recording", .live)
                    Label("By Claude Code", systemImage: BindersTheme.agentSymbol).foregroundStyle(BindersTheme.agent)
                    Label("Ask", systemImage: BindersTheme.askSymbol).foregroundStyle(.tintText)
                    HStack(spacing: 6) {
                        OwnerChip(name: TranscriptSegment.you)
                        OwnerChip(name: "Sam")
                        Image(systemName: "checklist").foregroundStyle(.infoText)
                    }
                    Button("Approve") {}.buttonStyle(.borderedProminent)
                }
                .frame(width: 300, alignment: .leading)
                .paperCard(padding: 16)
                VStack(alignment: .leading, spacing: 6) {
                    Text("# Launch checklist").font(.system(size: 17, weight: .bold))
                    Text("The note page: light paper in the light, a dark page in the dark.")
                    Text("Muted words on the page").foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(width: 300, height: 150, alignment: .topLeading)
                .paperSheet()
            }
            HStack(spacing: 10) {
                ForEach(0..<BinderPalette.colors.count, id: \.self) { index in
                    // What a binder's page wears: its mark by its name, titles in ink, its colour on a link and on what's
                    // selected with words that read on it, what only tells you something neutral, a trace of it in the
                    // ground.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(BinderPalette.color(index)).frame(width: 10, height: 10)
                            Text(BinderPalette.names[index]).font(BindersTheme.cardTitle)
                        }
                        Text("To-dos").font(.callout.weight(.semibold)).foregroundStyle(.sectionInk)
                        Text("Open the meeting").font(.caption).foregroundStyle(.tintText)
                        Capsule().fill(.tintFill).frame(height: 18)
                            .overlay(HStack(spacing: 4) {
                                Text("Everyone")
                                Text("8").foregroundStyle(OnTintFill(secondary: true))
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.onTintFill))
                        HStack(spacing: 5) {
                            OwnerChip(name: TranscriptSegment.you)
                            Image(systemName: "checklist").foregroundStyle(.infoText)
                        }
                        Text("8 open").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(width: 128, alignment: .leading)
                    .pageGround()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(BindersTheme.line))
                    .binderTint(index)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .pageGround()
    }
}
