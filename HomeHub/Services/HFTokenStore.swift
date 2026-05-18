import Foundation
import Security
import os

/// Secure storage for the user's Hugging Face access token.
///
/// Tokens belong in the Keychain rather than `AppSettings` (which is
/// plain-JSON on disk) because:
///   - They authenticate against a third-party service that can be
///     used to download paid/gated content under the user's account.
///   - iOS backups exposing the on-disk settings file should not leak
///     them; Keychain entries with `kSecAttrAccessibleAfterFirstUnlock`
///     stay on-device.
///
/// The store is intentionally tiny — three operations (save / load /
/// clear) and one `hasToken` synchronous probe for view gating. Adding
/// a multi-account model or rotation logic would require revisiting,
/// but the catalog only needs a single token today.
enum HFTokenStore {

    private static let service = "com.homehub.app.huggingface"
    private static let account = "default"
    private static let log = Logger(subsystem: "HomeHub", category: "HFTokenStore")

    /// UserDefaults key for the timestamp of the most recent successful
    /// `whoami-v2` validation. Not stored in the Keychain because the
    /// value isn't a secret — it's metadata the Settings UI uses to
    /// render "Naposledy ověřeno před X dny". Stored separately from
    /// the token itself so a fresh validation can update it without
    /// re-writing the Keychain entry.
    private static let lastVerifiedKey = "com.homehub.app.huggingface.lastVerifiedAt"
    /// UserDefaults key for the username HF echoed at last validation.
    /// Lets the Settings row display "stepan" instead of just a date,
    /// which makes the "is the right account configured?" question
    /// answerable without re-running the probe.
    private static let lastUsernameKey = "com.homehub.app.huggingface.lastUsername"

    // MARK: - Public API

    /// Persists `token` to the Keychain. Pass an empty / whitespace-only
    /// string to clear the entry instead — saves the caller a separate
    /// `clear()` round trip when the user blanks the field.
    @discardableResult
    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return true
        }
        let data = Data(trimmed.utf8)

        // Update-then-add: SecItemUpdate is the only way to replace an
        // existing entry's `kSecValueData` without reading the old value
        // back. If nothing exists yet, fall through to SecItemAdd.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateAttributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        var status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.error("HFTokenStore: save failed with OSStatus \(status)")
            return false
        }
        log.info("HFTokenStore: token persisted (\(trimmed.count) chars)")
        return true
    }

    /// Returns the persisted token, or `nil` if none has been stored or
    /// the Keychain rejected the request (locked device + non-AfterFirstUnlock
    /// access class, etc.). Never throws — callers default to anonymous
    /// requests on `nil`.
    static func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                log.notice("HFTokenStore: load returned OSStatus \(status) (treating as no-token)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the stored token. Idempotent — `errSecItemNotFound` is
    /// treated as success because the post-condition (no token in the
    /// Keychain) holds either way.
    static func clear() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("HFTokenStore: clear failed with OSStatus \(status)")
        }
    }

    /// Cheap "is a token configured?" probe for view gating. Returns
    /// `true` even if the load would fail later (e.g. device just locked
    /// and the entry isn't AlwaysReadable) — the only call site is the
    /// Settings UI, where the user is by definition unlocked.
    static var hasToken: Bool { load()?.isEmpty == false }

    // MARK: - Verification metadata

    /// Records that `username` authenticated successfully at `Date()`.
    /// Called by `SettingsView` after a successful `whoami-v2` probe.
    /// Cheap (two UserDefaults writes); no Keychain round-trip.
    static func recordVerification(username: String) {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: lastVerifiedKey)
        defaults.set(username, forKey: lastUsernameKey)
    }

    /// Snapshot of the most recent verification, or `nil` if none has
    /// happened (token saved but never validated, OR token cleared
    /// via `clear()`). Reading both keys at once keeps the UI from
    /// rendering half-states like "verified as ? — unknown when".
    static func lastVerification() -> (username: String, at: Date)? {
        let defaults = UserDefaults.standard
        let ts = defaults.double(forKey: lastVerifiedKey)
        guard ts > 0, let name = defaults.string(forKey: lastUsernameKey) else { return nil }
        return (name, Date(timeIntervalSince1970: ts))
    }

    /// Wipes both the token and the verification metadata. Used by
    /// "Restart onboarding" / "Clear token" paths so a future user
    /// of the same install doesn't inherit the previous account's
    /// signed-in state.
    static func clearAll() {
        clear()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastVerifiedKey)
        defaults.removeObject(forKey: lastUsernameKey)
    }
}
