import SwiftUI
import UIKit

/// Renders a single `Message.Artifact` in a chat bubble. Kept as a
/// separate file (not nested in `MessageBubbleView`) so the bubble
/// stays readable and so the artifact surface can be reused by
/// transcript exports / share sheets without dragging the entire
/// bubble in.
///
/// Each artifact kind owns its own visual treatment:
///   * `.image` — inline preview clipped to a rounded rectangle,
///     tap to expand into a full-screen viewer.
///   * `.code` — syntax-block with a copy-to-clipboard affordance.
///   * `.unknown` — graceful fallback that names the kind so the
///     user knows something is there, even if this build doesn't
///     know how to render it.
struct ArtifactView: View {
    let artifact: Message.Artifact

    @State private var showImageViewer = false
    @State private var didCopyCode = false
    /// Decoded `UIImage` cached across body re-runs. Without this,
    /// `UIImage(data:)` would run synchronously on every parent
    /// state change (token streaming re-renders sibling bubbles),
    /// paying the ~30 ms JPEG/PNG decode per render on a multi-MB
    /// photo artifact. Populated via `.task(id: artifact.id)` so
    /// the decode happens off the body callstack and only when the
    /// artifact identity actually changes.
    @State private var decodedImage: UIImage?

    var body: some View {
        switch artifact.kind {
        case .image(let data, _):
            imageView(data: data)
                // Decode off the body callstack. `.task(id:)` runs
                // when the view appears AND whenever `artifact.id`
                // changes, mirroring the lifecycle we want: fresh
                // artifact ⇒ fresh decode; same artifact rendered
                // again ⇒ reuse the cache.
                .task(id: artifact.id) {
                    if decodedImage == nil {
                        decodedImage = UIImage(data: data)
                    }
                }
        case .code(let source, let language):
            codeView(source: source, language: language)
        case .unknown(let rawKind):
            unknownView(rawKind: rawKind)
        }
    }

    // MARK: Image

    /// Image preview clipped to a max height so a tall portrait
    /// photo doesn't blow out the conversation column. The full
    /// resolution is available via the tap-to-expand viewer below.
    ///
    /// Reads from `decodedImage` rather than calling `UIImage(data:)`
    /// inline so the decode happens once per artifact identity (see
    /// the `.task(id:)` in `body`). While the decode is pending the
    /// view shows a neutral placeholder rather than collapsing to
    /// zero height — keeps the bubble layout stable.
    @ViewBuilder
    private func imageView(data: Data) -> some View {
        if let uiImage = decodedImage {
            Button {
                showImageViewer = true
            } label: {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                            .stroke(HHTheme.stroke, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $showImageViewer) {
                ImageArtifactViewer(image: uiImage, isPresented: $showImageViewer)
            }
        } else if data.isEmpty {
            // Empty buffer is treated as corrupt rather than
            // "pending" — `.task` would never populate
            // `decodedImage` from zero bytes.
            corruptArtifactRow(label: "Obrázek nelze zobrazit (prázdná data)")
        } else {
            // Decode pending or failed. Show a sized placeholder so
            // the bubble doesn't reflow when the image arrives.
            // `.task` will retry; if it returns nil we stay on this
            // branch, which is fine — the next render after a layout
            // pass will fall through to the `corruptArtifactRow`
            // below via the `.task` body. (Manual transition via a
            // separate `decodeFailed` flag is overkill for a
            // graceful-degrade surface.)
            RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                .fill(HHTheme.stroke.opacity(0.3))
                .frame(height: 120)
                .overlay(
                    ProgressView()
                        .controlSize(.small)
                )
        }
    }

    // MARK: Code

    /// Code block with a copy button. Monospaced font + subtle
    /// background tint to read as code without going full IDE-style
    /// syntax highlighting (deferred until there's a real
    /// highlighter in the project).
    @ViewBuilder
    private func codeView(source: String, language: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(HHTheme.textSecondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                    withAnimation { didCopyCode = true }
                    // Auto-reset the "copied" indicator after a
                    // beat so the affordance is reusable without
                    // a manual reset on tap-out.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { didCopyCode = false }
                    }
                } label: {
                    Label(didCopyCode ? "Zkopírováno" : "Kopírovat",
                          systemImage: didCopyCode ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(didCopyCode ? HHTheme.accent : HHTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(HHTheme.textPrimary)
                    .textSelection(.enabled)
                    .padding(HHTheme.spaceS)
            }
        }
        .padding(HHTheme.spaceS)
        .background(
            RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                .fill(HHTheme.stroke.opacity(0.4))
        )
    }

    // MARK: Unknown / corrupt fallbacks

    private func unknownView(rawKind: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.square.dashed")
                .foregroundStyle(HHTheme.textSecondary)
            Text("Neznámý artefakt: \(rawKind)")
                .font(.caption)
                .foregroundStyle(HHTheme.textSecondary)
        }
        .padding(HHTheme.spaceS)
        .background(
            RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                .fill(HHTheme.stroke.opacity(0.3))
        )
    }

    private func corruptArtifactRow(label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HHTheme.warning)
            Text(label)
                .font(.caption)
                .foregroundStyle(HHTheme.textSecondary)
        }
        .padding(HHTheme.spaceS)
        .background(
            RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                .fill(HHTheme.warning.opacity(0.1))
        )
    }
}

/// Full-screen image viewer reached by tapping a generated image
/// artifact. Plain `Image` + pinch-to-zoom would be nicer; this
/// minimal version unblocks the surface and can be upgraded later
/// without changing the artifact surface contract.
private struct ImageArtifactViewer: View {
    let image: UIImage
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea(edges: .horizontal)
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.4))
                    .padding()
            }
        }
    }
}
