import Foundation
import XCTest
@testable import LiveExaminerOverlayCore

/// Pre-existing state in the install folder, and disk space running out. Each
/// test installs onto its own small APFS disk image, which is also a non-boot
/// volume (where important-usage capacity reads 0).
final class WatcherRuntimeEdgeCaseTests: XCTestCase {
    private var temp: URL!
    private var mounts: [URL] = []
    private var server: Process?
    private let fm = FileManager.default

    override func setUpWithError() throws {
        temp = fm.temporaryDirectory.appendingPathComponent("wrt-edge-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server?.terminate()
        for m in mounts { sh("/usr/bin/hdiutil", ["detach", m.path, "-force", "-quiet"]) }
        try? fm.removeItem(at: temp)
    }

    // MARK: pre-existing state

    func testLeftoversFromEarlierInstallsAreReplaced() async throws {
        let (manifest, _) = try servedManifest(payloadMB: 2)
        let base = try disk("pre", sizeMB: 200).appendingPathComponent("support")
        // Old runtime version, a broken same-key folder (no browsers/), and an orphan from a killed install.
        try fm.createDirectory(at: base.appendingPathComponent("node-old_pw-old/node_modules/playwright"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("\(manifest.key)/node/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent(".partial-dead"), withIntermediateDirectories: true)

        let root = try await WatcherRuntimeInstaller.install(manifest: manifest, base: base) { _, _ in }
        XCTAssertTrue(WatcherRuntimeInstaller.isUsableHeavyRuntime(root))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base.path), [manifest.key])
    }

    func testAlreadyInstalledRuntimeSkipsDownload() async throws {
        let (manifest, _) = try servedManifest(payloadMB: 2)
        let base = try disk("skip", sizeMB: 200).appendingPathComponent("support")
        _ = try await WatcherRuntimeInstaller.install(manifest: manifest, base: base) { _, _ in }
        server?.terminate(); server = nil // no network now
        let calls = Counter()
        _ = try await WatcherRuntimeInstaller.install(manifest: manifest, base: base) { _, _ in calls.bump() }
        XCTAssertEqual(calls.value, 0, "second run must not download anything")
    }

    // MARK: disk space

    func testNotEnoughSpaceUpFrontLeavesNothingBehind() async throws {
        let (manifest, _) = try servedManifest(payloadMB: 30) // needs 4x = ~120 MB
        let base = try disk("small", sizeMB: 80).appendingPathComponent("support")
        do {
            _ = try await WatcherRuntimeInstaller.install(manifest: manifest, base: base) { _, _ in }
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? WatcherRuntimeInstallError, .notEnoughSpace)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base.path), [])
    }

    func testDiskFillsMidInstallThenRecoversAfterSpaceFreed() async throws {
        let (manifest, _) = try servedManifest(payloadMB: 25)
        let volume = try disk("mid", sizeMB: 300)
        let base = volume.appendingPathComponent("support")
        // A working older runtime must survive a failed upgrade.
        try makeRuntime(at: base.appendingPathComponent("node-old_pw-old"))

        let filler = volume.appendingPathComponent("filler.bin")
        let filled = Counter()
        do {
            _ = try await WatcherRuntimeInstaller.install(manifest: manifest, base: base) { _, _ in
                // First progress tick: another app eats the disk, leaving ~2 MB.
                if filled.bump() == 1 { self.fill(volume, leavingMB: 2, file: filler) }
            }
            XCTFail("install should fail when the disk fills")
        } catch {
            // Expected: the disk filled.
        }
        let left = try fm.contentsOfDirectory(atPath: base.path).sorted()
        XCTAssertEqual(left, ["node-old_pw-old"], "no partial or half-installed folders left")
        XCTAssertTrue(WatcherRuntimeInstaller.isUsableHeavyRuntime(base.appendingPathComponent("node-old_pw-old")))

        try? fm.removeItem(at: filler)
        let root = try await WatcherRuntimeInstaller.install(manifest: manifest, base: base) { _, _ in }
        XCTAssertTrue(WatcherRuntimeInstaller.isUsableHeavyRuntime(root))
    }

