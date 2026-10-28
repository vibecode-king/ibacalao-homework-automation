import AppKit

enum PrivacySettings {
    static func openAccessibility() {
        openPane("Privacy_Accessibility")
    }

    /// Not called automatically — kept for optional user-initiated deep links only.
    static func openInputMonitoring() {
        openPane("Privacy_ListenEvent")
    }

    /// Not called automatically — kept for optional user-initiated deep links only.
    static func openScreenRecording() {
        openPane("Privacy_ScreenCapture")
    }

    /// Sound settings — for when tips play on Speakers while AirPods are worn.
    static func openSoundOutput() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.sound",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                dlog("[Privacy] opened sound settings")
                return
            }
        }
        dlog("[Privacy] failed to open sound settings")
    }

    private static func openPane(_ pane: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane)",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                dlog("[Privacy] opened settings pane \(pane)")
                return
            }
        }
        dlog("[Privacy] failed to open settings pane \(pane)")
    }
}
