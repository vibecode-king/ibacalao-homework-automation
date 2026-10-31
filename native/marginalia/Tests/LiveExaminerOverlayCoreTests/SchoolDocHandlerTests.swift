import XCTest
@testable import LiveExaminerOverlayCore

final class SchoolDocHandlerTests: XCTestCase {
    func testAssignmentKeysRejectDotPathSegments() {
        XCTAssertEqual(try SchoolDocHandler.safeKey("deadline:a b"), "deadline_a_b")
        XCTAssertThrowsError(try SchoolDocHandler.safeKey("."))
        XCTAssertThrowsError(try SchoolDocHandler.safeKey(".."))
        XCTAssertThrowsError(try SchoolDocHandler.safeKey("foo..bar"))
        XCTAssertFalse(SchoolDocHandler.isAssignmentKey("."))
        XCTAssertFalse(SchoolDocHandler.isAssignmentKey(".."))
        XCTAssertTrue(SchoolDocHandler.isAssignmentKey("assignment_12_34"))
    }
}
