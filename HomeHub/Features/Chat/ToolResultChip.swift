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
}

/// Compact chip shown in place of a regular bubble when a message body
/// is actually a tool observation.
struct ToolResultChip: View {
    let observation: ToolObservation
    @State private var expanded = false

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
}
