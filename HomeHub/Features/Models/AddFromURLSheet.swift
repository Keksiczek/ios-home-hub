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
                buildBackendNotice
                requiredSection
                recentURLsSection
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
            .navigationTitle("Přidat z URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zrušit") {
                        probeTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Přidat") { submit() }
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

    /// Top-of-sheet notice that explains the runtime constraint for the
    /// import-by-URL flow. The flow only accepts direct `.gguf` links, which
    /// always target the llama.cpp backend — that backend isn't linked in
    /// the default MLX-only build, so we tell the user up front rather than
    /// letting them paste a URL, download 4 GB, and discover the constraint
    /// at load time.
    @ViewBuilder
    private var buildBackendNotice: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Podpora pro GGUF a MLX.")
                        .font(HHTheme.subheadline.weight(.semibold))
                    Text("Vlož přímý odkaz na GGUF pro llama.cpp, nebo použij `mlx://repo/id` pro import MLX modelu z Hugging Face.")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                }
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(HHTheme.accent)
            }
        }
    }

    private var requiredSection: some View {
        Section {
            TextField("Název modelu", text: $name)
                .focused($focusedField, equals: .name)
                .autocorrectionDisabled()
            TextField("https://…", text: $urlString)
                .focused($focusedField, equals: .url)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .autocorrectionDisabled()
        } header: {
            Text("Povinné")
        } footer: {
            Text("Zadej přímou .gguf URL (https://...) nebo MLX repo (mlx://mlx-community/Llama-3.2-1B-Instruct-4bit).")
        }
    }

    /// Persistent ring buffer of the most recently submitted URLs.
    /// Stored in UserDefaults so it survives app relaunches. Capped
    /// at 5 entries — the goal is to make "I just typed this 30 s
    /// ago" recovery a one-tap operation, not to be a full history
    /// browser. Most-recent first.
    @AppStorage(Self.recentURLsKey) private var recentURLsRaw: String = ""
    private static let recentURLsKey = "com.homehub.models.recentImportURLs"
    private static let recentURLsCap = 5

    private var recentURLs: [String] {
        recentURLsRaw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Rendered only when there's at least one prior URL and the field
    /// is empty / the probe hasn't started — once the user has typed
    /// something we get out of the way so the history doesn't compete
    /// with the probe status section for visual attention.
    @ViewBuilder
    private var recentURLsSection: some View {
        let urls = recentURLs
        if !urls.isEmpty,
           urlString.trimmingCharacters(in: .whitespaces).isEmpty {
            Section {
                ForEach(urls, id: \.self) { entry in
                    Button {
                        urlString = entry
                        // Derive a default name from the URL so the
                        // user doesn't have to retype it either. The
                        // user can still override before tapping Add.
                        if name.trimmingCharacters(in: .whitespaces).isEmpty {
                            name = Self.defaultName(from: entry)
                        }
                    } label: {
                        HStack {
                            Image(systemName: entry.lowercased().hasPrefix("mlx://") ? "shippingbox" : "doc.fill")
                                .foregroundStyle(HHTheme.textSecondary)
                            Text(entry)
                                .font(HHTheme.caption.monospaced())
                                .foregroundStyle(HHTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .onDelete { offsets in
                    var current = urls
                    current.remove(atOffsets: offsets)
                    recentURLsRaw = current.joined(separator: "\n")
                }
            } header: {
                Text("Recently used")
            } footer: {
                Text("Tap to fill the URL field. Swipe to remove.")
            }
        }
    }

    /// Updates the ring buffer. Called from `submit()` after a
    /// successful import enqueue — failed submissions don't pollute
    /// the history. De-duplicates: if the URL is already in the
    /// list it gets promoted to the front instead of duplicated.
    private func rememberRecentURL(_ url: String) {
        var current = recentURLs
        current.removeAll { $0 == url }
        current.insert(url, at: 0)
        if current.count > Self.recentURLsCap {
            current = Array(current.prefix(Self.recentURLsCap))
        }
        recentURLsRaw = current.joined(separator: "\n")
    }

    /// Best-effort guess of a friendly display name from a URL —
    /// `mlx://mlx-community/Gemma-3-1B-It` → "Gemma 3 1B It";
    /// `https://hf.co/foo/bar/blob/main/model-q4.gguf` → "model q4".
    static func defaultName(from url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("mlx://"),
           let parsed = URL(string: trimmed) {
            let path = parsed.path
                .split(separator: "/")
                .last
                .map(String.init) ?? trimmed
            return path.replacingOccurrences(of: "-", with: " ")
        }
        let last = (trimmed as NSString).lastPathComponent
        let withoutExt = (last as NSString).deletingPathExtension
        return withoutExt.replacingOccurrences(of: "-", with: " ")
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
                    icon: result.isGGUF || urlString.lowercased().hasPrefix("mlx://") ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    color: result.isGGUF || urlString.lowercased().hasPrefix("mlx://") ? HHTheme.success : HHTheme.warning,
                    title: urlString.lowercased().hasPrefix("mlx://") ? "MLX Repo" : (result.isGGUF ? "Valid GGUF" : "Reachable, but not a GGUF"),
                    detail: urlString.lowercased().hasPrefix("mlx://")
                        ? "MLX repository identifier will be used."
                        : (result.isGGUF ? "First 4 bytes match the GGUF magic header." : "First 4 bytes don't match GGUF. Download will fail validation.")
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
              url.scheme == "http" || url.scheme == "https" || url.scheme == "mlx" else {
            probe = .idle
            return
        }
        
        if url.scheme == "mlx" {
            probe = .ok(ModelDownloadService.URLProbe(sizeBytes: nil, isGGUF: false, suggestedName: url.lastPathComponent, statusCode: 200, detail: nil))
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
        // MLX repos use mlx:// scheme — no GGUF header probe applies.
        if URL(string: urlString.trimmingCharacters(in: .whitespaces))?.scheme?.lowercased() == "mlx" {
            return true
        }
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
              url.scheme == "https" || url.scheme == "http" || url.scheme == "mlx" else {
            validationError = "URL must start with http://, https:// or mlx://."
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

        // Clamp to a sensible range. Below 512 tokens nothing useful fits;
        // above 131_072 we're outside any context window the runtime can
        // actually allocate on iOS hardware. Empty / non-numeric input
        // falls back to the curated 4 096 default.
        let contextLength = max(512, min(Int(contextLengthText) ?? 4096, 131_072))
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
            // Only the success path populates the recent-URLs history
            // — a failed import shouldn't pollute it with bad inputs
            // that the user is about to correct anyway.
            rememberRecentURL(trimmedURL)
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
