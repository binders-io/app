import AppKit
import SwiftUI
import BindersKit

// Lane DS9: the Distill button in every note's toolbar, and the stage the note page draws Distill's motion on: the cards
// that lift out of the note as their items are found and fly into the Distill list, or into the button when the list is
// closed. A reading in the background stays quiet: the button only counts what it found.

// MARK: - The button

/// One prominent button, in the same place in every note: the wand and "Distill" on the accent. While you read the note it
/// says so, a ring turning round its wand and the count ticking up, with Cancel under the pointer; "3 new" when readings in
/// the background found items; "Up to date" for a moment when nothing changed. A click opens the list.
struct DistillButton: View {
    @Environment(DictationController.self) private var controller
    let note: NoteItem
    /// In the note's own window.
    var popout = false
    /// Short of room in the toolbar: the wand alone, on the accent.
    var compact = false
    @Environment(\.toolbarIconsOnly) private var iconsOnly
    @State private var hovering = false
    @State private var bump = 0
    @ReducedMotion private var reduceMotion

    var body: some View {
        // A note in a binder linked to a hub is distilled there, by the hub.
        if MCPServer.hubPlace(note.binderID) == nil { button }
    }

    @ViewBuilder private var button: some View {
        let compact = compact || iconsOnly
        let service = controller.distill
        let list = service.list(for: note.id)
        let reading = service.reading.contains(note.id) && !service.quietReading.contains(note.id)
        let face = DistillButtonFace.face(reading: reading ? service.readingItems[note.id] ?? 0 : nil,
                                          newItems: list.newItems.count, upToDateUntil: list.upToDateUntil)
        HStack(spacing: 0) {
            Button { DistillActions.press(note, controller: controller, popout: popout) } label: {
                DistillButtonFace_(face: face, compact: compact, reading: reading, reduceMotion: reduceMotion, bump: bump)
            }
            .buttonStyle(DistillButtonStyle(hovering: hovering))
            .help(help(face))
            .accessibilityLabel(face.spoken)
            if reading, hovering, !compact {
                Button { service.stopReading(note.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .heavy))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(BindersTheme.ink.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .help("Cancel: stop reading. The items found so far stay in the list.")
                .accessibilityLabel("Cancel Distill")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .fixedSize()
        .onHover { inside in withAnimation(BoardDesign.settle) { hovering = inside } }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: DistillButtonFrame.self, value: proxy.frame(in: .named(DistillStage.space)))
        })
        // A card that flew into the button: the count ticks and the button nods.
        .onChange(of: list.launches.count) { before, after in
            if after < before { bump += 1 }
        }
        // "Up to date" goes after its moment.
        .task(id: list.upToDateUntil) {
            guard let until = list.upToDateUntil, until > Date() else { return }
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow + 0.05))
            bump += 1
        }
        .fitProbe("distill.button")
    }

    private func help(_ face: DistillButtonFace) -> String {
        switch face {
        case .idle:
            note.distill ? "Distill: read what changed in the note into work items, in the list beside it (⇧⌘D). Nothing reaches the board until you accept it."
                : "Distill: read the note into work items, in a list beside it (⇧⌘D). Nothing reaches the board until you accept it."
        case .reading: "Distilling the note: click to see the items as they're found. Cancel stops it, keeping them."
        case .new(let count): "\(count == 1 ? "1 new item" : "\(count) new items") from what you wrote, read in the background. Click to see them."
        case .upToDate: "Nothing changed since the note was last read, so the list shows what was kept."
        }
    }
}

/// The button's face: the wand (in a turning ring while it reads), its words, and the count so far.
private struct DistillButtonFace_: View {
    let face: DistillButtonFace
    let compact: Bool
    let reading: Bool
    let reduceMotion: Bool
    let bump: Int

