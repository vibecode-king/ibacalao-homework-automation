import XCTest
@testable import LiveExaminerOverlayCore

final class SchoolWatcherServiceTests: XCTestCase {
    func testPlatformIDNormalizationIsFilesystemSafe() {
        XCTAssertEqual(SchoolWatcherService.normalizedPlatformID("  Canvas / My School  "), "canvas-my-school")
        XCTAssertEqual(SchoolWatcherService.normalizedPlatformID("managebac"), "managebac")
        XCTAssertEqual(SchoolWatcherService.normalizedPlatformID("../../Schoology"), "schoology")
    }

    func testPlatformIDNormalizationRejectsOnlyPunctuation() {
        XCTAssertEqual(SchoolWatcherService.normalizedPlatformID("///"), "")
    }
    func testDiscoveryOutputParsesConnection() {
        let output = "noise\nIBACALAO_SCHOOL_CONNECTED\t{\"platformId\":\"learnbox\",\"platformLabel\":\"Learnbox\",\"schoolLabel\":\"San Ignacio\",\"origin\":\"https://sanignacio.learnbox.com\",\"siteKey\":\"learnbox.com\",\"recognized\":false,\"profileKey\":\"school-platform\",\"connectedAt\":\"2026-09-11T12:00:00.000Z\"}\n"
        let connection = SchoolWatcherService.parseDiscoveryOutput(output)
        XCTAssertEqual(connection?.platformId, "learnbox")
        XCTAssertEqual(connection?.platformLabel, "Learnbox")
        XCTAssertEqual(connection?.schoolLabel, "San Ignacio")
    }

    func testDiscoveryOutputIgnoresOrdinaryLogs() {
        XCTAssertNil(SchoolWatcherService.parseDiscoveryOutput("Opening browser\nNo result\n"))
    }

    func testSchoolPlatformStatusDecodesActionState() throws {
        let json = #"{"sourceKey":"vendor:learnbox","platformLabel":"Learnbox","schoolLabel":"Ukschool","connected":true,"syncMode":"passive_browser","actionReason":"manual_learning_required","recipe":{"state":"missing"},"missingCapabilities":["assignments","messages"]}"#
        let status = try JSONDecoder().decode(SchoolPlatformStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.platformLabel, "Learnbox")
        XCTAssertEqual(status.actionReason, "manual_learning_required")
        XCTAssertEqual(status.recipe?.state, "missing")
        XCTAssertEqual(status.missingCapabilities, ["assignments", "messages"])
    }

    func testSchoolPlatformOpenModeRecognizesLearningAction() {
        XCTAssertEqual(SchoolPlatformOpenMode(rawValue: "learn"), .learn)
        XCTAssertEqual(SchoolPlatformOpenMode(rawValue: "reconnect"), .reconnect)
        XCTAssertNil(SchoolPlatformOpenMode(rawValue: "crawl"))
    }

    func testStudentReportHeadlineIsOneLine() {
        XCTAssertEqual(SchoolWatcherService.studentReportHeadline(actionReason: "reauth_required", ibacalaoSignedIn: false), "Signed out of iBacalao")
        XCTAssertEqual(SchoolWatcherService.studentReportHeadline(actionReason: "reauth_required", ibacalaoSignedIn: true), "School sign-in needed")
        XCTAssertEqual(SchoolWatcherService.studentReportHeadline(actionReason: "connector_stale", ibacalaoSignedIn: true), "Mac not syncing")
        XCTAssertEqual(SchoolWatcherService.studentReportHeadline(actionReason: "manual_learning_required", ibacalaoSignedIn: true), "Finish setup (one visit)")
    }

    func testStaleStatusKeepsSessionBarriers() {
        let base = SchoolPlatformStatus(
            sourceKey: "vendor:managebac",
            platformLabel: "ManageBac",
            schoolLabel: "School",
            connected: true,
            syncMode: "verified_background",
            actionReason: "none",
            lastSuccessAt: "2026-09-13T15:00:00Z",
            lastObservedAt: "2026-09-13T15:00:00Z",
            recipe: .init(version: "bundled", confidence: 1, state: "healthy"),
            missingCapabilities: nil,
            incompleteCapabilities: nil
        )
        let stale = SchoolWatcherService.staleStatus(from: base)
        XCTAssertFalse(stale.connected)
        XCTAssertEqual(stale.actionReason, "connector_stale")
        XCTAssertEqual(stale.recipe?.state, "stale")
        XCTAssertEqual(stale.lastSuccessAt, base.lastSuccessAt)

        let auth = SchoolPlatformStatus(
            sourceKey: base.sourceKey, platformLabel: base.platformLabel, schoolLabel: base.schoolLabel,
            connected: false, syncMode: base.syncMode, actionReason: "reauth_required",
            lastSuccessAt: base.lastSuccessAt, lastObservedAt: base.lastObservedAt, recipe: base.recipe, missingCapabilities: nil, incompleteCapabilities: nil
        )
        XCTAssertEqual(SchoolWatcherService.staleStatus(from: auth), auth)
    }

    func testWatcherTokenResponseAcceptsOnlyScopedCredentials() {
        let valid = #"{"token":"wt_abcdefghijklmnopqrstuvwx"}"#
        XCTAssertEqual(
            SchoolWatcherService.parseWatcherTokenResponse(data: Data(valid.utf8), statusCode: 200),
            "wt_abcdefghijklmnopqrstuvwx"
        )
        XCTAssertNil(SchoolWatcherService.parseWatcherTokenResponse(data: Data(valid.utf8), statusCode: 401))
        XCTAssertNil(SchoolWatcherService.parseWatcherTokenResponse(
            data: Data(#"{"token":"session-looking-token"}"#.utf8),
            statusCode: 200
        ))
        XCTAssertNil(SchoolWatcherService.parseWatcherTokenResponse(data: Data(#"{"ok":true}"#.utf8), statusCode: 200))
    }

    func testDaemonRestartBackoffIsBoundedAndCircuitBreaks() {
        XCTAssertEqual(SchoolWatcherService.daemonRestartDelaySeconds(attempt: 0), 1)
        XCTAssertEqual(SchoolWatcherService.daemonRestartDelaySeconds(attempt: 1), 2)
        XCTAssertEqual(SchoolWatcherService.daemonRestartDelaySeconds(attempt: 5), 32)
        XCTAssertNil(SchoolWatcherService.daemonRestartDelaySeconds(attempt: 6))
    }

    func testSchoolURLValidationRejectsUnsafeSavedOrigins() throws {
        XCTAssertNoThrow(try SchoolWatcherService.validateSchoolURL(URL(string: "https://school.example")!))
        XCTAssertNoThrow(try SchoolWatcherService.validateSchoolURL(URL(string: "http://localhost:3000")!))
        XCTAssertThrowsError(try SchoolWatcherService.validateSchoolURL(URL(string: "http://school.example")!))
        XCTAssertThrowsError(try SchoolWatcherService.validateSchoolURL(URL(string: "https://user:pass@school.example")!))
        XCTAssertThrowsError(try SchoolWatcherService.validateSchoolURL(URL(string: "file:///tmp/school.html")!))
    }

}
