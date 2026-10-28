import Foundation
import Security

/// Runtime App Sandbox detection — works for MAS-signed builds without relying on
/// `MAS` compile flags propagating into the SwiftPM core library target.
enum AppSandbox {
    static let isEnabled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.app-sandbox" as CFString,
            nil
        ) else { return false }
        return (value as? Bool) == true
    }()

    /// First keychain access group from entitlements (MAS builds declare
    /// `$(AppIdentifierPrefix)com.ibacalao.LiveExaminerOverlay`).
    static var keychainAccessGroup: String? {
        guard isEnabled else { return nil }
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let groups = SecTaskCopyValueForEntitlement(
            task,
            "keychain-access-groups" as CFString,
            nil
        ) as? [String] else { return nil }
        return groups.first { $0.hasSuffix("com.ibacalao.LiveExaminerOverlay") } ?? groups.first
    }
}
