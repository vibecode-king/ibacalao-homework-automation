//
//  SafariWebExtensionHandler.swift
//  iBacalao School Bridge Extension
//
//  Safari has no OS-level Native Messaging host. sendNativeMessage lands
//  here, inside the sandboxed appex. App extensions cannot reliably spawn
//  /Applications/iBacalao.app/.../iBacalaoSchoolBridge, so this handler
//  validates and appends with the same SchoolBridgeProtocol the helper uses.
//

import Darwin
import Foundation
import os.log
import SafariServices

private func realUserHomeDirectory() -> URL {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

private func unwrapNativeMessage(_ raw: Any) -> Any {
    guard let dictionary = raw as? [String: Any] else { return raw }
    if dictionary["type"] as? String == "school.capture" { return dictionary }
    if let inner = dictionary["message"] {
        return unwrapNativeMessage(inner)
    }
    return dictionary
}

private func handleSchoolCapture(_ messageObject: Any) throws -> [String: Any] {
    let unwrapped = unwrapNativeMessage(messageObject)
    let requestData = try JSONSerialization.data(withJSONObject: unwrapped)
    let capture = try SchoolBridgeValidation.validate(requestData)
    let fileURL = realUserHomeDirectory()
        .appendingPathComponent(".ibacalao/school-bridge/captures.ndjson")
    try CaptureRingStore(fileURL: fileURL).append(capture)
    return [
        "type": "school.capture.ack",
        "accepted": true,
        "captureEventId": capture.captureEventId,
    ]
}

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message: Any?
        if #available(macOS 11.0, *) {
            message = request?.userInfo?[SFExtensionMessageKey]
        } else {
            message = request?.userInfo?["message"]
        }

        let responsePayload: [String: Any]
        do {
            guard let message else { throw SchoolBridgeError.invalidJSON }
            responsePayload = try handleSchoolCapture(message)
        } catch {
            os_log(.error, "[SchoolBridge] capture failed: %{public}@", String(describing: error))
            responsePayload = [
                "type": "school.capture.error",
                "accepted": false,
                "error": String(describing: error),
            ]
        }

        let response = NSExtensionItem()
        if #available(macOS 11.0, *) {
            response.userInfo = [SFExtensionMessageKey: responsePayload]
        } else {
            response.userInfo = ["message": responsePayload]
        }
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
