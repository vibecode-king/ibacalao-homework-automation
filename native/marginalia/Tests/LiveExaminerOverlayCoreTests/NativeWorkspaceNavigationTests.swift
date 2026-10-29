import XCTest
@testable import LiveExaminerOverlayCore

@MainActor
final class NativeWorkspaceNavigationTests: XCTestCase {
    func testProductShellUsesHomeworkForTrustedPreviewAndChatInProduction() {
        let preview = "https://ibacalao-git-staging-vanos-projects-91d1222a.vercel.app"
        XCTAssertEqual(NativeRoutes.landingPath(for: preview), "/homework")
        XCTAssertEqual(NativeRoutes.initialLaunchPath(for: preview), "/desktop-entry")
        XCTAssertEqual(NativeRoutes.landingPath(for: "https://app.ibacalao.com"), "/chat")
        XCTAssertEqual(NativeRoutes.initialLaunchPath(for: "https://app.ibacalao.com"), "/desktop-entry")
        XCTAssertEqual(NativeRoutes.landingPath(for: "https://untrusted.vercel.app"), "/chat")
    }

    func testProfileAndSettingsProductRoutesStayNative() {
        let navigation = NativeWorkspaceNavigation.shared
        let paths = [
            "/profile",
            "/settings",
            "/account",
            "/school-connection",
            "/customization",
            "/reminders",
        ]

        for path in paths {
            XCTAssertTrue(navigation.canOpenNativePath(path), "Expected native route for \(path)")
        }
        XCTAssertFalse(navigation.canOpenNativePath("/privacy"))
        XCTAssertFalse(navigation.canOpenNativePath("/support"))
        XCTAssertFalse(navigation.canOpenNativePath("/chat"), "Chat should stay in the shell WKWebView instead of being rewritten as a native screen")
    }

    func testChatToolAliasesOpenNativeDesktopSurfaces() {
        let navigation = NativeWorkspaceNavigation.shared
        let aliases: [(String, NativeWorkspaceTab)] = [
            ("/tools/inbox", .toolsInbox),
            ("/tools/hub/inbox", .toolsInbox),
            ("/tools/camera", .toolsCamera),
            ("/tools/hub/camera", .toolsCamera),
            ("/tools/audio", .toolsAudio),
            ("/tools/hub/audio", .toolsAudio),
            ("/tools/hub/marginalia", .toolsMarginalia),
        ]

        for (path, expectedTab) in aliases {
            XCTAssertTrue(navigation.openNativePath(path), "Expected native route for \(path)")
            XCTAssertEqual(navigation.selection, expectedTab, "Wrong native surface for \(path)")
            navigation.dismiss()
        }
    }

    func testRetiredStudentToolsHomeStaysInChat() {
        let navigation = NativeWorkspaceNavigation.shared
        XCTAssertFalse(navigation.canOpenNativePath("/tools"))
        XCTAssertFalse(navigation.canOpenNativePath("/tools/hub"))
        XCTAssertTrue(navigation.openNativePath("/dashboard?view=student-tools"))
        XCTAssertEqual(navigation.selection, .dashboard)
        navigation.dismiss()
    }

    func testSettingsChildReturnsToSettingsWithoutWebFallback() {
        let navigation = NativeWorkspaceNavigation.shared
        XCTAssertTrue(navigation.openNativePath("/settings"))
        navigation.navigate(to: .account)
        XCTAssertEqual(navigation.selection, .account)

        navigation.goBack(fallback: .profile)
        XCTAssertEqual(navigation.selection, .settings)
        navigation.dismiss()
    }

    func testProfileChildReturnsToProfile() {
        let navigation = NativeWorkspaceNavigation.shared
        XCTAssertTrue(navigation.openNativePath("/profile"))
        navigation.navigate(to: .schoolConnection)
        XCTAssertEqual(navigation.selection, .schoolConnection)

        navigation.goBack(fallback: .profile)
        XCTAssertEqual(navigation.selection, .profile)
        navigation.dismiss()
    }
}
