import AppKit
import ApplicationServices
import ScreenCaptureKit

// Phase 0.3 sandbox spike — read-only, non-destructive checks of whether
// Accessibility (AX) cross-process reads and ScreenCaptureKit still work
// once `com.apple.security.app-sandbox` is applied to the process.
//
// Deliberately uses only NON-PROMPTING queries (AXIsProcessTrusted,
// CGPreflightScreenCaptureAccess) so this never pops a permission dialog or
// mutates system state. It reports current status; it does not request
// access. See docs/app-launch/SANDBOX_SPIKE.md for how to run this and how
// to read the results — including why a "not authorized" result from this
// binary alone does not prove or disprove the sandbox verdict.

func line(_ s: String) { print(s); fflush(stdout) }

line("=== iBacalao Sandbox Spike ===")
line("pid=\(ProcessInfo.processInfo.processIdentifier) bundlePath=\(Bundle.main.bundlePath)")

// --- 1. Accessibility: is this binary AX-trusted right now? ---
// Non-prompting: does not show the system permission dialog.
let axTrusted = AXIsProcessTrusted()
line("AX_TRUSTED=\(axTrusted)")

if axTrusted {
    // Cross-process AX read against Finder (always running, never destructive
    // to read its AXTitle/AXWindows attribute).
    if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
        let axApp = AXUIElementCreateApplication(finder.processIdentifier)
        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        line("AX_CROSS_PROCESS_READ_RESULT=\(err.rawValue) (\(axErrorName(err)))")
    } else {
        line("AX_CROSS_PROCESS_READ_RESULT=SKIPPED (Finder not found via NSRunningApplication)")
    }
} else {
    line("AX_CROSS_PROCESS_READ_RESULT=SKIPPED (not AX-trusted — see docs/app-launch/SANDBOX_SPIKE.md to grant, then re-run)")
}

// --- 2. ScreenCaptureKit: is Screen Recording currently granted? ---
// CGPreflightScreenCaptureAccess never prompts; it only reports status.
let scPreflight = CGPreflightScreenCaptureAccess()
line("SCREEN_RECORDING_PREFLIGHT=\(scPreflight)")

let semaphore = DispatchSemaphore(value: 0)
if scPreflight {
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            line("SCK_SHAREABLE_CONTENT_RESULT=OK displays=\(content.displays.count) windows=\(content.windows.count)")
        } catch {
            line("SCK_SHAREABLE_CONTENT_RESULT=ERROR \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()
} else {
    line("SCK_SHAREABLE_CONTENT_RESULT=SKIPPED (Screen Recording not granted — see docs/app-launch/SANDBOX_SPIKE.md to grant, then re-run)")
}

line("=== Done ===")

func axErrorName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .apiDisabled: return "apiDisabled — AX API disabled (matches sandbox-denial reports)"
    case .cannotComplete: return "cannotComplete — often the sandbox-cross-process-denial code"
    case .notImplemented: return "notImplemented"
    case .noValue: return "noValue"
    default: return "other(\(e.rawValue))"
    }
}
