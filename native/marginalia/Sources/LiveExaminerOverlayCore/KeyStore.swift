import Foundation
import Security
import LocalAuthentication

struct NativeAccount: Equatable {
    let id: String
    let email: String
    let plan: String?
    let planActive: Bool
    let entitled: Bool
    let credits: Int
    let username: String?
    let avatarB64: String?
}

/// Stores the iBacalao website session token. Provider API keys are never accepted
/// or migrated; old BYOK files/keychain entries are removed silently at launch.
enum KeyStore {
    private static let service = "com.ibacalao.LiveExaminerOverlay"
    private static let sessionAccount = "ibacalao-session"
    private static let legacyFileName = "api-keys.json"
    private static var didMigrate = false

    private static let noUIContext: LAContext = {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        return ctx
    }()

    private static func sessionQuery(account: String, returnData: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: noUIContext,
            // Fail closed instead of showing or waiting on a Keychain ACL dialog.
            // This app intentionally never asks for a login-password prompt at launch.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let group = AppSandbox.keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    static func saveSessionToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let data = Data(trimmed.utf8)
        let query = sessionQuery(account: sessionAccount)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeyStoreError.saveFailed(Self.describe(addStatus))
            }
        } else if status != errSecSuccess {
            throw KeyStoreError.saveFailed(Self.describe(status))
        }
        dlog("[KeyStore] saved iBacalao session token")
    }

    static func loadSessionToken() -> String? {
        migrateIfNeeded()
        // Preview deployments resolve any bearer to the shared preview account, so native screens load preview data without a login.
        if Self.isPreviewAPIHost { return "preview-session" }
        // Explicit local UI tests should never touch the user's real Keychain.
        // Returning the existing dev sentinel first also prevents macOS from
        // presenting a password dialog when a temporary test build is signed
        // differently from the installed app.
        if UserDefaults.standard.bool(forKey: "skipLoginForDev"), Self.isLocalAPIHost {
            return "dev-local"
        }
        // #region agent log
        agentLog("H2", location: "KeyStore.swift:loadSessionToken", message: "keychain read", data: [:])
        // #endregion
        let query = sessionQuery(account: sessionAccount, returnData: true)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let token, !token.isEmpty, token != "dev-local" { return token }
        }
        return nil
    }

    private static var isPreviewAPIHost: Bool {
        guard let host = URL(string: LLMClient.resolvedNativeAPIBaseURL)?.host?.lowercased() else { return false }
        return NativeHostPolicy.isTrustedPreviewHost(host)
    }

    private static var isLocalAPIHost: Bool {
        let base = LLMClient.resolvedNativeAPIBaseURL
        return base.contains("127.0.0.1") || base.contains("localhost")
    }

    static func deleteSession() {
        SecItemDelete(sessionQuery(account: sessionAccount) as CFDictionary)
    }

    static func hasSessionToken() -> Bool {
        loadSessionToken() != nil
    }

    /// Call once at launch so legacy provider credentials are removed before any UI.
    static func migrateIfNeeded() {
        guard !didMigrate else { return }
        didMigrate = true
        deleteLegacyAppSupportFile()
        // Do not SecItemDelete leftover BYOK keys at launch. Each delete can
        // raise the macOS login-password sheet (four accounts = four prompts).
        // #region agent log
        agentLog("H1", location: "KeyStore.swift:migrateIfNeeded", message: "skipped keychain BYOK deletes", data: [:])
        // #endregion
    }

    private static func deleteLegacyAppSupportFile() {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let url = base.appendingPathComponent("iBacalao", isDirectory: true).appendingPathComponent(legacyFileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            dlog("[KeyStore] removed legacy provider key file")
        }
    }

    private static func deleteKeychainQuietly(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func describe(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
    }
}

enum KeyStoreError: LocalizedError {
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let detail):
            return "Couldn't save sign-in session (\(detail))."
        }
    }
}
