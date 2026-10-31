import Foundation

enum NativeHostPolicy {
    private static let trustedVercelPreviewPattern =
        #"^ibacalao-git-[a-z0-9-]+-vanos-projects-91d1222a\.vercel\.app$"#

    static func isTrustedPreviewHost(_ rawHost: String) -> Bool {
        rawHost.lowercased().range(
            of: trustedVercelPreviewPattern,
            options: .regularExpression
        ) != nil
    }

    /// Hosts allowed to load in the desktop shell and to call native bridges.
    static func isTrustedShellHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased()
        if host == "ibacalao.com" || host == "www.ibacalao.com" || host == "localhost" || host == "127.0.0.1" {
            return true
        }
        if host.hasSuffix(".ibacalao.com") { return true }
        return isTrustedPreviewHost(host)
    }

    /// Page-world script handlers are visible to every frame. Only first-party
    /// HTTPS (and local HTTP) origins may invoke them.
    static func allowsWebOrigin(scheme: String, host: String) -> Bool {
        let scheme = scheme.lowercased()
        let host = host.lowercased()
        if scheme == "https" { return isTrustedShellHost(host) }
        if scheme == "http" { return host == "localhost" || host == "127.0.0.1" }
        return false
    }
}
