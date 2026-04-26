import SwiftUI

/// Sheet that lets the user import a GGUF model from a direct HTTPS URL.
///
/// ## Pre-flight verification
///
/// Pasting a URL kicks off a HEAD + Range-GET probe via
/// `ModelDownloadService.probeURL` so the user gets fast feedback ("285 MB,
/// valid GGUF") before committing to a multi-GB download. The probe also
/// derives a friendly default name from the filename and surfaces auth
/// errors (401/403 → gated repository) up front. The legacy "type the
/// name, paste the URL, hope for the best, find out 5 minutes later it
/// was a 404" flow is gone.
struct AddFromURLSheet: View {
    @EnvironmentObject private var downloads: ModelDownloadService
    @EnvironmentObject private var catalog: ModelCatalogService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var urlString: String = ""
    @State private var contextLengthText: String = "4096"
    @State private var validationError: String? = nil

    /// State machine for the URL-probe lifecycle. Drives the inline
    /// status row (spinner / size / error) and gates "Add" so the user
    /// can't submit a known-broken URL.
    @State private var probe: ProbeState = .idle
    @State private var probeTask: Task<Void, Never>? = nil

    @FocusState private var focusedField: Field?

    private enum Field { case name, url, context }

    private enum ProbeState: Equatable {
        case idle
        case probing
        case ok(ModelDownloadService.URLProbe)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                requiredSection
                probeStatusSection
                optionalSection

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
                    Button("Cancel") {
                        probeTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { submit() }
                        .bold()
                        .disabled(!canSubmit)
                }
            }
        }
        .onChange(of: urlString) { _, newValue in
            handleURLChange(newValue)
        }
    }

    // MARK: - Sections

    private var requiredSection: some View {
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
            Text("URL must point directly to a .gguf file (e.g. on Hugging Face). Hugging Face `/blob/` links are auto-rewritten to `/resolve/`.")
        }
    }

    @ViewBuilder
    private var probeStatusSection: some View {
        switch probe {
        case .idle:
            EmptyView()

        case .probing:
            Section {
                HStack(spacing: HHTheme.spaceM) {
                    ProgressView().controlSize(.small)
                    Text("Verifying URL…")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                }
            }

        case .ok(let result):
            Section {
                probeRow(
                    icon: result.isGGUF ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    color: result.isGGUF ? HHTheme.success : HHTheme.warning,
                    title: result.isGGUF ? "Valid GGUF" : "Reachable, but not a GGUF",
                    detail: result.isGGUF
                        ? "First 4 bytes match the GGUF magic header."
                        : "First 4 bytes don't match GGUF. Download will fail validation."
                )
                if let size = result.sizeBytes, size > 0 {
                    probeRow(
                        icon: "internaldrive",
                        color: HHTheme.textSecondary,
                        title: Self.byteFormatter.string(fromByteCount: size),
                        detail: "From server `Content-Length` — used for the disk-space check."
                    )
                }
                if let detail = result.detail {
                    probeRow(
                        icon: "info.circle",
                        color: HHTheme.warning,
                        title: "Heads-up",
                        detail: detail
                    )
                }
            } header: {
                Text("Verification")
            }

        case .failed(let message):
            Section {
                probeRow(
                    icon: "exclamationmark.triangle.fill",
                    color: HHTheme.danger,
                    title: "Couldn't verify URL",
                    detail: message
                )
            } header: {
                Text("Verification")
            }
        }
    }

    private var optionalSection: some View {
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
    }

    private func probeRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: HHTheme.spaceM) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HHTheme.caption.weight(.semibold))
                Text(detail)
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Probe orchestration

    /// Cancels any in-flight probe, then debounces the next one. Pasting
    /// a URL fires several `onChange` notifications in a row (URL field
    /// reformatting); the 400 ms debounce avoids spamming the network.
    private func handleURLChange(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        probeTask?.cancel()
        probeTask = nil
        if trimmed.isEmpty {
            probe = .idle
            return
        }
        guard let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https" else {
            probe = .idle
            return
        }
        probe = .probing
        probeTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            do {
                let result = try await ModelDownloadService.probeURL(url)
                if Task.isCancelled { return }
                await MainActor.run {
                    probe = .ok(result)
                    // Auto-fill name from the URL filename only when the
                    // user hasn't typed anything yet. Clearing the field
                    // re-arms the auto-fill, so re-pasting a URL gives a
                    // fresh suggestion without surprising the user mid-edit.
                    if name.trimmingCharacters(in: .whitespaces).isEmpty,
                       let suggested = result.suggestedName {
                        name = suggested
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    probe = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Submission

    private var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !urlString.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        // Block submission when the probe definitively failed — there's no
        // point starting a download we already know will fail. `idle` and
        // `probing` are still allowed so the user isn't blocked when the
        // probe is slow or skipped (e.g. behind a captive portal).
        if case .failed = probe { return false }
        if case .ok(let p) = probe, p.isGGUF == false, p.statusCode != 0 { return false }
        return true
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
        // Pass through the verified size when we have it so
        // `ModelDownloadService.start(_:)` can run its disk-space preflight
        // for user-added models too.
        let knownSize: Int64? = {
            if case .ok(let p) = probe { return p.sizeBytes }
            return nil
        }()
        do {
            try downloads.importFromURL(
                name: trimmedName,
                url: url,
                contextLength: contextLength,
                knownSizeBytes: knownSize
            )
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()
}
