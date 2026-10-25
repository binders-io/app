import AppKit
import SwiftUI
import BindersKit

// The board's own look: larger, tighter cards; columns that read as one surface; a card that lifts as it's dragged and a
// slot that says where it will land; a group header that belongs to a note, with the way back to it. Motion is short and
// springy, and every move respects Reduce Motion through BindersTheme.motion.

/// Board sizes, colours and motion, so the board, its group headers and the note's Work bar share one language.
enum BoardDesign {
    // MARK: Shape

    static let columnRadius: CGFloat = 16
    static let cardRadius: CGFloat = 13
    static let groupRadius: CGFloat = 10
    static let cardHorizontalInset: CGFloat = 12
    static let cardVerticalInset: CGFloat = 10
    static let cardGap: CGFloat = 8

    // MARK: Type

    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let cardMeta = Font.system(size: 11, weight: .semibold)
    static let columnTitle = Font.system(size: 16, weight: .heavy, design: .rounded)
    static let columnCount = Font.system(size: 11.5, weight: .heavy, design: .rounded).monospacedDigit()
    static let groupTitle = Font.system(size: 13.5, weight: .semibold)
    static let panelTitle = Font.system(size: 16, weight: .heavy, design: .rounded)
    static let panelRowTitle = Font.system(size: 13.5, weight: .semibold)
    static let panelMeta = Font.system(size: 11, weight: .medium)

    // MARK: Motion

    /// A card lifting under the pointer, or a column answering one.
    static let lift = Animation.spring(duration: 0.24, bounce: 0.18)
    /// A card landing in its column, or a group opening.
    static let drop = Animation.spring(duration: 0.32, bounce: 0.22)
    /// Hover, selection and small state changes: quick enough to feel immediate.
    static let settle = Animation.snappy(duration: 0.18)
    /// A short answer on a column after a drop.
    static let flash = Animation.easeOut(duration: 0.22)

    // MARK: Meaning

    /// The glyph a column wears. Semantic colours always come with it, as everywhere else in Binders.
    static func symbol(_ column: BoardColumn) -> String {
        switch column {
        case .backlog: "tray.full.fill"
        case .ready: "arrow.up.right.circle.fill"
        case .inProgress: "bolt.fill"
        case .blocked: "pause.circle.fill"
        case .review: "eye.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    /// A column's colour: neutral for work for later and work ready to pick up, lavender while an agent works, amber where
    /// it waits on you, green once it's done. Never a colour on its own: the glyph says what it means.
    static func accent(_ column: BoardColumn) -> Color {
        switch column {
        case .backlog: BindersTheme.faint
        case .ready: BindersTheme.muted
        case .inProgress: BindersTheme.agent
        case .blocked, .review: BindersTheme.needsYou
        case .done: BindersTheme.done
        }
    }

    /// What a column's colour means, for a column that needs you: the tint behind a drop, a header's mark.
    static func needsYou(_ column: BoardColumn) -> Bool {
        column == .blocked || column == .review
    }

    static func emptyHint(_ column: BoardColumn) -> String {
        switch column {
        case .backlog: "Ideas and work for later"
        case .ready: "Ready for someone, or some agent, to pick up"
        case .inProgress: "Being worked on"
        case .blocked: "Waiting for an answer"
        case .review: "Finished, waiting for you to check"
        case .done: "Nothing finished yet"
        }
    }

    /// The well a column sits in: a shade of ink, a trace of its own colour at the top, and, while a card is over it, the
    /// tint of what you act on (the binder's colour on its pages) and an edge that says it will take it.
    static func columnFill(_ column: BoardColumn, targeted: Bool, tint: Color) -> AnyShapeStyle {
        if targeted { return AnyShapeStyle(tint.opacity(0.16)) }
        let accent = accent(column)
        return AnyShapeStyle(LinearGradient(colors: [accent.opacity(0.05), BindersTheme.ink.opacity(0.035)],
                                            startPoint: .top, endPoint: .bottom))
    }

    static func columnBorder(_ column: BoardColumn, targeted: Bool, tint: Color) -> Color {
        targeted ? tint.opacity(0.75) : BindersTheme.line
    }
}

// MARK: - A card's chrome

/// A small capsule on a card or in the Work panel: a state, a due date, who has it. Its colour carries its glyph.
struct BoardPill: View {
    let text: String
    var symbol: String? = nil
    var color: Color = BindersTheme.muted
    var strong = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(text).lineLimit(1)
        }
        .font(BoardDesign.cardMeta)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(strong ? 0.18 : 0.10)))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

