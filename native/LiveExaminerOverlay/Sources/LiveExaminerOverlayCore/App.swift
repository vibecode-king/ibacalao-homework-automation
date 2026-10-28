import SwiftUI
import AppKit

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

    let settings = AppSettings.shared
    let usage = UsageStore.shared
    lazy var engine = FeedbackEngine(settings: settings, usage: usage)

    private var spaceObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.regular)
        // Do not set applicationIconImage — on Tahoe it bypasses Liquid Glass /
        // Assets.car and shows a sharp square inside the dark icon plate.
        // Import old Keychain keys silently (never show password dialogs).
        KeyStore.migrateIfNeeded()
        #if DEBUG
        AccessibilityTextExtractor.runSelfCheck()
        #endif
        setupMenu()
        setupDashboardWindow()
        setupOverlayWindow()
        engine.start()
        AccessibilityTextExtractor.requestTrustIfNeeded()

        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow.makeKeyAndOrderFront(nil)
        // Overlay stays hidden until Launch.
        overlayWindow.orderOut(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        engine.accessibilityTrusted = AccessibilityTextExtractor.isTrusted
        bringOverlayAlongIfVisible()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Keep the tip panel visible above the writing app we just left.
        bringOverlayAlongIfVisible()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleAuthCallback(url)
        }
    }

    func handleAuthCallback(_ url: URL) {
        guard url.scheme == "ibacalao", url.host == "auth" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
            return
        }
        do {
            try KeyStore.saveSessionToken(token)
            NotificationCenter.default.post(name: .nativeAuthDidChange, object: nil)
            DashboardNavigation.shared.tab = .settings
            dashboardWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            dlog("[Auth] failed to save callback token: \(error.localizedDescription)")
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "iBacalao")
        appMenu.addItem(withTitle: "About iBacalao", action: nil, keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit iBacalao", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        windowMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "1")
        windowMenu.addItem(withTitle: "Overlay", action: #selector(showOverlay), keyEquivalent: "2")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func setupDashboardWindow() {
        dashboardWindow = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 520, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        dashboardWindow.title = ""
        dashboardWindow.titleVisibility = .hidden
        dashboardWindow.titlebarAppearsTransparent = true
        dashboardWindow.minSize = NSSize(width: 460, height: 520)
        dashboardWindow.isReleasedWhenClosed = false
        dashboardWindow.backgroundColor = NSColor(Brand.ground)
        dashboardWindow.isMovableByWindowBackground = true

        let hosting = NSHostingView(
            rootView: DashboardView(settings: settings, engine: engine)
                .padding(.top, 8)
        )
        hosting.sizingOptions = []
        dashboardWindow.contentView = hosting
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
        applyOverlaySpaceBehavior(overlayWindow)
        // orderFrontRegardless keeps us visible without stealing key focus from Docs.
        overlayWindow.orderFrontRegardless()
        dlog("[Overlay] bringAlong reason=\(reason) visible=\(overlayWindow.isVisible)")
    }

    /// Primary CTA: show overlay, hide settings.
    @objc func launchOverlay() {
        dashboardWindow.orderOut(nil)
        focusOverlay()
    }

    @objc func showSettings() {
        DashboardNavigation.shared.tab = .settings
        dashboardWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showOverlay() {
        focusOverlay()
    }

    private func focusOverlay() {
        applyOverlaySpaceBehavior(overlayWindow)
        overlayWindow.orderFrontRegardless()
        overlayWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
