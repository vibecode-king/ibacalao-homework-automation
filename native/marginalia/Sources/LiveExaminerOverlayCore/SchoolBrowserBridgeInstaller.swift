import Foundation

enum SchoolBrowserBridgeInstaller {
    static let nativeHostName = "com.ibacalao.school_bridge"
    static let chromeExtensionID = "hlbhkdjklmhminlbdnbimliadhllfbef"

    private static let browserHostDirectories = [
        "Library/Application Support/Google/Chrome/NativeMessagingHosts",
        "Library/Application Support/Microsoft Edge/NativeMessagingHosts",
    ]

    static func installIfPossible() {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/iBacalaoSchoolBridge")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            dlog("[SchoolBridge] helper unavailable; native host manifests not installed")
            return
        }

        let manifest: [String: Any] = [
            "name": nativeHostName,
            "description": "iBacalao school portal bridge",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(chromeExtensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        for relativeDirectory in browserHostDirectories {
            let directory = home.appendingPathComponent(relativeDirectory, isDirectory: true)
            let destination = directory.appendingPathComponent("\(nativeHostName).json")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                dlog("[SchoolBridge] native host registered: \(destination.path)")
            } catch {
                dlog("[SchoolBridge] host registration failed: \(error.localizedDescription)")
            }
        }
    }
}
