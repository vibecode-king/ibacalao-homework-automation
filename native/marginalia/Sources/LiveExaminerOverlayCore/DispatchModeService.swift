import Foundation
import Combine
import IOKit.pwr_mgt
import MultipeerConnectivity

/// Local phone-to-Mac bridge for Dispatch Mode.
///
/// The Mac advertises only while Marginalia is open. A phone must provide the
/// six-digit code shown in the Mac app before it can start Dispatch Mode or
/// receive Marginalia events.
@MainActor
final class DispatchModeService: NSObject, ObservableObject {
    static let shared = DispatchModeService()

    static let serviceType = "ibacalao-dsp"

    @Published private(set) var isConnected = false
    @Published private(set) var isPaired = false
    @Published private(set) var isActive = false
    @Published private(set) var marginaliaVisible = false
    @Published private(set) var phoneName = "No phone connected"
    @Published private(set) var lastEvent = "No Marginalia event forwarded"
    @Published private(set) var pairingCode: String
    @Published private(set) var alwaysOn: Bool
    @Published private(set) var advertiserError: String?

    var pairingPayload: String {
        var components = URLComponents()
        components.scheme = "ibacalao-dispatch"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "code", value: pairingCode)]
        return components.url?.absoluteString ?? "ibacalao-dispatch://pair?code=\(pairingCode)"
    }

    private let defaults = UserDefaults.standard
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private var powerAssertionID: IOPMAssertionID?
    private var pairedPeer: MCPeerID?
    private var cachedServerToken: String?

    private static var nativeAPIBaseURL: URL {
        URL(string: LLMClient.resolvedNativeAPIBaseURL)
            ?? URL(string: LLMClient.defaultNativeAPIBaseURL)!
    }

    private enum Keys {
        static let pairingCode = "dispatchPairingCode"
        static let alwaysOn = "dispatchAlwaysOn"
    }

    private struct Message: Codable {
        let type: String
        let code: String?
        let title: String?
        let detail: String?
        let active: Bool?
        let paired: Bool?
        let lastEvent: String?
        let marginaliaVisible: Bool?

        init(
            type: String,
            code: String?,
            title: String?,
            detail: String?,
            active: Bool?,
            paired: Bool?,
            lastEvent: String?,
            marginaliaVisible: Bool? = nil
        ) {
            self.type = type
            self.code = code
            self.title = title
            self.detail = detail
            self.active = active
            self.paired = paired
            self.lastEvent = lastEvent
            self.marginaliaVisible = marginaliaVisible
        }
    }

    override init() {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "iBacalao Mac"
        peerID = MCPeerID(displayName: String(name.prefix(63)))
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["version": "1"],
            serviceType: Self.serviceType
        )
        pairingCode = defaults.string(forKey: Keys.pairingCode) ?? Self.makePairingCode()
        alwaysOn = defaults.bool(forKey: Keys.alwaysOn)

        super.init()
        if defaults.string(forKey: Keys.pairingCode) == nil {
            defaults.set(pairingCode, forKey: Keys.pairingCode)
        }
        session.delegate = self
        advertiser.delegate = self
    }

    func start() {
        advertiserError = nil
        advertiser.startAdvertisingPeer()
        publishServerStatus(action: "online")
        if alwaysOn { startDispatch() }
        dlog("[Dispatch] advertising service=\(Self.serviceType) code=\(pairingCode)")
    }

    /// Disconnects the currently paired phone from the Mac side. Sleep prevention
    /// stays on if Always On is enabled; otherwise it releases with the phone.
    func disconnectPhone() {
        guard pairedPeer != nil || isConnected else { return }
        if !alwaysOn { stopDispatch() }
        pairedPeer = nil
        isPaired = false
        phoneName = "No phone connected"
        session.disconnect()
        isConnected = false
        publishServerStatus(action: "unpaired")
        dlog("[Dispatch] disconnected from Mac side")
    }

    /// Local toggle: keeps the Mac awake regardless of phone pairing/connection.
    func setAlwaysOn(_ on: Bool) {
        guard alwaysOn != on else { return }
        alwaysOn = on
        defaults.set(on, forKey: Keys.alwaysOn)
        if on {
            startDispatch()
        } else if pairedPeer == nil {
            stopDispatch()
        }
        sendState()
    }

    func stop() {
        // Never Keychain-read on quit — that showed the macOS password sheet.
        stopDispatch()
        advertiser.stopAdvertisingPeer()
        publishServerStatus(action: "offline", allowKeychainRead: false)
        session.disconnect()
        pairedPeer = nil
        isConnected = false
        isPaired = false
        phoneName = "No phone connected"
    }

    func regeneratePairingCode() {
        let previousPeer = pairedPeer
        stopDispatch()
        pairedPeer = nil
        isPaired = false
        pairingCode = Self.makePairingCode()
        defaults.set(pairingCode, forKey: Keys.pairingCode)
        if let previousPeer { sendState(to: previousPeer) }
    }

    /// Re-announces the Mac after a native account login. The local phone link
    /// still works without a server; this only lets the student's profile show
    /// whether the computer is available for future school-data sync.
    func refreshServerStatus() {
        publishServerStatus(action: isPaired ? "paired" : "online")
    }

    func setMarginaliaVisible(_ visible: Bool) {
        guard marginaliaVisible != visible else { return }
        marginaliaVisible = visible
        sendState()
    }

    func publishEvent(title: String, detail: String) {
        guard isActive, isPaired else { return }
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let cleanDetail = String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard !cleanTitle.isEmpty else { return }
        lastEvent = cleanTitle
        send(Message(type: "event", code: nil, title: cleanTitle, detail: cleanDetail, active: true, paired: true, lastEvent: cleanTitle))
    }

    private func handle(_ message: Message, from peer: MCPeerID) {
        switch message.type {
        case "pair":
            if let pairedPeer, pairedPeer != peer {
                send(Message(type: "pair_result", code: nil, title: nil, detail: "This Mac is already paired. Unpair it before connecting another phone.", active: nil, paired: false, lastEvent: nil), to: peer)
                return
            }
            guard message.code == pairingCode else {
                send(Message(type: "pair_result", code: nil, title: nil, detail: "Pairing code did not match.", active: nil, paired: false, lastEvent: nil), to: peer)
                return
            }
            pairedPeer = peer
            isPaired = true
            phoneName = peer.displayName
            advertiserError = nil
            sendState(to: peer)
            publishServerStatus(action: "paired")
            dlog("[Dispatch] phone paired name=\(phoneName)")
        case "start":
            guard pairedPeer == peer else { return }
            startDispatch()
            sendState()
        case "stop":
            guard pairedPeer == peer else { return }
            stopDispatch()
            sendState()
        case "marginalia_show":
            guard pairedPeer == peer else { return }
            AppDelegate.shared?.launchOverlay()
            setMarginaliaVisible(true)
        case "marginalia_hide":
            guard pairedPeer == peer else { return }
            AppDelegate.shared?.hideOverlay()
            setMarginaliaVisible(false)
        case "status":
            guard pairedPeer == peer else { return }
            sendState(to: peer)
        case "unpair":
            guard pairedPeer == peer else { return }
            stopDispatch()
            pairedPeer = nil
            isPaired = false
            publishServerStatus(action: "unpaired")
            sendState(to: peer)
        default:
            break
        }
    }

    private func startDispatch() {
        guard powerAssertionID == nil else {
            isActive = true
            return
        }

        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "iBacalao Dispatch Mode" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            dlog("[Dispatch] failed to prevent idle sleep result=\(result)")
            return
        }
        powerAssertionID = assertionID
        isActive = true
        dlog("[Dispatch] active assertion=\(assertionID)")
    }

    private func stopDispatch() {
        if let assertionID = powerAssertionID {
            IOPMAssertionRelease(assertionID)
            powerAssertionID = nil
            dlog("[Dispatch] released assertion")
        }
        isActive = false
    }

    private func sendState(to peer: MCPeerID? = nil) {
        send(Message(
            type: "state",
            code: nil,
            title: nil,
            detail: nil,
            active: isActive,
            paired: isPaired,
            lastEvent: lastEvent,
            marginaliaVisible: marginaliaVisible
        ), to: peer)
    }

    private func send(_ message: Message, to explicitPeer: MCPeerID? = nil) {
        let targets: [MCPeerID]
        if let explicitPeer {
            guard session.connectedPeers.contains(explicitPeer) else { return }
            targets = [explicitPeer]
        } else if let pairedPeer, session.connectedPeers.contains(pairedPeer) {
            targets = [pairedPeer]
        } else {
            return
        }
        do {
            let data = try JSONEncoder().encode(message)
            try session.send(data, toPeers: targets, with: .reliable)
        } catch {
            dlog("[Dispatch] send failed error=\(error.localizedDescription)")
        }
    }

    private func publishServerStatus(action: String, allowKeychainRead: Bool = true) {
        let token: String?
        if allowKeychainRead {
            token = KeyStore.loadSessionToken()
            cachedServerToken = token
        } else {
            token = cachedServerToken
        }
        guard let token else { return }
        var request = URLRequest(url: Self.nativeAPIBaseURL.appendingPathComponent("/api/native/dispatch"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": action,
            "macName": peerID.displayName,
            "source": "mac",
        ])
        URLSession.shared.dataTask(with: request).resume()
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 100_000...999_999))
    }
}

extension DispatchModeService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.isConnected = !self.session.connectedPeers.isEmpty
            if state == .connected {
                if self.pairedPeer == peerID { self.phoneName = peerID.displayName }
            } else if state == .notConnected, self.pairedPeer == peerID {
                self.pairedPeer = nil
                self.isPaired = false
                if !self.alwaysOn { self.stopDispatch() }
                self.phoneName = "No phone connected"
                self.publishServerStatus(action: "unpaired")
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        Task { @MainActor in
            self.handle(message, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated func session(_ session: MCSession, didReceive certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}

extension DispatchModeService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            invitationHandler(true, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        dlog("[Dispatch] advertiser failed error=\(error.localizedDescription)")
        Task { @MainActor in
            self.advertiserError = "Couldn't make this Mac visible to phones. Check that Local Network access is allowed for this app in System Settings > Privacy & Security."
        }
    }
}
