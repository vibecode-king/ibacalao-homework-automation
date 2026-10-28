import Foundation

// ponytail: unified-log (NSLog/log show) has been unreliable for this app during
// dev — sometimes captures nothing for a healthy, running process. Writing
// straight to a file sidesteps that entirely. Remove once the app ships for real.
//
// Everything below — dlog's file-backed sink and the dev-session agentLog
// logger — is compiled out entirely in non-DEBUG (release/MAS) builds via the
// #else stub at the bottom of this file. No NSLog, no ~/Library/Logs or /tmp
// writes, no localhost HTTP ingest, and no hardcoded local paths ship in a
// release binary — only the no-op stubs below do.
#if DEBUG
private let logDirectory: URL = {
    let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/LiveExaminerOverlay", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}()

private let logPath = logDirectory.appendingPathComponent("live_examiner_debug.log").path

private func appendLine(_ entry: String, to path: String) {
    guard let data = entry.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}

func dlog(_ message: @autoclosure () -> String) {
    let resolved = message()
    let line = "\(Date()) \(resolved)\n"
    NSLog("%@", resolved)
    appendLine(line, to: logPath)
    appendLine(line, to: "/tmp/live_examiner_debug.log")
}

// #region agent log
/// Debug-mode NDJSON sink for Cursor session 4fd5cb. Do not log secrets/PII.
func agentLog(
    _ hypothesisId: String,
    location: String,
    message: String,
    data: [String: Any] = [:],
    runId: String = "pre-fix"
) {
    var payload: [String: Any] = [
        "sessionId": "4fd5cb",
        "runId": runId,
        "hypothesisId": hypothesisId,
        "location": location,
        "message": message,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
    ]
    if !data.isEmpty { payload["data"] = data }
    guard JSONSerialization.isValidJSONObject(payload),
          let json = try? JSONSerialization.data(withJSONObject: payload),
          var line = String(data: json, encoding: .utf8) else { return }
    line.append("\n")
    // Mirror to app log so we still get evidence if .cursor write is blocked.
    dlog("[Agent] \(hypothesisId) \(location) \(message) \(data)")
    appendLine(line, to: "/Users/joaquin/Documents/iBacalao/.cursor/debug-4fd5cb.log")
    appendLine(line, to: "/tmp/debug-4fd5cb.log")
    // Best-effort HTTP ingest (debug mode only).
    var req = URLRequest(url: URL(string: "http://127.0.0.1:7288/ingest/52cf5718-622c-4a49-b851-a886c53f73cb")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("4fd5cb", forHTTPHeaderField: "X-Debug-Session-Id")
    req.httpBody = json
    URLSession.shared.dataTask(with: req).resume()
}
#else
/// No-op in release/MAS builds. The entire debug logger — dlog's NSLog and
/// ~/Library/Logs/ /tmp file writes, plus agentLog's NDJSON/.cursor/localhost
/// sink — is compiled out here, not just individually stubbed. @autoclosure
/// parameters mean call-site arguments (string interpolations, dictionary
/// literals built from live state) are never evaluated in this build, so
/// there's no eager payload construction and no leaked local paths/ports in
/// the shipped binary.
@inline(__always)
func dlog(_ message: @autoclosure () -> String) {}

@inline(__always)
func agentLog(
    _ hypothesisId: @autoclosure () -> String,
    location: @autoclosure () -> String,
    message: @autoclosure () -> String,
    data: @autoclosure () -> [String: Any] = [:],
    runId: @autoclosure () -> String = "pre-fix"
) {}
#endif
// #endregion
