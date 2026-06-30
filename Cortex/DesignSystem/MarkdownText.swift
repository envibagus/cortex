import SwiftUI
import MarkdownUI

// MARK: - MarkdownText
//
// Beautiful GitHub-flavored markdown rendering via MarkdownUI: real tables, lists,
// blockquotes, code blocks, inline styles, links and images. Uses a custom theme
// ("cortex") built on native semantic colors so it looks right in BOTH light and dark,
// plus a lightweight code syntax highlighter (strings green, comments gray, keywords
// orange). The leading YAML frontmatter block is stripped so it never renders as body.
//
// The public API stays `MarkdownText(markdown:)`, so all detail panes are unchanged.

struct MarkdownText: View {
    let markdown: String

    var body: some View {
        Markdown(Self.stripped(markdown))
            .markdownTheme(.cortex)
            .markdownCodeSyntaxHighlighter(CortexCodeHighlighter())
            // Minimal table chrome: horizontal hairlines only (no full grid) + subtle zebra.
            .markdownTableBorderStyle(
                TableBorderStyle(
                    .horizontalBorders,
                    color: Color(nsColor: .separatorColor),
                    strokeStyle: .init(lineWidth: 1)
                )
            )
            .markdownTableBackgroundStyle(
                .alternatingRows(Color.clear, Color.secondary.opacity(0.05))
            )
            .textSelection(.enabled)
    }

    static func stripped(_ md: String) -> String {
        stripFrontmatter(md).joined(separator: "\n")
    }

    // Inline + block code colors (defined on Theme to avoid the Color(light:dark:)
    // ambiguity with MarkdownUI inside this file).
    static let codeTextColor = Theme.codeText
    static let codeFillColor = Theme.codeFill

    // MARK: - Frontmatter strip

    /// Drop a leading YAML frontmatter block (--- ... ---) so it does not render as body.
    static func stripFrontmatter(_ markdown: String) -> [String] {
        var lines = markdown.components(separatedBy: "\n")
        var first = 0
        while first < lines.count, lines[first].trimmingCharacters(in: .whitespaces).isEmpty { first += 1 }
        if first < lines.count, lines[first].trimmingCharacters(in: .whitespaces) == "---",
           let end = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(first...end)
        }
        return lines
    }

    // MARK: - Code block syntax highlighting (lightweight, dependency-free)

    private static let codeKeywords: Set<String> = [
        "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS",
        "import", "from", "export", "default", "def", "return", "func", "let", "var",
        "const", "class", "struct", "enum", "if", "else", "for", "while", "switch",
        "case", "async", "await", "try", "catch", "throw", "public", "private", "static",
        "true", "false", "null", "nil", "None", "True", "False", "self", "this",
    ]

    /// Highlight a fenced code block: strings green, comments gray, keywords / HTTP
    /// verbs orange, numbers purple. Heuristic and language-agnostic.
    static func highlight(_ code: String) -> AttributedString {
        var out = AttributedString()
        let lines = code.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { out += AttributedString("\n") }
            out += highlightLine(line)
        }
        return out
    }

    private static func highlightLine(_ line: String) -> AttributedString {
        let (codePart, comment) = splitComment(line)
        var out = AttributedString()
        var word = ""

        func flushWord() {
            guard !word.isEmpty else { return }
            var run = AttributedString(word)
            // Orange/blue code theme: keywords orange, numbers blue.
            if codeKeywords.contains(word) { run.foregroundColor = Theme.orange }
            else if Double(word) != nil { run.foregroundColor = Theme.blue }
            out += run
            word = ""
        }

        let chars = Array(codePart)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {
                flushWord()
                let quote = c
                var str = String(c)
                i += 1
                while i < chars.count {
                    str.append(chars[i])
                    let done = chars[i] == quote
                    i += 1
                    if done { break }
                }
                var run = AttributedString(str)
                run.foregroundColor = Theme.blue   // string literals -> blue (on-palette)
                out += run
                continue
            }
            if c.isLetter || c.isNumber || c == "_" {
                word.append(c)
                i += 1
            } else {
                flushWord()
                out += AttributedString(String(c))
                i += 1
            }
        }
        flushWord()

        if let comment {
            var run = AttributedString(comment)
            run.foregroundColor = .secondary
            out += run
        }
        return out
    }

    /// Split a trailing `# ...` or `// ...` comment off a code line, avoiding `://`.
    private static func splitComment(_ line: String) -> (String, String?) {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == "#", i == 0 || chars[i - 1] == " " {
                return (String(chars[..<i]), String(chars[i...]))
            }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/",
               (i == 0 || chars[i - 1] != ":") {
                return (String(chars[..<i]), String(chars[i...]))
            }
            i += 1
        }
        return (line, nil)
    }
}

// MARK: - Code syntax highlighter bridge

struct CortexCodeHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        Text(MarkdownText.highlight(code))
    }
}

// MARK: - Cortex markdown theme
//
// A polished, native-adaptive theme: system text colors, clear heading hierarchy,
// comfortable paragraph rhythm, a left-bar blockquote, tinted inline code, and a
// padded scrollable code block. Tables, lists and images use MarkdownUI's defaults.

extension MarkdownUI.Theme {
    static let cortex = MarkdownUI.Theme()
        .text {
            ForegroundColor(.primary)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.86))
            ForegroundColor(MarkdownText.codeTextColor)
            BackgroundColor(MarkdownText.codeFillColor)
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(.blue) }
        .heading1 { config in
            config.label
                .markdownMargin(top: 24, bottom: 12)
                .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.8)) }
        }
        .heading2 { config in
            config.label
                .markdownMargin(top: 22, bottom: 10)
                .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.45)) }
        }
        .heading3 { config in
            config.label
                .markdownMargin(top: 18, bottom: 8)
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.2)) }
        }
        .heading4 { config in
            config.label
                .markdownMargin(top: 16, bottom: 6)
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.0)) }
        }
        .paragraph { config in
            config.label
                .relativeLineSpacing(.em(0.22))
                .markdownMargin(top: 0, bottom: 14)
        }
        .listItem { config in
            config.label.markdownMargin(top: .em(0.2))
        }
        .blockquote { config in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                config.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .padding(.leading, 12)
            }
            .markdownMargin(top: 8, bottom: 14)
        }
        .codeBlock { config in
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(.em(0.85)) }
                    .padding(12)
            }
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .markdownMargin(top: 8, bottom: 14)
        }
        // Minimal table: padded cells, bold header row, horizontal hairlines only
        // (no heavy full grid), and a subtle zebra for row legibility.
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(configuration.row == 0 ? .semibold : .regular)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
        }
}

// MARK: - DetailMetadataBar
//
// Bottom status strip for detail panes: small caption items separated by dividers,
// a material background, and a trailing timestamp.

struct DetailMetadataBar: View {
    struct Item: Identifiable {
        let id = UUID()
        var icon: String? = nil
        var text: String
        var tint: Color? = nil
    }

    let leading: [Item]
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(leading.enumerated()), id: \.element.id) { idx, item in
                if idx > 0 { Divider().frame(height: 14) }
                HStack(spacing: 5) {
                    if let icon = item.icon {
                        Image(systemName: icon).font(.caption2)
                    }
                    Text(item.text)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(item.tint ?? Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
