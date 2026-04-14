import SwiftUI

/// Sheet that lets the user import a GGUF model from a direct HTTPS URL.
/// Validates inputs before handing off to `ModelDownloadService.importFromURL()`.
struct AddFromURLSheet: View {
    @EnvironmentObject private var downloads: ModelDownloadService
    @EnvironmentObject private var catalog: ModelCatalogService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var urlString: String = ""
    @State private var contextLengthText: String = "4096"
    @State private var validationError: String? = nil
    @FocusState private var focusedField: Field?

    private enum Field { case name, url, context }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Model name", text: $name)
                        .focused($focusedField, equals: .name)
                        .autocorrectionDisabled()
                    TextField("https://…", text: $urlString)
                        .focused($focusedField, equals: .url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } header: {
                    Text("Required")
                } footer: {
                    Text("URL must point directly to a .gguf file (e.g. on HuggingFace).")
                }

                Section {
                    HStack {
                        Text("Context length")
                        Spacer()
                        TextField("4096", text: $contextLengthText)
                            .focused($focusedField, equals: .context)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("tokens")
                            .foregroundStyle(HHTheme.textSecondary)
                    }
                } header: {
                    Text("Optional")
                } footer: {
                    Text("Leave at 4096 if you're not sure. This is only used for display — the actual limit comes from the model file.")
                }

                if let error = validationError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(HHTheme.warning)
                            .font(HHTheme.caption)
                    }
                }
            }
            .navigationTitle("Add from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { submit() }
                        .bold()
                        .disabled(!canSubmit)
                }
            }
        }
    }

    // MARK: - Validation

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL  = urlString.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationError = "Model name is required."
            return
        }
        guard !trimmedURL.isEmpty else {
            validationError = "Download URL is required."
            return
        }
        guard let url = URL(string: trimmedURL),
              url.scheme == "https" || url.scheme == "http" else {
            validationError = "URL must start with http:// or https://."
            return
        }

        // Check for an existing model with a suspiciously similar ID.
        let sanitized = trimmedName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        let wouldBeID = "user-\(sanitized)"
        if catalog.models.contains(where: { $0.id.hasPrefix(wouldBeID) && $0.installState != .notInstalled }) {
            validationError = "A model with a similar name is already downloaded. Choose a different name or delete the existing one first."
            return
        }

        let contextLength = Int(contextLengthText) ?? 4096
        do {
            try downloads.importFromURL(name: trimmedName, url: url, contextLength: contextLength)
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}
