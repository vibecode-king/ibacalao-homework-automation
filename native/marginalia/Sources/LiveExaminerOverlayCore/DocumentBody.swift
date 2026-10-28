import AppKit
import CoreGraphics

/// Permanent rule: coach the student's draft, never browser/Docs chrome or window metadata.
enum DocumentBody {
    struct Region {
        /// Vision bounding boxes: origin bottom-left, unit square.
        var minX: CGFloat
        var maxX: CGFloat
        var minY: CGFloat
        var maxY: CGFloat

        static let browser = Region(minX: 0.10, maxX: 0.94, minY: 0.04, maxY: 0.78)
        static let nativeEditor = Region(minX: 0.04, maxX: 0.98, minY: 0.03, maxY: 0.92)
    }

    static func isBrowser(_ app: NSRunningApplication?) -> Bool {
        let id = app?.bundleIdentifier?.lowercased() ?? ""
        let name = app?.localizedName?.lowercased() ?? ""
        if id.contains("safari") || id.contains("chrome") || id.contains("firefox")
            || id.contains("brave") || id.contains("edgemac") || id.contains("chromium")
            || id.contains("vivaldi") || id.contains("opera") || id.contains("orion")
            || id.contains("duckduckgo") || id.contains("arc") || id.contains("sigmaos")
            || id.contains("kagi") || id.contains("thebrowser") {
            return true
        }
        let names = ["safari", "chrome", "firefox", "brave", "microsoft edge", "arc", "opera", "vivaldi", "orion"]
        return names.contains { name == $0 || name.hasPrefix($0 + " ") }
    }

    static func containsPoint(_ box: CGRect, region: Region) -> Bool {
        let x = box.midX
        let y = box.midY
        return x >= region.minX && x <= region.maxX && y >= region.minY && y <= region.maxY
    }

    /// Crop a window screenshot so OCR never sees the tab strip / Docs toolbar.
    static func cropWritingArea(_ image: CGImage, isBrowser: Bool) -> CGImage {
        let region = isBrowser ? Region.browser : Region.nativeEditor
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        // CGImage cropping origin is bottom-left.
        let rect = CGRect(
            x: region.minX * w,
            y: region.minY * h,
            width: (region.maxX - region.minX) * w,
            height: (region.maxY - region.minY) * h
        ).integral
        guard rect.width > 32, rect.height > 32, let cropped = image.cropping(to: rect) else {
            return image
        }
        return cropped
    }

    static func clean(_ raw: String) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isChromeLine($0) }

        let proseRuns = consecutiveProseRuns(in: lines)
        let best = proseRuns.max(by: { $0.count < $1.count }) ?? lines
        return best.joined(separator: "\n")
    }

    static func isUsableDraft(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return false }
        return AccessibilityTextExtractor.looksLikeProse(trimmed)
    }

    static func isChromeLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 2 { return true }
        let lower = t.lowercased()

        let needles = [
            "skip to content", "skip to main",
            "google docs", "documentos de google", "docs.google",
            "contenido del documento", "document outline", "document tabs",
            "pageless format",
            "new tab", "bookmarks bar", "tab group",
            "cuenta de google", "google account",
            "enable screen reader",
            "untitled document", "documento sin título",
            "modo de impresión",
        ]
        if needles.contains(where: { lower.contains($0) }) { return true }

        let exactChrome: Set<String> = [
            "file", "edit", "view", "insert", "format", "tools", "extensions", "help",
            "archivo", "editar", "ver", "insertar", "formato", "herramientas", "ayuda",
            "share", "compartir", "comments", "comentarios", "printing",
        ]
        if exactChrome.contains(lower) { return true }

        // Menu bar mashed onto one line: "File Edit View Insert Format Tools"
        let menuTokens = ["file", "edit", "view", "insert", "format", "tools", "extensions", "help", "archivo", "editar"]
        let words = lower.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count >= 4, words.filter({ menuTokens.contains($0) }).count >= 3 {
            return true
        }

        // Tab title leftovers: "Something - Google Docs" / "… - Documentos de Google"
        if lower.contains(" - google") || lower.hasSuffix("- docs") { return true }

        return false
    }

    private static func consecutiveProseRuns(in lines: [String]) -> [[String]] {
        var runs: [[String]] = []
        var current: [String] = []
        for line in lines {
            let wordCount = line.split(whereSeparator: { $0.isWhitespace }).count
            let looksProse = wordCount >= 6 || line.contains(".") || line.contains("?") || line.contains("!")
            if looksProse {
                current.append(line)
            } else {
                if current.count >= 2 { runs.append(current) }
                current = []
            }
        }
        if current.count >= 2 { runs.append(current) }
        if runs.isEmpty, !lines.isEmpty { return [lines] }
        return runs
    }

    #if DEBUG
    static func runSelfCheck() {
        let chrome = """
        Contenido del documento
        TOK Essay Draft — Incomplete - Documentos de Google
        Skip to main content
        File Edit View Insert Format Tools Extensions Help
        Share
        """
        assert(clean(chrome).count < 40, "DocumentBody.clean should strip Docs/browser chrome")
        let prose = "The experiment measured reaction rate as a function of temperature. Three trials were conducted at each setting."
        assert(isUsableDraft(prose), "DocumentBody should accept real draft prose")
        dlog("[Capture] self-check passed: DocumentBody strips chrome")
    }
    #endif
}
