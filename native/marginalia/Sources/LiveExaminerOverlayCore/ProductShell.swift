import SwiftUI
import WebKit
import AppKit
import AuthenticationServices

enum SchoolPlatformOpenMode: String, Equatable {
    case discover
    case onboarding
    case reconnect
    case learn
}

// MARK: - Route allowlist
//
// Mirrors `lib/nativeRoutes.ts` (NATIVE_BLOCKED_PREFIXES). The server already
// redirects blocked paths away (see app/native-session/route.ts and
// middleware.ts), and the site's own AppSidebar/productNav never links to
// them either — this is defense-in-depth only, for a stray external link
// landing inside the webview. Keep in sync by hand — no shared package
// between Swift and TS here.
enum NativeRoutes {
    static let blockedPrefixes = ["/pricing", "/es/pricing", "/schools", "/wearables", "/lp", "/what-to-expect", "/", "/guides", "/students"]
    // Exact path, not a prefix — "/teachers" root is a marketing landing page
    // not yet live on ibacalao.com, but its subpaths (/teachers/calibration,
    // /demo, etc.) are real product tools that must stay reachable in-app.
    static let blockedExactPaths = ["/teachers"]
    // Production keeps Chat as the desktop home. A trusted Vercel preview lands
    // on Homework after authentication. Every host starts at the existing
    // desktop-entry screen; there is no separate Homework sign-in screen.
    static let chatLandingPath = "/chat"
    static let homeworkLandingPath = "/homework"
    static var landingPath: String {
        landingPath(for: LLMClient.resolvedNativeAPIBaseURL)
    }
    static let entryPath = "/desktop-entry"
    static let onboardingPath = "/onboarding"

    static func landingPath(for baseURL: String) -> String {
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        return NativeHostPolicy.isTrustedPreviewHost(host) ? homeworkLandingPath : chatLandingPath
    }

    static var initialLaunchPath: String {
        initialLaunchPath(for: LLMClient.resolvedNativeAPIBaseURL)
    }

    static func initialLaunchPath(for baseURL: String) -> String {
        entryPath
    }

    // Hosts an OAuth consent screen genuinely has to visit mid-flow (see
    // lib/oauth.ts googleAuthUrl/microsoftAuthUrl). Token exchange itself
    // happens server-side in the callback route, never in this webview --
    // these are only the interactive consent-screen hops. Must stay loaded
    // in-app (not kicked to Safari) or the resulting session lands in
    // Safari's cookie jar instead of the app's, and "sign in" never
    // completes here.
    // NOTE: kept only as a mid-flow fallback. Google and Microsoft both REFUSE
    // OAuth inside an embedded WKWebView (Google answers the consent screen
    // with "Something went wrong / Make sure Bluetooth is on" because WebAuthn
    // and passkeys are unavailable here), so the initial click is intercepted
    // below and run in ASWebAuthenticationSession instead. The comment above
    // about keeping the session in the app's cookie jar still holds — that is
    // now handled by copying the returned token into the webview cookie store.
    static let oauthHosts: Set<String> = ["accounts.google.com", "login.microsoftonline.com"]

    /// Server start routes that begin a provider OAuth flow.
    static let oauthStartPrefix = "/api/auth/oauth/"
    /// Matches CFBundleURLSchemes in Info.plist and OAUTH_NATIVE_CALLBACK_SCHEME in lib/oauth.ts.
    static let authCallbackScheme = "ibacalao"

    /// Preserve actionable query state when a link targets the blocked public
    /// root. This keeps old `/?review=...` and `/?upload=1` links useful inside
    /// the shell while keeping the marketing homepage out of the app.
    static func rootIntentPath(for url: URL) -> String {
        guard let query = url.query, !query.isEmpty else { return landingPath }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.contains(where: { $0.name == "review" }) {
            return "/review?\(query)"
        }
        if items.contains(where: { ["upload", "type", "subject", "ref"].contains($0.name) }) {
            return "/ia/feedback?\(query)"
        }
        if items.contains(where: { $0.name == "setup" && $0.value == "profile" }) {
            return "/profile/setup?\(query)"
        }
        return landingPath
    }

