import CryptoKit
import Foundation

/// The heavy school-watcher runtime (Node, Playwright, Chromium; ~230 MB of
/// downloads) is not shipped inside the app. After the student opens the app,
/// each piece is fetched from its official public source (nodejs.org, npm,
/// Google's Chrome for Testing) and assembled locally. No iBacalao hosting.
///
/// Trust: `runtime-manifest.json` lives inside the signed app bundle and pins
/// every file's SHA-256 and size, so a tampered or swapped download is rejected.
struct WatcherRuntimeManifest: Codable, Equatable {
    struct Part: Codable, Equatable {
        enum Format: String, Codable { case tgz, zip }
        let name: String
        /// Tried in order; every mirror must serve the same bytes (same hash).
        let urls: [URL]
        let sha256: String
        let size: Int64
        let format: Format
        /// Path inside the extracted archive ("." for its root).
        let from: String
        /// Destination inside the runtime folder.
        let to: String
        let markers: [String]?
    }

    let key: String
    let parts: [Part]

    var totalBytes: Int64 { parts.reduce(0) { $0 + $1.size } }

    static var current: WatcherRuntimeManifest? {
        guard let url = WatcherRuntimeInstaller.bundledRoot?.appendingPathComponent("runtime-manifest.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> WatcherRuntimeManifest? {
        guard let manifest = try? JSONDecoder().decode(WatcherRuntimeManifest.self, from: data),
              manifest.isValid else { return nil }
        return manifest
    }

    var isValid: Bool {
        guard key.range(of: "^[A-Za-z0-9._-]{1,120}$", options: .regularExpression) != nil, !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            part.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
                && part.size > 0
                && !part.urls.isEmpty
                && part.urls.allSatisfy(Self.isAllowedDownloadURL)
                && Self.isSafeRelativePath(part.from, allowRoot: true)
                && Self.isSafeRelativePath(part.to, allowRoot: false)
                && (part.markers ?? []).allSatisfy { Self.isSafeRelativePath($0, allowRoot: false) }
        }
    }

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if url.scheme == "https", !host.isEmpty { return true }
        #if DEBUG
        return url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)
        #else
        return false
        #endif
    }

    /// Manifest paths become filesystem moves, so they can never escape the runtime folder.
    static func isSafeRelativePath(_ path: String, allowRoot: Bool) -> Bool {
        if path == "." { return allowRoot }
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }
}

enum WatcherRuntimeState: Equatable {
    /// Full runtime ships inside this app (DEV builds, installs before 1.0.9).
    case bundled
    case ready
    /// No runtime and no manifest: nothing to download.
    case unavailable
    case downloading(fraction: Double)
    case installing
    case failed(message: String)

    var bridgePayload: [String: Any] {
        switch self {
        case .bundled, .ready: return ["state": "ready"]
        case .unavailable: return ["state": "unavailable"]
        case .downloading(let fraction): return ["state": "downloading", "progress": (fraction * 100).rounded() / 100]
        case .installing: return ["state": "installing"]
        case .failed(let message): return ["state": "failed", "message": message]
        }
    }
}

enum WatcherRuntimeInstallError: LocalizedError, Equatable {
    case notEnoughSpace
    case badResponse(Int)
    case sizeMismatch(String)
    case checksumMismatch(String)
    case extractFailed(String)
    case invalidLayout

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace: return "Not enough free disk space to set up school connection."
        case .badResponse(let code): return "Download failed (HTTP \(code))."
        case .sizeMismatch, .checksumMismatch: return "A download was incomplete or damaged."
        case .extractFailed, .invalidLayout: return "The school connection files could not be installed."
        }
    }
}

@MainActor
final class WatcherRuntimeInstaller {
    static let shared = WatcherRuntimeInstaller()

    private(set) var state: WatcherRuntimeState = .unavailable
    private var task: Task<Void, Never>?
    private var lastPublishedFraction = -1.0

    private init() {
        state = Self.initialState()
    }

    // MARK: Resolution (pure, tested)

