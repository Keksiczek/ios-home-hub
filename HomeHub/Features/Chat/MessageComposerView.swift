import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import os

private let composerLog = Logger(subsystem: "HomeHub", category: "MessageComposerView")

struct MessageComposerView: View {
    @EnvironmentObject private var settings: SettingsService
    /// Used purely as a read-only source of "can the active model see
    /// images?" so the composer can warn the user when they're about
    /// to send a photo to a text-only model. Optional — previews and
    /// some embed surfaces don't inject a RuntimeManager.
    @EnvironmentObject private var runtimeManager: RuntimeManager
    @Binding var draft: String
    let isStreaming: Bool
    let canSend: Bool
    let tokenFill: Double
    let onSend: ([Message.Attachment], Bool) -> Void
    let onCancel: () -> Void

    @State private var showingFilePicker = false
    @State private var showingDocError = false
    @State private var docErrorMessage = ""
    @State private var attachments: [Message.Attachment] = []

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var isWebSearchEnabled = false

    /// `true` if any current attachment carries raw image bytes (i.e.
    /// originated from the photo picker rather than a text document).
    /// Drives the "this model only OCRs photos" hint below the strip.
    private var hasImageAttachment: Bool {
        attachments.contains { $0.imageData != nil }
    }

    /// Whether the currently loaded model claims vision capability via
    /// its family profile. Defaults to `false` when no model is loaded
    /// — that keeps the hint shown (user attached a photo, no model
    /// can see it yet).
    private var activeModelSupportsVision: Bool {
        guard let active = runtimeManager.activeModel else { return false }
        return ModelCapabilityProfile.resolve(
            family: active.family,
            parameterCount: active.parameterCount,
            contextLength: active.contextLength
        ).supportsVision
    }

