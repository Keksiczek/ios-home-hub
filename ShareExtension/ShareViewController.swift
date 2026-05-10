import UIKit
import SwiftUI

/// Entry point for the Share Extension.
///
/// Two responsibilities:
/// 1. Host a tiny SwiftUI status view ("Saving…", success, error).
/// 2. Run the `ShareItemExtractor` against `extensionContext.inputItems`
///    and dismiss as soon as it finishes.
///
/// The extension does **no** parsing/embedding/networking. The
/// pipeline lives in the host app — we only persist the raw payload
/// + a `ShareRequest` so the host app can pick it up on next launch
/// or via the foreground/BG drain (see `KnowledgeBaseService`).
///
/// Lifetime is intentionally short. iOS gives Share Extensions a
/// few seconds before the user expects the sheet to vanish; if we
/// haven't finished by then, the user has either dismissed the
/// sheet or the extension is about to be killed. Persisting first
/// + showing UI second means even an aggressive system kill leaves
/// the user's data on disk.
final class ShareViewController: UIViewController {

    private var hostingController: UIHostingController<StatusView>?
    private let viewState = StatusViewState()

    override func viewDidLoad() {
        super.viewDidLoad()
        installStatusUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginExtraction()
    }

    // MARK: - UI

    private func installStatusUI() {
        let host = UIHostingController(rootView: StatusView(state: viewState))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    // MARK: - Extraction

    private func beginExtraction() {
        let context = extensionContext
        let items = (context?.inputItems as? [NSExtensionItem]) ?? []
        guard let storage = try? SharedStorage() else {
            // Most common cause: the App Group entitlement isn't on
            // the extension target. Show a clear error and tell the
            // system "we tried" via `cancelRequest` so iOS doesn't
            // animate a misleading success state.
            viewState.phase = .failure("App Group container není dostupný. Zkontrolujte entitlements.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                context?.cancelRequest(withError: NSError(
                    domain: "ShareExtension",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "App Group missing"]
                ))
            }
            return
        }

        let store = SharePayloadStore(storage: storage)
        let extractor = ShareItemExtractor(
            storage: storage,
            payloadStore: store,
            hostBundleID: Bundle.main.bundleIdentifier,
            defaultAction: ShareAction.saveToKnowledgeBase
        )

        viewState.phase = .working

        Task { [weak self] in
            let summary = await extractor.extract(from: items)
            await MainActor.run {
                self?.finish(with: summary, context: context)
            }
        }
    }

    private func finish(
        with summary: ShareItemExtractor.ExtractionSummary,
        context: NSExtensionContext?
    ) {
        if summary.didStoreAnything {
            viewState.phase = .success(
                succeeded: summary.succeeded,
                failed: summary.failed
            )
            // Brief flash of success, then dismiss. The user already
            // knows it worked (the share sheet animates away);
            // 600 ms is enough to register the green check.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                context?.completeRequest(returningItems: nil)
            }
        } else {
            let message = summary.failed > 0
                ? "Sdílení selhalo – \(summary.failed) položek se nepovedlo uložit."
                : "Tento obsah se nepodařilo přečíst."
            viewState.phase = .failure(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                context?.cancelRequest(withError: NSError(
                    domain: "ShareExtension",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: message]
                ))
            }
        }
    }
}

// MARK: - SwiftUI status surface

@MainActor
private final class StatusViewState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working
        case success(succeeded: Int, failed: Int)
        case failure(String)
    }

    @Published var phase: Phase = .idle
}

private struct StatusView: View {
    @ObservedObject var state: StatusViewState

    var body: some View {
        VStack(spacing: 16) {
            switch state.phase {
            case .idle, .working:
                ProgressView()
                    .controlSize(.large)
                Text("Ukládám do HomeHubu…")
                    .font(.headline)
            case .success(let succeeded, let failed):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("Uloženo")
                    .font(.headline)
                Text(detailLine(succeeded: succeeded, failed: failed))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .failure(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Chyba")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color(.systemBackground))
    }

    private func detailLine(succeeded: Int, failed: Int) -> String {
        if failed > 0 {
            return "\(succeeded) položek uloženo, \(failed) selhalo"
        }
        return succeeded == 1
            ? "1 položka připravena na zpracování"
            : "\(succeeded) položek připraveno na zpracování"
    }
}
