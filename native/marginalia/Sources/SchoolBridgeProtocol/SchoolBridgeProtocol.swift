import CryptoKit
import Foundation

public enum SchoolBridgeError: Error, Equatable {
    case malformedFrame
    case messageTooLarge
    case invalidJSON
    case invalidMessageType
    case invalidSourceSession
    case invalidSourceKey
    case invalidOrigin
    case invalidFingerprint
    case invalidObservedAt
    case invalidPayload
    case sensitivePayload
    case captureStoreCorrupt
    case captureStoreFull
}

public enum NativeMessagingFrame {
    public static let maxMessageBytes = 1_048_576

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maxMessageBytes else { throw SchoolBridgeError.messageTooLarge }
        var length = UInt32(payload.count).littleEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }

    public static func read(from handle: FileHandle) throws -> Data? {
        guard let header = try readExactly(4, from: handle) else { return nil }
        guard header.count == 4 else { throw SchoolBridgeError.malformedFrame }

        let length = header.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self).littleEndian
        }
        guard length <= UInt32(maxMessageBytes) else { throw SchoolBridgeError.messageTooLarge }
        guard let payload = try readExactly(Int(length), from: handle), payload.count == Int(length) else {
            throw SchoolBridgeError.malformedFrame
        }
        return payload
    }

    public static func write(_ payload: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: encode(payload))
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
        if count == 0 { return Data() }
        var result = Data()
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                return result.isEmpty ? nil : result
            }
            result.append(chunk)
        }
        return result
    }
}

public struct ValidatedSchoolCapture {
    public let object: [String: Any]
    public let rawData: Data
    public let observedAt: Date
    public let captureEventId: String

    public init(object: [String: Any], rawData: Data, observedAt: Date, captureEventId: String) {
        self.object = object
        self.rawData = rawData
        self.observedAt = observedAt
        self.captureEventId = captureEventId
    }
}

public enum SchoolBridgeValidation {
    private static let allowedKinds: Set<String> = [
        "hello", "route", "json-response-shape", "dom-snapshot", "navigation-edge", "attachment-download",
    ]

    private static let forbiddenKeys: Set<String> = [
        "password", "passwd", "cookie", "cookies", "authorization",
        "access_token", "refresh_token", "id_token", "sso_assertion",
    ]

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseISO8601(_ value: String) -> Date? {
        // Browser-generated timestamps come from Date.toISOString(), which
        // includes fractional seconds (for example 2026-09-11T16:34:06.123Z).
        // Foundation's default ISO8601DateFormatter does not consistently
        // accept that form across supported macOS versions, so accept both.
        iso8601Fractional.date(from: value) ?? iso8601.date(from: value)
    }

    public static func originFingerprint(_ origin: String) -> String {
        let digest = SHA256.hash(data: Data(origin.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func validate(_ data: Data) throws -> ValidatedSchoolCapture {
        guard data.count <= NativeMessagingFrame.maxMessageBytes else { throw SchoolBridgeError.messageTooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchoolBridgeError.invalidJSON
        }
        guard object["type"] as? String == "school.capture" else {
            throw SchoolBridgeError.invalidMessageType
        }
        guard let captureEventId = object["captureEventId"] as? String,
              UUID(uuidString: captureEventId) != nil else {
            throw SchoolBridgeError.invalidSourceSession
        }
        guard let sourceSessionId = object["sourceSessionId"] as? String,
              !sourceSessionId.isEmpty, sourceSessionId.count <= 160 else {
            throw SchoolBridgeError.invalidSourceSession
        }
        guard let sourceKey = object["sourceKey"] as? String,
              isValidSourceKey(sourceKey) else {
            throw SchoolBridgeError.invalidSourceKey
        }
        guard let origin = object["origin"] as? String,
              let url = URL(string: origin),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            throw SchoolBridgeError.invalidOrigin
        }
        guard let fingerprint = object["originFingerprint"] as? String,
              fingerprint == originFingerprint(origin) else {
            throw SchoolBridgeError.invalidFingerprint
        }
        guard let observedAtString = object["observedAt"] as? String,
              let observedAt = parseISO8601(observedAtString) else {
            throw SchoolBridgeError.invalidObservedAt
        }
        guard let payload = object["payload"] as? [String: Any],
              let kind = payload["kind"] as? String,
              allowedKinds.contains(kind) else {
            throw SchoolBridgeError.invalidPayload
        }
        if kind == "dom-snapshot" {
            try validateDOMSnapshot(payload)
        } else if kind == "navigation-edge" {
            try validateNavigationEdge(payload)
        } else if kind == "attachment-download" {
            try validateAttachmentDownload(payload)
        }
        guard !containsForbiddenKey(object) else { throw SchoolBridgeError.sensitivePayload }

        return ValidatedSchoolCapture(object: object, rawData: data, observedAt: observedAt, captureEventId: captureEventId)
    }

    private static func validateDOMSnapshot(_ payload: [String: Any]) throws {
        if let rows = payload["rows"] as? [Any], rows.count > 80 {
            throw SchoolBridgeError.invalidPayload
        }
        if let cards = payload["cards"] as? [Any], cards.count > 40 {
            throw SchoolBridgeError.invalidPayload
        }
        if let cards = payload["cards"] as? [[String: Any]] {
            for card in cards {
                if let links = card["links"] as? [Any], links.count > 12 {
                    throw SchoolBridgeError.invalidPayload
                }
            }
        }
        guard let html = payload["sanitizedHtml"] as? String else { return }
        guard html.utf8.count <= 256 * 1024 else { throw SchoolBridgeError.messageTooLarge }
        let lowered = html.lowercased()
        let blockedFragments = [
            "<form", "<input", "<textarea", "<select", "<option", "<button",
            "<script", "<style", "<noscript", "contenteditable=", " value=",
        ]
        if blockedFragments.contains(where: lowered.contains) {
            throw SchoolBridgeError.sensitivePayload
        }
    }

    private static func validateNavigationEdge(_ payload: [String: Any]) throws {
        guard let fromPath = payload["fromPath"] as? String,
              let toPath = payload["toPath"] as? String,
              !fromPath.isEmpty, !toPath.isEmpty,
              fromPath.count <= 500, toPath.count <= 500,
              fromPath.hasPrefix("/"), toPath.hasPrefix("/") else {
            throw SchoolBridgeError.invalidPayload
        }
        if let relationship = payload["relationship"] as? String,
           !["detail", "attachment", "unknown"].contains(relationship) {
            throw SchoolBridgeError.invalidPayload
        }
        if let sourceRecordId = payload["sourceRecordId"] as? String, sourceRecordId.count > 160 {
            throw SchoolBridgeError.invalidPayload
        }
        if let fromTitle = payload["fromTitle"] as? String, fromTitle.count > 300 {
            throw SchoolBridgeError.invalidPayload
        }
    }

    private static func validateAttachmentDownload(_ payload: [String: Any]) throws {
        guard let localPath = payload["localPath"] as? String,
              let fileName = payload["fileName"] as? String,
              !localPath.isEmpty, !fileName.isEmpty,
              localPath.count <= 2048, fileName.count <= 300 else {
            throw SchoolBridgeError.invalidPayload
        }
        if let sourcePagePath = payload["sourcePagePath"] as? String,
           sourcePagePath.count > 500 || !sourcePagePath.hasPrefix("/") {
            throw SchoolBridgeError.invalidPayload
        }
        if let sourceUrlPath = payload["sourceUrlPath"] as? String,
           sourceUrlPath.count > 500 || !sourceUrlPath.hasPrefix("/") {
            throw SchoolBridgeError.invalidPayload
        }
        if let mimeType = payload["mimeType"] as? String, mimeType.count > 160 {
            throw SchoolBridgeError.invalidPayload
        }
        if let sizeBytes = payload["sizeBytes"] as? NSNumber,
           sizeBytes.int64Value < 0 || sizeBytes.int64Value > 100 * 1024 * 1024 {
            throw SchoolBridgeError.invalidPayload
        }
    }

    private static func isValidSourceKey(_ value: String) -> Bool {
        guard (1...80).contains(value.count), value == value.lowercased() else { return false }
        guard let first = value.unicodeScalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789:_-").contains($0)
        }
    }

    private static func containsForbiddenKey(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if forbiddenKeys.contains(key.lowercased()) { return true }
                if containsForbiddenKey(child) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsForbiddenKey)
        }
        return false
    }
}

