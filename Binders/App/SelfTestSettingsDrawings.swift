import AppKit
import SwiftUI

/// Settings → Team, and sheets on their own, drawn for the self-tests.
extension SelfTest {
    /// Settings → Team in a window 1020 pt wide (and `height` tall, the whole page by default), drawn to `directory` as
    /// `name`.png when one is given; the controls it showed, by their probes' names.
    @MainActor
    static func teamSettingsDrawn(controller: DictationController, name: String, directory: URL?, height: CGFloat = 2400) async -> Set<String> {
        let wasOn = FitProbe.isOn
        FitProbe.isOn = true
        defer { FitProbe.isOn = wasOn }
        let navigation = HubNavigation()
        navigation.selection = .settings
        navigation.pendingSettingsPage = .team
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: height), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: SettingsView()
            .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
            .environment(controller.capture).environment(controller.commitments).environment(navigation).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1_800))
        let shown = Set(FitProbe.all(in: window).map(\.name))
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            capture(hosting, name: name, directory: directory)
        }
        window.close()
        return shown
    }

    /// A sheet drawn on its own, as it shows over Settings; where each of its probes is, by name (from the window's bottom).
    @MainActor
    static func drawnAlone(_ view: some View, controller: DictationController, name: String, size: NSSize, directory: URL?) async -> [String: NSRect] {
        let wasOn = FitProbe.isOn
        FitProbe.isOn = true
        defer { FitProbe.isOn = wasOn }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: view
            .environment(controller).environment(controller.team).environment(AppSettings.shared)
            .modelContainer(Store.shared.container))
        hosting.wantsLayer = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(900))
        var shown: [String: NSRect] = [:]
        for probe in FitProbe.all(in: window) { shown[probe.name] = probe.frame }
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            capture(hosting, name: name, directory: directory)
        }
        window.close()
        return shown
    }
}
