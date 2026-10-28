import Foundation

enum TextDiff {
    // Line-set diff, not a prefix diff: with full-screen capture, the student's
    // document is one region among many (menu bar, dock, other windows) — new
    // writing isn't necessarily the last thing in Vision's reading order, so a
    // "what changed at the very end" diff misses it. This instead keeps every
    // line from `current` that wasn't already in `previous`, in `current`'s
    // order. Static screen chrome (repeated every capture) naturally drops out
    // since it's present in both; only genuinely new lines survive.
    static func newSuffix(previous: String, current: String) -> String {
        if previous.isEmpty { return trimmed(current) }

        let previousLines = lineSet(previous)
        let newLines = current
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !previousLines.contains($0) }
        if !newLines.isEmpty { return newLines.joined(separator: "\n") }

        // OCR re-reads the same lines with minor drift (spacing, punctuation). Fall
        // back to a suffix diff on normalized text so in-place edits still register.
        let prevNorm = normalize(previous)
        let currNorm = normalize(current)
        if currNorm.count > prevNorm.count, currNorm.hasPrefix(prevNorm) {
            let suffix = String(currNorm.dropFirst(prevNorm.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty { return suffix }
        }
        return ""
    }

    /// Best text to send to the coach: delta when continuing the same draft,
    /// full OCR when the screen is mostly new (switched doc/app/full screen).
    static func textForFeedback(previous: String, current: String) -> String {
        let currentTrimmed = trimmed(current)
        guard !currentTrimmed.isEmpty else { return "" }
        if previous.isEmpty { return currentTrimmed }

        let overlap = lineOverlapRatio(previous: previous, current: current)
        let delta = newSuffix(previous: previous, current: current)

        // Mostly new screen — chrome overlaps but the draft changed; coach on what's visible.
        if overlap < 0.50 { return currentTrimmed }

        if !delta.isEmpty {
            if delta.count >= 12 { return delta }
            // Same doc with a tiny addition — still coach if there's plenty on screen.
            if currentTrimmed.count >= 60 { return currentTrimmed }
            if delta.count >= 4 { return delta }
            // Short delta but user clearly added something — prefer delta over silence.
            return delta
        }

        // Delta empty: same capture reread, OCR drift, or reordered lines.
        if overlap >= 0.95 { return "" }
        if currentTrimmed.count > previous.count + 12 { return currentTrimmed }
        if currentTrimmed.count >= 50 { return currentTrimmed }
        return ""
    }

    /// Share of current OCR lines that also appeared in the previous capture.
    static func lineOverlapRatio(previous: String, current: String) -> Double {
        let prev = lineSet(previous)
        let curr = lineSet(current)
        guard !curr.isEmpty else { return 1 }
        let shared = curr.intersection(prev).count
        return Double(shared) / Double(curr.count)
    }

    private static func lineSet(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
