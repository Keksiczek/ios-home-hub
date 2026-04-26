import SwiftUI

/// Renders LLM assistant output as formatted markdown.
///
/// ## Strategy (no external packages)
///
/// 1. **Fenced code blocks** are pulled out first with a greedy left-to-right
///    scan so streaming partial content is always safe (an unclosed fence
///    just renders as text until the closer arrives).
/// 2. **Block-level structure** for every text segment: each line is
///    classified as a heading (`#` / `##` / `###`), bullet-list item
///    (`- ` / `* ` / `+ `), ordered-list item (`1.` / `2.`), block-quote
///    (`> `), or paragraph. Consecutive list items merge into one list,
///    consecutive paragraph lines merge into one paragraph (single
///    newlines render as soft line breaks; blank lines split paragraphs).
/// 3. **Inline formatting** within each block (bold, italic, inline code,
///    links) is delegated to `AttributedString(markdown:)` with
///    `.inlineOnlyPreservingWhitespace` so the model's `**bold**`,
///    `*italic*`, `` `code` ``, and `[text](url)` survive intact.
///
/// Before this rewrite the view used `.inlineOnlyPreservingWhitespace`
/// for the *entire* assistant turn, so headings rendered as literal `##`
/// and bullets as literal `- `. That's the most visible cause of the
/// "the formatting is bad" complaint — small models lean heavily on
/// markdown structure for their answers.
struct MarkdownContentView: View {
    let content: String
    let textColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceS) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let str):
                    InlineMarkdownColumn(text: str, textColor: textColor)
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code)
                }
            }
        }
    }

    // MARK: - Top-level (text vs fenced code) parser

    private enum TopBlock {
        case text(String)
        case code(language: String?, code: String)
    }

    private var blocks: [TopBlock] {
        var result: [TopBlock] = []
        var remaining = content

        while !remaining.isEmpty {
            guard let fenceRange = remaining.range(of: "```") else {
                result.append(.text(remaining))
                break
            }

            // Text before opening fence
            let before = String(remaining[remaining.startIndex..<fenceRange.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.text(before))
            }

            let afterFence = String(remaining[fenceRange.upperBound...])

            // Optional language hint — everything up to the first newline
            let langLineEnd = afterFence.firstIndex(of: "\n") ?? afterFence.endIndex
            let lang = String(afterFence[afterFence.startIndex..<langLineEnd])
                .trimmingCharacters(in: .whitespaces)

            // Code body starts after the newline
            let bodyStart: String.Index
            if langLineEnd < afterFence.endIndex {
                bodyStart = afterFence.index(after: langLineEnd)
            } else {
                bodyStart = afterFence.endIndex
            }
            let body = bodyStart <= afterFence.endIndex
                ? String(afterFence[bodyStart...]) : ""

            if let closeRange = body.range(of: "```") {
                let code = String(body[body.startIndex..<closeRange.lowerBound])
                    .trimmingCharacters(in: .newlines)
                result.append(.code(language: lang.isEmpty ? nil : lang, code: code))
                remaining = String(body[closeRange.upperBound...])
            } else {
                // Unclosed fence (e.g. still streaming) — treat as text
                result.append(.text("```" + afterFence))
                remaining = ""
            }
        }

        return result.filter {
            if case .text(let s) = $0 {
                return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }
}

// MARK: - Block-level renderer for non-code text

/// Walks a text segment line-by-line, classifies each line into a block
/// (heading / list item / quote / paragraph), and stacks them with
/// SwiftUI views that look right for the role. This is what turns
/// `## Section\n- item 1\n- item 2` into actual visible structure
/// instead of literal markdown source.
struct InlineMarkdownColumn: View {
    let text: String
    let textColor: Color

    private var blocks: [InlineBlock] { InlineBlock.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceS) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    HeadingView(level: level, text: text, textColor: textColor)
                case .bullet(let items):
                    BulletList(items: items, ordered: false, textColor: textColor)
                case .ordered(let items):
                    BulletList(items: items, ordered: true, textColor: textColor)
                case .quote(let text):
                    BlockquoteView(text: text, textColor: textColor)
                case .paragraph(let text):
                    InlineParagraphView(text: text, textColor: textColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Inline block model

enum InlineBlock: Equatable {
    case heading(level: Int, text: String)
    /// Each item is the post-marker text. Items are rendered with bullets
    /// stacked vertically; nested lists aren't supported (small models
    /// rarely produce them and the rendering complexity isn't worth it).
    case bullet(items: [String])
    case ordered(items: [String])
    /// Joined with `\n` so multi-line block-quotes render as one styled
    /// block with internal line breaks.
    case quote(text: String)
    /// Internal newlines preserved as soft breaks; double-newlines split
    /// paragraphs at the parser stage so each `.paragraph(...)` is one
    /// logical paragraph.
    case paragraph(text: String)

    /// Parses a plain-text segment (already stripped of fenced code blocks)
    /// into a sequence of block-level elements. Tolerant of partial
    /// content during streaming — anything that doesn't match a block
    /// pattern falls through to a paragraph line.
    static func parse(_ text: String) -> [InlineBlock] {
        var out: [InlineBlock] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var quote: [String] = []
        var paragraph: [String] = []

        func flushBullets() {
            if !bullets.isEmpty { out.append(.bullet(items: bullets)); bullets = [] }
        }
        func flushOrdered() {
            if !ordered.isEmpty { out.append(.ordered(items: ordered)); ordered = [] }
        }
        func flushQuote() {
            if !quote.isEmpty {
                out.append(.quote(text: quote.joined(separator: "\n")))
                quote = []
            }
        }
        func flushParagraph() {
            if !paragraph.isEmpty {
                out.append(.paragraph(text: paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushAll() {
            flushBullets(); flushOrdered(); flushQuote(); flushParagraph()
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line: paragraph break / list separator.
            if trimmed.isEmpty {
                flushAll()
                continue
            }

            // ATX-style headings (1–4 leading hashes followed by a space).
            if let heading = parseHeading(trimmed) {
                flushAll()
                out.append(heading)
                continue
            }

            // Bullet items (- / * / + followed by a space).
            if let item = parseBullet(trimmed) {
                flushOrdered(); flushQuote(); flushParagraph()
                bullets.append(item)
                continue
            }

            // Ordered items (digits + . / ) followed by a space).
            if let item = parseOrdered(trimmed) {
                flushBullets(); flushQuote(); flushParagraph()
                ordered.append(item)
                continue
            }

            // Block-quote (> followed by optional space).
            if let quoteLine = parseQuote(trimmed) {
                flushBullets(); flushOrdered(); flushParagraph()
                quote.append(quoteLine)
                continue
            }

            // Plain paragraph line — fall through.
            flushBullets(); flushOrdered(); flushQuote()
            paragraph.append(line)
        }
        flushAll()
        return out
    }

    private static func parseHeading(_ trimmed: String) -> InlineBlock? {
        for level in stride(from: 4, through: 1, by: -1) {
            let prefix = String(repeating: "#", count: level) + " "
            if trimmed.hasPrefix(prefix) {
                let text = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                return .heading(level: level, text: text)
            }
        }
        return nil
    }

    private static func parseBullet(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(marker) {
                return String(trimmed.dropFirst(marker.count))
            }
        }
        return nil
    }

    private static func parseOrdered(_ trimmed: String) -> String? {
        // Match `123. text` or `123) text` — keep the marker simple so
        // we don't misclassify e.g. "1.5x" as a list item.
        guard let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) else {
            return nil
        }
        let prefix = trimmed[..<dot]
        guard !prefix.isEmpty,
              prefix.allSatisfy(\.isNumber) else { return nil }
        let after = trimmed.index(after: dot)
        guard after < trimmed.endIndex,
              trimmed[after] == " " else { return nil }
        return String(trimmed[trimmed.index(after: after)...])
    }

    private static func parseQuote(_ trimmed: String) -> String? {
        if trimmed == ">" { return "" }
        if trimmed.hasPrefix("> ") { return String(trimmed.dropFirst(2)) }
        return nil
    }
}

// MARK: - Block renderers

private struct HeadingView: View {
    let level: Int
    let text: String
    let textColor: Color

    var body: some View {
        Text(InlineMarkdownText.attributed(text))
            .font(font.weight(.semibold))
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, level == 1 ? HHTheme.spaceS : 2)
    }

    /// Body-relative sizing keeps the reading rhythm consistent with the
    /// rest of the message. Level 1/2 are noticeably bigger; level 3/4
    /// are subtle bumps so dense outlines don't blow up vertically.
    private var font: Font {
        switch level {
        case 1:  return HHTheme.title2
        case 2:  return HHTheme.title3
        case 3:  return HHTheme.headline
        default: return HHTheme.subheadline
        }
    }
}

private struct BulletList: View {
    let items: [String]
    let ordered: Bool
    let textColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(for: idx))
                        .font(HHTheme.body.monospacedDigit())
                        .foregroundStyle(HHTheme.textSecondary)
                        .frame(minWidth: 18, alignment: .trailing)
                    Text(InlineMarkdownText.attributed(item))
                        .font(HHTheme.body)
                        .foregroundStyle(textColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func marker(for index: Int) -> String {
        ordered ? "\(index + 1)." : "•"
    }
}

private struct BlockquoteView: View {
    let text: String
    let textColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: HHTheme.spaceM) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(HHTheme.accent.opacity(0.6))
                .frame(width: 3)
            Text(InlineMarkdownText.attributed(text))
                .font(HHTheme.body.italic())
                .foregroundStyle(textColor.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private struct InlineParagraphView: View {
    let text: String
    let textColor: Color

    var body: some View {
        Text(InlineMarkdownText.attributed(text))
            .font(HHTheme.body)
            .foregroundStyle(textColor)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tiny helper that wraps `AttributedString(markdown:)` in
/// `inlineOnlyPreservingWhitespace` mode so bold / italic / inline-code /
/// links work inside any block. Falls back to a plain string when the
/// parser rejects the input (rare — happens on partial streaming where
/// a code-span backtick is unmatched).
enum InlineMarkdownText {
    static func attributed(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
    }
}

// MARK: - Code block

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: language + copy button
            HStack {
                if let lang = language {
                    Text(lang)
                        .font(HHTheme.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: copyCode) {
                    Label(
                        copied ? "Copied" : "Copy",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(HHTheme.caption)
                    .foregroundStyle(copied ? HHTheme.success : HHTheme.textSecondary)
                    .animation(.easeInOut(duration: 0.15), value: copied)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied to clipboard" : "Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray5))

            // Code body — horizontal scroll for long lines
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(.label))
                    .padding(12)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGray6))
        }
        .clipShape(RoundedRectangle(cornerRadius: HHTheme.cornerSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HHTheme.cornerSmall, style: .continuous)
                .stroke(HHTheme.stroke, lineWidth: 1)
        )
    }

    private func copyCode() {
        UIPasteboard.general.string = code
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
        }
    }
}
