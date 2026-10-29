import AppKit
import Carbon

/// System-wide ⌘Return via Carbon `RegisterEventHotKey`.
///
/// Deliberately NOT `NSEvent.addGlobalMonitorForEvents` — that API requires
/// Input Monitoring (listen to *all* keystrokes). A single registered hotkey
/// does not, which is why Alfred / Raycast / etc. use Carbon for shortcuts.
final class HotkeyMonitor {
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var localMonitor: Any?
    /// True while iBacalao's own product shell (Homework, Chat) is the frontmost
    /// window. ⌘Return then belongs to the page (save, send), not to a screen capture.
    private(set) var suspended = false

    /// Always true for the Carbon path — no Input Monitoring TCC needed.
    static var isTrusted: Bool { true }

    static var statusLabel: String { "carbon-hotkey" }

    /// No-op kept for call-site compatibility. Do not call IOHIDRequestAccess —
    /// that was causing endless System Settings prompts.
    static func requestPermission() {
        dlog("[Hotkey] requestPermission ignored — Carbon hotkey needs no Input Monitoring")
    }

    func start() {
        stop()
        installCarbonHotKey()
        // Local monitor so ⌘Return still fires when our own windows are key.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only the overlay panel itself keeps a local ⌘Return. In the product
            // shell the key must reach the web page untouched.
            if event.keyCode == UInt16(kVK_Return), event.modifierFlags.contains(.command),
               event.window is KeyableOverlayWindow {
                dlog("[Hotkey] ⌘Return (local)")
                self?.onTrigger?()
                return nil
            }
            return event
        }
        dlog("[Hotkey] started (carbon=\(hotKeyRef != nil), local=\(localMonitor != nil))")
    }

    /// Release the system-wide ⌘Return while the product shell is in front, and
    /// take it back when another app is. Idempotent.
    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        if value {
            if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        } else if hotKeyRef == nil, handlerRef != nil {
            registerHotKeyOnly()
        }
        dlog("[Hotkey] suspended=\(value)")
    }

    private func registerHotKeyOnly() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4942_4143), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Return), UInt32(cmdKey), hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        if status != noErr { dlog("[Hotkey] re-register failed: \(status)") }
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    deinit {
        stop()
    }

    private func installCarbonHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4942_4143), id: 1) // 'IBAC'
        let status = RegisterEventHotKey(
            UInt32(kVK_Return),
            UInt32(cmdKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            dlog("[Hotkey] RegisterEventHotKey failed: \(status)")
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard err == noErr, hkID.id == 1 else { return noErr }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                dlog("[Hotkey] ⌘Return (carbon)")
                DispatchQueue.main.async {
                    monitor.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        if handlerStatus != noErr {
            dlog("[Hotkey] InstallEventHandler failed: \(handlerStatus)")
        }
    }
}
