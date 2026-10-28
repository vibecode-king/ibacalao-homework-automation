import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCapture {
    // CGPreflightScreenCaptureAccess() often stays false for ad-hoc signed builds
    // even when System Settings shows the toggle ON. Never use it alone to drive UI.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Never opens System Settings or calls CGRequestScreenCaptureAccess — avoids TCC re-prompts.
    static func requestPermission() {
        dlog("[Capture] requestPermission ignored — never auto-open Screen Recording settings")
    }

    static var permissionErrorMessage: String {
        "Couldn't read the screen. Try clicking into your document, or enable Accessibility for iBacalao."
    }

    /// Screen OCR only when Screen Recording is already granted — never prompts or opens Settings.
    static func captureForOCR(preferDisplay: Bool = false, targetPID: pid_t? = nil) async -> (image: CGImage, source: String)? {
        guard isAuthorized else {
            dlog("[Capture] skip OCR — screen recording not authorized")
            return nil
        }
        // #region agent log
        agentLog("H4", location: "ScreenCapture.swift:captureForOCR", message: "capture begin", data: [
            "preferDisplay": preferDisplay,
        ])
        // #endregion

        if let kit = await captureWithScreenCaptureKit(preferDisplay: preferDisplay, targetPID: targetPID) {
            dlog("[Capture] source=\(kit.source)")
            return kit
        }
        if !preferDisplay, let window = captureWindowLegacy(ownedBy: targetPID) {
            dlog("[Capture] source=legacyTargetWindow")
            return (window, "legacyTargetWindow")
        }
        if preferDisplay, let screen = captureScreenLegacy() {
            dlog("[Capture] source=legacyFullScreen")
            return (screen, "legacyFullScreen")
        }
        dlog("[Capture] all capture paths failed preferDisplay=\(preferDisplay)")
        return nil
    }

    /// Samples a downscaled copy; true when uniformly near-black (permission-denied capture).
    static func isLikelyBlank(_ image: CGImage) -> Bool {
        let w = min(image.width, 64)
        let h = min(image.height, 64)
        guard w > 0, h > 0 else { return true }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var maxBrightness = 0
        var totalBrightness = 0
        let pixelCount = w * h
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let brightness = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
            maxBrightness = max(maxBrightness, brightness)
            totalBrightness += brightness
        }
        let averageBrightness = pixelCount > 0 ? totalBrightness / pixelCount : 0
        return maxBrightness < 15 && averageBrightness < 5
    }

    private static func captureWithScreenCaptureKit(preferDisplay: Bool = false, targetPID: pid_t? = nil) async -> (image: CGImage, source: String)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ourPID = ProcessInfo.processInfo.processIdentifier
            let config = SCStreamConfiguration()
            config.captureResolution = .best

            if !preferDisplay {
                let targetWindowID = targetPID.flatMap { windowIDOwned(by: $0) }
                    ?? frontmostWindowID(excludingPID: ourPID)
                if let targetWindowID,
                   let window = content.windows.first(where: { $0.windowID == targetWindowID }) {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    if !isLikelyBlank(image) {
                        return (image, "screenCaptureKitWindow")
                    }
                    dlog("[Capture] ScreenCaptureKit window image blank for id \(targetWindowID)")
                }
            }

            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                dlog("[Capture] ScreenCaptureKit: main display not found")
                return nil
            }
            let ourWindows = content.windows.filter { $0.owningApplication?.processID == ourPID }
            let filter = SCContentFilter(display: display, excludingWindows: ourWindows)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if isLikelyBlank(image) {
                dlog("[Capture] ScreenCaptureKit display image blank")
                return nil
            }
            return (image, "screenCaptureKitDisplay")
        } catch {
            dlog("[Capture] ScreenCaptureKit failed: \(error)")
            return nil
        }
    }

    private static func windowPassesSize(_ info: [String: Any]) -> Bool {
        guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
        guard info[kCGWindowIsOnscreen as String] as? Bool != false else { return false }
        guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let width = boundsDict["Width"],
              let height = boundsDict["Height"],
              width >= 120, height >= 120 else { return false }
        return true
    }

    private static func windowIDOwned(by pid: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid else { continue }
            guard windowPassesSize(info) else { continue }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }

    private static func frontmostWindowID(excludingPID: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID != excludingPID else {
                continue
            }
            guard windowPassesSize(info) else { continue }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }

    /// Full-screen legacy capture doesn't exclude our own window by itself — with
    /// sharingType == .none our overlay is already invisible to it, but this is a
    /// second guard in case sharingType is ever set to .readOnly (demo mode).
    private static func captureScreenLegacy() -> CGImage? {
        CGDisplayCreateImage(CGMainDisplayID())
    }

    private static func captureWindowLegacy(ownedBy targetPID: pid_t?) -> CGImage? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let ourPID = ProcessInfo.processInfo.processIdentifier

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID != ourPID else {
                continue
            }
            if let targetPID, ownerPID != targetPID { continue }
            guard windowPassesSize(info) else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else { continue }

            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            let rect = CGRect(x: x, y: y, width: width, height: height)
            if let image = CGWindowListCreateImage(
                rect,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            ), !isLikelyBlank(image) {
                return image
            }
        }

        return nil
    }
}
