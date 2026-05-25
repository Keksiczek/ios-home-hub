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

    /// `true` when the observation is a structurally-empty result —
    /// "No results for …" emitted by `WebSearchEngine.renderObservation`,
    /// the parallel "Refused to fetch …" / "Could not fetch …" lines
    /// from `FetchPageSkill`, etc. Distinct from `isError` because
    /// these are *expected* operational outcomes (bad query, paywall,
    /// down upstream) that the chip should surface in a calmer
    /// neutral palette rather than full warning red.
    var isEmptyResult: Bool {
        let lc = body.lowercased()
        return lc.hasPrefix("no results for")
            || lc.hasPrefix("could not fetch")
            || lc.hasPrefix("refused to fetch")
    }

    /// Inferred originating tool, used to pick the chip's icon + label
    /// without plumbing the tool name through the observation envelope.
    /// Falls back to a generic "Tool" label when no pattern matches.
    ///
    /// Detection patterns mirror the prefixes emitted by:
    ///   * `WebSearchEngine.renderObservation` ("Web results for …" /
    ///     "No results for …")
    ///   * `FetchPageSkill.execute` ("FetchPage https://… :" / "Could
    ///     not fetch …" / "Refused to fetch …")
    /// Anything else (Calculator, Calendar, Reminders, HomeKit,
    /// DeviceInfo) hits the default branch — those skills emit free-
    /// form text and a per-skill prefix would be a bigger refactor
    /// than this UI polish justifies.
    var inferredToolName: String {
        let lc = body.lowercased()
        if lc.hasPrefix("web results for") || lc.hasPrefix("no results for") {
            return "WebSearch"
        }
        if lc.hasPrefix("fetchpage ") || lc.hasPrefix("could not fetch")
           || lc.hasPrefix("refused to fetch") {
            return "FetchPage"
        }
        return "Tool"
    }

    /// Hero image URL surfaced by `FetchPageSkill` via the
    /// `Image: https://...` line in its output. Returned only when the
    /// observation actually contains that line — most tools (WebSearch,
    /// Calculator, …) never emit one, so the chip's thumbnail layer
    /// stays opt-in.
    ///
    /// Conservative parsing: anchor to a line start (`^Image: `), then
    /// match a single http(s) URL up to the line break. Markdown link
    /// syntax and bare hosts are NOT recognised — we control the
    /// emitter (`FetchPageSkill`), so the parser only needs to handle
    /// the exact shape it produces.
    var heroImageURL: URL? {
        let pattern = #"(?m)^Image:\s*(https?://\S+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = body as NSString
        guard let match = regex.firstMatch(
            in: body,
            range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges >= 2 else { return nil }
        var raw = ns.substring(with: match.range(at: 1))
        while let last = raw.last, ".,);!?\"]'>".contains(last) {
            raw.removeLast()
        }
        return URL(string: raw)
    }

    /// URLs (and their titles when available) scraped out of the
    /// observation body. Used by the chip to render tap-able citations
    /// underneath search results, so the user can verify what the
    /// model is summarising without copying the link out of the
    /// assistant's prose.
    ///
    /// Two-pass extraction:
    ///
    ///   1. **Structured.** `WebSearchEngine.renderObservation` emits
    ///      results as numbered three-line records — `N. Title\n   \
    ///      Snippet\n   URL`. We pattern-match that shape so each
    ///      citation gets the *title* in the citation row, not just
    ///      the bare host. Far more useful at a glance ("Current
    ///      Weather in Prague" beats "weather.com").
    ///   2. **Fallback.** When the structured match returns nothing
    ///      (FetchPage observations, custom tool output, malformed
    ///      WebSearch render), fall back to plain regex URL
    ///      extraction. Yields host-only citations but at least
    ///      keeps the link list functional.
    ///
    /// Deliberately conservative: we only pick up `http(s)://` URLs.
    /// Markdown link syntax (`[text](url)`) is NOT supported — the
    /// agentic loop renders hits as plain URL lines, and we want to
    /// avoid swallowing punctuation that follows a link in prose.
    var citations: [Citation] {
        let structured = Self.parseStructuredCitations(body)
        if !structured.isEmpty { return structured }
        return Self.parseBareURLCitations(body)
    }

    /// Pulls citations from the structured `N. Title\n   ...\n   URL`
    /// render emitted by `WebSearchEngine.renderObservation`. Lines
    /// after the title are tolerated in any number — the engine
    /// currently emits exactly one snippet line, but a future tweak
    /// (publish date, source label) could add more without breaking
    /// this parser.
    private static func parseStructuredCitations(_ body: String) -> [Citation] {
        // `N. Title` followed by any number of indented lines, with
        // the last indented line being a URL. The trailing URL line
        // is what anchors the record, so we capture it directly.
        let pattern = #"^\s*\d+\.\s+(.+?)\n(?:.*\n)*?\s+(https?://\S+)\s*$"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else { return [] }

        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var out: [Citation] = []
        for match in matches where match.numberOfRanges >= 3 {
            let title = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var raw = ns.substring(with: match.range(at: 2))
            while let last = raw.last, ".,);!?\"]'>".contains(last) {
                raw.removeLast()
            }
            guard !seen.contains(raw), let url = URL(string: raw) else { continue }
            seen.insert(raw)
            out.append(Citation(url: url, host: url.host ?? raw, title: title.isEmpty ? nil : title))
            if out.count >= 5 { break }
        }
        return out
    }

    /// Fallback: plain regex URL scan. Same behaviour as before the
    /// structured pass was added — emits host-only citations.
    private static func parseBareURLCitations(_ body: String) -> [Citation] {
        let pattern = #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var out: [Citation] = []
        for match in matches {
            var raw = ns.substring(with: match.range)
            while let last = raw.last, ".,);!?\"]'>".contains(last) {
                raw.removeLast()
            }
            guard !seen.contains(raw), let url = URL(string: raw) else { continue }
            seen.insert(raw)
            out.append(Citation(url: url, host: url.host ?? raw, title: nil))
            if out.count >= 5 { break }
        }
        return out
    }

    struct Citation: Hashable {
        let url: URL
        let host: String
        /// Optional human-readable title (e.g. "Current Weather in
        /// Prague") parsed out of structured WebSearch results. `nil`
        /// when the source is a bare-URL fallback or a tool that
        /// doesn't emit titles. The chip falls back to the host
        /// string when `nil`.
        let title: String?
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
        // Picks the per-tool icon + label. Error / empty-result
        // observations override the icon below; the style's
        // `completedLabel` still wins for the chip headline so the
        // user sees "Web search" / "Načtená stránka" instead of a
        // bare "Tool result".
        let style = ToolPresenter.style(for: observation.inferredToolName)
        let icon: String
        let iconColor: Color
        if observation.isError {
            icon = "exclamationmark.triangle.fill"
            iconColor = HHTheme.danger
        } else if observation.isEmptyResult {
            icon = "questionmark.circle"
            iconColor = HHTheme.textSecondary
        } else {
            icon = style.systemImage
            iconColor = HHTheme.accent
        }
        return HStack(alignment: .top, spacing: HHTheme.spaceM) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(headlineText(style: style))
                    .font(HHTheme.caption.weight(.semibold))
                    .foregroundStyle(HHTheme.textSecondary)

                if let imageURL = observation.heroImageURL {
                    heroThumbnail(imageURL)
                }

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

    /// Headline shown above the body text. Carries both the tool
    /// identity (so the user sees "Web search" / "Načtená stránka"
    /// instead of a generic "Tool result") and an outcome qualifier
    /// for the two structured empty / error cases.
    private func headlineText(style: ToolPresenter.Style) -> String {
        if observation.isError {
            return "Tool error"
        }
        if observation.isEmptyResult {
            return "\(style.completedLabel) — bez výsledku"
        }
        return style.completedLabel
    }

    /// Renders the `og:image` thumbnail surfaced by FetchPage. Uses
    /// `AsyncImage` with a placeholder + failure fall-through so a slow
    /// CDN doesn't block the chip layout and a broken image just
    /// degrades to "no thumbnail" rather than a visible error icon.
    ///
    /// Sized to fit the chip's column: full width, 140pt tall, fill
    /// aspect (cropping rather than letterboxing — hero images are
    /// almost always wider than the chip and look better cropped than
    /// pillarboxed). Rounded corners match the parent surface so the
    /// thumbnail reads as part of the chip rather than a floating tile.
    @ViewBuilder
    private func heroThumbnail(_ url: URL) -> some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: HHTheme.cornerSmall, style: .continuous))
            case .empty:
                RoundedRectangle(cornerRadius: HHTheme.cornerSmall, style: .continuous)
                    .fill(HHTheme.surface)
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .overlay(ProgressView())
            case .failure:
                // Silent fail — the chip is still useful without an image.
                EmptyView()
            @unknown default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    /// Renders citations as a single tappable column. When the
    /// citation came from a structured WebSearch render we show the
    /// page title prominently with the host underneath in muted grey;
    /// fallback citations (bare-URL extraction) show only the host.
    /// Either way the full URL is preserved in the link's destination.
    @ViewBuilder
    private func citationList(_ citations: [ToolObservation.Citation]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(citations, id: \.self) { citation in
                Button {
                    openURL(citation.url)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "link")
                            .font(.caption2)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            if let title = citation.title {
                                Text(title)
                                    .font(HHTheme.caption.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(citation.host)
                                    .font(.caption2)
                                    .foregroundStyle(HHTheme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text(citation.host)
                                    .font(HHTheme.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .foregroundStyle(HHTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }
}
