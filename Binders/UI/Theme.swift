import AppKit
import SwiftUI

/// The Binders look: the indigo from the icon as the accent, paper surfaces with a hairline edge, rounded display type.
enum BindersTheme {
    static let accent = Color(red: 0.376, green: 0.298, blue: 0.957)
    static let accentDeep = Color(red: 0.133, green: 0.094, blue: 0.431)

    /// Page titles: rounded and a little tighter than the system large title.
    static func title(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static let columnTitle = Font.system(size: 20, weight: .semibold, design: .rounded)

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

/// A paper-coloured surface with a hairline edge, for cards and panels.
struct PaperCard: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

extension View {
    func paperCard(padding: CGFloat = 14, radius: CGFloat = 12) -> some View {
        modifier(PaperCard(padding: padding, radius: radius))
    }
}
