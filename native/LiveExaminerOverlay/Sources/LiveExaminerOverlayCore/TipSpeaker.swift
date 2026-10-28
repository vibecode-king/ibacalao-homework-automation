import Foundation
import AppKit
import AVFoundation
import CoreAudio

/// One installed macOS speech voice (`say -v`).
struct SystemVoice: Identifiable, Hashable {
    let name: String
    let locale: String
    var id: String { "\(name)|\(locale)" }
    var menuLabel: String { "\(name)  ·  \(locale)" }

    /// Language code from locale (`en_US` → `en`).
    var languageCode: String {
        let normalized = locale.replacingOccurrences(of: "-", with: "_")
        return normalized.split(separator: "_").first.map { String($0).lowercased() } ?? normalized.lowercased()
    }

    /// Compact cue for the custom voice menu.
    var emoji: String {
        switch languageCode {
        case "en": return "🇺🇸"
        case "es": return "🇪🇸"
        case "fr": return "🇫🇷"
        case "de": return "🇩🇪"
        case "it": return "🇮🇹"
        case "pt": return "🇧🇷"
        case "zh": return "🇨🇳"
        case "ja": return "🇯🇵"
        case "ko": return "🇰🇷"
        case "ar": return "🇸🇦"
        case "hi": return "🇮🇳"
        case "ru": return "🇷🇺"
        case "nl": return "🇳🇱"
        case "sv": return "🇸🇪"
        case "nb", "nn", "no": return "🇳🇴"
        case "da": return "🇩🇰"
        case "fi": return "🇫🇮"
        case "pl": return "🇵🇱"
        case "tr": return "🇹🇷"
        default: return "🔊"
        }
    }
}

/// Speaks examiner tips aloud. DirectDMG builds use `/usr/bin/say` + an optional
/// AirPods routing helper; MAS (App Sandbox) builds use `AVSpeechSynthesizer`
/// in-process — no `Process`, `swiftc`, or shell tools.
@MainActor
final class TipSpeaker {
    static let shared = TipSpeaker()

    private var sayTask: Process?
    private var speakGeneration = 0
    private let masSynthesizer = AVSpeechSynthesizer()

    private static var usesSandboxSpeech: Bool { AppSandbox.isEnabled }

    /// True only when the system output is muted — never adjusts the user's volume.
    static var isSystemAudioSilent: Bool {
        if usesSandboxSpeech { return false }
        guard let raw = try? Shell.stdout("/usr/bin/osascript", args: ["-e", "get volume settings"]) else {
            return false
        }
        return raw.contains("output muted:true")
    }

    static var silentAudioMessage: String {
        "Mac sound is muted. Unmute to hear spoken tips."
    }

    /// Cached so we don't block speech on `system_profiler`.
    private static var cachedOutputName = "Mac speakers"
    private static var lastOutputProbe: Date = .distantPast

    static var currentOutputName: String {
        if usesSandboxSpeech { return "Mac speakers" }
        if Date().timeIntervalSince(lastOutputProbe) < 30 {
            return cachedOutputName
        }
        lastOutputProbe = Date()
        guard let raw = try? Shell.stdout("/usr/sbin/system_profiler", args: ["SPAudioDataType", "-detailLevel", "mini"]) else {
            return cachedOutputName
        }
        let lines = raw.components(separatedBy: .newlines)
        for (idx, line) in lines.enumerated() {
            if line.contains("Default Output Device: Yes") {
                for back in stride(from: idx, through: max(0, idx - 8), by: -1) {
                    let trimmed = lines[back].trimmingCharacters(in: .whitespaces)
                    if trimmed.hasSuffix(":") && !trimmed.contains("Default") {
                        cachedOutputName = String(trimmed.dropLast())
                        return cachedOutputName
                    }
                }
            }
        }
        return cachedOutputName
    }

    static func bluetoothAirPodsConnected() -> (connected: Bool, name: String?) {
        if usesSandboxSpeech { return (false, nil) }
        guard let raw = try? Shell.stdout("/usr/sbin/system_profiler", args: ["SPBluetoothDataType", "-json"]),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["SPBluetoothDataType"] as? [[String: Any]],
              let first = list.first
        else {
            return (false, nil)
        }
        if let connected = first["device_connected"] as? [[String: Any]] {
            for item in connected {
                for name in item.keys where name.localizedCaseInsensitiveContains("AirPod") {
                    return (true, name)
                }
            }
        }
        return (false, nil)
    }

    static func spokenRouteDiagnosis() -> (route: String, warning: String?) {
        let route = currentOutputName
        let onAirPods = route.localizedCaseInsensitiveContains("AirPod")
        if onAirPods {
            return (route, nil)
        }
        let bt = bluetoothAirPodsConnected()
        if bt.connected {
            return (
                route,
                "AirPods are on Bluetooth but Mac sound is still \(route). Control Center → Sound → \(bt.name ?? "AirPods"), then try again. Or remove AirPods to hear Speakers."
            )
        }
        // Don't nag on every tip — only warn when AirPods are connected but unused.
        return (route, nil)
    }

