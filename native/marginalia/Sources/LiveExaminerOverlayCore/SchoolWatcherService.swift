import AppKit
import Foundation

struct SchoolPlatformConnection: Decodable, Equatable {
    let platformId: String
    let platformLabel: String
    let schoolLabel: String?
    let origin: String
    let profileKey: String
    let connectedAt: String
}

struct SchoolPlatformStatus: Codable, Equatable {
    struct Recipe: Codable, Equatable {
        let version: String?
        let confidence: Double?
        let state: String
    }

    let sourceKey: String
    let platformLabel: String
    let schoolLabel: String?
    let connected: Bool
    let syncMode: String
    let actionReason: String
    let lastSuccessAt: String?
    let lastObservedAt: String?
    let recipe: Recipe?
    let missingCapabilities: [String]?
    let incompleteCapabilities: [String]?
}

/// Runs the local school-platform browser helper bundled inside the signed app.
///
/// This layer is deliberately platform-agnostic. `platform` is a stable profile
/// id (for example managebac, canvas, toddle, schoology, …) and `loginURL` is the
/// school's own HTTPS sign-in URL. Extraction support is separate: establishing
/// a local authenticated browser profile does not claim that an adapter already
/// exists for that LMS.
@MainActor
final class SchoolWatcherService {
    static let shared = SchoolWatcherService()

    private var daemon: Process?
    private var daemonToken: String?
    private var daemonSessionToken: String?
    private var daemonGeneration = 0
    private var daemonRestartAttempt = 0
    private var daemonRestartTask: Task<Void, Never>?
    private var daemonStabilityTask: Task<Void, Never>?
    private var loginProcesses: [Process] = []

    private init() {}

    /// Node, Playwright, Chromium and Scrapling: bundled in older/DEV apps,
    /// downloaded by WatcherRuntimeInstaller in release apps.
    private var runtimeRoot: URL? {
        WatcherRuntimeInstaller.currentHeavyRoot()
    }

    private var nodeURL: URL? {
        runtimeRoot?.appendingPathComponent("node/bin/node")
    }

    /// Always shipped inside the app so watcher fixes never need a new runtime download.
    private var scriptURL: URL? {
        WatcherRuntimeInstaller.bundledRoot?.appendingPathComponent("watcher-daemon.cjs")
    }

    private var browsersURL: URL? {
        runtimeRoot?.appendingPathComponent("browsers", isDirectory: true)
    }

    /// Our own PyInstaller build, so it ships signed inside the app rather than
    /// being downloaded with the public runtime pieces.
    private var scraplingHelperURL: URL? {
        WatcherRuntimeInstaller.bundledRoot?.appendingPathComponent("scrapling-repair")
    }