/// The coloured mark a column wears: its glyph in a soft square, never a colour without one.
struct BoardColumnMark: View {
    let column: BoardColumn
    var size: CGFloat = 24

    var body: some View {
        let accent = BoardDesign.accent(column)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(accent.opacity(0.14))
            .overlay {
                Image(systemName: BoardDesign.symbol(column))
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// What is dragged: one card, or a stack of the chosen ones, lifted a little and turned as a hand would hold it.
struct BoardDragPreview: View {
    let titles: [String]
    let column: BoardColumn

    var body: some View {
        let shown = Array(titles.prefix(3))
        let accent = BoardDesign.accent(column)
        ZStack(alignment: .topLeading) {
            ForEach(Array(shown.indices).reversed(), id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(accent)
                            .frame(width: 3, height: 16)
                        Text(shown[index])
                            .font(BoardDesign.cardTitle)
                            .foregroundStyle(BindersTheme.ink)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if index == 0, titles.count > 1 {
                        Text("\(titles.count) cards")
                            .font(BoardDesign.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, BoardDesign.cardHorizontalInset)
                .padding(.vertical, BoardDesign.cardVerticalInset)
                .frame(width: 226, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BoardDesign.cardRadius, style: .continuous).fill(BindersTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: BoardDesign.cardRadius, style: .continuous).strokeBorder(accent.opacity(0.5)))
                .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
                .offset(x: CGFloat(index) * 6, y: CGFloat(index) * 6)
                .rotationEffect(.degrees(Double(index) * -1.2))
                .opacity(index == 0 ? 1 : 0.88)
            }
        }
        .frame(width: 226, alignment: .topLeading)
    }
}

/// Where a dragged card will land: a slot at the top of the column it's over, saying what will move there. The board
/// puts a moved card at the top of its column, so the slot is the truth, not a guess.
struct BoardDropSlot: View {
    let column: BoardColumn
    let titles: [String]

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 11, weight: .bold))
            Text(line)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .opacity(0.7)
        }
        .foregroundStyle(.tintText)
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BoardDesign.groupRadius, style: .continuous).fill(TintFill().opacity(0.12)))
        .overlay {
            RoundedRectangle(cornerRadius: BoardDesign.groupRadius, style: .continuous)
                .strokeBorder(TintFill().opacity(0.65), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
        }
        .transition(.scale(scale: 0.94).combined(with: .opacity))
        .accessibilityLabel("\(column.title): \(line)")
    }

    private var line: String {
        if titles.count > 1 { return "Move \(titles.count) cards here" }
        guard let title = titles.first else { return "Drop here" }
        return "Move “\(title.count > 28 ? String(title.prefix(28)) + "…" : title)” here"
    }
}

/// An empty column: a quiet well that says what goes there, instead of a bare gap.
struct BoardEmptyColumn: View {
    let column: BoardColumn

    var body: some View {
        let accent = BoardDesign.accent(column)
        VStack(spacing: 7) {
            Image(systemName: BoardDesign.symbol(column))
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(accent.opacity(0.75))
            Text(BoardDesign.emptyHint(column))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 78)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: BoardDesign.groupRadius, style: .continuous).fill(accent.opacity(0.035)))
        .overlay {
            RoundedRectangle(cornerRadius: BoardDesign.groupRadius, style: .continuous)
                .strokeBorder(accent.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .transition(.opacity)
    }
}

extension View {
    /// A card's surface: opaque, with an edge, and a shadow only while it's lifted or under the pointer.
    func boardCardSurface(radius: CGFloat = BoardDesign.cardRadius, hovered: Bool, lifted: Bool, accent: Color?) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(BindersTheme.surface)
                    .overlay(alignment: .top) {
                        if let accent {
                            LinearGradient(colors: [accent.opacity(hovered ? 0.10 : 0.04), .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(hovered || lifted ? BindersTheme.lineStrong : BindersTheme.line,
                                  lineWidth: hovered || lifted ? 1.2 : 1)
            }
            .shadow(color: .black.opacity(lifted ? 0.22 : hovered ? 0.12 : 0.04),
                    radius: lifted ? 14 : hovered ? 7 : 1.5,
                    y: lifted ? 8 : hovered ? 3 : 1)
    }
}