    static func prewarmAudioRoute() {
        if usesSandboxSpeech { return }
        _ = currentOutputName
    }

    func reset() {
        speakGeneration &+= 1
        if Self.usesSandboxSpeech {
            masSynthesizer.stopSpeaking(at: .immediate)
            dlog("[Speech] reset gen=\(speakGeneration) (AVSpeech)")
            return
        }
        sayTask?.terminate()
        sayTask = nil
        Self.killStraySayProcesses()
        dlog("[Speech] reset gen=\(speakGeneration)")
    }

    /// Speak the full tip once. Cancels any in-flight speech first.
    /// Strips parenthetical asides (e.g. route footers, "e.g. …") so they aren't read aloud.
    func speakTip(_ tip: String) {
        speak(tip, voice: AppSettings.shared.spokenVoice, rate: 190)
    }

    /// Short sample of the selected (or given) macOS voice.
    func previewVoice(_ voice: String? = nil) {
        let name = (voice ?? AppSettings.shared.spokenVoice).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = name.isEmpty ? "Samantha" : name
        speak("Hi — this is how tips will sound with \(resolved).", voice: resolved, rate: 190)
    }

    private func speak(_ tip: String, voice: String, rate: Int) {
        let cleaned = Self.spokenText(from: tip)
        guard !cleaned.isEmpty else { return }

        let voiceName = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVoice = voiceName.isEmpty ? "Samantha" : voiceName

        reset()
        let gen = speakGeneration

        if Self.usesSandboxSpeech {
            dlog("[Speech] AVSpeech voice=\(resolvedVoice) len=\(cleaned.count) gen=\(gen)")
            let utterance = AVSpeechUtterance(string: cleaned)
            utterance.voice = Self.avVoice(named: resolvedVoice)
            // Map `say -r 190` (~words/min) to AVSpeech rate (0.0–1.0, default ~0.5).
            let normalized = (Float(rate) / 400.0).clamped(to: 0.35...0.65)
            utterance.rate = normalized
            masSynthesizer.speak(utterance)
            return
        }

        let output = Self.cachedOutputName
        dlog("[Speech] speak once voice=\(resolvedVoice) len=\(cleaned.count) gen=\(gen) output=\(output)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        proc.arguments = ["-v", resolvedVoice, "-r", "\(rate)", cleaned]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        sayTask = proc

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try proc.run()
                dlog("[Speech] say started len=\(cleaned.count) pid=\(proc.processIdentifier) gen=\(gen)")
                proc.waitUntilExit()
                dlog("[Speech] say finished status=\(proc.terminationStatus) len=\(cleaned.count) gen=\(gen)")
            } catch {
                dlog("[Speech] say failed: \(error.localizedDescription)")
            }
            Task { @MainActor in
                guard let self, self.speakGeneration == gen else { return }
                if self.sayTask === proc { self.sayTask = nil }
            }
        }
    }

    /// Installed macOS `say` voices. English-locale voices first, then the rest.
    /// When `matchingDeviceLanguages` is true, keep only voices for the user's
    /// preferred languages (primary + secondary from System Settings).
    static func availableVoices(matchingDeviceLanguages: Bool = false) -> [SystemVoice] {
        if usesSandboxSpeech {
            return avAvailableVoices(matchingDeviceLanguages: matchingDeviceLanguages)
        }
        guard let raw = try? Shell.stdout("/usr/bin/say", args: ["-v", "?"]) else {
            return [SystemVoice(name: "Samantha", locale: "en_US")]
        }
        var voices: [SystemVoice] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Format: "Name                en_US    # sample…"
            // Voice names can include spaces (e.g. "Bad News").
            guard let hashRange = trimmed.range(of: " #") ?? trimmed.range(of: "\t#") else {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 2 else { continue }
                let locale = String(parts[parts.count - 1])
                if locale.contains("_") || locale.contains("-") {
                    let name = parts.dropLast().joined(separator: " ")
                    voices.append(SystemVoice(name: name, locale: locale))
                }
                continue
            }
            let beforeHash = String(trimmed[..<hashRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let parts = beforeHash.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2 else { continue }
            let locale = String(parts.last!)
            let name = parts.dropLast().joined(separator: " ")
            guard !name.isEmpty else { continue }
            voices.append(SystemVoice(name: name, locale: locale))
        }
        if voices.isEmpty {
            return [SystemVoice(name: "Samantha", locale: "en_US")]
        }
        // `say -v ?` can list the same voice twice on newer macOS.
        var seen = Set<String>()
        var unique = voices.filter { seen.insert($0.name).inserted }

        if matchingDeviceLanguages {
            let preferred = devicePreferredLanguageCodes()
            let filtered = unique.filter { voice in
                preferred.contains { pref in
                    voice.languageCode == pref || voice.languageCode.hasPrefix(pref)
                        || pref.hasPrefix(voice.languageCode)
                }
            }
            if !filtered.isEmpty {
                unique = filtered
            }
            // If filter wiped everything, keep unfiltered rather than an empty menu.
        }

        return unique.sorted { a, b in
            let preferred = devicePreferredLanguageCodes()
            let aRank = preferred.firstIndex(of: a.languageCode) ?? 999
            let bRank = preferred.firstIndex(of: b.languageCode) ?? 999
            if aRank != bRank { return aRank < bRank }
            let aEn = a.locale.lowercased().hasPrefix("en")
            let bEn = b.locale.lowercased().hasPrefix("en")
            if aEn != bEn { return aEn && !bEn }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Language codes from System Settings preferred languages (primary + secondary…).
    static func devicePreferredLanguageCodes() -> [String] {
        var codes: [String] = []
        var seen = Set<String>()
        for id in Locale.preferredLanguages {
            let lang = Locale(identifier: id).language.languageCode?.identifier.lowercased()
                ?? id.split(separator: "-").first.map { String($0).lowercased() }
                ?? id.lowercased()
            if seen.insert(lang).inserted {
                codes.append(lang)
            }
        }
        if codes.isEmpty { codes = ["en"] }
        return codes
    }


    /// Text that `/usr/bin/say` should read — no parentheticals, no route footers.
    static func spokenText(from tip: String) -> String {
        var text = tip
        // Drop our UI footers if they ever get passed in.
        if let range = text.range(of: "\n\n(") {
            text = String(text[..<range.lowerBound])
        }
        // Remove (…) / (...) asides so "e.g." chunks aren't a second voice.
        while let open = text.firstIndex(of: "("),
              let close = text[open...].firstIndex(of: ")") {
            text.removeSubrange(open...close)
        }
        while let open = text.firstIndex(of: "（"),
              let close = text[open...].firstIndex(of: "）") {
            text.removeSubrange(open...close)
        }
        return text
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Kill orphaned `say` processes from prior tips (overlapping doubles).
    private static func killStraySayProcesses() {
        guard !usesSandboxSpeech else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["-9", "say"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func avVoice(named name: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().first { $0.name == name }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func avAvailableVoices(matchingDeviceLanguages: Bool) -> [SystemVoice] {
        let voices = AVSpeechSynthesisVoice.speechVoices().map {
            SystemVoice(name: $0.name, locale: $0.language)
        }
        if voices.isEmpty {
            return [SystemVoice(name: "Samantha", locale: "en-US")]
        }
        var seen = Set<String>()
        var unique = voices.filter { seen.insert($0.name).inserted }

        if matchingDeviceLanguages {
            let preferred = devicePreferredLanguageCodes()
            let filtered = unique.filter { voice in
                preferred.contains { pref in
                    voice.languageCode == pref || voice.languageCode.hasPrefix(pref)
                        || pref.hasPrefix(voice.languageCode)
                }
            }
            if !filtered.isEmpty {
                unique = filtered
            }
        }

        return unique.sorted { a, b in
            let preferred = devicePreferredLanguageCodes()
            let aRank = preferred.firstIndex(of: a.languageCode) ?? 999
            let bRank = preferred.firstIndex(of: b.languageCode) ?? 999
            if aRank != bRank { return aRank < bRank }
            let aEn = a.locale.lowercased().hasPrefix("en")
            let bEn = b.locale.lowercased().hasPrefix("en")
            if aEn != bEn { return aEn && !bEn }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

enum Shell {
    static func stdout(_ launchPath: String, args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// In-process CoreAudio helper. Keeping this in the app removes the runtime
/// swiftc dependency that made spoken tips silently fail on clean Macs.
@MainActor
enum AudioRouteHelper {
    static func preferAirPodsIfNeeded() {
        guard !AppSandbox.isEnabled else { return }
        let output = TipSpeaker.currentOutputName.lowercased()
        if output.contains("airpod") {
            dlog("[Speech] already on AirPods")
            return
        }

        guard let airPods = listOutputs()
            .filter({ $0.name.localizedCaseInsensitiveContains("AirPod") })
            .max(by: { $0.channels < $1.channels })
        else {
            dlog("[Speech] no AirPods output available")
            return
        }

        let switched = setDefaultOutput(airPods.id)
        let now = defaultOutputID().flatMap { propertyString($0, kAudioObjectPropertyName) } ?? "?"
        dlog("[Speech] AirPods route switched=\(switched) target=\(airPods.name) now=\(now)")
    }

    private static func propertyString(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee as String?
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func defaultOutputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
            return nil
        }
        return id
    }

    private static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var deviceID = id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        ) == noErr
    }

    private static func listOutputs() -> [(id: AudioDeviceID, name: String, channels: Int)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            let channels = outputChannelCount(id)
            guard channels > 0, let name = propertyString(id, kAudioObjectPropertyName) else { return nil }
            return (id: id, name: name, channels: channels)
        }
    }
}
