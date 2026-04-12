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
                Menu {
                    Button(action: { showingFilePicker = true }) {
                        Label("Vybrat soubor", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24))
                        .foregroundColor(HHTheme.accent)
                        .padding(8)
                        .background(
                            Circle().stroke(HHTheme.accent, lineWidth: 1)
                        )
                }
                .padding(.bottom, 2)
                
                // Add PhotosPicker invisibly over the menu, wait, a Menu can't easily host a PhotosPicker button directly due to iOS 16 limitations unless using UIViewControllerRepresentable. 
                // Let's just overlay a generic button or add an explicit PhotosPicker inside the HStack.
                PhotosPicker(selection: $selectedPhotos, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundColor(HHTheme.accent)
                        .padding(8)
                        .background(
                            Circle().stroke(HHTheme.accent, lineWidth: 1)
                        )
                }
                .padding(.bottom, 2)
                
                Button(action: {
                    HHHaptics.impact(.light, enabled: settings.current.haptics)
                    isWebSearchEnabled.toggle()
                }) {
                    Image(systemName: "globe")
                        .font(.system(size: 24))
                        .foregroundColor(isWebSearchEnabled ? .white : HHTheme.textSecondary)
                        .padding(8)
                        .background(
                            Circle().fill(isWebSearchEnabled ? HHTheme.accent : Color.clear)
                        )
                }
                .padding(.bottom, 2)
                
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .font(HHTheme.body)
                    .padding(.horizontal, HHTheme.spaceL)
                    .padding(.vertical, HHTheme.spaceM)
                    .background(
                        RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                            .fill(HHTheme.surface)
                    )

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

    private var contextBarColor: Color {
        if tokenFill > 0.9 { return HHTheme.danger }
        if tokenFill > 0.75 { return HHTheme.warning }
        return HHTheme.accent.opacity(0.6)
    }
}
