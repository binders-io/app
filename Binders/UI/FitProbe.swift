import AppKit
import SwiftUI

/// Where a control is drawn in its window, for the window-fit self-test (--selftest-window-fit): an empty view behind the
/// control, found by name, whose frame AppKit gives in the window's own coordinates whichever of the window's columns it's
/// in. Off unless a self-test turns it on before the views are made, so the app never makes one.
@MainActor
enum FitProbe {
    static var isOn = false
    private static var probes: [(name: String, view: WeakView)] = []

    fileprivate final class WeakView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    fileprivate static func add(_ view: NSView, name: String) {
        probes.removeAll { $0.view.view == nil }
        probes.append((name, WeakView(view)))
    }

    /// The frames, in `window`'s coordinates (origin at the bottom left), of the probes named `name` that are drawn in it
    /// and not hidden.
    static func frames(_ name: String, in window: NSWindow) -> [NSRect] {
        probes.compactMap { probe in
            guard probe.name == name, let view = probe.view.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return view.convert(view.bounds, to: nil)
        }
    }

    /// Every probe drawn in `window`, by name. Inside a scroll view, only the part of a probe within the scroll view's
    /// height counts, and one scrolled wholly out of sight is left out: scrolling brings it in (a page that opens on a
    /// later part of a long form, such as Settings). Its width is never cut, so a control too wide for the window still
    /// shows as outside it.
    static func all(in window: NSWindow) -> [(name: String, frame: NSRect)] {
        probes.compactMap { probe in
            guard let view = probe.view.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
            var frame = view.convert(view.bounds, to: nil)
            if let scroll = view.enclosingScrollView {
                let shown = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
                let top = min(frame.maxY, shown.maxY), bottom = max(frame.minY, shown.minY)
                guard top > bottom else { return nil }
                frame.origin.y = bottom
                frame.size.height = top - bottom
            }
            return (probe.name, frame)
        }
    }
}

private struct FitProbeView: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        FitProbe.add(view, name: name)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

extension View {
    /// Names this control for the window-fit self-test, which checks that it lies inside the window. Nothing at all outside
    /// that test, nor for an empty name.
    @ViewBuilder
    func fitProbe(_ name: String) -> some View {
        if FitProbe.isOn, !name.isEmpty {
            background(FitProbeView(name: name).allowsHitTesting(false).accessibilityHidden(true))
        } else {
            self
        }
    }
}
