import SwiftUI

/// Renders LLM assistant output as formatted markdown.
///
/// Strategy (no external packages):
/// - Splits content on fenced code blocks (``` ... ```) using a greedy
///   left-to-right scan so streaming partial content is always safe.
/// - Text segments are rendered via `AttributedString(markdown:)` for
///   inline bold, italic, inline code, and lists.
/// - Code blocks get a header bar with the language label + copy button,
///   a dark background, monospaced font, and horizontal scroll for long lines.
struct MarkdownContentView: View {
    let content: String
    let textColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceS) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let str):
                    MarkdownTextSegment(text: str, textColor: textColor)
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code)
                }
            }
        }
    }

    // MARK: - Block model + parser

    private enum Block {
        case text(String)
        case code(language: String?, code: String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
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

// MARK: - Text segment

private struct MarkdownTextSegment: View {
    let text: String
    let textColor: Color

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
                    .foregroundStyle(textColor)
            } else {
                Text(text)
                    .foregroundStyle(textColor)
            }
        }
        .font(HHTheme.body)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
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
