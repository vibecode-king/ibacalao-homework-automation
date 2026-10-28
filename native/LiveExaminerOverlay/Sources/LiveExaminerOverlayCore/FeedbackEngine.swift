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
    /// Prevents overlapping tip generations (was causing two voices).
    private var isGeneratingTip = false
    /// Subject the user last dismissed the mismatch banner for — don't re-nag about the
    /// same disagreement on every ⌘Return within one writing session.
    private var dismissedMismatchSubject: CoachingSubject?

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

    func start() {
        hotkey.start()
        hotkeyTrusted = true
        accessibilityTrusted = AccessibilityTextExtractor.isTrusted
        TipSpeaker.prewarmAudioRoute()
        trackFrontmostWritingApp()
        dlog("[Engine] started — hotkey=\(HotkeyMonitor.statusLabel) axTrusted=\(AccessibilityTextExtractor.isTrusted) cgPreflight=\(ScreenCapture.isAuthorized) path=\(Bundle.main.bundlePath)")
        // #region agent log
        agentLog("H-A", location: "FeedbackEngine.swift:start", message: "engine started", data: [
            "axTrusted": AccessibilityTextExtractor.isTrusted,
            "cgPreflight": ScreenCapture.isAuthorized,
            "bundlePath": Bundle.main.bundlePath,
        ])
        // #endregion
    }

    /// Remember the last app that isn't us so Check/Launch still reads the draft.
    private func trackFrontmostWritingApp() {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ourPID {
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
                self?.lastTargetApp = app
            }
        }
    }

    /// Bundle IDs that are never the document the user wants coached — terminals/dev tools
    /// have no meaningful Accessibility text, so treating them as target always fails the read.
    private static let nonDocumentBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "co.zeit.hyper", "net.kovidgoyal.kitty", "org.alacritty",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]

    /// App to read: current frontmost if not us and not a dev tool, else last remembered writing app.
    private func targetAppForCapture() -> NSRunningApplication? {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ourPID,
           !(front.bundleIdentifier.map(Self.nonDocumentBundleIDs.contains) ?? false) {
            lastTargetApp = front
            return front
        }
        if let remembered = lastTargetApp, remembered.processIdentifier != ourPID,
           remembered.isTerminated == false {
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
        guard let sessionToken = resolvedSessionToken() else {
            throw LLMClientError.missingSession
        }
        let client = makeClient()
        try await client.testConnection(sessionToken: sessionToken)
    }

    func sendChat(_ message: String) async {
        guard !chatStreaming else { return }
        guard let sessionToken = resolvedSessionToken() else {
            stage = .error("Sign in with your iBacalao account first.")
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
            chatMessages.append(ChatTurn(role: .assistant, content: result.text))
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
        // #region agent log
        agentLog("H-E", location: "FeedbackEngine.swift:handleTrigger:entry", message: "trigger entry", data: [
            "source": source,
            "stage": String(describing: stage),
            "isBusy": isBusy,
            "isGeneratingTip": isGeneratingTip,
            "axTrusted": AccessibilityTextExtractor.isTrusted,
            "cgPreflight": ScreenCapture.isAuthorized,
            "hasSession": resolvedSessionToken() != nil,
            "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil",
            "bundlePath": Bundle.main.bundlePath,
            "previousLen": lastFullText.count,
        ])
        // #endregion

        guard !isGeneratingTip else {
            dlog("[Engine] skip duplicate trigger source=\(source)")
            return
        }
        guard !isBusy else { return }

        isGeneratingTip = true
        defer { isGeneratingTip = false }

        guard resolvedSessionToken() != nil else {
            stage = .error("Sign in with your iBacalao account first.")
            return
        }

        lastCapturedApp = NSWorkspace.shared.frontmostApplication?.localizedName
        lastTipWasPractice = false
        stage = .capturing
        accessibilityTrusted = AccessibilityTextExtractor.isTrusted

        // No synthetic practice drafts on ⌘Return / Check — only real screen text.
        if !accessibilityTrusted && !ScreenCapture.isAuthorized {
            // #region agent log
            agentLog("H-A", location: "FeedbackEngine.swift:handleTrigger:noPerms", message: "no capture perms", data: [
                "axTrusted": false,
                "cgPreflight": false,
            ], runId: "post-fix")
            // #endregion
            await reportCouldNotReadScreen(reason: "no-capture-perms")
            return
        }

        let targetApp = targetAppForCapture()
        // #region agent log
        agentLog("H-A", location: "FeedbackEngine.swift:handleTrigger:target", message: "capture target app", data: [
            "target": targetApp?.localizedName ?? "nil",
            "targetPID": targetApp.map { Int($0.processIdentifier) } ?? -1,
            "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil",
        ], runId: "post-fix")
        // #endregion

        // 1. Accessibility first — prefer the writing app, not iBacalao itself.
        let axResult: (text: String, appName: String)? = {
            if let target = targetApp {
                return AccessibilityTextExtractor.extract(from: target)
            }
            return AccessibilityTextExtractor.extractFromFrontmostApp()
        }()
        // #region agent log
        agentLog("H-A", location: "FeedbackEngine.swift:handleTrigger:ax", message: "AX extraction result", data: [
            "axTrusted": AccessibilityTextExtractor.isTrusted,
            "axLen": axResult?.text.count ?? -1,
            "axApp": axResult?.appName ?? "nil",
            "axSubstantial": (axResult?.text.count ?? 0) >= AccessibilityTextExtractor.minSubstantialLength,
        ], runId: "post-fix")
        // #endregion
        if let ax = axResult,
           ax.text.count >= AccessibilityTextExtractor.minSubstantialLength,
           AccessibilityTextExtractor.looksLikeProse(ax.text) {
            accessibilityTrusted = true
            lastCapturedApp = ax.appName
            dlog("[Engine] source=accessibility len=\(ax.text.count) app=\(ax.appName)")
            await processExtractedText(ax.text, source: "accessibility")
            return
        }

        accessibilityTrusted = AccessibilityTextExtractor.isTrusted

        // 2. Screen OCR fallback — only when Screen Recording is already granted.
        var currentText: String?
        var textSource = "accessibility"
        // #region agent log
        agentLog("H-C", location: "FeedbackEngine.swift:handleTrigger:beforeCapture", message: "starting OCR fallback", data: [
            "cgPreflight": ScreenCapture.isAuthorized,
            "preferDisplay": source == "button",
        ])
        // #endregion
        if let capture = await ScreenCapture.captureForOCR(preferDisplay: source == "button"),
           !ScreenCapture.isLikelyBlank(capture.image) {
            // #region agent log
            agentLog("H-C", location: "FeedbackEngine.swift:handleTrigger:captured", message: "capture ok, starting OCR", data: [
                "captureSource": capture.source,
                "width": capture.image.width,
                "height": capture.image.height,
            ])
            // #endregion
            do {
                let ocrText = try await OCR.recognizeText(in: capture.image)
                // #region agent log
                agentLog("H-C", location: "FeedbackEngine.swift:handleTrigger:ocrDone", message: "OCR finished", data: [
                    "ocrLen": ocrText.count,
                    "preview": String(ocrText.prefix(80)),
                ])
                // #endregion
                if !ocrText.isEmpty {
                    currentText = ocrText
                    textSource = "screenOCR"
                    dlog("[Engine] source=screenOCR len=\(ocrText.count) capture=\(capture.source)")
                }
            } catch {
                dlog("[Engine] OCR failed: \(error)")
                // #region agent log
                agentLog("H-C", location: "FeedbackEngine.swift:handleTrigger:ocrFail", message: "OCR threw", data: [
                    "error": String(describing: error),
                ])
                // #endregion
            }
        } else {
            dlog("[Engine] screen capture unavailable or blank preflight=\(ScreenCapture.isAuthorized)")
            // #region agent log
            agentLog("H-C", location: "FeedbackEngine.swift:handleTrigger:captureMiss", message: "capture unavailable or blank", data: [
                "cgPreflight": ScreenCapture.isAuthorized,
            ])
            // #endregion
        }

        // Partial AX text when below substantial threshold but screen also failed.
        if currentText == nil {
            if let target = targetApp,
               let ax = AccessibilityTextExtractor.extract(from: target),
               !ax.text.isEmpty,
               AccessibilityTextExtractor.looksLikeProse(ax.text) {
                currentText = ax.text
                lastCapturedApp = ax.appName
                textSource = "accessibility-partial"
                dlog("[Engine] source=accessibility-partial len=\(ax.text.count) app=\(ax.appName)")
            } else if let ax = AccessibilityTextExtractor.extractFromFrontmostApp(),
                      !ax.text.isEmpty,
                      AccessibilityTextExtractor.looksLikeProse(ax.text) {
                currentText = ax.text
                lastCapturedApp = ax.appName
                textSource = "accessibility-partial"
                dlog("[Engine] source=accessibility-partial len=\(ax.text.count)")
            }
        }

        guard let text = currentText, !text.isEmpty else {
            // #region agent log
            agentLog("H-A", location: "FeedbackEngine.swift:handleTrigger:noText", message: "no extractable text", data: [
                "axTrusted": AccessibilityTextExtractor.isTrusted,
                "target": targetApp?.localizedName ?? "nil",
            ], runId: "post-fix")
            // #endregion
            await reportCouldNotReadScreen(reason: "no-extractable-text")
            return
        }

        await processExtractedText(text, source: textSource)
    }

    static let couldNotReadMessage = """
    Couldn't understand your screen. Click into your document (Docs, Word, Pages, etc.) and press ⌘Return again.

    Using Google Docs, Sheets, or Slides? Their canvas hides text from Accessibility — turn on Tools → Accessibility → "Enable screen reader support" in that document.

    Otherwise, grant Screen Recording for iBacalao in System Settings → Privacy & Security → Screen Recording so the OCR fallback can read the screen.
    """

    /// Shorter line for speech — same meaning as `couldNotReadMessage`.
    private static let couldNotReadSpoken =
        "Couldn't read your document. For Google Docs, turn on screen reader support in its Accessibility menu, or grant Screen Recording so I can read the screen instead."

    private func reportCouldNotReadScreen(reason: String) async {
        dlog("[Engine] couldNotRead reason=\(reason)")
        // #region agent log
        agentLog("H-A", location: "FeedbackEngine.swift:reportCouldNotReadScreen", message: "showing honest error", data: [
            "reason": reason,
        ])
        // #endregion
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

        guard resolvedSessionToken() != nil else {
            stage = .error("Sign in with your iBacalao account first.")
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
        // #region agent log
        agentLog("H-F", location: "FeedbackEngine.swift:runPracticeTip", message: "practice tip", data: [
            "reason": reason,
            "n": n,
            "spoken": settings.spokenTipsEnabled,
        ], runId: "post-fix")
        // #endregion
        await requestTip(text: practice)
    }

    private func processExtractedText(_ currentText: String, source: String) async {
        lastTipWasPractice = false
        lastOCRText = currentText

        let previousSnapshot = lastFullText
        let tipText = TextDiff.textForFeedback(previous: previousSnapshot, current: currentText)
        lastFullText = currentText

        guard !tipText.isEmpty else {
            let delta = TextDiff.newSuffix(previous: previousSnapshot, current: currentText)
            let overlap = TextDiff.lineOverlapRatio(previous: previousSnapshot, current: currentText)
            // First capture after launch should never dead-end on gating.
            if previousSnapshot.isEmpty, currentText.count >= 20 {
                dlog("[Engine] first capture — forcing tip len=\(currentText.count)")
                // #region agent log
                agentLog("H-D", location: "FeedbackEngine.swift:processExtractedText:firstForce", message: "forcing first capture tip", data: [
                    "source": source,
                    "currentLen": currentText.count,
                ])
                // #endregion
                await requestTip(text: currentText.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            stage = delta.isEmpty ? .noNewText : .tooShort
            dlog("[Engine] skip tip source=\(source) delta=\(delta.count) overlap=\(String(format: "%.2f", overlap))")
            // #region agent log
            agentLog("H-D", location: "FeedbackEngine.swift:processExtractedText:gated", message: "tip gated by TextDiff", data: [
                "source": source,
                "outcome": delta.isEmpty ? "noNewText" : "tooShort",
                "currentLen": currentText.count,
                "previousLen": previousSnapshot.count,
                "deltaLen": delta.count,
                "overlap": overlap,
                "preview": String(currentText.prefix(80)),
            ])
            // #endregion
            return
        }

        dlog("[Engine] tip source=\(source) len=\(tipText.count) overlap=\(String(format: "%.2f", TextDiff.lineOverlapRatio(previous: previousSnapshot, current: currentText)))")
        // #region agent log
        agentLog("H-D", location: "FeedbackEngine.swift:processExtractedText:pass", message: "sending tip request", data: [
            "source": source,
            "tipLen": tipText.count,
            "currentLen": currentText.count,
            "previousLen": previousSnapshot.count,
        ])
        // #endregion
        await requestTip(text: tipText)
    }

    private func requestTip(text: String) async {
        guard let sessionToken = resolvedSessionToken() else {
            stage = .error("Sign in with your iBacalao account first.")
            return
        }
        // #region agent log
        agentLog("H-F", location: "FeedbackEngine.swift:requestTip:start", message: "LLM tip start", data: [
            "provider": settings.provider.rawValue,
            "textLen": text.count,
        ])
        // #endregion

        if settings.spokenTipsEnabled {
            TipSpeaker.shared.reset()
        }

        // Stream tip into the chat list (same surface as follow-up replies).
        stage = .streaming("")
        chatStreaming = true
        chatStreamPartial = ""
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
            let spokenLine: String
            var displayTip: String
            if let parsed {
                displayTip = parsed.displayText
                spokenLine = "\(parsed.section). \(parsed.problem) \(parsed.fix)"
                updateSubjectMismatch(from: parsed)
            } else {
                // Parse failed — fall back to a hard-capped slice of the raw text rather
                // than dumping unbounded reasoning into the UI.
                let capped = String(result.text.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
                displayTip = capped
                spokenLine = capped
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
            // #region agent log
            agentLog("H-F", location: "FeedbackEngine.swift:requestTip:ok", message: "LLM tip success", data: [
                "tipLen": result.text.count,
                "parsed": parsed != nil,
            ])
            // #endregion
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
            // #region agent log
            agentLog("H-F", location: "FeedbackEngine.swift:requestTip:err", message: "LLM tip failed", data: [
                "error": error.localizedDescription,
            ])
            // #endregion
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

    private func makeClient() -> LLMClient {
        LLMClient(
            provider: settings.provider,
            customInstructions: settings.customInstructions,
            subject: settings.subject
        )
    }
}