    static func isDispatchRoute(_ url: URL) -> Bool {
        let path = url.path
        if path == "/dashboard/dispatch" || path.hasPrefix("/dashboard/dispatch/") {
            return true
        }
        guard path == "/dashboard" || path == "/dashboard/" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "view" && $0.value == "dispatch" }
    }

    static func isNativeStudentFeatureRoute(_ url: URL) -> Bool {
        if isDispatchRoute(url) { return false }
        switch url.path {
        case "/dashboard",
             "/dashboard/your-ib",
             "/today",
             "/todo",
             "/tools/inbox",
             "/tools/hub/inbox",
             "/tools/cas-log",
             "/tools/cas-project",
             "/tools/practice",
             "/tools/markband",
             "/termle",
             "/tool/camera",
             "/tools/camera",
             "/tools/hub/camera",
             "/tool/audio",
             "/tools/audio",
             "/tools/hub/audio",
             "/tool/marginalia",
             "/tools/hub/marginalia",
             "/draft-editor",
             "/sync":
            return true
        default:
            return false
        }
    }

    static func isBlocked(_ path: String) -> Bool {
        blockedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") } || blockedExactPaths.contains(path)
    }
}

final class ShellMessageHandler: NSObject, WKScriptMessageHandler {
    static let shared = ShellMessageHandler()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "openMarginalia" {
            Task { @MainActor in
                AppDelegate.shared?.launchOverlay()
            }
            return
        }
        if message.name == "openDispatch" {
            Task { @MainActor in
                AppDelegate.shared?.showDispatch()
            }
            return
        }
        if message.name == "openNativeStudentFeature" {
            guard let path = message.body as? String else { return }
            Task { @MainActor in
                ShellController.shared?.load(path: path)
            }
            return
        }
        if message.name == "clearNativeSession" {
            Task { @MainActor in
                ShellController.shared?.clearSessionAndShowWelcome()
            }
            return
        }
        if message.name == "openSchoolPlatform" {
            guard let payload = message.body as? [String: Any] else {
                dlog("[SchoolWatcher] rejected malformed connection request")
                return
            }
            if let rawMode = payload["mode"] as? String,
               let mode = SchoolPlatformOpenMode(rawValue: rawMode) {
                switch mode {
                case .discover, .onboarding:
                    let staysOnboarding = mode == .onboarding
                    Task { @MainActor in
                        do {
                            try SchoolWatcherService.shared.openDiscovery { connection in
                                Task { @MainActor in
                                    if !staysOnboarding {
                                        ShellController.shared?.showSchoolConnection(connection)
                                    } else {
                                        ShellController.shared?.emitSchoolBrowserConnected(connection)
                                    }
                                    ShellController.shared?.emitSchoolPlatformStatus()
                                }
                            }
                            if staysOnboarding {
                                ShellController.shared?.emitSchoolBrowserOpened()
                            }
                        } catch {
                            dlog("[SchoolWatcher] discovery launch failed: \(error.localizedDescription)")
                            if staysOnboarding {
                                ShellController.shared?.emitSchoolBrowserOpenFailed()
                            }
                        }
                    }
                case .reconnect:
                    Task { @MainActor in
                        do {
                            try SchoolWatcherService.shared.openReconnect {
                                Task { @MainActor in
                                    ShellController.shared?.emitSchoolPlatformStatus()
                                }
                            }
                            ShellController.shared?.emitSchoolBrowserOpened()
                        } catch {
                            dlog("[SchoolWatcher] reconnect launch failed: \(error.localizedDescription)")
                            ShellController.shared?.emitSchoolBrowserOpenFailed()
                        }
                    }
                case .learn:
                    Task { @MainActor in
                        do {
                            try SchoolWatcherService.shared.openLearning()
                            ShellController.shared?.emitSchoolBrowserOpened()
                            ShellController.shared?.emitSchoolPlatformStatus()
                        } catch {
                            dlog("[SchoolWatcher] learning launch failed: \(error.localizedDescription)")
                            ShellController.shared?.emitSchoolBrowserOpenFailed()
                        }
                    }
                }
                return
            }

            // Backward-compatible explicit login path for older web surfaces.
            guard let platform = payload["platform"] as? String,
                  let loginURLString = payload["loginUrl"] as? String,
                  let loginURL = URL(string: loginURLString) else {
                dlog("[SchoolWatcher] rejected malformed web login request")
                return
            }
            Task { @MainActor in
                do {
                    try SchoolWatcherService.shared.openLogin(platform: platform, loginURL: loginURL)
                } catch {
                    dlog("[SchoolWatcher] login launch failed: \(error.localizedDescription)")
                }
            }
            return
        }
        if message.name == "getSchoolPlatformStatus" {
            Task { @MainActor in
                ShellController.shared?.emitSchoolPlatformStatus()
            }
            return
        }
        if message.name == "getSchoolRuntimeStatus" {
            Task { @MainActor in
                // Asking is also the retry path after a failed download.
                WatcherRuntimeInstaller.shared.ensureInstalled()
                ShellController.shared?.emitSchoolRuntimeStatus()
            }
            return
        }
        if message.name == "getDispatchStatus" {
            Task { @MainActor in
                ShellController.shared?.emitDispatchStatus()
            }
            return
        }
        if message.name == "setDispatchAlwaysOn" {
            guard let alwaysOn = message.body as? Bool else { return }
            Task { @MainActor in
                DispatchModeService.shared.setAlwaysOn(alwaysOn)
                ShellController.shared?.emitDispatchStatus()
            }
        }
    }
}

