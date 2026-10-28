import XCTest
@testable import LiveExaminerOverlayCore

final class WatcherChildEnvironmentTests: XCTestCase {
    func testChildEnvironmentUsesAllowlistInsteadOfCopyingParentSecrets() {
        let environment = WatcherChildEnvironment.make(
            parentEnvironment: [
                "HOME": "/attacker/home",
                "PATH": "/attacker/bin",
                "TMPDIR": "/private/tmp",
                "OPENAI_API_KEY": "secret-api-key",
                "IBACALAO_TOKEN": "secret-watcher-token",
                "NODE_OPTIONS": "--require /tmp/injected.js",
            ],
            homeDirectory: "/Users/student",
            browsersPath: "/app/Runtime/browsers",
            nodeModulesPath: "/app/Runtime/node_modules",
            scraplingHelperPath: "/app/Runtime/scrapling-repair"
        )

        XCTAssertEqual(environment["HOME"], "/Users/student")
        XCTAssertEqual(environment["PATH"], WatcherChildEnvironment.systemPath)
        XCTAssertEqual(environment["TMPDIR"], "/private/tmp")
        XCTAssertEqual(environment["PLAYWRIGHT_BROWSERS_PATH"], "/app/Runtime/browsers")
        XCTAssertEqual(environment["NODE_PATH"], "/app/Runtime/node_modules")
        XCTAssertEqual(environment["IBACALAO_DESKTOP_BUNDLED"], "1")
        XCTAssertEqual(environment["IBACALAO_SCRAPLING_HELPER"], "/app/Runtime/scrapling-repair")
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["IBACALAO_TOKEN"])
        XCTAssertNil(environment["NODE_OPTIONS"])
    }
}