    var body: some View {
        VStack(spacing: 0) {
            // Context usage strip. The bar appears at 50% fill (early
            // warning, no label yet); above 70% we tint it amber and
            // show a percentage chip so the user knows *how* full
            // before summarisation kicks in around 55–75% (the curve
            // in `ConversationService.summarizationTriggerFraction`).
            if tokenFill > 0.5 {
                contextFillStrip
            }

            Divider().overlay(HHTheme.stroke)

            // Attachments Preview Area
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HHTheme.spaceM) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.filename.hasSuffix(".jpg") || attachment.filename.hasSuffix(".png") ? "photo.fill" : "doc.text.fill")
                                    .foregroundColor(HHTheme.accent)
                                Text(attachment.filename)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(HHTheme.textSecondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(HHTheme.stroke)
                            .cornerRadius(HHTheme.cornerLarge)
                        }
                    }
                    .padding(.horizontal, HHTheme.spaceL)
                    .padding(.top, HHTheme.spaceM)
                }

                // Vision-capability hint. Only renders when the user
                // has attached at least one *image* (text docs go
                // through the OCR path regardless of model). Two
                // states:
                //   * no vision model loaded → tell the user the
                //     image will be turned into OCR text only
                //   * vision model loaded → small confirmation
                //     badge so the user knows the picture itself
                //     is in play, not just extracted text
                //
                // Renders inline (not as a popover/sheet) because
                // it's contextual to the staged attachments — pulling
                // the user away to a modal for a one-line hint would
                // be heavier than the information warrants.
                if hasImageAttachment {
                    HStack(spacing: 6) {
                        if activeModelSupportsVision {
                            Image(systemName: "eye.fill")
                                .foregroundColor(HHTheme.accent)
                                .imageScale(.small)
                            Text("Vision: model uvidí obrázek přímo.")
                                .font(.caption2)
                                .foregroundColor(HHTheme.textSecondary)
                        } else {
                            Image(systemName: "text.viewfinder")
                                .foregroundColor(HHTheme.textSecondary)
                                .imageScale(.small)
                            Text("Aktivní model čte fotky jen jako OCR text. Pro skutečné porozumění obrázku zvol SmolVLM nebo Qwen2-VL.")
                                .font(.caption2)
                                .foregroundColor(HHTheme.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, HHTheme.spaceL)
                    .padding(.top, 4)
                }
            }

            HStack(alignment: .bottom, spacing: HHTheme.spaceM) {
                // Unified attachments + tools menu — one button instead of three.
                // PhotosPicker is anchored invisibly inside the menu by toggling
                // `showingPhotoPicker` → it flips a PhotosPicker overlay that
                // lives outside the menu (SwiftUI doesn't allow PhotosPicker
                // inside a Menu label directly on iOS 17).
                Menu {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Vybrat soubor", systemImage: "doc")
                    }
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Vybrat fotku", systemImage: "photo")
                    }
                    Divider()
                    Button {
                        HHHaptics.impact(.light, enabled: settings.current.haptics)
                        isWebSearchEnabled.toggle()
                    } label: {
                        if isWebSearchEnabled {
                            Label("Hledat na webu", systemImage: "checkmark")
                        } else {
                            Label("Hledat na webu", systemImage: "globe")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(HHTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().stroke(HHTheme.accent.opacity(0.35), lineWidth: 1)
                        )
                }
                .padding(.bottom, 2)

                // Text field with an inline web-search chip (right-aligned
                // suffix). Small, non-agressive, auto-hides when off.
                HStack(alignment: .bottom, spacing: HHTheme.spaceS) {
                    TextField("Zpráva", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .font(HHTheme.body)

                    if isWebSearchEnabled {
                        Button {
                            HHHaptics.impact(.light, enabled: settings.current.haptics)
                            isWebSearchEnabled = false
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                Text("Web")
                            }
                            .font(HHTheme.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(HHTheme.accent))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .accessibilityLabel("Webové vyhledávání zapnuto. Klepnutím vypneš.")
                    }
                }
                .padding(.horizontal, HHTheme.spaceL)
                .padding(.vertical, HHTheme.spaceM)
                .background(
                    RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                        .fill(HHTheme.surface)
                )
                .animation(.easeOut(duration: 0.18), value: isWebSearchEnabled)

                if isStreaming {
                    Button {
                        HHHaptics.impact(.medium, enabled: settings.current.haptics)
                        onCancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(HHTheme.danger)
                    }
                    .accessibilityLabel("Zastavit")
                } else {
                    let enableSend = canSend || !attachments.isEmpty
                    Button {
                        HHHaptics.impact(.light, enabled: settings.current.haptics)
                        let items = attachments
                        attachments.removeAll()
                        onSend(items, isWebSearchEnabled)
                        isWebSearchEnabled = false
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(enableSend ? HHTheme.accent : HHTheme.textSecondary.opacity(0.3))
                    }
                    .disabled(!enableSend)
                    .accessibilityLabel("Odeslat")
                }
            }
            .padding(.horizontal, HHTheme.spaceL)
            .padding(.vertical, HHTheme.spaceM)
        }
        .background(HHTheme.canvas)
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedPhotos,
            matching: .images,
            photoLibrary: .shared()
        )
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.plainText, .pdf, .commaSeparatedText, .json],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                // OCR fallback path is async — wrap the loop in
                // a Task so scanned PDFs without a text layer
                // still produce text via Apple Vision instead of
                // failing the attachment with "extraction failed".
                Task { @MainActor in
                    for url in urls {
                        do {
                            let pages = try await DocumentReaderService.extractPagesWithOCRFallback(from: url)
                            let extracted = pages
                                .map(\.text)
                                .joined(separator: "\n\n")
                            let newAttachment = Message.Attachment(
                                id: UUID(),
                                filename: url.lastPathComponent,
                                extractedText: extracted
                            )
                            attachments.append(newAttachment)
                        } catch {
                            docErrorMessage = error.localizedDescription
                            showingDocError = true
                        }
                    }
                }
            case .failure(let error):
                composerLog.error("File picking failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let original = UIImage(data: data) {
                        // Downscale before handing to Vision. A 4K
                        // screenshot is ~12 MP and Vision converts it
                        // to a CIImage internally, briefly tripling
                        // memory; downscaling to 1024 px on the long
                        // edge keeps the peak under ~5 MB while
                        // preserving OCR accuracy (Vision's text
                        // recogniser internally normalises to a
                        // similar scale anyway). The downscaled JPEG
                        // is what we persist alongside the OCR text
                        // so a future VLM path has actual pixels to
                        // feed the model — quality 0.8 keeps perceived
                        // detail high while landing each attachment
                        // under ~500 KB on disk.
                        let image = Self.downscaledForVision(original)
                        let imageBytes = image.jpegData(compressionQuality: 0.8)
                        // OCR is best-effort. A pure-graphic image
                        // (chart, photo of a dog, UI screenshot
                        // without OCR-able text) shouldn't fail the
                        // attachment — the VLM cestou will read the
                        // pixels later. We still try OCR so chat
                        // gets the recognised text as a hint today.
                        let extractedText: String = await {
                            do {
                                return try await ImageVisionService.extractText(from: image)
                            } catch {
                                return ""
                            }
                        }()
                        let hasUseful = !extractedText.isEmpty || imageBytes != nil
                        guard hasUseful else {
                            docErrorMessage = "Obrázek se nepodařilo zpracovat."
                            showingDocError = true
                            continue
                        }
                        let displayName = extractedText.isEmpty
                            ? "Fotografie"
                            : "Fotografie (Text)"
                        let newAttachment = Message.Attachment(
                            id: UUID(),
                            filename: displayName,
                            extractedText: extractedText,
                            imageData: imageBytes,
                            imageMimeType: imageBytes == nil ? nil : "image/jpeg"
                        )
                        attachments.append(newAttachment)
                    }
                }
                selectedPhotos.removeAll() // reset
            }
        }
        .alert("Chyba při nahrávání", isPresented: $showingDocError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(docErrorMessage)
        }
    }

    private var contextBarColor: Color {
        if tokenFill > 0.9 { return HHTheme.danger }
        if tokenFill > 0.75 { return HHTheme.warning }
        return HHTheme.accent.opacity(0.6)
    }

    /// The context-fill strip rendered above the divider. Two layers:
    /// a 3 px progress bar that animates as the conversation grows,
    /// and a small percentage / state chip that surfaces once the
    /// fill crosses 70% so the user knows it's getting tight without
    /// needing to enable the dev-only `TokenUsageBadge`.
    @ViewBuilder
    private var contextFillStrip: some View {
        VStack(spacing: 0) {
            if tokenFill > 0.7 {
                HStack(spacing: 6) {
                    Image(systemName: tokenFill > 0.9
                          ? "exclamationmark.circle.fill"
                          : "circle.lefthalf.filled")
                        .imageScale(.small)
                    Text(contextFillLabel)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(contextBarColor)
                .padding(.horizontal, HHTheme.spaceM)
                .padding(.vertical, 3)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Kontext zaplněn z \(Int(tokenFill * 100)) procent")
            }
            GeometryReader { geo in
                Rectangle()
                    .fill(contextBarColor)
                    .frame(width: geo.size.width * tokenFill)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.3), value: tokenFill)
            }
            .frame(height: 3)
        }
    }

    /// One-line description for the chip. We avoid raw "85 %" by
    /// itself — pair it with a hint about what happens next so the
    /// number is actionable instead of just alarming.
    private var contextFillLabel: String {
        let pct = Int((tokenFill * 100).rounded())
        if tokenFill > 0.9 {
            return "Kontext skoro plný (\(pct) %) — starší zprávy se brzy zhustí do shrnutí"
        }
        if tokenFill > 0.75 {
            return "Kontext \(pct) % — udržuju historii čistou"
        }
        return "Kontext \(pct) %"
    }

    /// Maximum dimension the resulting `UIImage` should have on its
    /// longest edge. Picked to comfortably exceed the resolution at
    /// which Vision's text recogniser starts to lose accuracy on
    /// fine print (~700 px on most fonts), with headroom for
    /// downstream consumers that may want pixel-accurate crops.
    private static let visionMaxDimension: CGFloat = 1024

    /// Aspect-ratio-preserving downscale using UIGraphicsImageRenderer
    /// (bridges to the modern, color-space-aware bitmap path under
    /// the hood). Returns the original image untouched when it
    /// already fits — avoids paying the bitmap allocation cost on
    /// thumbnails or screen-shot snippets that came in small.
    static func downscaledForVision(_ image: UIImage) -> UIImage {
        let size = image.size
        let longestEdge = max(size.width, size.height)
        guard longestEdge > visionMaxDimension else { return image }
        let scale = visionMaxDimension / longestEdge
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        // `scale = 1` produces pixel-accurate target dimensions
        // regardless of @2x / @3x display scale — the resulting
        // bitmap is the right size for both Vision and any future
        // disk-serialised representation.
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