/// Onboarding "Turn on reminders" on desktop: asks macOS for notification permission
/// through the same switch as Settings > Notifications (NativeMacSchoolNotifications).
/// Page call: `webkit.messageHandlers.setSchoolNotifications.postMessage({ enabled: true })`,
/// resolves with `{ enabled, note }`.
final class SchoolNotificationsHandler: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let enabled = (message.body as? [String: Any])?["enabled"] as? Bool ?? true
        Task { @MainActor in
            let state = await NativeMacSchoolNotifications.setEnabled(enabled)
            replyHandler(["enabled": state.enabled, "note": state.note ?? ""], nil)
        }
    }
}

/// Page feedback (/tools/camera) on desktop: the page hands over a photo as a
/// data: URL and gets back its text, read on-device with Vision like the phone
/// does. Nothing leaves the Mac here; the page sends only the text it gets back.
final class ImageTextHandler: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let dataURL = message.body as? String,
              let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            replyHandler(nil, "unreadable_image")
            return
        }
        Task {
            do {
                replyHandler(try await OCR.recognizeText(in: image), nil)
            } catch {
                dlog("[Shell] page OCR failed: \(error.localizedDescription)")
                replyHandler(nil, "ocr_failed")
            }
        }
    }
}

// MARK: - Session bridge + navigation

@MainActor
final class ShellWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, ObservableObject {
    @Published var isLoading = false
    @Published var isOffline = false

    /// WKWebView never opens a file picker on its own: an <input type="file">
    /// tap is silently dropped unless the host app answers this delegate call.
    /// Without it the upload drop zone on /ia/feedback looks dead in the app
    /// while working fine in Safari.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    /// Held strongly for the lifetime of the flow — ASWebAuthenticationSession
    /// cancels itself the moment it is deallocated.
    private var authSession: ASWebAuthenticationSession?