    var body: some View {
        HStack(spacing: 6) {
            DistillWand(reading: reading, reduceMotion: reduceMotion)
            if !compact {
                Text(face.title)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                    .lineLimit(1)
                if case .reading(let items) = face, items > 0 {
                    Text("\(items)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.22)))
                        .contentTransition(.numericText(value: Double(items)))
                        .animation(BindersTheme.motion(BoardDesign.settle, reduced: reduceMotion), value: items)
                }
            }
        }
        .padding(.horizontal, compact ? 6 : 11)
        .frame(height: 26)
        .frame(minWidth: compact ? 26 : nil)
        .keyframeAnimator(initialValue: 1.0, trigger: bump) { content, scale in
            content.scaleEffect(reduceMotion ? 1 : scale)
        } keyframes: { _ in
            SpringKeyframe(1.08, duration: 0.12)
            SpringKeyframe(1.0, duration: 0.25)
        }
    }
}

/// The wand, and while the note is read, a ring of light turning round it.
private struct DistillWand: View {
    let reading: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if reading {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                    Circle()
                        .strokeBorder(AngularGradient(colors: [.white.opacity(0), .white.opacity(0.35), .white], center: .center), lineWidth: 2)
                        .rotationEffect(.degrees(turn * 360))
                }
                .frame(width: 19, height: 19)
                .transition(.opacity)
            }
            Image(systemName: BindersTheme.modelSymbol)
                .font(.system(size: reading ? 9.5 : 12, weight: .bold))
        }
        .frame(width: 19, height: 19)
        .animation(BoardDesign.settle, value: reading)
        .accessibilityHidden(true)
    }
}

/// The accent, filled, with a soft glow of itself under it: larger than the toolbar's icons, and pressed a little smaller.
private struct DistillButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.onTintFill)
            .background {
                Capsule()
                    .fill(TintFill())
                    .overlay {
                        // Light from above, so it reads as a button and not a badge.
                        Capsule().fill(LinearGradient(colors: [.white.opacity(hovering ? 0.22 : 0.16), .clear, .black.opacity(0.08)],
                                                      startPoint: .top, endPoint: .bottom))
                    }
                    .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                    .shadow(color: Color(nsColor: BindersTheme.NS.accent).opacity(hovering ? 0.45 : 0.30), radius: hovering ? 7 : 4, y: 2)
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(BoardDesign.settle, value: configuration.isPressed)
    }
}

// MARK: - The stage

/// Where a note page draws Distill's motion: what the flying cards need to know, where the note's lines are (its editor),
/// where each row of the list is, and the button. Frames are in the stage's space (`space`), which its anchor shares.
@MainActor
final class DistillStage {
    static let space = "DistillStage"
    weak var editor: MarkdownTextView?
    weak var anchor: NSView?
    var rows: [UUID: CGRect] = [:]
    var viewport: CGRect?
    var button: CGRect?
    /// Whether the list shows now: cards fly into its rows, or else into the button.
    var listShown = false

    /// Where a card lifts off for `id`: the start of its first line in the note; out of sight, the edge of what shows.
    func source(for id: UUID) -> CGRect? {
        guard let editor, let anchor, editor.window != nil, anchor.window === editor.window else { return nil }
        let visible = editor.visibleRect
        var rect = editor.distillRect(for: id) ?? NSRect(x: visible.minX + 40, y: visible.midY, width: 200, height: 20)
        if rect.maxY < visible.minY { rect.origin.y = visible.minY + 8 }
        if rect.minY > visible.maxY { rect.origin.y = visible.maxY - rect.height - 8 }
        rect.size.width = min(rect.width, 280)
        return anchor.convert(rect, from: editor)
    }

    /// Where a card lands for `id`: its row, kept inside the list's view; or the button.
    func target(for id: UUID) -> CGRect? {
        if listShown, var row = rows[id] {
            if let viewport {
                row.origin.y = min(max(row.minY, viewport.minY), max(viewport.minY, viewport.maxY - row.height))
            }
            return row
        }
        return button
    }
}

/// The stage's anchor: a flipped view behind the page, whose coordinates are the stage's, for turning the editor's rects
/// into the stage's.
struct DistillStageAnchor: NSViewRepresentable {
    let stage: DistillStage

    final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        stage.anchor = view
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        stage.anchor = view
    }
}

extension View {
    /// The note page's stage for Distill: the flying cards drawn over it, the list and button's frames gathered.
    func distillStage(_ stage: DistillStage, note: NoteItem, listShown: Bool) -> some View {
        modifier(DistillStageHost(stage: stage, note: note, listShown: listShown))
    }
}

private struct DistillStageHost: ViewModifier {
    @Environment(DictationController.self) private var controller
    let stage: DistillStage
    let note: NoteItem
    let listShown: Bool

    func body(content: Content) -> some View {
        let service = controller.distill
        content
            .background(DistillStageAnchor(stage: stage))
            .overlay { DistillFlightsOverlay(note: note.id, stage: stage).allowsHitTesting(false) }
            .coordinateSpace(name: DistillStage.space)
            .onPreferenceChange(DistillRowFrames.self) { frames in MainActor.assumeIsolated { stage.rows = frames } }
            .onPreferenceChange(DistillViewportFrame.self) { frame in MainActor.assumeIsolated { stage.viewport = frame } }
            .onPreferenceChange(DistillButtonFrame.self) { frame in MainActor.assumeIsolated { stage.button = frame } }
            .onAppear { stage.listShown = listShown }
            .onChange(of: listShown) { _, shown in stage.listShown = shown }
            .onChange(of: service.reading.contains(note.id)) { _, reading in
                if !reading { service.list(for: note.id).proposalMade(service: service, undo: nil) }
            }
    }
}

