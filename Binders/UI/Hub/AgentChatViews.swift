import SwiftUI
import BindersKit

/// A reply's Markdown, as a chat shows it (`ChatMarkdown`): paragraphs, headings, bullets and numbered items, fenced code
/// and quotes, with bold, italics, inline code and links within them.
struct ChatMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdown.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ block: ChatMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text).font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .numbered(let depth, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).fixedSize()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BindersTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(BindersTheme.lineStrong).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> some View {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(attributed).fixedSize(horizontal: false, vertical: true)
    }
}
