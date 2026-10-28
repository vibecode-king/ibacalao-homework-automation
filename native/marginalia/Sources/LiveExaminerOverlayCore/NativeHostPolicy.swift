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
}
