import Foundation
import AppKit

enum FeedbackStage: Equatable {
    case idle
    case capturing
    case noNewText
    case streaming(String)
    case tip(String, String?)
    case tooShort
    case couldNotRead
    case error(String)
}

@MainActor
final class FeedbackEngine: ObservableObject {
    @Published var stage: FeedbackStage = .idle
    @Published var lastCapturedApp: String?
    /// True when the last tip used the synthetic practice draft (capture failed).
    @Published var lastTipWasPractice = false
    /// Carbon hotkey — no Input Monitoring TCC.
    @Published var hotkeyTrusted = true
    @Published var accessibilityTrusted = false
    @Published var lastOCRText = ""
    @Published var lastTip = ""
    @Published var chatMessages: [ChatTurn] = []
    /// Structured form of the last tip — drives the inline sentence-fix card. Cleared on the
    /// next capture so a stale annotation doesn't linger over new writing.
    @Published var lastParsedTip: TipResult?
    /// Exact text sent for the latest tip. Sentence-fix quotes must ground in this text.
    @Published var lastTipSourceText = ""
    @Published var chatStreaming = false
    @Published var chatStreamPartial = ""
    /// Set when the model's inferred subject disagrees with the selected one — drives the
    /// overlay mismatch banner. Cleared once the user switches or the next tip agrees.
    @Published var subjectMismatch: (detected: CoachingSubject, evidence: String)?

    var isBusy: Bool {
        if isGeneratingTip { return true }
        if case .capturing = stage { return true }
        if case .streaming = stage { return true }
        return chatStreaming
    }

    private let settings: AppSettings
    private let usage: UsageStore
    private var lastFullText = ""
    private var practiceTipCount = 0
    private let hotkey = HotkeyMonitor()
    /// Last non-self app the user focused — used when Check activates iBacalao.
    private var lastTargetApp: NSRunningApplication?
    private var appActivationObserver: NSObjectProtocol?
    private var permissionPollTimer: Timer?
    /// Prevents overlapping tip generations (was causing two voices).
    private var isGeneratingTip = false
    /// Subject the user last dismissed the mismatch banner for — don't re-nag about the
    /// same disagreement on every ⌘Return within one writing session.
    private var dismissedMismatchSubject: CoachingSubject?
    private let processStartedAt = Date()

    /// User tapped "Switch" on the mismatch banner.
    func acceptSubjectMismatch() {
        guard let detected = subjectMismatch?.detected else { return }
        settings.subject = detected
        subjectMismatch = nil
        dismissedMismatchSubject = nil
    }

    /// User dismissed the mismatch banner without switching.
    func dismissSubjectMismatch() {
        dismissedMismatchSubject = subjectMismatch?.detected
        subjectMismatch = nil
    }

    init(settings: AppSettings, usage: UsageStore) {
        self.settings = settings
        self.usage = usage
        hotkey.onTrigger = { [weak self] in
            Task { @MainActor in await self?.handleTrigger() }
        }
    }

    /// See HotkeyMonitor.setSuspended: no capture hotkey while the product shell is in front.
    func setHotkeySuspended(_ suspended: Bool) { hotkey.setSuspended(suspended) }

