import AppKit
import SwiftUI
import BindersKit

// The card's own look: a card identity panel over the conversation, messages that read as a conversation rather than a log,
// a needs-you callout, and a details panel that belongs to the card. The board's cards open into this, so the two surfaces
// share type, colour and motion, while the card keeps its own reading width and layout.

enum CardDesign {
    // MARK: Type

    static let title = Font.system(size: 24, weight: .heavy, design: .rounded)
    static let chip = Font.system(size: 12, weight: .medium)
    static let chipStrong = Font.system(size: 12, weight: .semibold)
    static let meta = Font.system(size: 11, weight: .medium)
    static let message = Font.system(size: 14)
    static let messageHeader = Font.system(size: 12, weight: .semibold)
    static let sectionTitle = Font.system(size: 12, weight: .semibold)
    static let panelTitle = Font.system(size: 16, weight: .heavy, design: .rounded)

    // MARK: Shape

    static let panelRadius: CGFloat = 16
    static let chipRadius: CGFloat = 9
    static let bubbleRadius: CGFloat = 12
    static let avatarSize: CGFloat = 26

    // MARK: Motion

    static let hover = Animation.snappy(duration: 0.16)
    static let settle = Animation.snappy(duration: 0.2)
    static let drop = Animation.spring(duration: 0.3, bounce: 0.18)
}

/// The card's identity panel: the surface it sits on, with the binder's colour on its leading edge.
extension View {
    func cardIdentityPanel() -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: CardDesign.panelRadius, style: .continuous)
                    .fill(BindersTheme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: CardDesign.panelRadius, style: .continuous)
                    .strokeBorder(BindersTheme.line)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(TintFill().opacity(0.45))
                    .frame(width: 3)
                    .padding(.vertical, 12)
                    .padding(.leading, 1)
            }
            .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
    }

    /// A message or a callout's surface: opaque, edged, and never glass.
    func cardBubble(fill: Color = BindersTheme.surface2, edge: Color = BindersTheme.line) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: CardDesign.bubbleRadius, style: .continuous).fill(fill))
            .overlay {
                RoundedRectangle(cornerRadius: CardDesign.bubbleRadius, style: .continuous)
                    .strokeBorder(edge)
            }
    }
}

/// An agent, you or Binders in the conversation: a soft square with its glyph, so a message says who it's from at a glance.
struct CardAvatar: View {
    enum Kind { case agent, you, binders }

    let kind: Kind
    var size: CGFloat = CardDesign.avatarSize

    var body: some View {
        let (symbol, color) = look
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.opacity(0.14))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var look: (String, Color) {
        switch kind {
        case .agent: (BindersTheme.agentSymbol, BindersTheme.agent)
        case .you: ("person.fill", BindersTheme.ink)
        case .binders: ("info.circle.fill", BindersTheme.muted)
        }
    }
}

/// A card chip: its glyph in its colour, its words, a small chevron when it opens a menu. Under the pointer it lifts its
/// fill a little, so every chip on the card says it can be pressed.
struct CardChipLabel: View {
    var glyph: String?
    var glyphColor: Color = BindersTheme.muted
    let words: String
    var trailing: String?
    var fill: Color = BindersTheme.ink.opacity(0.07)
    var edge: Color = BindersTheme.line
    var opens = true
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(glyphColor)
                    .accessibilityHidden(true)
            }
            Text(words)
                .font(CardDesign.chip)
                .foregroundStyle(BindersTheme.ink)
                .lineLimit(1)
            if let trailing {
                Text(trailing)
                    .font(CardDesign.meta)
                    .monospacedDigit()
                    .foregroundStyle(BindersTheme.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            if opens {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(BindersTheme.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: CardDesign.chipRadius, style: .continuous)
            .fill(hovering ? fill.opacity(0.16) : fill))
        .overlay {
            RoundedRectangle(cornerRadius: CardDesign.chipRadius, style: .continuous)
                .strokeBorder(hovering ? BindersTheme.lineStrong : edge)
        }
        .contentShape(RoundedRectangle(cornerRadius: CardDesign.chipRadius, style: .continuous))
        .onHover { inside in
            withAnimation(CardDesign.hover) { hovering = inside }
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

/// A section's title in the card's Details panel.
struct CardSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(CardDesign.sectionTitle)
            .foregroundStyle(BindersTheme.muted)
            .padding(.top, 2)
    }
}
