import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BindersKit

/// Picks apps to capture writing in: the ones running now, or any app in Applications. Password managers and terminals
/// are shown but can't be picked.
struct CaptureAppPicker: View {
    @Environment(\.dismiss) private var dismiss
    /// Already being captured.
    let current: Set<String>
    let onAdd: ([String]) -> Void
    @State private var chosen: Set<String> = []
    @State private var running: [Candidate] = []

    struct Candidate: Identifiable, Hashable {
        let id: String
        let name: String
        let url: URL?
        var icon: NSImage { url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)! }
        var neverCaptured: Bool { WritingCaptureService.isNeverCaptured(id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Capture writing in…").font(BindersTheme.cardTitle)
                Text("Apps that are open now. What you write in them is kept once you send or save it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            List(running) { app in
                HStack(spacing: 10) {
                    Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        if app.neverCaptured {
                            Text(WritingCaptureService.isTerminal(app.id)
                                 ? "Its screen isn't read; what you send Claude Code or Codex in it is, under In the terminal"
                                 : "Never captured: it holds passwords").font(.caption).foregroundStyle(.secondary)
                        } else if WritingCaptureService.isBrowser(app.id) {
                            Text("A browser: only the sites listed in Settings, never login or payment pages").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if current.contains(app.id) {
                        Text("Captured").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle("", isOn: Binding(get: { chosen.contains(app.id) },
                                                 set: { on in if on { chosen.insert(app.id) } else { chosen.remove(app.id) } }))
                            .labelsHidden()
                            .disabled(app.neverCaptured)
                    }
                }
                .padding(.vertical, 2)
                .opacity(app.neverCaptured ? 0.5 : 1)
            }
            .frame(minHeight: 280)
            Divider()
            HStack {
                Button("Choose from Applications…", action: chooseFromApplications)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Add \(chosen.count) Apps" : "Add") {
                    onAdd(running.map(\.id).filter(chosen.contains))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 460)
        .pageGround()
        .onAppear(perform: load)
    }

    /// The apps open now with a window or a Dock icon, by name, without Binders itself.
    private func load() {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != own }
            .compactMap { app -> Candidate? in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return Candidate(id: id, name: app.localizedName ?? WritingCaptureService.appName(id), url: app.bundleURL)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseFromApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { !WritingCaptureService.isNeverCaptured($0) && !current.contains($0) }
        guard !ids.isEmpty else { return }
        onAdd(ids)
        dismiss()
    }
}

/// Other AI tools: describe where one keeps your prompts, or have its hook hand them over.
struct AgentHookRow: View {
    @Binding var off: Bool
    @State private var copied = false
    @State private var copiedAntigravity = false

    private static var binary: String { Bundle.main.executableURL?.path ?? "/Applications/Binders.app/Contents/MacOS/Binders" }

    private var command: String {
        "\"\(Self.binary)\" --capture-prompt --tool \"Name of the tool\""
    }

    /// A hook for Antigravity's ~/.gemini/config/hooks.json: before each model call, with the last thing you sent, once
    /// per prompt (Binders skips the repeats), answering with the empty JSON object Antigravity expects.
    static var antigravityHook: String {
        let command = "\"\(binary)\" --capture-prompt --tool Antigravity --reply-json"
        let hook = OrderedJSON.object([("binders-capture", .object([("PreInvocation", .array([.object([("type", .string("command")), ("command", .string(command))])]))]))])
        return hook.text()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Prompts from other tools' hooks", isOn: Binding(get: { !off }, set: { off = !$0 }))
            Text("A tool that runs a command when you send a prompt (Cursor's beforeSubmitPrompt, Gemini CLI's, Copilot CLI's and Antigravity's hooks, your own scripts) can hand it to Binders with:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            HStack {
                Text("For Antigravity, add this hook to ~/.gemini/config/hooks.json yourself; Binders doesn't change that file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(copiedAntigravity ? "Copied" : "Copy Hook") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.antigravityHook, forType: .string)
                    copiedAntigravity = true
                }
                .controlSize(.small)
            }
            HStack {
                Text("Or describe where a tool keeps your prompts, and Binders reads them like these:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add a Tool…") { AgentHarnesses.revealCustomFile() }
                    .controlSize(.small)
            }
        }
    }
}
