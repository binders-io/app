import SwiftUI

/// A text field with its name above it, the width of the row and written from the left: in a grouped form a plain
/// TextField sits right-aligned beside its name, one line high, and a long value or hint runs into the name. One line
/// unless `lines` lets it grow (a description, a command, a list), then it wraps and grows within them. `secure` makes it
/// a SecureField, always one line. `accessory` sits beside the box, such as a Download or an Add button, and `caption`
/// under it. The name stays the field's accessibility label; the words above are for the eye.
///
/// `probe` names it for the window-fit self-test: the row as `probe`, the box as `probe.box` (`FitProbe`).
struct StackedField<Accessory: View>: View {
    let label: String
    @Binding var text: String
    var prompt: String?
    var lines: ClosedRange<Int>
    var secure: Bool
    var monospaced: Bool
    var caption: String?
    var probe: String
    let accessory: Accessory

    init(label: String, text: Binding<String>, prompt: String? = nil, lines: ClosedRange<Int> = 1...1, secure: Bool = false,
         monospaced: Bool = false, caption: String? = nil, probe: String = "", @ViewBuilder accessory: () -> Accessory) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.lines = lines
        self.secure = secure
        self.monospaced = monospaced
        self.caption = caption
        self.probe = probe
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                box
                    .fitProbe(probe.isEmpty ? "" : probe + ".box")
                accessory
            }
            if let caption {
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fitProbe(probe)
    }

    @ViewBuilder
    private var box: some View {
        Group {
            if secure {
                SecureField(label, text: $text, prompt: prompt.map { Text($0) })
            } else if lines.upperBound > 1 {
                TextField(label, text: $text, prompt: prompt.map { Text($0) }, axis: .vertical)
                    .lineLimit(lines)
            } else {
                TextField(label, text: $text, prompt: prompt.map { Text($0) })
            }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)
        .font(monospaced ? .body.monospaced() : .body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension StackedField where Accessory == EmptyView {
    init(label: String, text: Binding<String>, prompt: String? = nil, lines: ClosedRange<Int> = 1...1, secure: Bool = false,
         monospaced: Bool = false, caption: String? = nil, probe: String = "") {
        self.init(label: label, text: text, prompt: prompt, lines: lines, secure: secure, monospaced: monospaced, caption: caption,
                  probe: probe) { EmptyView() }
    }
}

/// A row's name with what it shows under it, from the left: for a long value (a command, a list of tools) that beside
/// its name would be pushed right and wrapped into a narrow column.
struct StackedRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
