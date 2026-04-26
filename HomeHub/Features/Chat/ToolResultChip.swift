import SwiftUI

/// Parsed payload of a tool-result `<Observation>…</Observation>`
/// envelope as the agentic loop in `ConversationService` smuggles it
/// back into the prompt. The chat UI uses this to render a compact
/// "tool result" chip instead of a full user-style bubble — observations
/// aren't really things the user typed and showing them as such is
/// confusing.
struct ToolObservation: Equatable {
    let body: String

    /// Returns nil when `text` is not an observation envelope.
    static func parse(from text: String) -> ToolObservation? {
        guard
            let openRange = text.range(of: "<Observation>"),
            let closeRange = text.range(of: "</Observation>",
                                        range: openRange.upperBound..<text.endIndex)
        else { return nil }

        let body = String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolObservation(body: body)
    }

    /// Best-effort short label — first non-empty line, truncated.
    var headline: String {
        let line = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? body
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    /// `true` for the typed-error envelopes the new tool runner emits
    /// (`[tool error: <reason>] …`). Drives the chip's icon / colour.
    var isError: Bool {
        body.lowercased().hasPrefix("[tool error")
    }

    /// URLs scraped out of the observation body. Used by the chip to
    /// render tap-able citations underneath search results, so the user
    /// can verify what the model is summarising without copying the
    /// link out of the assistant's prose.
    ///
    /// Deliberately conservative: we only pick up `http(s)://` URLs that
    /// match a strict scheme/host/path pattern. Markdown link syntax
    /// (`[text](url)`) is NOT supported here — the agentic loop renders
    /// search hits as plain `URL` lines, and we want to avoid swallowing
    /// punctuation that follows a link in prose.
    var citations: [Citation] {
        let pattern = #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var out: [Citation] = []
        for match in matches {
            var raw = ns.substring(with: match.range)
            // Trim trailing punctuation that the regex eagerly includes
            // when the URL ends a sentence (").", "),"  etc.).
            while let last = raw.last, ".,);!?\"]'>".contains(last) {
                raw.removeLast()
            }
            guard !seen.contains(raw), let url = URL(string: raw) else { continue }
            seen.insert(raw)
            out.append(Citation(url: url, host: url.host ?? raw))
            if out.count >= 5 { break }   // chip stays compact
        }
        return out
    }

    struct Citation: Hashable {
        let url: URL
        let host: String
    }
}

/// Compact chip shown in place of a regular bubble when a message body
/// is actually a tool observation.
///
/// When the observation contains URLs (typically web-search results) the
/// chip renders each one as a tap-able citation under the body text so
/// the user can verify the model's summary without scrolling the prose
/// for the hyperlink.
struct ToolResultChip: View {
    let observation: ToolObservation
    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: HHTheme.spaceM) {
            Image(systemName: observation.isError ? "exclamationmark.triangle.fill" : "wrench.adjustable.fill")
                .foregroundStyle(observation.isError ? HHTheme.danger : HHTheme.accent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(observation.isError ? "Tool error" : "Tool result")
                    .font(HHTheme.caption.weight(.semibold))
                    .foregroundStyle(HHTheme.textSecondary)

                if expanded {
                    Text(observation.body)
                        .font(HHTheme.caption.monospaced())
                        .foregroundStyle(HHTheme.textPrimary)
                        .textSelection(.enabled)
                } else {
                    Text(observation.headline)
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textPrimary)
                        .lineLimit(2)
                }

                let citations = observation.citations
                if !citations.isEmpty {
                    citationList(citations)
                }
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .foregroundStyle(HHTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, HHTheme.spaceM)
        .padding(.vertical, HHTheme.spaceS)
        .background(
            RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                .fill(HHTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                .stroke(observation.isError ? HHTheme.danger.opacity(0.3) : HHTheme.stroke, lineWidth: 1)
        )
    }

    /// Renders citations as a single tappable column. Each row shows the
    /// host (`example.com`) so the user can recognise the source at a
    /// glance — the full URL is preserved in the link's destination.
    @ViewBuilder
    private func citationList(_ citations: [ToolObservation.Citation]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(citations, id: \.self) { citation in
                Button {
                    openURL(citation.url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption2)
                        Text(citation.host)
                            .font(HHTheme.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(HHTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}