    /// Runs a provider OAuth flow in the system browser instead of this
    /// webview, then copies the returned session token back into the webview's
    /// cookie jar and the KeyStore so the app is signed in exactly as it would
    /// be after a normal web login.
    func startNativeOAuth(startURL: URL) {
        var components = URLComponents(url: startURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        if !items.contains(where: { $0.name == "native" }) {
            items.append(URLQueryItem(name: "native", value: "1"))
        }
        // Production OAuth uses the marketing callback host. A Vercel preview
        // must keep its own host so QA creates the session in that deployment's
        // Better Auth environment instead of silently signing into production.
        let startHost = startURL.host?.lowercased() ?? ""
        if !NativeHostPolicy.isTrustedPreviewHost(startHost) {
            components?.host = "www.ibacalao.com"
        }
        components?.scheme = "https"
        components?.queryItems = items
        guard let authURL = components?.url else { return }

        // Deliberately NOT ASWebAuthenticationSession. On this app its start()
        // returns true but the Safari sheet attaches to the presentation anchor,
        // and the shell has no anchor the system will draw on — the sheet opened
        // somewhere invisible and the sign-in button just spun forever.
        //
        // Opening the user's real browser is what desktop apps do anyway: the
        // callback comes back through the registered ibacalao:// scheme and is
        // handled in AppDelegate.handleAuthCallback (App.swift), which hands the
        // token to adoptSession below.
        ShellController.awaitingOAuthCallback = true
        let opened = NSWorkspace.shared.open(authURL)
        dlog("[Shell] native OAuth opened browser=\(opened) url=\(authURL.absoluteString)")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // <a download> (teacher exports, .ics, blob: links) is dropped by
        // WKWebView unless it is turned into a WKDownload here.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "ibacalao", url.host == "overlay" {
            AppDelegate.shared?.launchOverlay()
            decisionHandler(.cancel)
            return
        }
        guard navigationAction.targetFrame?.isMainFrame == true,
              url.scheme == "http" || url.scheme == "https"
        else {
            decisionHandler(.allow)
            return
        }

        let allowedHosts: Set<String> = ["ibacalao.com", "www.ibacalao.com", "localhost", "127.0.0.1"]
        let host = url.host ?? ""
        let isOwnHost = allowedHosts.contains(host)
            || host.hasSuffix(".ibacalao.com")
            || NativeHostPolicy.isTrustedPreviewHost(host)
        if isOwnHost, NativeRoutes.isNativeStudentFeatureRoute(url) {
            let path = url.path + (url.query.map { "?\($0)" } ?? "")
            decisionHandler(.cancel)
            Task { @MainActor in
                ShellController.shared?.load(path: path)
            }
            return
        }
        if isOwnHost, NativeRoutes.isDispatchRoute(url) {
            AppDelegate.shared?.showDispatch()
            decisionHandler(.cancel)
            return
        }
        if isOwnHost, url.path == "/tools/live-examiner" || url.path.hasPrefix("/tools/live-examiner/") {
            AppDelegate.shared?.launchOverlay()
            decisionHandler(.cancel)
            return
        }
        if isOwnHost, url.path == "/wearables/digital" {
            AppDelegate.shared?.launchOverlay()
            decisionHandler(.cancel)
            return
        }
        // Provider OAuth cannot run in a WKWebView — Google and Microsoft both
        // block embedded webviews. Cancel the in-app navigation and run the
        // flow in ASWebAuthenticationSession instead.
        if isOwnHost, url.path.hasPrefix(NativeRoutes.oauthStartPrefix),
           !url.path.contains("/callback") {
            decisionHandler(.cancel)
            startNativeOAuth(startURL: url)
            return
        }

        let isOAuthHop = NativeRoutes.oauthHosts.contains(host)

        if isOAuthHop {
            decisionHandler(.allow)
            return
        }
        if !isOwnHost {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if NativeRoutes.isBlocked(url.path) {
            if url.path == "/" {
                Task { @MainActor in
                    ShellController.shared?.load(path: NativeRoutes.rootIntentPath(for: url))
                }
            } else if url.path == "/pricing" || url.path == "/es/pricing" {
                Task { @MainActor in
                    await ShellController.shared?.openAuthenticatedPricing(path: url.path)
                }
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Responses the webview can't render (attachments, PDFs served as
    /// downloads) go to a save panel instead of silently doing nothing.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let isAttachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased().hasPrefix("attachment") == true
        decisionHandler(isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Without these three, window.confirm() returns false and alert() is a
    /// no-op — e.g. "Delete this class?" on /teacher could never be confirmed.
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    /// Popup windows opened by window.open / target=_blank. Own-host popups
    /// (Evidence Pack print view writes into window.open("")) get a real
    /// window; anything external goes to the browser.
    private var popupWindows: [NSWindow] = []

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https",
           let host = url.host,
           !(host == "ibacalao.com" || host.hasSuffix(".ibacalao.com") || host == "localhost" || host == "127.0.0.1")
            || url.path == "/support" || url.path.hasPrefix("/support/") {
            NSWorkspace.shared.open(url)
            return nil
        }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let window = NSWindow(
            contentRect: popup.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popupWindows.removeAll { !$0.isVisible }
        popupWindows.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.window?.close()
    }

    /// A crashed web content process leaves a blank window; reload instead.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dlog("[Shell] web content process terminated, reloading")
        webView.reload()
    }

    /// Audio notes (/tools/audio) asks for the microphone. Only our own pages
    /// get it; macOS still shows its own one-time permission prompt.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = origin.host
        let own = host == "ibacalao.com" || host.hasSuffix(".ibacalao.com") || host == "localhost" || host == "127.0.0.1"
        decisionHandler(own && type == .microphone ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        isOffline = false
        // #region agent log
        agentLog("H6", location: "ProductShell.swift:didFinish", message: "shell loaded", data: [
            "path": webView.url?.path ?? "",
            "host": webView.url?.host ?? "",
        ])
        // #endregion
        Task { await ShellController.shared?.syncWebsiteSessionIntoKeyStore() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        let ns = error as NSError
        // -999 (cancelled by a redirect/new load) and -1002 (unsupported URL,
        // e.g. a custom-scheme hop) are not connectivity failures.
        if ns.domain != NSURLErrorDomain || (ns.code != NSURLErrorCancelled && ns.code != NSURLErrorUnsupportedURL) {
            isOffline = true
        }
        // #region agent log
        agentLog("H6", location: "ProductShell.swift:didFail", message: "shell load failed", data: [
            "code": ns.code,
            "domain": ns.domain,
        ])
        // #endregion
        dlog("[Shell] navigation failed: \(error.localizedDescription)")
    }
}

@MainActor
final class ShellController: ObservableObject {
    static private(set) var shared: ShellController?

    /// Set while the shell is waiting on a browser OAuth round-trip, so the
    /// ibacalao:// callback lands in the shell instead of popping the
    /// Marginalia overlay (which is the right behaviour only for the overlay's
    /// own sign-in flow).
    static var awaitingOAuthCallback = false

    let webView: WKWebView
    let coordinator = ShellWebCoordinator()

    @Published var hasAccount: Bool

    /// Same host the overlay uses for /api/native/complete, so the website login cookie works for tips.
    private static var base: URL {
        URL(string: LLMClient.resolvedNativeAPIBaseURL)
            ?? URL(string: LLMClient.defaultNativeAPIBaseURL)!
    }
    private static var externalWebBase: URL {
        let resolved = Self.base
        let host = resolved.host?.lowercased() ?? ""
        // Production app APIs live on app.ibacalao.com, but public pricing
        // belongs on www. Preview/local overrides should stay on their own
        // origin so the complete handoff can be exercised before promotion.
        if host == "app.ibacalao.com" {
            return URL(string: "https://www.ibacalao.com")!
        }
        return resolved
    }
    private var lastPath = NativeRoutes.landingPath

    init() {
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(ImageTextHandler(), contentWorld: .page, name: "recognizeImageText")
        config.userContentController.addScriptMessageHandler(SchoolDocHandler(), contentWorld: .page, name: "schoolDoc")
        config.userContentController.addScriptMessageHandler(SchoolNotificationsHandler(), contentWorld: .page, name: "setSchoolNotifications")
        config.userContentController.add(ShellMessageHandler.shared, name: "openMarginalia")
        config.userContentController.add(ShellMessageHandler.shared, name: "openDispatch")
        config.userContentController.add(ShellMessageHandler.shared, name: "openNativeStudentFeature")
        config.userContentController.add(ShellMessageHandler.shared, name: "clearNativeSession")
        config.userContentController.add(ShellMessageHandler.shared, name: "openSchoolPlatform")
        config.userContentController.add(ShellMessageHandler.shared, name: "getSchoolPlatformStatus")
        config.userContentController.add(ShellMessageHandler.shared, name: "getSchoolRuntimeStatus")
        config.userContentController.add(ShellMessageHandler.shared, name: "getDispatchStatus")
        config.userContentController.add(ShellMessageHandler.shared, name: "setDispatchAlwaysOn")
        let nativeStudentRouteBridge = """
        (() => {
          const routes = new Set([
            '/dashboard', '/dashboard/your-ib', '/today', '/todo',
            '/tools/inbox', '/tools/hub/inbox', '/tools/cas-log', '/tools/cas-project', '/tools/practice', '/tools/markband',
            '/termle', '/tool/camera', '/tools/camera', '/tools/hub/camera', '/tool/audio', '/tools/audio', '/tools/hub/audio',
            '/tool/marginalia', '/tools/hub/marginalia', '/draft-editor', '/sync'
          ]);
          document.addEventListener('click', (event) => {
            if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
            const target = event.target instanceof Element ? event.target : event.target?.parentElement;
            const link = target?.closest('a[href]');
            if (!link || link.target === '_blank' || link.hasAttribute('download')) return;
            const destination = new URL(link.href, window.location.href);
            if (destination.origin !== window.location.origin || !routes.has(destination.pathname)) return;
            if (destination.pathname === '/dashboard' && destination.searchParams.get('view') === 'dispatch') return;
            const handler = window.webkit?.messageHandlers?.openNativeStudentFeature;
            if (!handler) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            handler.postMessage(destination.pathname + destination.search);
          }, true);
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: nativeStudentRouteBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: .zero, configuration: config)
        // Rubber-band scrolling reveals area outside the page; WKWebView's default
        // background there is white, which flashes against our dark theme. Match
        // the app's `ground` token (see DESIGN.md) so the bounce is invisible.
        if #available(macOS 13.0, *) {
            webView.underPageBackgroundColor = NSColor(red: 0x0a / 255, green: 0x0c / 255, blue: 0x0d / 255, alpha: 1)
        }
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
        hasAccount = KeyStore.loadSessionToken() != nil
        Self.shared = self
    }

    /// Copy the desktop website session into KeyStore so Marginalia does not ask for a second login.
    func syncWebsiteSessionIntoKeyStore() async {
        let apiHost = URL(string: LLMClient.resolvedNativeAPIBaseURL)?.host?.lowercased() ?? ""
        if NativeHostPolicy.isTrustedPreviewHost(apiHost) { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let sessionCookies = cookies.filter { $0.name == "ib_session" && !$0.value.isEmpty }
        let matching = sessionCookies.first { cookie in
            let domain = cookie.domain.lowercased()
            if domain.contains(apiHost) { return true }
            if apiHost.contains(domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) { return true }
            return false
        }
        guard let cookie = matching else { return }
        try? KeyStore.saveSessionToken(cookie.value)
        SchoolWatcherService.shared.restartWithCurrentSession()
        dlog("[Shell] synced ib_session from \(cookie.domain)")
    }

    /// Installs a session token obtained outside the webview (native OAuth via
    /// ASWebAuthenticationSession) into both the webview cookie jar and the
    /// KeyStore, then loads the signed-in surface. Mirrors what a normal web
    /// login would have left behind.
    func adoptSession(token: String, needsSetup: Bool, onboarding: Bool = false) async {
        try? KeyStore.saveSessionToken(token)
        SchoolWatcherService.shared.restartWithCurrentSession()
        if let cookie = HTTPCookie(properties: [
            .name: "ib_session",
            .value: token,
            .path: "/",
            .originURL: Self.base,
        ]) {
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        dlog("[Shell] adopted native OAuth session (needsSetup: \(needsSetup), onboarding: \(onboarding))")
        // `/` is deliberately blocked inside app mode because it is the public
        // marketing homepage. New OAuth users therefore need an allowed native
        // setup route instead of the web-only `/?setup=profile` entry point.
        load(path: onboarding ? NativeRoutes.onboardingPath : (needsSetup ? "/profile/setup" : NativeRoutes.landingPath))
    }

    func chooseHaveAccount() {
        hasAccount = true
        load(path: "/native-login")
    }

    func chooseNoAccount() {
        hasAccount = true
        load(path: "/balance")
    }

    func clearSessionAndShowWelcome() {
        SchoolWatcherService.shared.stop()
        KeyStore.deleteSession()
        hasAccount = false
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        Task {
            let cookies = await cookieStore.allCookies()
            for cookie in cookies where cookie.name == "ib_session" || cookie.name == "ib_app" {
                await cookieStore.deleteCookie(cookie)
            }
            do {
                _ = try await webView.evaluateJavaScript("localStorage.removeItem('ibacalao:desktop-welcome-seen-v1')")
            } catch {
                dlog("[Shell] could not reset desktop welcome state: \(error.localizedDescription)")
            }
            load(path: "\(NativeRoutes.entryPath)?welcome=1")
        }
    }

    func retry() {
        load(path: lastPath)
    }

    func load(path: String) {
        if NativeWorkspaceNavigation.shared.canOpenNativePath(path) {
            Task { @MainActor in
                await syncWebsiteSessionIntoKeyStore()
                _ = NativeWorkspaceNavigation.shared.openNativePath(path)
            }
            return
        }
        NativeWorkspaceNavigation.shared.dismiss()
        lastPath = path
        Task { await performLoad(path: path) }
    }

    func setAnalyticsConsent(_ enabled: Bool) {
        let value = enabled ? "granted" : "denied"
        guard let cookie = HTTPCookie(properties: [
            .name: "ib_analytics_consent",
            .value: value,
            .path: "/",
            .originURL: Self.base,
            .secure: Self.base.scheme == "https",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 365),
        ]) else { return }
        Task { @MainActor in
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            let script = "try { localStorage.setItem('ibacalao:analytics-consent-v1', '\(value)'); window.dispatchEvent(new Event('ibacalao-analytics-consent-change')); } catch {}"
            do { _ = try await webView.evaluateJavaScript(script) }
            catch { dlog("[Shell] analytics preference sync failed: \(error.localizedDescription)") }
        }
    }

    func dismissNativeStudentFeature() {
        NativeWorkspaceNavigation.shared.dismiss()
    }

    func showSchoolConnection(_ connection: SchoolPlatformConnection) {
        var components = URLComponents()
        components.path = "/dashboard"
        var items = [
            URLQueryItem(name: "view", value: "dispatch"),
            URLQueryItem(name: "schoolPlatform", value: connection.platformLabel),
        ]
        if let school = connection.schoolLabel, !school.isEmpty {
            items.append(URLQueryItem(name: "schoolName", value: school))
        }
        components.queryItems = items
        load(path: components.string ?? "/dashboard?view=dispatch")
    }

    func emitDispatchStatus() {
        let dispatch = DispatchModeService.shared
        let payload: [String: Any] = [
            "isActive": dispatch.isActive,
            "isPaired": dispatch.isPaired,
            "alwaysOn": dispatch.alwaysOn,
            "phoneName": dispatch.phoneName,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.dispatchEvent(new CustomEvent('ibacalao:dispatch-status',{detail:\(json)}));"
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                dlog("[Dispatch] status bridge emit failed: \(error.localizedDescription)")
            }
        }
    }

    /// Download/install progress of the school watcher runtime, for the web
    /// "Connect your school" step.
    func emitSchoolRuntimeStatus() {
        let payload = WatcherRuntimeInstaller.shared.state.bridgePayload
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.dispatchEvent(new CustomEvent('ibacalao:school-runtime-status',{detail:\(json)}));"
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                dlog("[WatcherRuntime] status bridge emit failed: \(error.localizedDescription)")
            }
        }
    }

    func emitSchoolPlatformStatus() {
        let status = SchoolWatcherService.shared.loadStatus()
        let detail: String
        if let status, let data = try? JSONEncoder().encode(status), let json = String(data: data, encoding: .utf8) {
            detail = json
        } else {
            detail = "null"
        }
        let script = "window.dispatchEvent(new CustomEvent('ibacalao:school-platform-status',{detail:\(detail)}));"
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                dlog("[SchoolWatcher] status bridge emit failed: \(error.localizedDescription)")
            }
        }
    }

    func emitSchoolBrowserOpened() {
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('ibacalao:school-browser-opened'));"
        ) { _, error in
            if let error {
                dlog("[SchoolWatcher] onboarding browser-open emit failed: \(error.localizedDescription)")
            }
        }
    }

    func emitSchoolBrowserOpenFailed() {
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('ibacalao:school-browser-open-failed'));"
        ) { _, error in
            if let error {
                dlog("[SchoolWatcher] onboarding browser-failure emit failed: \(error.localizedDescription)")
            }
        }
    }

    func emitSchoolBrowserConnected(_ connection: SchoolPlatformConnection) {
        var payload: [String: Any] = [
            "platformLabel": connection.platformLabel,
            "connectedAt": connection.connectedAt,
        ]
        if let school = connection.schoolLabel, !school.isEmpty {
            payload["schoolLabel"] = school
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.dispatchEvent(new CustomEvent('ibacalao:school-browser-connected',{detail:\(json)}));"
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                dlog("[SchoolWatcher] onboarding browser status emit failed: \(error.localizedDescription)")
            }
        }
    }

    /// Opens the normal public pricing page in the user's browser, already
    /// signed in. The long-lived native session token never enters the URL:
    /// Safari receives only the same short-lived, single-use code used by the
    /// WKWebView session bridge.
    func openAuthenticatedPricing(path: String = "/pricing") async {
        let allowedPath = path == "/es/pricing" ? "/es/pricing" : "/pricing"
        let fallback = URL(string: allowedPath, relativeTo: Self.externalWebBase)!.absoluteURL
        guard let token = KeyStore.loadSessionToken() else {
            NSWorkspace.shared.open(fallback)
            return
        }

        do {
            var req = URLRequest(url: Self.base.appendingPathComponent("/api/native/web-session"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.userAuthenticationRequired)
            }

            struct MintResponse: Decodable { let code: String }
            let mint = try JSONDecoder().decode(MintResponse.self, from: data)
            var comps = URLComponents(
                url: Self.externalWebBase.appendingPathComponent("native-session"),
                resolvingAgainstBaseURL: false
            )!
            comps.queryItems = [
                URLQueryItem(name: "code", value: mint.code),
                URLQueryItem(name: "external", value: "pricing"),
                URLQueryItem(name: "next", value: allowedPath),
            ]
            guard let handoff = comps.url else { throw URLError(.badURL) }
            let opened = NSWorkspace.shared.open(handoff)
            dlog("[Shell] authenticated pricing opened browser=\(opened)")
        } catch {
            let ns = error as NSError
            dlog("[Shell] authenticated pricing handoff failed: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
            NSWorkspace.shared.open(fallback)
        }
    }

    /// Marks this WKWebView as the Mac app so middleware serves /dashboard
    /// instead of redirecting it to the public homepage.
    private func installAppModeCookie() async {
        guard let base = URL(string: LLMClient.resolvedNativeAPIBaseURL),
              let cookie = HTTPCookie(properties: [
                  .name: "ib_app",
                  .value: "mac",
                  .path: "/",
                  .originURL: base,
              ]) else { return }
        await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
    }

    /// Signs the webview in via the one-time-code bridge (POST /api/native/web-session
    /// → GET /native-session?code=...) so a 30-day session token never rides in a URL.
    /// Falls back to an unauthenticated load if minting fails — the site's own
    /// /login gate still protects everything downstream.
    private func performLoad(path: String) async {
        // appendingPathComponent treats `?` and `#` as literal path characters
        // (`/?setup=profile` became `/%3Fsetup=profile`). Resolve as a URL path
        // instead so any future shell destination can carry query/hash state.
        guard let url = URL(string: path.hasPrefix("/") ? path : "/\(path)", relativeTo: Self.base)?.absoluteURL else {
            dlog("[Shell] refused invalid path: \(path)")
            return
        }
        await installAppModeCookie()
        #if DEBUG
        // #region agent log
        agentLog("H5", location: "ProductShell.swift:performLoad", message: "loading shell", data: [
            "path": path,
            "host": url.host ?? "",
            "port": url.port ?? 0,
            "skipKeychain": true,
        ])
        // #endregion
        dlog("[Shell] LOADING url=\(url.absoluteString) base=\(Self.base.absoluteString)")
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return
        #else
        guard let token = KeyStore.loadSessionToken() else {
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            return
        }
        do {
            var req = URLRequest(url: Self.base.appendingPathComponent("/api/native/web-session"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            struct MintResponse: Decodable { let code: String }
            let mint = try JSONDecoder().decode(MintResponse.self, from: data)

            var comps = URLComponents(
                url: Self.base.appendingPathComponent("/native-session"),
                resolvingAgainstBaseURL: false
            )!
            comps.queryItems = [
                URLQueryItem(name: "code", value: mint.code),
                URLQueryItem(name: "next", value: path),
            ]
            webView.load(URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData))
        } catch {
            let ns = error as NSError
            dlog("[Shell] web-session mint failed: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        #endif
    }
}

// MARK: - Views

private struct ShellWebView: NSViewRepresentable {
    @ObservedObject var controller: ShellController

    func makeNSView(context: Context) -> WKWebView {
        controller.webView.navigationDelegate = controller.coordinator
        controller.webView.uiDelegate = controller.coordinator
        return controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct AccountChoiceView: View {
    let onHaveAccount: () -> Void
    let onNoAccount: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("iBacalao")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Brand.bright)
            Text("Let's get your workspace set up.")
                .foregroundStyle(Brand.secondary)

            VStack(spacing: 12) {
                Button(action: onHaveAccount) {
                    Text("I already have an account")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(Brand.accent))

                Button(action: onNoAccount) {
                    Text("I don't have one")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .frame(width: 280)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.ground)
    }
}

private struct OfflineView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 32))
                .foregroundStyle(Brand.muted)
            Text("Can't reach ibacalao.com")
                .foregroundStyle(Brand.bright)
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .tint(Color(Brand.accent))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.ground.opacity(0.96))
    }
}

/// The product shell keeps the existing dashboard and broad product routes.
/// The migrated student routes are intercepted into native SwiftUI screens
/// inside this same window; they do not create a second dashboard or sidebar.
/// Marginalia and Dispatch remain native features reachable from this shell.
struct ShellView: View {
    @StateObject private var controller = ShellController()
    @StateObject private var studentFeatures = NativeWorkspaceNavigation.shared
    @State private var didLoad = false

    var body: some View {
        ZStack {
            ShellWebView(controller: controller)
                .opacity(studentFeatures.isShowing ? 0 : 1)
                .allowsHitTesting(!studentFeatures.isShowing)
            if controller.coordinator.isOffline && !studentFeatures.isShowing {
                OfflineView(onRetry: controller.retry)
            }
            if studentFeatures.isShowing {
                NativeStudentFeaturesView(
                    onReturnToApp: controller.dismissNativeStudentFeature,
                    onOpenWeb: controller.load,
                    onSignOut: controller.clearSessionAndShowWelcome,
                    onShowDispatch: { AppDelegate.shared?.showDispatch() },
                    onLaunchOverlay: { AppDelegate.shared?.launchOverlay() },
                    onSetAnalyticsConsent: { controller.setAnalyticsConsent($0) },
                    onSessionEstablished: { token in
                        Task { await controller.adoptSession(token: token, needsSetup: false) }
                    }
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let override = ProcessInfo.processInfo.environment["IBACALAO_QA_LAUNCH_PATH"] ?? UserDefaults.standard.string(forKey: "ShellLaunchPathOverride"),
               override.hasPrefix("/"),
               override.dropFirst().first != "/" {
                #if DEBUG
                controller.load(path: override)
                return
                #else
                // Release QA builds may target an immutable Vercel preview. Keep
                // the path override unavailable on the production API origin.
                let host = URL(string: LLMClient.resolvedNativeAPIBaseURL)?.host?.lowercased() ?? ""
                if NativeHostPolicy.isTrustedPreviewHost(host) {
                    controller.load(path: override)
                    return
                }
                #endif
            }
            controller.load(path: NativeRoutes.initialLaunchPath)
        }
        .background(Brand.ground)
    }
}

extension ShellWebCoordinator: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { response in
            // Save panel already confirmed overwrite; WKDownload refuses existing files.
            guard response == .OK, let url = panel.url else { return completionHandler(nil) }
            try? FileManager.default.removeItem(at: url)
            completionHandler(url)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        dlog("[Shell] download failed: \(error.localizedDescription)")
    }
}
