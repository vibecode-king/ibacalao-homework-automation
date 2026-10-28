import Foundation

// ponytail: unified-log (NSLog/log show) has been unreliable for this app during
// dev — sometimes captures nothing for a healthy, running process. Writing
// straight to a file sidesteps that entirely. Remove once the app ships for real.
//
// dlog is compiled out entirely in non-DEBUG (release/MAS) builds via the
// #else stub at the bottom of this file.
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
func agentLog(_ hypothesisId: String, location: String, message: String, data: [String: Any] = [:]) {
    var payload: [String: Any] = [
        "sessionId": "32284a",
        "runId": "tcc",
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
    appendLine(line, to: "/Users/joaquin/Documents/iBacalao/.cursor/debug-32284a.log")
    var req = URLRequest(url: URL(string: "http://127.0.0.1:7494/ingest/48e69a81-48b0-4c67-976d-255ff0f580b2")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("32284a", forHTTPHeaderField: "X-Debug-Session-Id")
    req.httpBody = json
    URLSession.shared.dataTask(with: req).resume()
}
#else
@inline(__always)
func dlog(_ message: @autoclosure () -> String) {}
@inline(__always)
func agentLog(
    _ hypothesisId: @autoclosure () -> String,
    location: @autoclosure () -> String,
    message: @autoclosure () -> String,
    data: @autoclosure () -> [String: Any] = [:]
) {}
#endif
