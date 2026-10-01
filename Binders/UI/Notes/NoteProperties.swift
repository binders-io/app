import SwiftUI
import BindersKit

/// A note's properties (status, owner, due) and its #tags, above its digest. In a shared binder they sync with the note,
/// and in the team folder they're front matter, which Obsidian shows as properties.
struct NotePropertiesPanel: View {
    @Bindable var note: NoteItem

    private var tags: [String] { NoteTagCache.tags(of: note) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Properties").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    Menu(note.status ?? "None") {
                        Button("None") { update { $0.status = nil } }
                        Divider()
                        ForEach(NoteProperties.statuses, id: \.self) { status in
                            Button(status) { update { $0.status = status } }
                        }
                    }
                    .fixedSize()
                }
                GridRow {
                    Text("Owner").foregroundStyle(.secondary)
                    TextField("Nobody", text: Binding(get: { note.owner ?? "" }, set: { value in update { $0.owner = value } }))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Due").foregroundStyle(.secondary)
                    if let due = note.dueAt {
                        HStack(spacing: 4) {
                            DatePicker("Due", selection: Binding(get: { due }, set: { value in update { $0.due = Calendar.current.startOfDay(for: value) } }),
                                       displayedComponents: .date)
                                .labelsHidden()
                            Button { update { $0.due = nil } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.tertiary)
                                .help("No due date")
                        }
                    } else {
                        Button("Add a date") {
                            update { $0.due = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .font(.callout)
            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags.prefix(8), id: \.self) { tag in
                        Button("#\(tag)") { TagSearch.show(tag) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                            .help("Everything tagged #\(tag)")
                    }
                }
            }
        }
    }

    private func update(_ change: (inout NoteProperties) -> Void) {
        var properties = note.properties
        change(&properties)
        note.properties = NoteProperties(status: properties.status, owner: properties.owner, due: properties.due)
        note.updatedAt = Date()
    }
}

/// Everything with a #tag: the quick switcher, with the tag typed in.
@MainActor
enum TagSearch {
    static func show(_ tag: String) {
        let hub = HubWindowController.shared
        hub.show()
        hub.navigation.switcherQuery = "#\(tag)"
        hub.navigation.switcher = .open
    }
}