    private var connectionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ibacalao/watcher/connection.json")
    }

    private var statusURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ibacalao/school/status.json")
    }

    private var learningSessionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ibacalao/school/learning.json")
    }

    var isRuntimeAvailable: Bool {
        guard let nodeURL, let scriptURL else { return false }
        return FileManager.default.isExecutableFile(atPath: nodeURL.path)
            && FileManager.default.fileExists(atPath: scriptURL.path)
    }

    func loadStatus() -> SchoolPlatformStatus? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder().decode(SchoolPlatformStatus.self, from: data)
    }

    nonisolated static func studentReportHeadline(actionReason: String, ibacalaoSignedIn: Bool) -> String {
        if !ibacalaoSignedIn { return "Signed out of iBacalao" }
        switch actionReason {
        case "reauth_required": return "School sign-in needed"
        case "challenge_paused": return "School paused us"
        case "connector_stale": return "Mac not syncing"
        case "manual_learning_required": return "Finish setup (one visit)"
        default: return "School connected"
        }
    }

    nonisolated static func staleStatus(from status: SchoolPlatformStatus) -> SchoolPlatformStatus {
        if ["reauth_required", "challenge_paused"].contains(status.actionReason) { return status }
        return SchoolPlatformStatus(
            sourceKey: status.sourceKey,
            platformLabel: status.platformLabel,
            schoolLabel: status.schoolLabel,
            connected: false,
            syncMode: status.syncMode,
            actionReason: "connector_stale",
            lastSuccessAt: status.lastSuccessAt,
            lastObservedAt: status.lastObservedAt,
            recipe: status.recipe.map { .init(version: $0.version, confidence: $0.confidence, state: "stale") },
            missingCapabilities: status.missingCapabilities,
            incompleteCapabilities: status.incompleteCapabilities
        )
    }

    private func markStatusStale() {
        guard let status = loadStatus() else { return }
        let stale = Self.staleStatus(from: status)
        guard stale != status, let data = try? JSONEncoder().encode(stale) else { return }
        try? FileManager.default.createDirectory(
            at: statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: statusURL, options: .atomic)
    }

    func loadConnection() -> SchoolPlatformConnection? {
        guard let data = try? Data(contentsOf: connectionURL) else { return nil }
        return try? JSONDecoder().decode(SchoolPlatformConnection.self, from: data)
    }

    func startIfAuthenticated() {
        guard let token = KeyStore.loadSessionToken(), !token.isEmpty else { return }
        Task { await sync(sessionToken: token) }
    }

    func restartWithCurrentSession() {
        guard let token = KeyStore.loadSessionToken(), !token.isEmpty else {
            stopDaemon()
            return
        }
        Task { await sync(sessionToken: token) }
    }

    private func sync(sessionToken: String) async {
        if daemon?.isRunning == true, daemonSessionToken == sessionToken { return }
        let ingestToken = await mintWatcherToken(sessionToken: sessionToken) ?? sessionToken
        guard !Task.isCancelled else { return }
        if daemon?.isRunning == true, daemonSessionToken == sessionToken { return }
        stopDaemon()
        daemonRestartAttempt = 0
        daemonSessionToken = sessionToken
        start(token: ingestToken)
    }

    private func mintWatcherToken(sessionToken: String) async -> String? {
        guard let url = URL(string: "\(LLMClient.resolvedNativeAPIBaseURL)/api/native/school/watcher-token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return Self.parseWatcherTokenResponse(data: data, statusCode: http.statusCode)
    }

    nonisolated static func revokeWatcherTokensNow(sessionToken: String, timeout: TimeInterval = 2) {
        guard !sessionToken.hasPrefix("wt_"),
              let url = URL(string: "\(LLMClient.resolvedNativeAPIBaseURL)/api/native/school/watcher-token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    nonisolated static func parseWatcherTokenResponse(data: Data, statusCode: Int) -> String? {
        guard statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              token.hasPrefix("wt_"),
              token.count > 8,
              token.count <= 200
        else { return nil }
        return token
    }

    /// The watcher's own output, kept on this Mac so crawl, pagination and
    /// upload problems are diagnosable instead of discarded. Owner-only, and
    /// reset past 5 MB so it cannot grow without bound.
    nonisolated static func watcherLogHandle() -> FileHandle {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ibacalao/watcher/daemon.log")
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            try? manager.removeItem(at: url)
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return FileHandle.nullDevice }
        handle.seekToEndOfFile()
        return handle
    }

    private func start(token: String) {
        guard let process = makeProcess(arguments: [
            scriptURL?.path ?? "",
            "--token-stdin",
            "--base-url",
            LLMClient.resolvedNativeAPIBaseURL,
        ]) else {
            markStatusStale()
            dlog("[SchoolWatcher] bundled runtime unavailable; daemon not started")
            return
        }

        markStatusStale()
        let input = Pipe()
        process.standardInput = input
        let log = Self.watcherLogHandle()
        process.standardOutput = log
        process.standardError = log
        let generation = daemonGeneration
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.daemon === finished else { return }
                self.daemon = nil
                guard self.daemonGeneration == generation, self.daemonToken == token, self.loginProcesses.isEmpty else { return }
                self.markStatusStale()
                self.scheduleDaemonRestart(token: token, generation: generation)
            }
        }

        do {
            try process.run()
            input.fileHandleForWriting.write(Data((token + "\n").utf8))
            try? input.fileHandleForWriting.close()
            daemon = process
            daemonToken = token
            daemonStabilityTask?.cancel()
            daemonStabilityTask = Task { [weak self, weak process] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, let process, self.daemon === process, process.isRunning, self.daemonToken == token else { return }
                    self.daemonRestartAttempt = 0
                    dlog("[SchoolWatcher] daemon remained stable; restart budget reset")
                }
            }
            dlog("[SchoolWatcher] daemon started pid=\(process.processIdentifier)")
        } catch {
            markStatusStale()
            dlog("[SchoolWatcher] daemon failed to start: \(error.localizedDescription)")
        }
    }

    /// Opens one visible persistent browser at a search page. The student finds
    /// their school platform and signs in normally; the bundled watcher detects
    /// the authenticated platform locally and reports only its label/origin back
    /// to the shell. Passwords and cookies never cross this process boundary.
    func openDiscovery(onConnected: @escaping (SchoolPlatformConnection) -> Void) throws {
        guard let process = makeProcess(arguments: [
            scriptURL?.path ?? "",
            "--discover",
            "--base-url",
            LLMClient.resolvedNativeAPIBaseURL,
        ]) else {
            throw SchoolWatcherError.runtimeMissing
        }

        stopDaemon()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let connection = Self.parseDiscoveryOutput(text)
            Task { @MainActor in
                self?.loginProcesses.removeAll { $0 === finished }
                self?.restartWithCurrentSession()
                if let connection { onConnected(connection) }
            }
        }
        try process.run()
        loginProcesses.append(process)
        dlog("[SchoolWatcher] opened discovery browser pid=\(process.processIdentifier)")
    }

    /// Reuses the exact persistent profile/origin discovered for this school.
    /// This is intentionally not another discovery pass: expired auth should
    /// take the student straight back to their own portal once.
    func openReconnect(onFinished: @escaping () -> Void = {}) throws {
        guard let connection = loadConnection(), let url = URL(string: connection.origin) else {
            throw SchoolWatcherError.connectionMissing
        }
        try Self.validateSchoolURL(url)
        try openLogin(
            platformID: connection.platformId,
            platformLabel: connection.platformLabel,
            loginURL: url,
            profileKey: connection.profileKey,
            onFinished: onFinished
        )
    }

    /// Arms a bounded local learning request, then opens the already-known
    /// school origin in the student's normal browser. The Chrome/Edge bridge is
    /// passive: this method does not inject, click, fetch, or bypass anything.
    func openLearning() throws {
        guard let connection = loadConnection(), let origin = URL(string: connection.origin) else {
            throw SchoolWatcherError.connectionMissing
        }
        try Self.validateSchoolURL(origin)
        let status = loadStatus()
        let object: [String: Any] = [
            "sourceKey": status?.sourceKey ?? "vendor:\(connection.platformId)",
            "origin": connection.origin,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "missingCapabilities": status?.missingCapabilities ?? [],
        ]
        let directory = learningSessionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: learningSessionURL, options: .atomic)
        guard NSWorkspace.shared.open(origin) else { throw SchoolWatcherError.browserOpenFailed }
    }

    nonisolated static func parseDiscoveryOutput(_ output: String) -> SchoolPlatformConnection? {
        let prefix = "IBACALAO_SCHOOL_CONNECTED\t"
        guard let line = output.split(whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix(prefix) }) else { return nil }
        let json = String(line.dropFirst(prefix.count))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SchoolPlatformConnection.self, from: data)
    }

    /// Opens a visible, persistent browser profile for ANY school platform.
    /// Credentials are typed directly into the platform page by the student and
    /// never pass through iBacalao.
    func openLogin(platform: String, loginURL: URL) throws {
        try Self.validateSchoolURL(loginURL)
        let platformID = Self.normalizedPlatformID(platform)
        guard !platformID.isEmpty else { throw SchoolWatcherError.invalidPlatform }
        try openLogin(
            platformID: platformID,
            platformLabel: platform,
            loginURL: loginURL,
            profileKey: platformID
        )
    }

    private func openLogin(
        platformID: String,
        platformLabel: String,
        loginURL: URL,
        profileKey: String,
        onFinished: @escaping () -> Void = {}
    ) throws {
        let token = daemonToken
        var arguments = [
            scriptURL?.path ?? "",
            "--login", platformID,
            "--label", platformLabel,
            "--url", loginURL.absoluteString,
            "--profile-key", profileKey,
            "--base-url", LLMClient.resolvedNativeAPIBaseURL,
        ]
        if let token, token.hasPrefix("wt_") {
            arguments.append(contentsOf: ["--token-stdin"])
        }
        guard let process = makeProcess(arguments: arguments) else {
            throw SchoolWatcherError.runtimeMissing
        }

        // A persistent Chromium profile cannot be opened safely by two browser
        // processes at once. Pause background polling while the student owns a
        // visible login window, then continue as the same process when a token
        // is passed so we do not cold-spawn a second daemon.
        stopDaemon()
        let input = Pipe()
        if let token, token.hasPrefix("wt_") {
            process.standardInput = input
        }
        let log = Self.watcherLogHandle()
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.loginProcesses.removeAll { $0 === finished }
                if self?.daemon === finished {
                    self?.daemon = nil
                    self?.daemonToken = nil
                }
                self?.restartWithCurrentSession()
                onFinished()
            }
        }
        try process.run()
        if let token, token.hasPrefix("wt_") {
            input.fileHandleForWriting.write(Data((token + "\n").utf8))
            try? input.fileHandleForWriting.close()
            daemon = process
            daemonToken = token
        }
        loginProcesses.append(process)
        dlog("[SchoolWatcher] opened login platform=\(platformID) pid=\(process.processIdentifier)")
    }

    /// Explicit user-initiated disconnect. This is the only path that removes
    /// the saved school profile metadata; ordinary failures remain recoverable
    /// and never force the student to sign in again.
    func disconnect() {
        stop()
        for url in [connectionURL, statusURL, learningSessionURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func stop() {
        let sessionToken = daemonSessionToken ?? KeyStore.loadSessionToken()
        let shouldRevoke = daemonToken?.hasPrefix("wt_") == true || sessionToken != nil
        stopDaemon()
        for process in loginProcesses where process.isRunning { process.terminate() }
        loginProcesses.removeAll()
        if shouldRevoke, let sessionToken, !sessionToken.hasPrefix("wt_") {
            Self.revokeWatcherTokensNow(sessionToken: sessionToken)
        }
    }

    nonisolated static func daemonRestartDelaySeconds(attempt: Int) -> UInt64? {
        guard attempt >= 0, attempt < 6 else { return nil }
        return UInt64(min(60, 1 << attempt))
    }

    private func scheduleDaemonRestart(token: String, generation: Int) {
        guard let delay = Self.daemonRestartDelaySeconds(attempt: daemonRestartAttempt) else {
            dlog("[SchoolWatcher] daemon restart circuit open after repeated failures — LMS traffic paused, profile kept")
            return
        }
        daemonRestartAttempt += 1
        daemonRestartTask?.cancel()
        daemonRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.daemonGeneration == generation, self.daemon == nil, self.loginProcesses.isEmpty else { return }
                self.restartWithCurrentSession()
            }
        }
        dlog("[SchoolWatcher] daemon exited unexpectedly; restart attempt=\(daemonRestartAttempt) in \(delay)s")
    }

    private func stopDaemon() {
        daemonGeneration += 1
        daemonRestartTask?.cancel()
        daemonRestartTask = nil
        daemonStabilityTask?.cancel()
        daemonStabilityTask = nil
        if daemon?.isRunning == true { daemon?.terminate() }
        daemon = nil
        daemonToken = nil
        daemonSessionToken = nil
    }

    private func makeProcess(arguments: [String]) -> Process? {
        guard isRuntimeAvailable, let runtimeRoot, let nodeURL, let browsersURL else {
            // Missing runtime is expected right after install: fetch it and
            // the installer restarts the watcher when it lands.
            WatcherRuntimeInstaller.shared.ensureInstalled()
            return nil
        }
        let process = Process()
        process.executableURL = nodeURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PLAYWRIGHT_BROWSERS_PATH"] = browsersURL.path
        // The script lives in the app bundle but its `playwright` require must
        // resolve from the runtime folder, wherever that is.
        environment["NODE_PATH"] = runtimeRoot.appendingPathComponent("node_modules").path
        environment["IBACALAO_DESKTOP_BUNDLED"] = "1"
        if let scraplingHelperURL,
           FileManager.default.isExecutableFile(atPath: scraplingHelperURL.path) {
            environment["IBACALAO_SCRAPLING_HELPER"] = scraplingHelperURL.path
        }
        process.environment = environment
        return process
    }

    nonisolated static func normalizedPlatformID(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        var output = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                output.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                output.append("-")
                lastWasDash = true
            }
            if output.count >= 80 { break }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    nonisolated static func validateSchoolURL(_ url: URL) throws {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased() ?? ""
        let isHTTPS = scheme == "https" && !host.isEmpty
        let isLocalDev = scheme == "http" && ["localhost", "127.0.0.1"].contains(host)
        guard isHTTPS || isLocalDev, url.user == nil, url.password == nil else {
            throw SchoolWatcherError.invalidLoginURL
        }
    }
}

enum SchoolWatcherError: LocalizedError {
    case runtimeMissing
    case invalidPlatform
    case invalidLoginURL
    case connectionMissing
    case browserOpenFailed

    var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The bundled school-platform runtime is unavailable."
        case .invalidPlatform: return "The school platform id is invalid."
        case .invalidLoginURL: return "School sign-in must use a secure HTTPS URL."
        case .connectionMissing: return "No saved school connection is available on this Mac."
        case .browserOpenFailed: return "The school portal could not be opened in your browser."
        }
    }
}
