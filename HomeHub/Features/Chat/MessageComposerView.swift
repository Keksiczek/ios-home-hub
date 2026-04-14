import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

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
    @State private var isWebSearchEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            // Context usage bar — visible only when context is getting full
            if tokenFill > 0.5 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(contextBarColor)
                        .frame(width: geo.size.width * tokenFill)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeInOut(duration: 0.3), value: tokenFill)
                }
                .frame(height: 2)
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
                            Label("Search web", systemImage: "checkmark")
                        } else {
                            Label("Search web", systemImage: "globe")
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
                    TextField("Message", text: $draft, axis: .vertical)
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
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .accessibilityLabel("Disable web search")
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
                    .accessibilityLabel("Stop")
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
                    .accessibilityLabel("Send")
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
                print("File picking failed: \(error.localizedDescription)")
            }
        }
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
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

    @State private var showingPhotoPicker = false

    private var contextBarColor: Color {
        if tokenFill > 0.9 { return HHTheme.danger }
        if tokenFill > 0.75 { return HHTheme.warning }
        return HHTheme.accent.opacity(0.6)
    }
}