    func start() {
        hotkey.start()
        hotkeyTrusted = true
        accessibilityTrusted = AccessibilityTextExtractor.isTrusted
        TipSpeaker.prewarmAudioRoute()
        trackFrontmostWritingApp()
        dlog("[Engine] started — hotkey=\(HotkeyMonitor.statusLabel) axTrusted=\(AccessibilityTextExtractor.isTrusted) cgPreflight=\(ScreenCapture.isAuthorized) path=\(Bundle.main.bundlePath)")
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let trusted = AccessibilityTextExtractor.isTrusted
                guard let self, self.accessibilityTrusted != trusted else { return }
                self.accessibilityTrusted = trusted
            }
        }
    }

    /// Remember the last app that isn't us so Check/Launch still reads the draft.
    private func trackFrontmostWritingApp() {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ourPID,
           !Self.isNonDocumentApp(front) {
            lastTargetApp = front
        }
        if appActivationObserver != nil { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                guard !Self.isNonDocumentApp(app) else { return }
                self?.lastTargetApp = app
            }
        }
    }

    /// IDEs/terminals/Finder — never the draft. Screenshotting them is chrome, not writing.
    private static let nonDocumentBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "co.zeit.hyper", "net.kovidgoyal.kitty", "org.alacritty",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "com.anysphere.cursor", "dev.zed.Zed", "com.apple.finder",
        "com.apple.SecurityAgent", "com.apple.loginwindow",
        "com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent",
    ]

    private static func isNonDocumentApp(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, nonDocumentBundleIDs.contains(id) { return true }
        let name = (app.localizedName ?? "").lowercased()
        let blocked = [
            "cursor", "visual studio code", "xcode", "terminal", "iterm", "warp", "finder", "zed",
            "securityagent", "security agent",
        ]
        return blocked.contains { name == $0 || name.hasPrefix($0 + " ") }
    }

    /// App whose pixels we OCR: current frontmost if it is a writing app, else last remembered one.
    private func targetAppForCapture() -> NSRunningApplication? {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ourPID,
           !Self.isNonDocumentApp(front) {
            lastTargetApp = front
            return front
        }
        if let remembered = lastTargetApp,
           remembered.processIdentifier != ourPID,
           remembered.isTerminated == false,
           !Self.isNonDocumentApp(remembered) {
            return remembered
        }
        return nil
    }

    func checkNow() {
        Task { await handleTrigger(source: "button") }
    }

    /// Spoken tip on a practice paragraph — no Accessibility / Screen Recording needed.
    func practiceTip() {
        Task { await runPracticeTip(reason: "button") }
    }

    func testConnection() async throws {
        guard let sessionToken = await resolvedSessionTokenAfterDesktopSync() else {
            throw LLMClientError.missingSession
        }
        let client = makeClient()
        try await client.testConnection(sessionToken: sessionToken)
    }

    func sendChat(_ message: String) async {
        guard !chatStreaming else { return }
        guard let sessionToken = await resolvedSessionTokenAfterDesktopSync() else {
            stage = .error("Couldn't reach iBacalao. Try Check again in a moment.")
            return
        }

        chatMessages.append(ChatTurn(role: .user, content: message))
        chatStreaming = true
        chatStreamPartial = ""

        let client = makeClient()
        let promptChars = message.count + lastOCRText.count + lastTip.count

        do {
            let result = try await client.streamChat(
                messages: chatMessages,
                contextOCR: lastOCRText,
                contextTip: lastTip,
                sessionToken: sessionToken,
                onDelta: { [weak self] partial in
                    Task { @MainActor in
                        self?.chatStreamPartial = partial
                    }
                }
            )
            chatMessages.append(ChatTurn(role: .assistant, content: PlainFeedback.clean(result.text, max: 4000)))
            chatStreamPartial = ""
            recordUsage(
                result.usage,
                promptChars: promptChars,
                completionChars: result.text.count,
                client: client
            )
        } catch {
            chatStreamPartial = ""
            stage = .error(error.localizedDescription)
        }
        chatStreaming = false
    }

    private func handleTrigger(source: String = "hotkey") async {
        dlog("[Engine] trigger source=\(source) stage=\(stage) chatStreaming=\(chatStreaming)")

        guard !isGeneratingTip else {
            dlog("[Engine] skip duplicate trigger source=\(source)")
            return
        }
        guard !isBusy else {
            return
        }

        isGeneratingTip = true
        defer { isGeneratingTip = false }

        let sessionToken = await resolvedSessionTokenAfterDesktopSync()
        guard sessionToken != nil else {
            stage = .error("Couldn't reach iBacalao. Try Check again in a moment.")
            return
        }

        lastCapturedApp = NSWorkspace.shared.frontmostApplication?.localizedName
        lastTipWasPractice = false
        lastParsedTip = nil
        lastTipSourceText = ""
        stage = .capturing
        accessibilityTrusted = AccessibilityTextExtractor.isTrusted

        let targetApp = targetAppForCapture()
        let browser = DocumentBody.isBrowser(targetApp)
        let force = source == "hotkey" || source == "button"

        // Screen pixels only. Never Accessibility — that returns tab titles / chrome.
        let attempts: [(preferDisplay: Bool, sourceHint: String)] = [
            (false, "window"),
            (true, "display"),
        ]
        for attempt in attempts {
            guard let capture = await ScreenCapture.captureForOCR(
                preferDisplay: attempt.preferDisplay,
                targetPID: targetApp?.processIdentifier
            ), !ScreenCapture.isLikelyBlank(capture.image) else {
                dlog("[Engine] screen capture miss path=\(attempt.sourceHint) preflight=\(ScreenCapture.isAuthorized)")
                continue
            }
            let cropped = DocumentBody.cropWritingArea(capture.image, isBrowser: browser || attempt.preferDisplay)
            do {
                let ocrText = try await OCR.recognizeDocumentText(in: cropped)
                if DocumentBody.isUsableDraft(ocrText) {
                    lastCapturedApp = targetApp?.localizedName
                        ?? NSWorkspace.shared.frontmostApplication?.localizedName
                    dlog("[Engine] source=screenOCR len=\(ocrText.count) capture=\(capture.source) browser=\(browser)")
                    await processExtractedText(ocrText, source: "screenOCR", forceFullText: force)
                    return
                }
                dlog("[Engine] OCR rejected as chrome/metadata len=\(ocrText.count) path=\(capture.source)")
            } catch {
                dlog("[Engine] OCR failed: \(error)")
            }
        }

        await reportCouldNotReadScreen(reason: "no-extractable-text")
    }

    static let couldNotReadMessage = """
    Couldn't read the writing on screen. Click into your document (Docs, Word, Pages) so it is visible, then press ⌘Return again.

    Grant Screen Recording for iBacalao in System Settings → Privacy & Security → Screen Recording if it is off.
    """

    /// Shorter line for speech — same meaning as `couldNotReadMessage`.
    private static let couldNotReadSpoken =
        "Couldn't read the writing on your screen. Click into the document so it is visible, then try again."

    private func reportCouldNotReadScreen(reason: String) async {
        dlog("[Engine] couldNotRead reason=\(reason)")
        if settings.spokenTipsEnabled {
            TipSpeaker.shared.reset()
            TipSpeaker.shared.speakTip(Self.couldNotReadSpoken)
        }
        stage = .couldNotRead
    }

    /// Explicit Practice button only — not used as an automatic fallback.
    private func runPracticeTip(reason: String) async {
        // When called from the Practice button, take the generation lock ourselves.
        let tookLock: Bool
        if reason == "button" {
            guard !isGeneratingTip, !isBusy else {
                dlog("[Engine] skip duplicate practiceTip")
                return
            }
            isGeneratingTip = true
            tookLock = true
        } else {
            tookLock = false
        }
        defer { if tookLock { isGeneratingTip = false } }

        guard await resolvedSessionTokenAfterDesktopSync() != nil else {
            stage = .error("Couldn't reach iBacalao. Try Check again in a moment.")
            return
        }
        practiceTipCount += 1
        let n = practiceTipCount
        let practice = """
        The Industrial Revolution transformed labor and family life. Factories pulled \
        workers into cities, and children often worked long hours. This essay argues \
        that economic growth came with social costs that reformers only slowly \
        addressed through legislation and unions.
        """
        lastTipWasPractice = true
        lastCapturedApp = "Practice"
        lastOCRText = practice
        dlog("[Engine] source=practice reason=\(reason) n=\(n) spoken=\(settings.spokenTipsEnabled)")
        await requestTip(text: practice)
    }

    private func processExtractedText(_ currentText: String, source: String, forceFullText: Bool = false) async {
        lastTipWasPractice = false
        lastOCRText = currentText

        let previousSnapshot = lastFullText
        lastFullText = currentText

        // ⌘Return / Check is an explicit ask — coach the draft even if it hasn't changed.
        if forceFullText {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 20 else {
                stage = .tooShort
                return
            }
            dlog("[Engine] explicit trigger — coaching full capture len=\(trimmed.count) source=\(source)")
            await requestTip(text: trimmed)
            return
        }

        let tipText = TextDiff.textForFeedback(previous: previousSnapshot, current: currentText)

        guard !tipText.isEmpty else {
            let delta = TextDiff.newSuffix(previous: previousSnapshot, current: currentText)
            let overlap = TextDiff.lineOverlapRatio(previous: previousSnapshot, current: currentText)
            // First capture after launch should never dead-end on gating.
            if previousSnapshot.isEmpty, currentText.count >= 20 {
                dlog("[Engine] first capture — forcing tip len=\(currentText.count)")
                await requestTip(text: currentText.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            stage = delta.isEmpty ? .noNewText : .tooShort
            dlog("[Engine] skip tip source=\(source) delta=\(delta.count) overlap=\(String(format: "%.2f", overlap))")
            return
        }

        dlog("[Engine] tip source=\(source) len=\(tipText.count) overlap=\(String(format: "%.2f", TextDiff.lineOverlapRatio(previous: previousSnapshot, current: currentText)))")
        await requestTip(text: tipText)
    }

    private func requestTip(text: String) async {
        lastParsedTip = nil
        lastTipSourceText = text
        let sessionToken = await resolvedSessionTokenAfterDesktopSync()
        guard let sessionToken else {
            stage = .error("Couldn't reach iBacalao. Try Check again in a moment.")
            return
        }

        if settings.spokenTipsEnabled {
            TipSpeaker.shared.reset()
        }

        // Stream tip into the chat list (same surface as follow-up replies).
        stage = .streaming("")
        chatStreaming = true
        chatStreamPartial = ""
        AppDelegate.shared?.launchOverlay()
        let client = makeClient()
        let promptChars = text.count

        do {
            // No live delta into chatStreamPartial here: the raw tip stream is JSON.
            // Showing partial JSON is worse than just a "Coach thinking…" indicator.
            let result = try await client.streamTip(
                documentText: text,
                sessionToken: sessionToken,
                onDelta: { [weak self] _ in
                    Task { @MainActor in
                        self?.stage = .streaming("")
                    }
                }
            )
            lastTip = result.text
            let parsed = TipResult.parse(from: result.text)
            lastParsedTip = parsed
            let spokenLine: String
            var displayTip: String
            if let parsed {
                displayTip = parsed.displayText
                spokenLine = "\(PlainFeedback.clean(parsed.section, max: 120)). \(PlainFeedback.clean(parsed.problem)). \(PlainFeedback.clean(parsed.fix))"
                updateSubjectMismatch(from: parsed)
            } else {
                // Parse failed — fall back to a hard-capped slice of the raw text rather
                // than dumping unbounded reasoning into the UI.
                let capped = String(result.text.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
                displayTip = PlainFeedback.clean(capped)
                spokenLine = displayTip
                dlog("[Engine] tip JSON parse failed, falling back to raw slice len=\(capped.count) preview=\(result.text.prefix(200))")
            }
            if settings.spokenTipsEnabled {
                TipSpeaker.shared.speakTip(spokenLine)
                // Route footnotes stay visual-only — never spoken.
                if TipSpeaker.isSystemAudioSilent {
                    displayTip = displayTip + "\n\n(" + TipSpeaker.silentAudioMessage + ")"
                }
            }
            chatMessages.append(ChatTurn(role: .assistant, content: displayTip))
            chatStreamPartial = ""
            chatStreaming = false
            stage = .tip(displayTip, nil)
            DispatchModeService.shared.publishEvent(
                title: "Feedback ready",
                detail: "Marginalia finished a feedback check for \(lastCapturedApp ?? "your writing app")."
            )
            recordUsage(
                result.usage,
                promptChars: promptChars,
                completionChars: result.text.count,
                client: client
            )
        } catch {
            chatStreamPartial = ""
            chatStreaming = false
            if settings.spokenTipsEnabled {
                TipSpeaker.shared.reset()
            }
            stage = .error(error.localizedDescription)
        }
    }

    private func recordUsage(
        _ apiUsage: LLMTokenUsage?,
        promptChars: Int,
        completionChars: Int,
        client: LLMClient
    ) {
        let tokens = apiUsage ?? LLMTokenUsage.estimate(
            promptChars: promptChars,
            completionChars: completionChars
        )
        usage.recordSpend(
            promptTokens: tokens.promptTokens,
            completionTokens: tokens.completionTokens,
            provider: settings.provider,
            model: client.activeModelID
        )
    }

    /// Compares the model's inferred subject to the selected one. Only surfaces a banner
    /// on medium/high confidence disagreement, and not for a subject the user already
    /// dismissed once this session.
    private func updateSubjectMismatch(from parsed: TipResult) {
        guard let subjectRaw = parsed.subject,
              let detected = CoachingSubject(rawValue: subjectRaw),
              detected != settings.subject,
              detected != dismissedMismatchSubject else {
            subjectMismatch = nil
            return
        }
        let confidence = (parsed.confidence ?? "").lowercased()
        guard confidence == "high" || confidence == "medium" else {
            subjectMismatch = nil
            return
        }
        subjectMismatch = (detected: detected, evidence: parsed.section)
    }

    private func resolvedSessionToken() -> String? {
        KeyStore.loadSessionToken()
    }

    private func resolvedSessionTokenAfterDesktopSync() async -> String? {
        await ShellController.shared?.syncWebsiteSessionIntoKeyStore()
        if let token = KeyStore.loadSessionToken(), !token.isEmpty,
           token != "preview", token != "dev-local" {
            return token
        }
        return nil
    }


    private func makeClient() -> LLMClient {
        LLMClient(
            provider: settings.provider,
            customInstructions: settings.customInstructions,
            subject: settings.subject
        )
    }
}
