import AppKit
import ApplicationServices

/// Reads text from the frontmost app via Accessibility APIs — no Screen Recording needed.
enum AccessibilityTextExtractor {
    /// Minimum characters to treat AX extraction as usable (skip tiny chrome labels).
    static let minSubstantialLength = 12

    /// Minimum word count on the longest line for text to plausibly be prose (vs. UI chrome).
    static let minProseLineWords = 8
    /// Minimum sentence-terminating punctuation marks required across the whole text.
    static let minSentenceTerminators = 2

    private static let didPromptKey = "accessibilityTrustPromptedOnceForBuild"

    /// Bundle path + short version — a rename or version bump re-arms the one-shot
    /// prompt, since TCC grants bind to path+CDHash and a rename orphans old grants.
    private static var promptIdentity: String {
        let path = Bundle.main.bundlePath
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "\(path)#\(version)"
    }

    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false,
        ] as CFDictionary)
    }

    /// Ask the system Accessibility prompt at most once per build identity. Never opens
    /// Settings automatically — that felt like endless permission nagging. User can also
    /// tap Grant in the dashboard at any time via openSettingsForGrant().
    static func requestTrustIfNeeded() {
        guard !isTrusted else { return }
        let identity = promptIdentity
        guard UserDefaults.standard.string(forKey: didPromptKey) != identity else {
            dlog("[AX] already prompted once for this build — not asking again")
            return
        }
        UserDefaults.standard.set(identity, forKey: didPromptKey)
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary)
        dlog("[AX] requested trust prompt (once per build)")
    }

    /// User-initiated only (Grant button). Opens Settings without re-showing the system dialog.
    static func openSettingsForGrant() {
        PrivacySettings.openAccessibility()
        dlog("[AX] user opened Accessibility Settings")
    }

    static var untrustedMessage: String {
        """
        Couldn't read the front app.

        Enable Accessibility for iBacalao in System Settings → Privacy & Security → Accessibility, then try again.
        """
    }

    static var noTextMessage: String {
        "Couldn't read text from the front app. Click into your document and try again."
    }

    /// Discriminates real document prose from UI chrome (menu items, tab titles, toolbar
    /// labels) by shape rather than length. Chrome text is many short disjoint lines; prose
    /// has at least one long, sentence-punctuated line.
    static func looksLikeProse(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        let longestLineWordCount = lines
            .map { $0.split(whereSeparator: { $0.isWhitespace }).count }
            .max() ?? 0
        guard longestLineWordCount >= minProseLineWords else { return false }

        let terminatorCount = text.reduce(into: 0) { count, char in
            if char == "." || char == "!" || char == "?" { count += 1 }
        }
        return terminatorCount >= minSentenceTerminators
    }

    /// Extract visible/focused text from a specific app (preferred target for tips).
    static func extract(from app: NSRunningApplication) -> (text: String, appName: String)? {
        guard isTrusted else {
            dlog("[AX] not trusted")
            return nil
        }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        guard app.processIdentifier != ourPID else {
            dlog("[AX] refused self pid")
            return nil
        }
        return extractText(fromPID: app.processIdentifier, appName: app.localizedName ?? "Unknown")
    }

    /// Extract visible/focused text from the frontmost non-self application.
    static func extractFromFrontmostApp() -> (text: String, appName: String)? {
        guard isTrusted else {
            dlog("[AX] not trusted")
            return nil
        }

        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return extract(from: app)
    }

    private static func extractText(fromPID pid: pid_t, appName: String) -> (text: String, appName: String)? {
        let appElement = AXUIElementCreateApplication(pid)

        var parts: [String] = []

        if let focused = focusedElement(in: appElement),
           let focusedText = textFromElement(focused, includeValue: true) {
            parts.append(focusedText)
        }

        if let window = mainOrFocusedWindow(of: appElement) {
            let windowText = collectText(from: window, depth: 0, maxDepth: 12)
            if !windowText.isEmpty {
                parts.append(windowText)
            }
        }

        let merged = dedupeAndJoin(parts)
        guard merged.count >= minSubstantialLength else {
            dlog("[AX] insufficient text len=\(merged.count) app=\(appName)")
            return merged.isEmpty ? nil : (merged, appName)
        }

        dlog("[AX] extracted len=\(merged.count) app=\(appName)")
        return (merged, appName)
    }

    // MARK: - Tree walk

    private static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let ref = value else { return nil }
        return (ref as! AXUIElement)
    }

    private static func mainOrFocusedWindow(of app: AXUIElement) -> AXUIElement? {
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let ref = focusedWindow {
            return (ref as! AXUIElement)
        }
        var mainWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &mainWindow) == .success,
           let ref = mainWindow {
            return (ref as! AXUIElement)
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement],
           let first = list.first {
            return first
        }
        return nil
    }

    private static func collectText(from element: AXUIElement, depth: Int, maxDepth: Int) -> String {
        guard depth <= maxDepth else { return "" }

        var chunks: [String] = []
        if let chunk = textFromElement(element, includeValue: depth > 0) {
            chunks.append(chunk)
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childList = children as? [AXUIElement] else {
            return dedupeAndJoin(chunks)
        }

        for child in childList {
            let childText = collectText(from: child, depth: depth + 1, maxDepth: maxDepth)
            if !childText.isEmpty { chunks.append(childText) }
        }

        return dedupeAndJoin(chunks)
    }

    private static func textFromElement(_ element: AXUIElement, includeValue: Bool) -> String? {
        var parts: [String] = []

        if includeValue {
            if let selected = copyStringAttribute(element, kAXSelectedTextAttribute as CFString), !selected.isEmpty {
                parts.append(selected)
            }
            if let value = copyStringAttribute(element, kAXValueAttribute as CFString), !value.isEmpty {
                parts.append(value)
            }
        }

        if let title = copyStringAttribute(element, kAXTitleAttribute as CFString), !title.isEmpty {
            parts.append(title)
        }
        if let desc = copyStringAttribute(element, kAXDescriptionAttribute as CFString), !desc.isEmpty {
            parts.append(desc)
        }

        let joined = dedupeAndJoin(parts)
        return joined.isEmpty ? nil : joined
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let attr = value as? NSAttributedString {
            return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    #if DEBUG
    /// Asserts `looksLikeProse` correctly separates browser/UI chrome from real document
    /// text. Run once at launch in debug builds — no test target exists in this package.
    static func runSelfCheck() {
        let chrome = "Untitled document - Google Docs\nFile Edit View Insert Format Tools Extensions Help\nShare\nBold\nItalic\nUnderline\nFont\n11\nNew Tab\nBookmarks"
        assert(!looksLikeProse(chrome), "looksLikeProse should reject browser chrome text")

        let prose = "The experiment measured reaction rate as a function of temperature. Three trials were conducted at each of five temperature settings, and the results were averaged to reduce measurement error. This method allowed for a more reliable comparison across conditions."
        assert(looksLikeProse(prose), "looksLikeProse should accept real prose")

        dlog("[AX] self-check passed: looksLikeProse discriminates chrome vs. prose")
    }
    #endif

    private static func dedupeAndJoin(_ parts: [String]) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for part in parts {
            for line in part.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else { continue }
                let key = trimmed.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n")
    }
}