public struct CaptureRingStore {
    public static let maxBytes = 20 * 1024 * 1024
    public static let maxAge: TimeInterval = 24 * 60 * 60

    public let fileURL: URL
    public let capacityBytes: Int

    public init(fileURL: URL? = nil, capacityBytes: Int = Self.maxBytes) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ibacalao/school-bridge/captures.ndjson")
        self.capacityBytes = capacityBytes
    }

    public func append(_ capture: ValidatedSchoolCapture, now: Date = Date()) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var retained = try existingEntries(now: now)
        if retained.contains(where: { entry in
            guard let existing = try? JSONSerialization.jsonObject(with: entry) as? [String: Any] else { return false }
            return existing["captureEventId"] as? String == capture.captureEventId
        }) { return }
        var object = capture.object
        object["receivedAt"] = ISO8601DateFormatter().string(from: now)
        let line: Data
        do {
            line = try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw SchoolBridgeError.invalidPayload
        }
        guard line.count <= NativeMessagingFrame.maxMessageBytes else {
            throw SchoolBridgeError.messageTooLarge
        }
        retained.append(line)

        let retainedBytes = retained.reduce(0, { $0 + $1.count + 1 })
        guard retainedBytes <= capacityBytes else {
            // Do not evict an older, potentially unconsumed capture to make room
            // for a new one. Refuse the ACK so the extension retains the new
            // capture in its own durable outbox until capacity is available.
            throw SchoolBridgeError.captureStoreFull
        }
        var output = Data()
        for line in retained {
            output.append(line)
            output.append(0x0A)
        }
        try output.write(to: fileURL, options: .atomic)
    }

    private func existingEntries(now: Date) throws -> [Data] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SchoolBridgeError.captureStoreCorrupt
        }
        if data.isEmpty { return [] }

        var retained: [Data] = []
        for slice in data.split(separator: 0x0A) {
            let line = Data(slice)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let received = object["receivedAt"] as? String,
                  let date = ISO8601DateFormatter().date(from: received) else {
                // Never compact a malformed journal as if the bad entry did not
                // exist. Refuse the new ACK so the browser keeps its durable
                // copy until the local journal is repaired/quarantined.
                throw SchoolBridgeError.captureStoreCorrupt
            }
            let age = now.timeIntervalSince(date)
            if age <= Self.maxAge { retained.append(line) }
        }
        return retained
    }
}

public enum SchoolBridgeResponse {
    public static func ack(captureEventId: String) -> Data {
        let object: [String: Any] = [
            "type": "school.capture.ack",
            "accepted": true,
            "captureEventId": captureEventId,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"type":"school.capture.ack","accepted":true}"#.utf8)
    }

    public static func error(_ error: Error) -> Data {
        let name = String(describing: error).replacingOccurrences(of: "\"", with: "")
        let object: [String: Any] = [
            "type": "school.capture.error",
            "accepted": false,
            "error": name,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"type":"school.capture.error","accepted":false}"#.utf8)
    }
}