    /// A force-quit mid-install leaves `.partial-*`; it must not block the next install's space check.
    func testOrphanPartialFromKilledInstallIsClearedBeforeSpaceCheck() async throws {
        let (manifest, _) = try servedManifest(payloadMB: 15) // needs ~60 MB
        let volume = try disk("orphan", sizeMB: 150)
        let base = volume.appendingPathComponent("support")
        let orphan = base.appendingPathComponent(".partial-killed")
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        fill(volume, leavingMB: 40, file: orphan.appendingPathComponent("chromium.download"))

        let root = try await WatcherRuntimeInstaller.install(manifest: manifest, base: base) { _, _ in }
        XCTAssertTrue(WatcherRuntimeInstaller.isUsableHeavyRuntime(root))
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
    }

    // MARK: helpers

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        @discardableResult func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func disk(_ name: String, sizeMB: Int) throws -> URL {
        let image = temp.appendingPathComponent("\(name).sparseimage")
        let mount = temp.appendingPathComponent("mnt-\(name)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        XCTAssertEqual(sh("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(sizeMB)m", "-type", "SPARSE", "-fs", "APFS", "-volname", name, image.path]), 0)
        XCTAssertEqual(sh("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path]), 0)
        mounts.append(mount)
        return mount
    }

    private func fill(_ volume: URL, leavingMB: Int, file: URL) {
        let free = (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0
        let mb = max(0, free / 1_000_000 - leavingMB)
        sh("/bin/dd", ["if=/dev/zero", "of=\(file.path)", "bs=1m", "count=\(mb)"])
    }

    /// One zip part (random bytes, incompressible) plus tiny node/playwright parts.
    private func servedManifest(payloadMB: Int) throws -> (WatcherRuntimeManifest, URL) {
        let serve = temp.appendingPathComponent("serve-\(UUID().uuidString)")
        let src = temp.appendingPathComponent("src-\(UUID().uuidString)")
        try fm.createDirectory(at: serve, withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appendingPathComponent("n/node-v/bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: src.appendingPathComponent("n/node-v/bin/node"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("n/node-v/bin/node").path)
        sh("/usr/bin/tar", ["-czf", serve.appendingPathComponent("node.tgz").path, "-C", src.appendingPathComponent("n").path, "node-v"])
        try fm.createDirectory(at: src.appendingPathComponent("p/package"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: src.appendingPathComponent("p/package/package.json"))
        sh("/usr/bin/tar", ["-czf", serve.appendingPathComponent("pw.tgz").path, "-C", src.appendingPathComponent("p").path, "package"])
        try fm.createDirectory(at: src.appendingPathComponent("c/chrome-mac-arm64"), withIntermediateDirectories: true)
        sh("/bin/dd", ["if=/dev/urandom", "of=\(src.appendingPathComponent("c/chrome-mac-arm64/blob").path)", "bs=1m", "count=\(payloadMB)"])
        sh("/usr/bin/ditto", ["-c", "-k", src.appendingPathComponent("c").path, serve.appendingPathComponent("chrome.zip").path])
        try? fm.removeItem(at: src)

        let port = Int.random(in: 49_152...60_000)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", serve.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); server = p
        for _ in 0..<50 where (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/")!)) == nil { Thread.sleep(forTimeInterval: 0.1) }

        func part(_ file: String, _ name: String, _ format: WatcherRuntimeManifest.Part.Format, _ from: String, _ to: String) throws -> WatcherRuntimeManifest.Part {
            let url = serve.appendingPathComponent(file)
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
            return .init(name: name, urls: [URL(string: "http://127.0.0.1:\(port)/\(file)")!], sha256: try WatcherRuntimeInstaller.sha256Hex(of: url), size: size, format: format, from: from, to: to, markers: nil)
        }
        let manifest = WatcherRuntimeManifest(key: "k-edge", parts: [
            try part("node.tgz", "node", .tgz, "node-v/bin/node", "node/bin/node"),
            try part("pw.tgz", "playwright", .tgz, "package", "node_modules/playwright"),
            try part("chrome.zip", "chromium", .zip, ".", "browsers/chromium-1228"),
        ])
        return (manifest, serve)
    }

    private func makeRuntime(at root: URL) throws {
        try fm.createDirectory(at: root.appendingPathComponent("node/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/playwright"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("browsers"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("node/bin/node"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("node/bin/node").path)
    }

    @discardableResult
    private func sh(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
}
