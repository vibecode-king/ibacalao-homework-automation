import Foundation
import Security

struct NativeAccount: Equatable {
    let email: String
    let plan: String?
    let entitled: Bool
}

/// Stores the iBacalao website session token. Provider API keys are never accepted
/// or migrated; old BYOK files/keychain entries are removed silently at launch.
enum KeyStore {
    private static let service = "com.ibacalao.LiveExaminerOverlay"
    private static let sessionAccount = "ibacalao-session"
    private static let legacyFileName = "api-keys.json"
    private static var didMigrate = false

    private static func sessionQuery(account: String, returnData: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
        let query = sessionQuery(account: sessionAccount, returnData: true)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
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
        for account in ["anthropic", "openai", "freellm", "hosted"] {
            deleteKeychainQuietly(account: account)
        }
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