// MARK: - Flying cards

/// The cards in flight, drawn above the page while there are any: each lifts out of its lines, arcs over to its row in the
/// list (or the button) and settles into it. Under Reduce Motion, none: the rows fade in.
struct DistillFlightsOverlay: View {
    @Environment(DictationController.self) private var controller
    let note: UUID
    let stage: DistillStage
    @ReducedMotion private var reduceMotion

    var body: some View {
        let list = controller.distill.list(for: note)
        if !list.launches.isEmpty, !reduceMotion {
            TimelineView(.animation) { _ in
                let now = DistillMotion.now()
                ZStack(alignment: .topLeading) {
                    ForEach(list.launches) { launch in
                        if let flight = Self.flight(launch, stage: stage, now: now) {
                            DistillFlyingCard(title: launch.title, color: launch.color, toButton: flight.toButton, progress: flight.t)
                                .frame(width: flight.frame.width, height: flight.frame.height)
                                .scaleEffect(flight.scale)
                                .rotationEffect(.degrees(flight.tilt))
                                .opacity(flight.opacity)
                                .position(x: flight.frame.midX, y: flight.frame.midY)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Where a card is at `now`: its frame along the curve, how big, how tilted and how clear.
    struct Flight {
        var frame: CGRect
        var scale: CGFloat
        var tilt: Double
        var opacity: Double
        var t: Double
        var toButton: Bool
    }

    static func flight(_ launch: DistillListModel.Launch, stage: DistillStage, now: Date) -> Flight? {
        guard now >= launch.start, let from = stage.source(for: launch.id) else { return nil }
        let toButton = !stage.listShown || stage.rows[launch.id] == nil
        guard let to = stage.target(for: launch.id) else { return nil }
        let t = DistillFlights.progress(started: launch.start, now: now)
        let raw = min(1, max(0, now.timeIntervalSince(launch.start) / DistillFlights.duration))
        // It starts as a small card at the start of its line, and ends the size of its row (or shrinks into the button).
        let start = CGSize(width: min(max(from.width, 150), 230), height: 34)
        let end = toButton ? CGSize(width: to.width * 0.7, height: to.height * 0.8) : to.size
        let size = CGSize(width: start.width + (end.width - start.width) * t, height: start.height + (end.height - start.height) * t)
        // It rises out of its line: from just above it.
        let a = CGPoint(x: from.minX + start.width / 2, y: from.midY - min(18, from.height * 0.7))
        let b = CGPoint(x: to.midX, y: to.midY)
        let lift = 50 + min(140, hypot(b.x - a.x, b.y - a.y) * 0.18)
        let centre = DistillFlights.point(from: a, to: b, lift: lift, t: t)
        // Lifted off the page, a little larger, then settling to its row's size.
        let rise = sin(.pi * min(1, raw * 1.15))
        let grow = min(1, raw / 0.18)
        let scale = 0.86 + 0.14 * CGFloat(grow) + 0.05 * CGFloat(rise) - (toButton ? 0.6 * CGFloat(t * t) : 0)
        let tilt = -3.5 * rise * (b.x >= a.x ? 1 : -1)
        // Into the button: it's gone before it reaches the button's words.
        let opacity = min(1, raw / 0.07) * (toButton ? max(0, 1 - max(0, raw - 0.55) / 0.33) : 1)
        return Flight(frame: CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height),
                      scale: scale, tilt: tilt, opacity: opacity, t: t, toButton: toButton)
    }
}

/// A card in flight: the row it becomes, title and all, in the colour of who it's for.
struct DistillFlyingCard: View {
    let title: String
    let color: Color
    let toButton: Bool
    let progress: Double

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(title)
                .font(BoardDesign.panelRowTitle)
                .foregroundStyle(BindersTheme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(BindersTheme.surface))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.16 * (1 - progress)), .clear], startPoint: .leading, endPoint: .trailing))
        }
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(color.opacity(0.55)) }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 2.5).padding(.vertical, 9).padding(.leading, 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: color.opacity(0.35 * (1 - progress)), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.18 * sin(.pi * progress)), radius: 14, y: 8)
    }
}
