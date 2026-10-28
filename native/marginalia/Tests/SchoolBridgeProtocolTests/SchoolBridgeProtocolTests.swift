import Foundation
import XCTest
@testable import SchoolBridgeProtocol

final class SchoolBridgeProtocolTests: XCTestCase {
    private func validCapture(origin: String = "https://school.example") -> Data {
        let fingerprint = SchoolBridgeValidation.originFingerprint(origin)
        let object: [String: Any] = [
            "type": "school.capture",
            "captureEventId": "11111111-1111-4111-8111-111111111111",
            "sourceSessionId": "session:1",
            "sourceKey": "portal:\(fingerprint)",
            "origin": origin,
            "originFingerprint": fingerprint,
            "observedAt": "2026-09-11T13:00:00Z",
            "payload": ["kind": "route", "path": "/student/tasks"],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testFrameRoundTrip() throws {
        let payload = Data("hello".utf8)
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: NativeMessagingFrame.encode(payload))
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try NativeMessagingFrame.read(from: pipe.fileHandleForReading), payload)
    }

    func testOversizedFrameIsRejectedBeforeBodyRead() throws {
        var length = UInt32(NativeMessagingFrame.maxMessageBytes + 1).littleEndian
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(bytes: &length, count: 4))
        try pipe.fileHandleForWriting.close()
        XCTAssertThrowsError(try NativeMessagingFrame.read(from: pipe.fileHandleForReading)) { error in
            XCTAssertEqual(error as? SchoolBridgeError, .messageTooLarge)
        }
    }

    func testValidCaptureIsAccepted() throws {
        let result = try SchoolBridgeValidation.validate(validCapture())
        XCTAssertEqual(result.object["type"] as? String, "school.capture")
    }

    func testBrowserTimestampWithFractionalSecondsIsAccepted() throws {
        let object = try JSONSerialization.jsonObject(with: validCapture()) as! [String: Any]
        var browserCapture = object
        browserCapture["observedAt"] = "2026-09-11T16:34:06.123Z"
        let data = try JSONSerialization.data(withJSONObject: browserCapture)

        let result = try SchoolBridgeValidation.validate(data)
        XCTAssertEqual(result.object["type"] as? String, "school.capture")
    }

    func testFingerprintMismatchIsRejected() throws {
        let object = try JSONSerialization.jsonObject(with: validCapture()) as! [String: Any]
        var bad = object
        bad["originFingerprint"] = String(repeating: "0", count: 32)
        let data = try JSONSerialization.data(withJSONObject: bad)
        XCTAssertThrowsError(try SchoolBridgeValidation.validate(data)) { error in
            XCTAssertEqual(error as? SchoolBridgeError, .invalidFingerprint)
        }
    }

    func testUnknownMessageTypeIsRejected() throws {
        let object = try JSONSerialization.jsonObject(with: validCapture()) as! [String: Any]
        var bad = object
        bad["type"] = "school.execute"
        let data = try JSONSerialization.data(withJSONObject: bad)
        XCTAssertThrowsError(try SchoolBridgeValidation.validate(data)) { error in
            XCTAssertEqual(error as? SchoolBridgeError, .invalidMessageType)
        }
    }

    func testSensitiveKeysAreRejected() throws {
        let object = try JSONSerialization.jsonObject(with: validCapture()) as! [String: Any]
        var bad = object
        bad["payload"] = ["kind": "route", "authorization": "Bearer secret"]
        let data = try JSONSerialization.data(withJSONObject: bad)
        XCTAssertThrowsError(try SchoolBridgeValidation.validate(data)) { error in
            XCTAssertEqual(error as? SchoolBridgeError, .sensitivePayload)
        }
    }

    func testNavigationEdgeIsAccepted() throws {
        let object = try JSONSerialization.jsonObject(with: validCapture()) as! [String: Any]
        var edge = object
        edge["payload"] = [
            "kind": "navigation-edge",
            "fromPath": "/calendar",
            "toPath": "/assignments/52983",
            "relationship": "detail",
            "sourceRecordId": "a1",
        ]
        XCTAssertNoThrow(try SchoolBridgeValidation.validate(JSONSerialization.data(withJSONObject: edge)))
    }

    func testAttachmentDownloadIsAcceptedWithoutUploadingFileBytes() throws {
        let object = try JSONSerialization.jsonObject(with: validCapture()) as! [String: Any]
        var download = object
        download["payload"] = [
            "kind": "attachment-download",
            "sourcePagePath": "/assignments/52983",
            "localPath": "/Users/student/Downloads/rubric.pdf",
            "fileName": "rubric.pdf",
            "mimeType": "application/pdf",
            "sizeBytes": 12345,
        ]
        XCTAssertNoThrow(try SchoolBridgeValidation.validate(JSONSerialization.data(withJSONObject: download)))
    }

    func testAttachmentDownloadRejectsOversizedMetadata() throws {
        let object = try JSONSerialization.jsonObject(with: validCapture()) as! [String: Any]
        var download = object
        download["payload"] = [
            "kind": "attachment-download",
            "localPath": "/tmp/rubric.pdf",
            "fileName": "rubric.pdf",
            "sizeBytes": 101 * 1024 * 1024,
        ]
        XCTAssertThrowsError(try SchoolBridgeValidation.validate(JSONSerialization.data(withJSONObject: download))) { error in
            XCTAssertEqual(error as? SchoolBridgeError, .invalidPayload)
        }
    }

    func testSanitizedDOMRejectsFormValuesEvenFromModifiedExtension() throws {
        let object = try JSONSerialization.jsonObject(with: validCapture()) as! [String: Any]
        var bad = object
        bad["payload"] = [
            "kind": "dom-snapshot",
            "path": "/assignments",
            "rows": [["tag": "h2", "text": "Assignments"]],
            "sanitizedHtml": #"<main><input type="password" value="secret"></main>"#,
        ]
        let data = try JSONSerialization.data(withJSONObject: bad)
        XCTAssertThrowsError(try SchoolBridgeValidation.validate(data)) { error in
            XCTAssertEqual(error as? SchoolBridgeError, .sensitivePayload)
        }
    }

    func testAckEchoesCaptureEventId() throws {
        let data = SchoolBridgeResponse.ack(captureEventId: "11111111-1111-4111-8111-111111111111")
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["accepted"] as? Bool, true)
        XCTAssertEqual(object["captureEventId"] as? String, "11111111-1111-4111-8111-111111111111")
    }

    func testRingStoreDeduplicatesReplayedEvent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("captures.ndjson")
        let store = CaptureRingStore(fileURL: file)
        let capture = try SchoolBridgeValidation.validate(validCapture())
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.append(capture, now: now)
        try store.append(capture, now: now.addingTimeInterval(1))
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        try? FileManager.default.removeItem(at: root)
    }


    func testRingStoreFailsClosedWhenCapacityIsExceeded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("captures.ndjson")
        let store = CaptureRingStore(fileURL: file, capacityBytes: 64)
        let capture = try SchoolBridgeValidation.validate(validCapture())

        XCTAssertThrowsError(try store.append(capture, now: Date())) { error in
            XCTAssertEqual(error as? SchoolBridgeError, .captureStoreFull)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testRingStoreRefusesToCompactMalformedJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("captures.ndjson")
        try Data("not-json\n".utf8).write(to: file)
        let store = CaptureRingStore(fileURL: file)
        let capture = try SchoolBridgeValidation.validate(validCapture())

        XCTAssertThrowsError(try store.append(capture, now: Date())) { error in
            XCTAssertEqual(error as? SchoolBridgeError, .captureStoreCorrupt)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not-json\n")
        try? FileManager.default.removeItem(at: root)
    }

    func testRingStoreExpiresOldEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("captures.ndjson")
        let store = CaptureRingStore(fileURL: file)
        let capture = try SchoolBridgeValidation.validate(validCapture())
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.append(capture, now: now.addingTimeInterval(-CaptureRingStore.maxAge - 1))
        try store.append(capture, now: now)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        try? FileManager.default.removeItem(at: root)
    }
}
