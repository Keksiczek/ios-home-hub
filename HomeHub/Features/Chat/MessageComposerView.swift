import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import os

private let composerLog = Logger(subsystem: "HomeHub", category: "MessageComposerView")

struct MessageComposerView: View {
    @EnvironmentObject private var settings: SettingsService
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
                for url in urls {
                    do {
                        let extracted = try DocumentReaderService.extractText(from: url)
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
                        // similar scale anyway). Originals never enter
                        // SwiftData — only the OCR'd text does — so
                        // there's no quality argument for keeping the
                        // full-resolution UIImage past this point.
                        let image = Self.downscaledForVision(original)
                        do {
                            let extractedText = try await ImageVisionService.extractText(from: image)
                            let newAttachment = Message.Attachment(
                                id: UUID(),
                                filename: "Fotografie (Text)",
                                extractedText: extractedText
                            )
                            attachments.append(newAttachment)
                        } catch {
                            docErrorMessage = "Z obrázku se nepodařilo přečíst žádný text."
                            showingDocError = true
                        }
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
