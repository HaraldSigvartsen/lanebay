import SwiftUI

/// Applies explicit line and paragraph breaks to Markdown's inline attributed text.
public struct MarkdownBlocks: View {
    private let markdown: String
    private let onOpenLink: (URL) -> Void

    public init(markdown: String, onOpenLink: @escaping (URL) -> Void = { _ in }) {
        self.markdown = markdown
        self.onOpenLink = onOpenLink
    }

    public var blockCount: Int { markdown.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count }
    public var plainText: String { markdown.replacingOccurrences(of: "\n\n", with: "\n") }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(markdown.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                if !block.isEmpty {
                    Text(attributed(block))
                        .environment(\.openURL, OpenURLAction { url in
                            onOpenLink(url)
                            return .handled
                        })
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func attributed(_ block: String) -> AttributedString {
        let inline = block.components(separatedBy: "\n").joined(separator: "\u{2028}")
        return (try? AttributedString(markdown: inline, options: .init(interpretedSyntax: .full))) ?? AttributedString(inline)
    }
}
