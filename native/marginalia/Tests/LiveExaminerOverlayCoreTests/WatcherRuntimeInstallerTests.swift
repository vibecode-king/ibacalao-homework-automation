import Foundation
import XCTest
@testable import LiveExaminerOverlayCore

final class WatcherRuntimeInstallerTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("wrt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private let sha = String(repeating: "a", count: 64)

    private func part(_ name: String, url: String = "https://nodejs.org/x.tgz", from: String = ".", to: String = "node", sha: String? = nil, size: Int64 = 1, format: WatcherRuntimeManifest.Part.Format = .tgz, markers: [String]? = nil) -> WatcherRuntimeManifest.Part {
        .init(name: name, urls: [URL(string: url)!], sha256: sha ?? self.sha, size: size, format: format, from: from, to: to, markers: markers)
    }

    func testManifestValidation() {
        XCTAssertTrue(WatcherRuntimeManifest(key: "node-26_pw-1.61.1_abc_arm64", parts: [part("node")]).isValid)
        XCTAssertFalse(WatcherRuntimeManifest(key: "../escape", parts: [part("node")]).isValid, "key becomes a folder name")
        XCTAssertFalse(WatcherRuntimeManifest(key: "k", parts: []).isValid)
        XCTAssertFalse(WatcherRuntimeManifest(key: "k", parts: [part("node", sha: "abc")]).isValid)
        XCTAssertFalse(WatcherRuntimeManifest(key: "k", parts: [part("node", url: "http://evil.example/x.tgz")]).isValid, "plain http is refused")
        XCTAssertFalse(WatcherRuntimeManifest(key: "k", parts: [part("node", to: "../../Applications/x")]).isValid, "cannot write outside the runtime")
        XCTAssertFalse(WatcherRuntimeManifest(key: "k", parts: [part("node", from: "/etc")]).isValid)
        XCTAssertFalse(WatcherRuntimeManifest(key: "k", parts: [part("node", to: ".")]).isValid, "cannot replace the whole runtime")
        XCTAssertFalse(WatcherRuntimeManifest(key: "k", parts: [part("node", markers: ["../x"])]).isValid)
        XCTAssertFalse(WatcherRuntimeManifest(key: "k", parts: [part("node", size: 0)]).isValid)
    }

    func testManifestDecodesReleaseJSON() throws {
        let json = #"{"key":"k1","parts":[{"name":"chromium","urls":["https://storage.googleapis.com/a.zip","https://cdn.playwright.dev/a.zip"],"sha256":"\#(sha)","size":179277110,"format":"zip","from":".","to":"browsers/chromium-1228","markers":["browsers/chromium-1228/INSTALLATION_COMPLETE"]}]}"#
        let manifest = try XCTUnwrap(WatcherRuntimeManifest.decode(Data(json.utf8)))
        XCTAssertEqual(manifest.parts.first?.urls.count, 2)
        XCTAssertEqual(manifest.totalBytes, 179_277_110)
        XCTAssertNil(WatcherRuntimeManifest.decode(Data(#"{"key":"k1","parts":[]}"#.utf8)))
    }

    func testBundledRuntimeWinsOverDownloadedOne() throws {
        let bundled = try makeRuntime(at: temp.appendingPathComponent("bundle/WatcherRuntime"))
        let base = temp.appendingPathComponent("support")
        _ = try makeRuntime(at: base.appendingPathComponent("k1"))
        let manifest = WatcherRuntimeManifest(key: "k1", parts: [part("node")])
        XCTAssertEqual(WatcherRuntimeInstaller.resolveHeavyRoot(bundled: bundled, installBase: base, manifest: manifest), bundled)
    }

    func testDownloadedRuntimeUsedWhenBundleIsSlim() throws {
        let slim = temp.appendingPathComponent("bundle/WatcherRuntime")
        try FileManager.default.createDirectory(at: slim, withIntermediateDirectories: true)
        let base = temp.appendingPathComponent("support")
        let manifest = WatcherRuntimeManifest(key: "k2", parts: [part("node")])
        XCTAssertNil(WatcherRuntimeInstaller.resolveHeavyRoot(bundled: slim, installBase: base, manifest: manifest))
        let installed = try makeRuntime(at: base.appendingPathComponent("k2"))
        XCTAssertEqual(WatcherRuntimeInstaller.resolveHeavyRoot(bundled: slim, installBase: base, manifest: manifest)?.standardizedFileURL.path, installed.standardizedFileURL.path)
    }

    func testIncompleteRuntimeIsNotUsable() throws {
        let root = try makeRuntime(at: temp.appendingPathComponent("rt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("browsers"))
        XCTAssertFalse(WatcherRuntimeInstaller.isUsableHeavyRuntime(root))
    }

    func testSha256MatchesShasum() throws {
        let file = temp.appendingPathComponent("f.bin")
        try Data("ibacalao".utf8).write(to: file)
        XCTAssertEqual(try WatcherRuntimeInstaller.sha256Hex(of: file), try shasum(file))
    }

    /// End to end against a real local server, with archives shaped like the
    /// official ones: a Node tarball, npm package tarballs, a Chromium zip.
    func testAssemblesRuntimeFromSeparateOfficialStyleArchives() async throws {
        let serve = temp.appendingPathComponent("serve")
        let fm = FileManager.default

        let nodeSrc = temp.appendingPathComponent("src-node/node-v26.3.0-darwin-arm64/bin")
        try fm.createDirectory(at: nodeSrc, withIntermediateDirectories: true)
        try executable("#!/bin/sh\necho v26\n", at: nodeSrc.appendingPathComponent("node"))
        try fm.createDirectory(at: serve, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-czf", serve.appendingPathComponent("node.tar.gz").path, "-C", temp.appendingPathComponent("src-node").path, "node-v26.3.0-darwin-arm64"])

        for pkg in ["playwright", "playwright-core"] {
            let dir = temp.appendingPathComponent("src-\(pkg)/package")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"name":"\#(pkg)"}"#.utf8).write(to: dir.appendingPathComponent("package.json"))
            try run("/usr/bin/tar", ["-czf", serve.appendingPathComponent("\(pkg).tgz").path, "-C", temp.appendingPathComponent("src-\(pkg)").path, "package"])
        }

        let chrome = temp.appendingPathComponent("src-chrome/chrome-mac-arm64/Chrome.app/Contents")
        try fm.createDirectory(at: chrome, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: temp.appendingPathComponent("src-chrome/chrome-mac-arm64/Current").path, withDestinationPath: "Chrome.app")
        try run("/usr/bin/ditto", ["-c", "-k", temp.appendingPathComponent("src-chrome").path, serve.appendingPathComponent("chrome.zip").path])

        let (server, port) = try startServer(serving: serve)
        defer { server.terminate() }
        func served(_ file: String, name: String, format: WatcherRuntimeManifest.Part.Format, from: String, to: String, markers: [String]? = nil, badFirstMirror: Bool = false) throws -> WatcherRuntimeManifest.Part {
            let url = serve.appendingPathComponent(file)
            let size = try XCTUnwrap((try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value)
            var urls = [URL(string: "http://127.0.0.1:\(port)/\(file)")!]
            if badFirstMirror { urls.insert(URL(string: "http://127.0.0.1:\(port)/missing-\(file)")!, at: 0) }
            return .init(name: name, urls: urls, sha256: try WatcherRuntimeInstaller.sha256Hex(of: url), size: size, format: format, from: from, to: to, markers: markers)
        }

        let manifest = WatcherRuntimeManifest(key: "k-real", parts: [
            try served("node.tar.gz", name: "node", format: .tgz, from: "node-v26.3.0-darwin-arm64/bin/node", to: "node/bin/node"),
            try served("playwright.tgz", name: "playwright", format: .tgz, from: "package", to: "node_modules/playwright"),
            try served("playwright-core.tgz", name: "playwright-core", format: .tgz, from: "package", to: "node_modules/playwright-core"),
            try served("chrome.zip", name: "chromium", format: .zip, from: ".", to: "browsers/chromium-1228",
                       markers: ["browsers/chromium-1228/INSTALLATION_COMPLETE"], badFirstMirror: true),
        ])
        XCTAssertTrue(manifest.isValid)

        let base = temp.appendingPathComponent("support")
        try fm.createDirectory(at: base.appendingPathComponent("old-key"), withIntermediateDirectories: true)
        let fractions = LockedList()
        let installed = try await WatcherRuntimeInstaller.install(manifest: manifest, base: base) { fraction, _ in fractions.append(fraction) }

        XCTAssertTrue(WatcherRuntimeInstaller.isUsableHeavyRuntime(installed))
        XCTAssertTrue(fm.isExecutableFile(atPath: installed.appendingPathComponent("node/bin/node").path), "exec bit survives tar")
        XCTAssertTrue(fm.fileExists(atPath: installed.appendingPathComponent("node_modules/playwright-core/package.json").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: installed.appendingPathComponent("browsers/chromium-1228/chrome-mac-arm64/Current").path), "Chrome.app", "symlinks survive ditto")
        XCTAssertTrue(fm.fileExists(atPath: installed.appendingPathComponent("browsers/chromium-1228/INSTALLATION_COMPLETE").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base.path), ["k-real"], "old versions and temp folders are removed")
        XCTAssertEqual(fractions.values.last ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(fractions.values, fractions.values.sorted(), "progress never goes backwards across files")

        var tampered = manifest.parts
        tampered[1] = .init(name: "playwright", urls: tampered[1].urls, sha256: String(repeating: "0", count: 64), size: tampered[1].size, format: .tgz, from: "package", to: "node_modules/playwright", markers: nil)
        do {
            _ = try await WatcherRuntimeInstaller.install(manifest: .init(key: "k-bad", parts: tampered), base: base) { _, _ in }
            XCTFail("a hash mismatch must never install")
        } catch let error as WatcherRuntimeInstallError {
            XCTAssertEqual(error, .checksumMismatch("playwright"))
            XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("k-bad").path))
            XCTAssertTrue(WatcherRuntimeInstaller.isUsableHeavyRuntime(installed), "a failed install never damages the working runtime")
        }
    }

    /// Opt-in (downloads ~230 MB): IBACALAO_RUNTIME_E2E_MANIFEST=/path/runtime-manifest.json
    /// Installs from the real official URLs, then launches Chromium through Playwright.
    func testRealOfficialDownloadsLaunchChromium() async throws {
        guard let path = ProcessInfo.processInfo.environment["IBACALAO_RUNTIME_E2E_MANIFEST"] else {
            throw XCTSkip("set IBACALAO_RUNTIME_E2E_MANIFEST to run against the real downloads")
        }
        let manifest = try XCTUnwrap(WatcherRuntimeManifest.decode(Data(contentsOf: URL(fileURLWithPath: path))))
        let root = try await WatcherRuntimeInstaller.install(manifest: manifest, base: temp.appendingPathComponent("support")) { _, _ in }

        let script = temp.appendingPathComponent("probe.cjs")
        try Data("""
        const { chromium } = require("playwright");
        (async () => {
          const ctx = await chromium.launchPersistentContext(process.argv[2], { headless: true, channel: "chromium" });
          const page = await ctx.newPage();
          await page.setContent("<title>ibacalao-ok</title>");
          console.log(await page.title());
          await ctx.close();
        })().catch((e) => { console.error(e.message); process.exit(1); });
        """.utf8).write(to: script)
        let out = Pipe()
        let node = Process()
        node.executableURL = root.appendingPathComponent("node/bin/node")
        node.arguments = [script.path, temp.appendingPathComponent("profile").path]
        node.environment = [
            "NODE_PATH": root.appendingPathComponent("node_modules").path,
            "PLAYWRIGHT_BROWSERS_PATH": root.appendingPathComponent("browsers").path,
            "HOME": NSHomeDirectory(),
        ]
        node.standardOutput = out
        try node.run(); node.waitUntilExit()
        XCTAssertEqual(node.terminationStatus, 0)
        XCTAssertTrue(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("ibacalao-ok"))
    }

    // MARK: helpers

    final class LockedList: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Double] = []
        func append(_ v: Double) { lock.lock(); items.append(v); lock.unlock() }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @discardableResult
    private func makeRuntime(at root: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("node/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/playwright"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("browsers"), withIntermediateDirectories: true)
        try executable("#!/bin/sh\n", at: root.appendingPathComponent("node/bin/node"))
        return root
    }

    private func executable(_ contents: String, at url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func shasum(_ file: URL) throws -> String {
        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", file.path]
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ")[0].description
    }

    private func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(path) \(args)")
    }

    private func startServer(serving dir: URL) throws -> (Process, Int) {
        let port = Int.random(in: 49_152...60_000)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", dir.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        for _ in 0..<50 {
            if (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/")!)) != nil { return (p, port) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        p.terminate()
        throw XCTSkip("could not start local HTTP server")
    }
}
