import AppKit
import Foundation
import UserNotifications
import WebKit

/// School assignment drafts, kept on this Mac only.
///
/// The watcher saves the teacher's original file under
/// ~/.ibacalao/school-docs/originals/<key>/ (lib/watcher/schoolDocs.ts, keep the
/// layout and safeKey rule in sync). The chat page asks this handler to open it
/// as editable HTML, save the student's draft as .docx, list saved drafts,
/// reveal one in Finder, and post a notification. Conversions run through a
/// headless LibreOffice that is downloaded once on first use.
///
/// Page call: `webkit.messageHandlers.schoolDoc.postMessage({ action, ... })`,
/// resolves with a dictionary or rejects with an error code.
final class SchoolDocHandler: NSObject, WKScriptMessageHandlerWithReply {
    nonisolated static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ibacalao/school-docs", isDirectory: true)
    nonisolated static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else {
            replyHandler(nil, "bad_request")
            return
        }
        let reply: @Sendable (Any?, String?) -> Void = { value, error in
            DispatchQueue.main.async { replyHandler(value, error) }
        }
        nonisolated(unsafe) let payload = body
        Task.detached(priority: .userInitiated) {
            do {
                reply(try await Self.handle(action, payload), nil)
            } catch {
                dlog("[SchoolDoc] \(action) failed: \(error.localizedDescription)")
                reply(nil, (error as? SchoolDocError)?.rawValue ?? "failed")
            }
        }
    }

    // MARK: Actions

    nonisolated static func handle(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        switch action {
        case "open":
            return try await open(key: try key(body))
        case "openOriginal":
            // Recording flow must not substitute a previous draft or blank
            // worksheet for the teacher's file. Missing originals fail closed.
            return try await openOriginal(key: try key(body))
        case "import":
            // The student picked the assignment file themselves (original missing,
            // or an extra assignment). Replaces whatever original the key had.
            guard let name = body["fileName"] as? String, let encoded = body["data"] as? String,
                  encoded.utf8.count < 36_000_000, let data = Data(base64Encoded: encoded) else { throw SchoolDocError.badRequest }
            try importOriginal(key: try key(body), fileName: name, data: data)
            return try await open(key: try key(body))
        case "save":
            guard let html = body["html"] as? String, html.utf8.count < 5_000_000 else { throw SchoolDocError.badRequest }
            return try await save(key: try key(body), html: html, meta: [
                "key": try key(body),
                "recordId": body["recordId"] as? String ?? "",
                "title": body["title"] as? String ?? "Draft",
                "subject": body["subject"] as? String ?? "",
                "dueAt": body["dueAt"] as? String ?? "",
                "url": body["url"] as? String ?? "",
                "savedAt": ISO8601DateFormatter().string(from: Date()),
            ], requireDocx: body["requireDocx"] as? Bool == true)
        case "list":
            prune()
            return ["drafts": listDrafts()]
        case "reveal":
            let k = try key(body)
            guard let file = draftFile(k) else { throw SchoolDocError.notFound }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            return ["ok": true]
        case "notify":
            await notify(title: body["title"] as? String ?? "iBacalao", body: body["body"] as? String ?? "")
            return ["ok": true]
        default:
            throw SchoolDocError.badRequest
        }
    }

    nonisolated static let importExtensions: Set<String> = ["docx", "doc", "odt", "rtf", "pdf", "txt"]

    nonisolated static func openOriginal(key: String) async throws -> [String: Any] {
        let dir = root.appendingPathComponent("originals/\(key)", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { importExtensions.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let rank = ["docx": 0, "doc": 1, "odt": 2, "rtf": 3, "pdf": 4, "txt": 5]
        guard let file = files.min(by: { (rank[$0.pathExtension.lowercased()] ?? 99) < (rank[$1.pathExtension.lowercased()] ?? 99) }) else {
            throw SchoolDocError.notFound
        }
        // HTML is an editable view of this genuine input document, not a
        // generated assignment. The original bytes remain unchanged on disk.
        let html = try await LibreOffice.toHTML(file)
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SchoolDocError.conversionFailed }
        return ["source": "original", "html": html, "fileName": file.lastPathComponent]
    }

    nonisolated static func importOriginal(key: String, fileName: String, data: Data) throws {
        let name = (fileName as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        guard importExtensions.contains((name as NSString).pathExtension.lowercased()),
              !data.isEmpty, data.count <= 25 * 1024 * 1024 else { throw SchoolDocError.badRequest }
        let fm = FileManager.default
        let dir = root.appendingPathComponent("originals/\(key)", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(String(name.prefix(160))), options: .atomic)
    }

    /// Draft first, then the teacher's original, else a blank doc. A file we
    /// cannot convert also falls back to blank rather than failing the open.
    nonisolated static func open(key: String) async throws -> [String: Any] {
        let fm = FileManager.default
        if let draft = draftFile(key) {
            if draft.pathExtension == "docx", let html = try? await LibreOffice.toHTML(draft) {
                return ["source": "draft", "html": html, "fileName": draft.lastPathComponent]
            }
            if draft.pathExtension == "doc", let html = try? String(contentsOf: draft, encoding: .utf8) {
                return ["source": "draft", "html": html, "fileName": draft.lastPathComponent]
            }
        }
        let originals = root.appendingPathComponent("originals/\(key)", isDirectory: true)
        let files = ((try? fm.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // Prefer a document over images or slides when the teacher attached several.
        let rank = ["docx": 0, "doc": 1, "odt": 2, "rtf": 3, "pdf": 4, "txt": 5]
        if let original = files.min(by: { (rank[$0.pathExtension.lowercased()] ?? 9) < (rank[$1.pathExtension.lowercased()] ?? 9) }) {
            do {
                return ["source": "original", "html": try await LibreOffice.toHTML(original), "fileName": original.lastPathComponent]
            } catch {
                dlog("[SchoolDoc] original conversion failed, falling back to blank: \(error.localizedDescription)")
                return ["source": "blank", "html": "", "fileName": original.lastPathComponent, "conversionFailed": true]
            }
        }
        return ["source": "blank", "html": ""]
    }

    nonisolated static func save(key: String, html: String, meta: [String: Any], requireDocx: Bool = false) async throws -> [String: Any] {
        let fm = FileManager.default
        let drafts = root.appendingPathComponent("drafts", isDirectory: true)
        try fm.createDirectory(at: drafts, withIntermediateDirectories: true)
        let page = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(escape(meta["title"] as? String ?? ""))</title></head><body>\(html)</body></html>"
        let work = fm.temporaryDirectory.appendingPathComponent("ibacalao-draft-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let source = work.appendingPathComponent("\(key).html")
        try page.write(to: source, atomically: true, encoding: .utf8)

        var target = drafts.appendingPathComponent("\(key).docx")
        do {
            let converted = try await LibreOffice.convert(source, to: "docx:MS Word 2007 XML", outDir: work, inFilter: "HTML (StarWriter)")
            _ = try? fm.removeItem(at: target)
            try fm.moveItem(at: converted, to: target)
            try? fm.removeItem(at: drafts.appendingPathComponent("\(key).doc"))
        } catch {
            if requireDocx { throw SchoolDocError.conversionFailed }
            // ponytail: Word opens an HTML file named .doc, so a draft is never
            // lost while LibreOffice is still downloading or fails.
            dlog("[SchoolDoc] docx export unavailable, saving .doc: \(error.localizedDescription)")
            target = drafts.appendingPathComponent("\(key).doc")
            try page.write(to: target, atomically: true, encoding: .utf8)
        }
        var meta = meta
        meta["fileName"] = target.lastPathComponent
        let json = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        try json.write(to: drafts.appendingPathComponent("\(key).json"), options: .atomic)
        return ["ok": true, "fileName": target.lastPathComponent, "path": target.path]
    }

    // MARK: Files

    nonisolated static func key(_ body: [String: Any]) throws -> String {
        guard let raw = body["key"] as? String, !raw.isEmpty else { throw SchoolDocError.badRequest }
        return safeKey(raw)
    }

    /// Same rule as schoolDocKey in lib/watcher/schoolDocs.ts.
    nonisolated static func safeKey(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return String(mapped.prefix(120))
    }

    nonisolated static func draftFile(_ key: String) -> URL? {
        let drafts = root.appendingPathComponent("drafts", isDirectory: true)
        return ["docx", "doc"].map { drafts.appendingPathComponent("\(key).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static func listDrafts() -> [[String: Any]] {
        let drafts = root.appendingPathComponent("drafts", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: drafts, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = meta["key"] as? String, draftFile(key) != nil else { return nil }
            return meta
        }
    }

    /// Mirrors pruneSchoolDocs: anything untouched for 30 days goes.
    nonisolated static func prune() {
        let fm = FileManager.default
        for sub in ["originals", "drafts"] {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for entry in entries {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                if Date().timeIntervalSince(modified) > maxAge { try? fm.removeItem(at: entry) }
            }
        }
    }

    nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    nonisolated static func notify(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(120))
        content.body = String(body.prefix(400))
        content.sound = .default
        content.userInfo = ["destination": "/chat"]
        try? await center.add(UNNotificationRequest(identifier: "school-doc-\(UUID().uuidString)", content: content, trigger: nil))
    }
}

enum SchoolDocError: String, Error {
    case badRequest = "bad_request"
    case notFound = "not_found"
    case converterUnavailable = "converter_unavailable"
    case conversionFailed = "conversion_failed"
}

/// Headless LibreOffice, used only for file conversion. Uses an installed
/// /Applications copy when present, otherwise downloads the official build
/// once (~300MB) into Application Support. No window ever opens.
actor LibreOffice {
    static let shared = LibreOffice()
    // ponytail: pinned release; bump when a newer stable ships.
    static let version = "26.8.1"

    static var installDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iBacalao/LibreOffice", isDirectory: true)
    }

    private var installTask: Task<URL, Error>?

    static func soffice() -> URL? {
        [URL(fileURLWithPath: "/Applications/LibreOffice.app"), installDir.appendingPathComponent("LibreOffice.app")]
            .map { $0.appendingPathComponent("Contents/MacOS/soffice") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func ensureInstalled() async throws -> URL {
        if let binary = Self.soffice() { return binary }
        if let installTask { return try await installTask.value }
        let task = Task<URL, Error> { try await Self.install() }
        installTask = task
        defer { installTask = nil }
        return try await task.value
    }

    private static func install() async throws -> URL {
        #if arch(arm64)
        let arch = ("aarch64", "aarch64")
        #else
        let arch = ("x86_64", "x86-64")
        #endif
        let url = URL(string: "https://download.documentfoundation.org/libreoffice/stable/\(version)/mac/\(arch.0)/LibreOffice_\(version)_MacOS_\(arch.1).dmg")!
        dlog("[SchoolDoc] downloading LibreOffice \(version)")
        let (dmg, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: dmg) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SchoolDocError.converterUnavailable }

        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("ibacalao-lo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path], timeout: 300)
        defer { Task { try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60) } }

        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let staged = installDir.appendingPathComponent("LibreOffice.app.partial")
        try? FileManager.default.removeItem(at: staged)
        try await run("/usr/bin/ditto", [mount.appendingPathComponent("LibreOffice.app").path, staged.path], timeout: 600)
        let final = installDir.appendingPathComponent("LibreOffice.app")
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: staged, to: final)
        guard let binary = soffice() else { throw SchoolDocError.converterUnavailable }
        dlog("[SchoolDoc] LibreOffice ready")
        return binary
    }

    /// Converts `input` into `outDir`, returning the produced file.
    static func convert(_ input: URL, to format: String, outDir: URL, inFilter: String? = nil) async throws -> URL {
        let binary = try await shared.ensureInstalled()
        // Own profile so a LibreOffice the student has open never blocks us.
        let profile = installDir.appendingPathComponent("profile", isDirectory: true)
        var args = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore", "--nolockcheck"]
        if let inFilter { args.append("--infilter=\(inFilter)") }
        args += ["--convert-to", format, "--outdir", outDir.path, input.path]
        try await run(binary.path, args, timeout: 180)
        let ext = String(format.split(separator: ":").first ?? "")
        let output = outDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
        guard FileManager.default.fileExists(atPath: output.path) else { throw SchoolDocError.conversionFailed }
        return output
    }

    /// Any document → the <body> of a Writer HTML export. Images are dropped
    /// (they export as side files the page can't load).
    static func toHTML(_ input: URL) async throws -> String {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ibacalao-open-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let ext = input.pathExtension.lowercased()
        if ext == "txt" {
            let text = try String(contentsOf: input, encoding: .utf8)
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "<p>\(SchoolDocHandler.escape(String($0)))</p>" }.joined()
        }
        // PDFs open in Draw by default, which can't export to Writer HTML.
        let filter = ext == "pdf" ? "writer_pdf_import" : nil
        let output = try await convert(input, to: "html:XHTML Writer File:UTF8", outDir: work, inFilter: filter)
        let html = try String(contentsOf: output, encoding: .utf8)
        guard let start = html.range(of: "<body[^>]*>", options: .regularExpression),
              let end = html.range(of: "</body>", options: .backwards) else { return html }
        return String(html[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "<img[^>]*>", with: "", options: .regularExpression)
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { finished in
                timer.cancel()
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: 0)
                } else {
                    continuation.resume(throwing: SchoolDocError.conversionFailed)
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
