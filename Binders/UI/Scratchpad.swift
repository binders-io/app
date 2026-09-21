import AppKit
import SwiftData
import SwiftUI

/// A floating note you can dictate into (⌥S by default). Notes are saved to the Notes page.
@MainActor
final class ScratchpadController: NSObject {
    static let shared = ScratchpadController()

    private var panel: NSPanel?
    private var note: NoteItem?

    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        let note = currentNote()
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.title = "Scratchpad"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.center()
            panel.setFrameAutosaveName("BindersScratchpad")
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: ScratchpadView(note: note, onNew: { [weak self] in self?.newNote() })
            .modelContainer(Store.shared.container))
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func newNote() {
        let previous = note
        note = nil
        show()
        // Delete only after the panel stopped showing it.
        if let previous, previous.text.trimmed.isEmpty { Store.shared.delete(previous) }
    }

    /// Call before deleting a note elsewhere so the panel never renders a deleted model.
    func noteWillBeDeleted(_ deleted: NoteItem) {
        guard note?.id == deleted.id else { return }
        panel?.orderOut(nil)
        panel?.contentView = nil
        note = nil
    }

    private func currentNote() -> NoteItem {
        if let note, note.modelContext != nil, note.text.trimmed.isEmpty || Date().timeIntervalSince(note.updatedAt) < 3600 {
            return note
        }
        let fresh = NoteItem()
        let binder = Store.shared.binder(AppSettings.shared.currentBinderID) ?? Store.shared.defaultBinder()
        fresh.binderID = binder.id
        fresh.sharedWithTeam = binder.sharedWithTeam
        Store.shared.insert(fresh)
        note = fresh
        return fresh
    }
}

private struct ScratchpadView: View {
    @Bindable var note: NoteItem
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $note.text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.top, 30)
                .onChange(of: note.text) { note.updatedAt = Date() }
            HStack {
                Text("Hold \(AppSettings.shared.hotkeys.dictation.displayString()) to dictate · saved to Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { TextInserter.copyToClipboard(note.text) }
                Button("New", action: onNew)
            }
            .padding(10)
        }
    }
}