    nonisolated static var bundledRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("WatcherRuntime", isDirectory: true)
    }

    nonisolated static var installBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iBacalao/WatcherRuntime", isDirectory: true)
    }

    nonisolated static func isUsableHeavyRuntime(_ root: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        return fm.isExecutableFile(atPath: root.appendingPathComponent("node/bin/node").path)
            && fm.fileExists(atPath: root.appendingPathComponent("node_modules/playwright").path, isDirectory: &isDir) && isDir.boolValue
            && fm.fileExists(atPath: root.appendingPathComponent("browsers").path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Bundled runtime wins so existing installs keep the exact runtime they
    /// have today; otherwise the downloaded runtime for this app's manifest.
    nonisolated static func resolveHeavyRoot(bundled: URL?, installBase: URL, manifest: WatcherRuntimeManifest?) -> URL? {
        if let bundled, isUsableHeavyRuntime(bundled) { return bundled }
        if let manifest {
            let installed = installBase.appendingPathComponent(manifest.key, isDirectory: true)
            if isUsableHeavyRuntime(installed) { return installed }
        }
        return nil
    }

    nonisolated static func currentHeavyRoot() -> URL? {
        resolveHeavyRoot(bundled: bundledRoot, installBase: installBase, manifest: .current)
    }

    private static func initialState() -> WatcherRuntimeState {
        if let bundledRoot, isUsableHeavyRuntime(bundledRoot) { return .bundled }
        if currentHeavyRoot() != nil { return .ready }
        return .unavailable
    }

    // MARK: Install

    /// Safe to call often: no-op when the runtime exists or a download is running.
    func ensureInstalled() {
        if Self.currentHeavyRoot() != nil {
            if state != .bundled && state != .ready { publish(Self.initialState()) }
            return
        }
        guard task == nil, let manifest = WatcherRuntimeManifest.current else { return }
        publish(.downloading(fraction: 0))
        task = Task { [weak self] in
            await self?.run(manifest: manifest)
        }
    }

    private func run(manifest: WatcherRuntimeManifest) async {
        defer { task = nil }
        var lastError: Error?
        // ponytail: per-attempt restart of the current file, no byte-range
        // resume. Add resumeData if slow connections keep failing past 3 tries.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(attempt == 1 ? 5 : 30)) }
            do {
                lastPublishedFraction = -1
                _ = try await Self.install(manifest: manifest, base: Self.installBase) { fraction, installing in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if installing {
                            self.publish(.installing)
                        } else if fraction - self.lastPublishedFraction >= 0.01 || fraction >= 1 {
                            self.lastPublishedFraction = fraction
                            self.publish(.downloading(fraction: fraction))
                        }
                    }
                }
                publish(.ready)
                dlog("[WatcherRuntime] installed key=\(manifest.key)")
                SchoolWatcherService.shared.startIfAuthenticated()
                return
            } catch {
                lastError = error
                dlog("[WatcherRuntime] attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }
        publish(.failed(message: lastError?.localizedDescription ?? "Setup failed."))
    }

    private func publish(_ next: WatcherRuntimeState) {
        guard next != state else { return }
        state = next
        ShellController.shared?.emitSchoolRuntimeStatus()
    }

    /// For each part: download → verify size + SHA-256 → extract → move into a
    /// temp runtime folder. Only a complete, validated runtime is renamed to its
    /// final path, so a crash mid-way just retries next launch.
    nonisolated static func install(
        manifest: WatcherRuntimeManifest,
        base: URL,
        progress: @escaping @Sendable (Double, Bool) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let final = base.appendingPathComponent(manifest.key, isDirectory: true)
        if isUsableHeavyRuntime(final) { return final }

        // A force-quit mid-install leaves `.partial-*` behind; free that space
        // before checking, or a nearly full disk fails here on every launch.
        for entry in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        where entry.lastPathComponent.hasPrefix(".partial-") {
            try? fm.removeItem(at: entry)
        }

        // One archive plus its expanded copy coexist at a time; Chromium expands ~2x.
        let values = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // Important-usage reads 0 on non-boot volumes; fall back to plain free space.
        let important = values?.volumeAvailableCapacityForImportantUsage ?? 0
        if let free = important > 0 ? important : values?.volumeAvailableCapacity.map(Int64.init),
           free < manifest.totalBytes * 4 {
            throw WatcherRuntimeInstallError.notEnoughSpace
        }

        let work = base.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let runtime = work.appendingPathComponent("runtime", isDirectory: true)
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)

        let total = Double(max(manifest.totalBytes, 1))
        let highWater = ProgressHighWater()
        var doneBytes: Int64 = 0
        for part in manifest.parts {
            let archive = work.appendingPathComponent("\(part.name).download")
            let offset = doneBytes
            try await downloadVerified(part, to: archive) { written in
                // A failed mirror restarts its file; never show the bar going backwards.
                if let fraction = highWater.advance(to: min(1, Double(offset + written) / total)) {
                    progress(fraction, false)
                }
            }
            doneBytes += part.size

            let extracted = work.appendingPathComponent("x-\(part.name)", isDirectory: true)
            try extract(archive, format: part.format, into: extracted, partName: part.name)
            try? fm.removeItem(at: archive)

            let source = part.from == "." ? extracted : extracted.appendingPathComponent(part.from)
            let destination = runtime.appendingPathComponent(part.to)
            guard fm.fileExists(atPath: source.path) else { throw WatcherRuntimeInstallError.invalidLayout }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: destination)
            try? fm.removeItem(at: extracted)
            for marker in part.markers ?? [] {
                let url = runtime.appendingPathComponent(marker)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: Data())
            }
        }
        progress(1, true)

        guard isUsableHeavyRuntime(runtime) else { throw WatcherRuntimeInstallError.invalidLayout }
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: runtime, to: final)

        for entry in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        where entry.lastPathComponent != manifest.key && entry != work {
            try? fm.removeItem(at: entry)
        }
        return final
    }

    private nonisolated static func downloadVerified(
        _ part: WatcherRuntimeManifest.Part,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var lastError: Error = WatcherRuntimeInstallError.badResponse(0)
        for url in part.urls {
            do {
                try await download(from: url, to: destination, progress: progress)
                let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
                guard size == part.size else { throw WatcherRuntimeInstallError.sizeMismatch(part.name) }
                guard try sha256Hex(of: destination) == part.sha256 else { throw WatcherRuntimeInstallError.checksumMismatch(part.name) }
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: destination)
            }
        }
        throw lastError
    }

    private nonisolated static func extract(_ archive: URL, format: WatcherRuntimeManifest.Part.Format, into directory: URL, partName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        switch format {
        case .tgz:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", directory.path]
        case .zip:
            // ditto keeps symlinks and permissions inside Chromium's app bundle.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, directory.path]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WatcherRuntimeInstallError.extractFailed(partName) }
    }

    nonisolated static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }
}

private final class ProgressHighWater: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    func advance(to next: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard next > value else { return nil }
        value = next
        return next
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns, so move it now.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            moveError = WatcherRuntimeInstallError.badResponse(http.statusCode)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? moveError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
