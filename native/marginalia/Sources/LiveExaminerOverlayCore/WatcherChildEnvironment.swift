import Foundation

enum WatcherChildEnvironment {
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    static func make(
        parentEnvironment: [String: String],
        homeDirectory: String,
        browsersPath: String,
        nodeModulesPath: String,
        scraplingHelperPath: String?
    ) -> [String: String] {
        var environment = [
            "HOME": homeDirectory,
            "PATH": systemPath,
            "PLAYWRIGHT_BROWSERS_PATH": browsersPath,
            "NODE_PATH": nodeModulesPath,
            "IBACALAO_DESKTOP_BUNDLED": "1",
        ]
        if let temporaryDirectory = parentEnvironment["TMPDIR"], !temporaryDirectory.isEmpty {
            environment["TMPDIR"] = temporaryDirectory
        }
        if let scraplingHelperPath {
            environment["IBACALAO_SCRAPLING_HELPER"] = scraplingHelperPath
        }
        return environment
    }
}
