import SwiftUI
import AppKit
import AuthenticationServices
import ServiceManagement

extension Notification.Name {
    /// Posted when the overlay window becomes key — focus chat input.
    static let overlayDidBecomeKey = Notification.Name("overlayDidBecomeKey")
    static let nativeAuthDidChange = Notification.Name("nativeAuthDidChange")
}

/// Floating tip panel that stays above writing apps and follows Space switches.
final class KeyableOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        NotificationCenter.default.post(name: .overlayDidBecomeKey, object: nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    var dashboardWindow: NSWindow!
    var overlayWindow: NSWindow!
    var shellWindow: NSWindow!

    let settings = AppSettings.shared
    let usage = UsageStore.shared
    let dispatch = DispatchModeService.shared
    lazy var engine = FeedbackEngine(settings: settings, usage: usage)
    private var authSession: ASWebAuthenticationSession?

    private var spaceObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NativeMacSchoolNotifications.installDelegate()
        NSApp.setActivationPolicy(.regular)
        Self.applyLimeDockTile()
        // Import old Keychain keys silently (never show password dialogs).
        #if DEBUG
        Self.applyDebugTestDefaults()
        #endif
        KeyStore.migrateIfNeeded()
        SchoolBrowserBridgeInstaller.installIfPossible()
        Self.registerLaunchAtLoginIfNeeded()
        // Start fetching the school runtime immediately, signed in or not, so
        // it's usually ready by the time the student reaches "Connect school".
        WatcherRuntimeInstaller.shared.ensureInstalled()
        SchoolWatcherService.shared.startIfAuthenticated()
        NativeMacSchoolNotifications.startIfEnabled()
        // #region agent log
        agentLog("H0", location: "App.swift:didFinishLaunching", message: "launch begin", data: [:])
        // #endregion
        #if DEBUG
        AccessibilityTextExtractor.runSelfCheck()
        DocumentBody.runSelfCheck()
        #endif
        setupMenu()
        setupDashboardWindow()
        setupOverlayWindow()
        setupShellWindow()
        engine.start()

        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow.orderOut(nil)
        overlayWindow.orderOut(nil)
        showShell()
        dlog("[App] launched desktop shell")
    }

    func applicationWillTerminate(_ notification: Notification) {
        dispatch.stop()
        SchoolWatcherService.shared.stop()
        NativeMacSchoolNotifications.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showShell()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        engine.accessibilityTrusted = AccessibilityTextExtractor.isTrusted
        bringOverlayAlongIfVisible()
        syncShellFocusState()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Keep the tip panel visible above the writing app we just left.
        engine.setHotkeySuspended(false)
        bringOverlayAlongIfVisible()
    }

    /// True when the product shell (Homework, Chat) is the window the student is working in.
    private var shellIsFrontmost: Bool {
        NSApp.isActive && shellWindow?.isVisible == true && shellWindow.isKeyWindow
    }

    /// While the shell is in front the status-level tip panel would sit over the
    /// page, and ⌘Return would capture the page instead of saving it.
    private func syncShellFocusState() {
        engine.setHotkeySuspended(shellIsFrontmost)
        if shellIsFrontmost, overlayWindow?.isVisible == true, !engine.isBusy {
            hideOverlay()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleAuthCallback(url)
        }
    }

    func handleAuthCallback(_ url: URL) {
        if url.scheme == "ibacalao", url.host == "overlay" {
            launchOverlay()
            return
        }
        if url.scheme == "ibacalao", url.host == "open" {
            ShellController.shared?.load(path: NativeRoutes.entryPath)
            return
        }
        guard url.scheme == "ibacalao", url.host == "auth" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
            return
        }
        // The product shell starts OAuth in the user's real browser, so this is
        // also the return path for "Continue with Google/Microsoft" in the shell
        // — hand the token to the webview too, or the shell stays on /login even
        // though the app is now signed in.
        let needsSetup = items.first(where: { $0.name == "setup" })?.value == "1"
        let onboarding = items.first(where: { $0.name == "onboarding" })?.value == "1"
        let fromShell = ShellController.awaitingOAuthCallback
        ShellController.awaitingOAuthCallback = false
        Task { @MainActor in
            await ShellController.shared?.adoptSession(token: token, needsSetup: needsSetup, onboarding: onboarding)
        }
        do {
            try KeyStore.saveSessionToken(token)
            SchoolWatcherService.shared.restartWithCurrentSession()
            dispatch.refreshServerStatus()
            NotificationCenter.default.post(name: .nativeAuthDidChange, object: nil)
            engine.stage = .idle
            // Signing in from the product shell should leave you in the shell.
            // Only the overlay's own sign-in flow wants the overlay popped open.
            if !fromShell {
                launchOverlay()
            }
        } catch {
            dlog("[Auth] failed to save callback token: \(error.localizedDescription)")
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "iBacalao Homework")
        appMenu.addItem(withTitle: "About iBacalao Homework", action: nil, keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit iBacalao Homework", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Required for ⌘V / ⌘C / ⌘X in text fields (SecureField included).
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Homework", action: #selector(showShell), keyEquivalent: "0")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func setupDashboardWindow() {
        // Portrait 9:16 launcher — art fills edge to edge; traffic lights sit on the photo.
        let launchSize = NSSize(width: 405, height: 720)
        dashboardWindow = NSWindow(
            contentRect: NSRect(x: 120, y: 80, width: launchSize.width, height: launchSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        dashboardWindow.title = ""
        dashboardWindow.titleVisibility = .hidden
        dashboardWindow.titlebarAppearsTransparent = true
        dashboardWindow.titlebarSeparatorStyle = .none
        dashboardWindow.minSize = NSSize(width: 360, height: 620)
        dashboardWindow.isReleasedWhenClosed = false
        dashboardWindow.backgroundColor = NSColor(Brand.ground)
        dashboardWindow.isMovableByWindowBackground = true
        dashboardWindow.contentView = NSView()
        // Do not host DashboardView here — its onAppear hits Keychain and can
        // raise the macOS password sheet on every launch.
    }

    private func setupShellWindow() {
        shellWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1160, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        shellWindow.title = "iBacalao"
        shellWindow.titlebarAppearsTransparent = true
        shellWindow.minSize = NSSize(width: 820, height: 560)
        shellWindow.isReleasedWhenClosed = false
        shellWindow.backgroundColor = NSColor(Brand.ground)
        shellWindow.alphaValue = 0.96 // whole window incl. content; 1.0 = opaque
        // Reopen on the Space the user is looking at, while still allowing the
        // primary product shell itself to enter native macOS full-screen mode.
        shellWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]

        let hosting = NSHostingView(rootView: ShellView())
        hosting.sizingOptions = []
        shellWindow.contentView = hosting

        // Clicking back into the shell while the app is already active does not
        // fire applicationDidBecomeActive, so track the window itself.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: shellWindow, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.syncShellFocusState() }
            }
        }
    }

    private func setupOverlayWindow() {
        let panel = KeyableOverlayWindow(
            contentRect: NSRect(x: 560, y: 140, width: 360, height: 440),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        // Stay visible when switching writing apps / Spaces (NSPanel defaults to hide).
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        applyOverlaySpaceBehavior(panel)
        // Critical for real glass: must not paint an opaque fill over the blur.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 320, height: 360)
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.acceptsMouseMovedEvents = true

        let root = OverlayView(settings: settings, engine: engine)
        panel.contentView = LiquidGlassHostingView(rootView: root, cornerRadius: 22)
        panel.setFrame(NSRect(x: 560, y: 140, width: 360, height: 440), display: false)
        overlayWindow = panel
        applyOverlaySharingType()

        let workspace = NSWorkspace.shared.notificationCenter
        // Mission Control Space change — drag the panel onto the new Space.
        spaceObserver = workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.bringOverlayAlongIfVisible(reason: "space")
            }
        }
        // App switches (Docs ↔ Chrome ↔ Cursor) — keep panel above the new front app.
        appActivationObserver = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.bringOverlayAlongIfVisible(reason: "app")
            }
        }
    }

    private func applyOverlaySpaceBehavior(_ window: NSWindow) {
        // Higher than .floating so fullscreen / Stage Manager apps don't cover us.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        // moveToActiveSpace: follow the Space the user just switched to (Tahoe-
        // reliable). canJoinAllSpaces alone often leaves the panel on Desktop 1.
        // fullScreenAuxiliary: appear over fullscreen writing apps.
        window.collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
    }

    /// .none hides the panel from screen recorders/screenshots/OCR entirely (default) —
    /// also stops our legacy OCR fallback from reading our own tip text back in.
    /// .readOnly makes it visible to recorders for demo/marketing capture, opt-in only.
    func applyOverlaySharingType() {
        guard let overlayWindow else { return }
        overlayWindow.sharingType = settings.demoRecordingModeEnabled ? .readOnly : .none
    }

    /// Keep the tip panel on the active Space and above the frontmost writing app.
    private func bringOverlayAlongIfVisible(reason: String = "refresh") {
        guard let overlayWindow, overlayWindow.isVisible else { return }
        if shellIsFrontmost, !engine.isBusy {
            syncShellFocusState()
            return
        }
        applyOverlaySharingType()
        applyOverlaySpaceBehavior(overlayWindow)
        // orderFrontRegardless keeps us visible without stealing key focus from Docs.
        overlayWindow.orderFrontRegardless()
        dlog("[Overlay] bringAlong reason=\(reason) visible=\(overlayWindow.isVisible)")
    }

    func startNativeSignIn() {
        // Overlay-only: never open native-login or the old dashboard.
    }

    /// Native school-browser handoff retained for Homework's existing connector flow.
    @objc func showDispatch() {
        dispatch.start()
        let hosting = NSHostingView(rootView: DispatchModePanel())
        hosting.sizingOptions = []
        dashboardWindow.contentView = hosting
        dashboardWindow.title = "School connection"
        dashboardWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Legacy overlay entry points return to the current Homework app.
    @objc func launchOverlay() {
        ShellController.shared?.load(path: "/homework?retired=1")
        showShell()
    }

    @objc func hideOverlay() {
        overlayWindow.orderOut(nil)
        dispatch.setMarginaliaVisible(false)
    }

    @objc func showSettings() {
        dashboardWindow.orderOut(nil)
        shellWindow.orderOut(nil)
        focusOverlay()
    }

    @objc private func showShell() {
        if shellWindow.isMiniaturized { shellWindow.deminiaturize(nil) }
        shellWindow.orderFrontRegardless()
        shellWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func focusOverlay() {
        applyOverlaySharingType()
        applyOverlaySpaceBehavior(overlayWindow)
        if let screen = NSScreen.main?.visibleFrame {
            let size = NSSize(width: 360, height: 440)
            overlayWindow.setFrame(
                NSRect(
                    x: screen.maxX - size.width - 28,
                    y: screen.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                display: true
            )
        }
        overlayWindow.orderFrontRegardless()
        overlayWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        dispatch.setMarginaliaVisible(true)
    }

    /// "Always watching": start automatically at login so the school-connector
    /// daemon (SchoolWatcherService, started right after this call) keeps
    /// polling across reboots without the student having to reopen the app.
    /// SMAppService (not a raw LaunchAgent plist) is the only login-item API
    /// that works whether or not this build is sandboxed for MAS submission.
    /// register() is idempotent — .enabled is a no-op — so this is safe to
    /// call on every launch rather than tracking a "did we already ask" flag.
    private static func registerLaunchAtLoginIfNeeded() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do {
            try service.register()
            dlog("[App] registered as login item")
        } catch {
            // ponytail: no user-facing retry/toggle for a denied login-item
            // request — macOS surfaces its own System Settings approval UI
            // for this. Add a Settings toggle if students report it silently
            // failing to stick.
            dlog("[App] login item registration failed: \(error.localizedDescription)")
        }
    }

    /// The installed app is not sandboxed, so `defaults write com.ibacalao…`
    /// often lands in the MAS container plist and this process never sees it.
    #if DEBUG
    private static func applyDebugTestDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "skipLoginForDev")
        // Only seed a fallback if nothing is configured yet — this used to
        // force-overwrite ShellBaseURLOverride to localhost on every single
        // launch, silently wiping out a deliberately-set preview/dev URL
        // (e.g. a Vercel preview link) each time the app restarted.
        if defaults.string(forKey: "ShellBaseURLOverride") == nil {
            defaults.set("http://127.0.0.1:3000", forKey: "ShellBaseURLOverride")
        }
        defaults.synchronize()
    }
    #endif

    /// Tinted restyles Assets.car. contentView is the Dock's actual pixels
    /// while running; the docktileplugin does the same when quit.
    private static func applyLimeDockTile() {
        guard
            let url = Bundle.main.url(forResource: "AppIconDock", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return }
        image.isTemplate = false
        let tile = NSApp.dockTile
        let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        tile.contentView = view
        tile.display()
    }
}

/// Entry point exposed to whatever executable target links this library —
/// either the SwiftPM `LiveExaminerOverlay` executable (dev flow, see
/// `Sources/LiveExaminerOverlay/Entry.swift`) or the Xcode app target's
/// `App/AppMain.swift`. Keeps `AppDelegate` and everything else internal to Core.
public enum LiveExaminerOverlayApp {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
