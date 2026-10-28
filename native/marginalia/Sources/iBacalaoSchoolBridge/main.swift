import Foundation
import SchoolBridgeProtocol

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let captureOverride = ProcessInfo.processInfo.environment["IBACALAO_SCHOOL_CAPTURE_FILE"]
    .map { URL(fileURLWithPath: $0) }
let store = CaptureRingStore(fileURL: captureOverride)

while true {
    do {
        guard let payload = try NativeMessagingFrame.read(from: input) else { break }
        do {
            let capture = try SchoolBridgeValidation.validate(payload)
            try store.append(capture)
            try NativeMessagingFrame.write(SchoolBridgeResponse.ack(captureEventId: capture.captureEventId), to: output)
        } catch {
            try NativeMessagingFrame.write(SchoolBridgeResponse.error(error), to: output)
        }
    } catch {
        // A malformed/oversized frame means the byte stream can no longer be
        // trusted to have message boundaries. Reply once, then exit cleanly.
        try? NativeMessagingFrame.write(SchoolBridgeResponse.error(error), to: output)
        break
    }
}
