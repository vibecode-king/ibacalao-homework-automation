import XCTest
@testable import LiveExaminerOverlayCore

@MainActor
final class NativeWorkspaceNavigationTests: XCTestCase {
    func testProductShellUsesHomeworkForEveryHost() {
        let preview = "https://ibacalao-git-staging-vanos-projects-91d1222a.vercel.app"
        XCTAssertEqual(NativeRoutes.landingPath(for: preview), "/homework")
        XCTAssertEqual(NativeRoutes.initialLaunchPath(for: preview), "/login?redirect=%2Fhomework")
        XCTAssertEqual(NativeRoutes.landingPath(for: "https://app.ibacalao.com"), "/homework")
        XCTAssertEqual(NativeRoutes.initialLaunchPath(for: "https://app.ibacalao.com"), "/login?redirect=%2Fhomework")
        XCTAssertEqual(NativeRoutes.landingPath(for: "https://untrusted.vercel.app"), "/homework")
    }

    func testAllLegacyProductRoutesReturnToHomework() {
        let retired = [
            "/cas", "/cas/projects", "/chat", "/dashboard", "/today", "/tools/cas-log",
            "/tools/cas-project", "/tools/audio", "/tools/hub/marginalia", "/tools/live-examiner",
            "/dashboard/dispatch", "/wearables/digital", "/profile", "/settings", "/teacher",
        ]
        for path in retired {
            XCTAssertTrue(NativeRoutes.isRetiredProductRoute(URL(string: "https://www.ibacalao.com\(path)")!), "Expected retired route: \(path)")
        }
        let active = [
            "/homework", "/homework/sign-in", "/login?redirect=%2Fhomework",
            "/school-connected", "/privacy", "/terms", "/api/auth/me", "/_next/static/chunk.js",
        ]
        for path in active {
            XCTAssertFalse(NativeRoutes.isRetiredProductRoute(URL(string: "https://www.ibacalao.com\(path)")!), "Expected active Homework route: \(path)")
        }
    }
}
