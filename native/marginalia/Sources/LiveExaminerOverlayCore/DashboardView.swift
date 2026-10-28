import SwiftUI
import AppKit
import AuthenticationServices

final class NativeAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = NativeAuthPresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // ASWebAuthenticationSession.start() returns false — silently, with no
        // error and no completion callback — when the anchor is not an on-screen
        // window. The old order handed it overlayWindow first, which is hidden
        // whenever the product shell is in front, so "Continue with Google" in
        // the shell spun forever and nothing was logged. Always anchor to a
        // window that is actually visible.
        if let key = NSApp.keyWindow, key.isVisible { return key }
        if let main = NSApp.mainWindow, main.isVisible { return main }
        if let visible = NSApp.windows.first(where: { $0.isVisible }) { return visible }
        return ASPresentationAnchor()
    }
}

enum DashboardTab: String, CaseIterable, Identifiable {
    case launch
    case profile
    case dispatch
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .launch: return "Launch"
        case .profile: return "Profile"
        case .dispatch: return "Dispatch"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .launch: return "play.fill"
        case .profile: return "person.crop.circle"
        case .dispatch: return "antenna.radiowaves.left.and.right"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class DashboardNavigation: ObservableObject {
    static let shared = DashboardNavigation()
    @Published var tab: DashboardTab = .launch
}

struct DashboardView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: FeedbackEngine
    @ObservedObject private var navigation = DashboardNavigation.shared
    @ObservedObject private var usage = UsageStore.shared

    @State private var account: NativeAccount?
    @State private var authSession: ASWebAuthenticationSession?
    @State private var sessionKeyDraft = ""
    @State private var testStatus: TestStatus = .idle
    @State private var testMessage = ""
    @State private var availableVoices: [SystemVoice] = []

    private enum TestStatus {
        case idle, testing, success, failure
    }

    private static let pricingURL = URL(string: "https://ibacalao.com/pricing")!

    var body: some View {
        ZStack {
            if navigation.tab == .launch {
                launchBackground
            } else {
                Brand.ground.ignoresSafeArea()
            }
            VStack(spacing: 0) {
                dockBar
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                Group {
                    switch navigation.tab {
                    case .launch:
                        launchPage
                    case .profile:
                        profilePage
                    case .dispatch:
                        DispatchModePanel()
                    case .settings:
                        settingsPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 360, minHeight: 620)
        .preferredColorScheme(.dark)
        .onAppear {
            availableVoices = TipSpeaker.availableVoices(matchingDeviceLanguages: true)
            ensureSpokenVoiceValid()
            refreshAccount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeAuthDidChange)) { _ in
            refreshAccount()
        }
    }

    // MARK: - Dock

    private var dockBar: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                dockIcon(for: .launch)
                dockIcon(for: .profile)
                dockIcon(for: .dispatch)
                Rectangle()
                    .fill(Brand.hairline)
                    .frame(width: 1, height: 28)
                    .padding(.horizontal, 6)
                dockIcon(for: .settings)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 1)
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    private func dockIcon(for tab: DashboardTab) -> some View {
        let selected = navigation.tab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                navigation.tab = tab
            }
        } label: {
            Image(systemName: tab.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Brand.onAccent : Brand.bright)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Brand.accent : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.label)
        .accessibilityLabel(tab.label)
    }

    // MARK: - Launch

    private var launchPage: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let contentWidth = min(360, max(240, width - 56))
            let topPad = max(20, height * 0.07)
            let midGap = max(24, height * 0.09)
            let bottomPad = max(20, height * 0.04)
            let sidePad = max(20, (width - contentWidth) / 2)

            ZStack {
                VStack(spacing: 0) {
                    Spacer(minLength: topPad)

                    Button("Launch") {
                        AppDelegate.shared?.launchOverlay()
                    }
                    .buttonStyle(BrandLiquidGlassButtonStyle())
                    .frame(maxWidth: contentWidth)

                    Spacer(minLength: midGap)

                    VStack(spacing: 10) {
                        BrandDropdownSelector(
                            options: Array(CoachingSubject.allCases),
                            selection: $settings.subject,
                            emoji: { $0.emoji },
                            title: { $0.label },
                            maxListHeight: min(280, max(140, height * 0.35))
                        )

                        if !engine.accessibilityTrusted {
                            Button("Grant Accessibility") {
                                AccessibilityTextExtractor.openSettingsForGrant()
                            }
                            .buttonStyle(.plain)
                            .font(BrandFont.body(11))
                            .foregroundStyle(Brand.faint)
                        }

                        if case .error(let message) = engine.stage {
                            Text(message)
                                .font(BrandFont.body(11))
                                .foregroundStyle(Brand.danger)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: contentWidth)
                        } else if case .couldNotRead = engine.stage {
                            Text(FeedbackEngine.couldNotReadMessage)
                                .font(BrandFont.body(11))
                                .foregroundStyle(Brand.warning)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: contentWidth)
                        }
                    }
                    .frame(maxWidth: contentWidth)
                    .padding(.bottom, bottomPad)
                }
                .padding(.horizontal, sidePad)
                .frame(width: width, height: height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Arch texture behind Launch. Portrait art for a tall window; landscape art
    /// when the user stretches/full-sizes the launcher so it still fills the frame.
    @ViewBuilder
    private var launchBackground: some View {
        GeometryReader { geo in
            let useWide = geo.size.width > geo.size.height * 1.05
            if let image = Self.loadLaunchBackgroundImage(wide: useWide) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                    .clipped()
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: Brand.ground.opacity(0.72), location: 0),
                                .init(color: Brand.ground.opacity(0.28), location: 0.38),
                                .init(color: Color.clear, location: 0.7),
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    }
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func loadLaunchBackgroundImage(wide: Bool) -> NSImage? {
        let names = wide
            ? ["launch-bg-wide", "launch-bg"]
            : ["launch-bg", "launch-bg-wide"]
        for name in names {
            let candidates: [URL?] = [
                Bundle.main.url(forResource: name, withExtension: "png"),
                Bundle.main.resourceURL?.appendingPathComponent("\(name).png"),
            ]
            for case let url? in candidates {
                if let img = NSImage(contentsOf: url) { return img }
            }
        }
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let fallback = wide ? "launch-bg-wide.png" : "launch-bg.png"
        return NSImage(contentsOf: dir.appendingPathComponent(fallback))
            ?? NSImage(contentsOf: dir.appendingPathComponent("launch-bg.png"))
    }

    // MARK: - Profile

    private var profilePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("PROFILE")
                        .font(BrandFont.mono(11, weight: .medium))
                        .foregroundStyle(Brand.faint)
                        .tracking(1.2)

                    Text(apiStatusTitle)
                        .font(BrandFont.display(22, weight: .semibold))
                        .foregroundStyle(Brand.bright)
                        .tracking(-0.4)

                    if let subtitle = apiStatusSubtitle {
                        Text(subtitle)
                            .font(BrandFont.body(13))
                            .foregroundStyle(apiStatusSubtitleColor)
                    }

                    HStack(spacing: 16) {
                        if account != nil || KeyStore.hasSessionToken() {
                            Button("Sign out") {
                                SchoolWatcherService.shared.stop()
                                KeyStore.deleteSession()
                                account = nil
                                sessionKeyDraft = ""
                                testStatus = .idle
                                testMessage = ""
                            }
                            .buttonStyle(BrandGhostButtonStyle())
                        } else {
                            Button("Sign in with browser") { startSignIn() }
                                .buttonStyle(BrandGhostButtonStyle())
                        }

                        BrandTextLink(title: "Get your key here") {
                            NSWorkspace.shared.open(Self.pricingURL)
                        }

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 12) {
                        Button("Test connection") { runTest() }
                            .buttonStyle(.plain)
                            .font(BrandFont.body(11))
                            .foregroundStyle(Brand.faint)
                            .disabled(testStatus == .testing)

                        if !testMessage.isEmpty {
                            Text(testMessage)
                                .font(BrandFont.body(11))
                                .foregroundStyle(
                                    testStatus == .success ? Brand.success
                                        : (testStatus == .failure ? Brand.danger : Brand.muted)
                                )
                                .lineLimit(2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("USAGE")
                        .font(BrandFont.mono(11, weight: .medium))
                        .foregroundStyle(Brand.faint)
                        .tracking(1.2)

                    let weekDelta = usage.tipsWeekDeltaFraction
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        profileStatCard(
                            label: "Credits left",
                            value: account.map { "\($0.credits)" } ?? "—",
                            systemImage: "creditcard",
                            deltaFraction: nil,
                            positiveIsGood: true
                        )
                        profileStatCard(
                            label: "Tips used",
                            value: "\(usage.tipsUsed)",
                            systemImage: "lightbulb",
                            deltaFraction: weekDelta,
                            positiveIsGood: true
                        )
                        profileStatCard(
                            label: "Hours used",
                            value: usage.formatHours(usage.hoursUsed),
                            systemImage: "clock",
                            deltaFraction: weekDelta,
                            positiveIsGood: false
                        )
                        profileStatCard(
                            label: "Time saved",
                            value: "~" + usage.formatHours(usage.hoursSaved),
                            systemImage: "chart.line.uptrend.xyaxis",
                            deltaFraction: weekDelta,
                            positiveIsGood: true
                        )
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func profileStatCard(
        label: String,
        value: String,
        systemImage: String,
        deltaFraction: Double?,
        positiveIsGood: Bool
    ) -> some View {
        let rising = (deltaFraction ?? 0) >= 0
        let trendGood = deltaFraction == nil ? true : (rising == positiveIsGood)
        let trendColor: Color = {
            guard deltaFraction != nil else { return Brand.faint }
            return trendGood ? Brand.success : Brand.danger
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(BrandFont.body(13))
                        .foregroundStyle(Brand.muted)
                    Text(value)
                        .font(BrandFont.display(22, weight: .medium))
                        .foregroundStyle(Brand.bright)
                        .tracking(-0.4)
                }
                Spacer(minLength: 8)
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.info)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Brand.info.opacity(0.18)))
            }

            HStack(spacing: 4) {
                if let deltaFraction, let pct = usage.formatDeltaPercent(deltaFraction) {
                    Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(trendColor)
                    Text(pct)
                        .font(BrandFont.body(11, weight: .medium))
                        .foregroundStyle(trendColor)
                    Text("Since last week")
                        .font(BrandFont.body(11))
                        .foregroundStyle(Brand.faint)
                } else {
                    Text("Since last week")
                        .font(BrandFont.body(11))
                        .foregroundStyle(Brand.faint)
                    Text("—")
                        .font(BrandFont.body(11, weight: .medium))
                        .foregroundStyle(Brand.faint)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card)
        .overlay(
            RoundedRectangle(cornerRadius: Brand.cornerLg)
                .stroke(Brand.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerLg))
    }

    // MARK: - Settings

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Set up key")
                        .font(BrandFont.body(12, weight: .medium))
                        .foregroundStyle(Brand.faint)

                    ZStack(alignment: .topLeading) {
                        if sessionKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Paste your iBacalao session key")
                                .font(BrandFont.body(13))
                                .foregroundStyle(Brand.faint)
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $sessionKeyDraft)
                            .font(BrandFont.mono(12))
                            .foregroundStyle(Brand.bright)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 72)
                    }
                    .background(Brand.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.cornerMd)
                            .stroke(Brand.hairline, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))

                    HStack(spacing: 12) {
                        Button("Connect") { connectWithPastedKey() }
                            .buttonStyle(BrandGhostButtonStyle())
                            .disabled(sessionKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        BrandTextLink(title: "Get your key here") {
                            NSWorkspace.shared.open(Self.pricingURL)
                        }

                        Spacer(minLength: 0)
                    }

                    if !testMessage.isEmpty, navigation.tab == .settings {
                        Text(testMessage)
                            .font(BrandFont.body(11))
                            .foregroundStyle(
                                testStatus == .success ? Brand.success
                                    : (testStatus == .failure ? Brand.danger : Brand.muted)
                            )
                    }
                }

                captureSection
                voiceSection
                instructionsSection
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var apiStatusTitle: String {
        if let account {
            return account.email
        }
        if KeyStore.hasSessionToken() {
            return "Checking plan…"
        }
        return "Not signed in"
    }

    private var apiStatusSubtitle: String? {
        if let account {
            let plan = (account.plan ?? "").uppercased()
            if account.entitled {
                return plan.isEmpty ? "Pro / Ultra active" : "\(plan) active"
            }
            return "Needs Pro or Ultra"
        }
        if KeyStore.hasSessionToken() {
            return nil
        }
        return "Sign in with your iBacalao plan to use Marginalia."
    }

    private var apiStatusSubtitleColor: Color {
        if let account {
            return account.entitled ? Brand.success : Brand.warning
        }
        return Brand.muted
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CAPTURE")
                .font(BrandFont.mono(11, weight: .medium))
                .foregroundStyle(Brand.faint)
                .tracking(1.2)

            Toggle(isOn: $settings.demoRecordingModeEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Visible in screen recordings")
                        .font(BrandFont.body(13))
                        .foregroundStyle(Brand.bright)
                    Text("Shows the overlay in QuickTime, OBS, and screen shares.")
                        .font(BrandFont.body(11))
                        .foregroundStyle(Brand.muted)
                }
            }
            .toggleStyle(.switch)
            .tint(Brand.accent)
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("VOICE")
                .font(BrandFont.mono(11, weight: .medium))
                .foregroundStyle(Brand.faint)
                .tracking(1.2)

            BrandBoolPillSelector(title: "Speak tips aloud", isOn: $settings.spokenTipsEnabled)

            HStack(alignment: .center, spacing: 8) {
                BrandDropdownSelector(
                    options: availableVoices,
                    selection: voiceSelectionBinding,
                    emoji: { $0.emoji },
                    title: { $0.name },
                    subtitle: { $0.locale },
                    isEnabled: settings.spokenTipsEnabled,
                    maxListHeight: 220
                )
                .frame(maxWidth: .infinity)

                Button("Preview") {
                    TipSpeaker.shared.previewVoice(settings.spokenVoice)
                }
                .buttonStyle(BrandGhostButtonStyle())
                .disabled(!settings.spokenTipsEnabled)
            }
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INSTRUCTIONS")
                .font(BrandFont.mono(11, weight: .medium))
                .foregroundStyle(Brand.faint)
                .tracking(1.2)

            ZStack(alignment: .topLeading) {
                if settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Optional — sent with every tip")
                        .font(BrandFont.body(13))
                        .foregroundStyle(Brand.faint)
                        .padding(12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $settings.customInstructions)
                    .font(BrandFont.body(13))
                    .foregroundStyle(Brand.bright)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 88)
            }
            .background(Brand.card)
            .overlay(
                RoundedRectangle(cornerRadius: Brand.cornerMd)
                    .stroke(Brand.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
        }
    }

    // MARK: - Voice helpers

    private var voiceSelectionBinding: Binding<SystemVoice> {
        Binding(
            get: {
                availableVoices.first { $0.name == settings.spokenVoice }
                    ?? availableVoices.first
                    ?? SystemVoice(name: "Samantha", locale: "en_US")
            },
            set: { settings.spokenVoice = $0.name }
        )
    }

    private func ensureSpokenVoiceValid() {
        let names = Set(availableVoices.map(\.name))
        guard !names.contains(settings.spokenVoice) else { return }
        if names.contains("Samantha") {
            settings.spokenVoice = "Samantha"
        } else if let first = availableVoices.first {
            settings.spokenVoice = first.name
        }
    }

    private func runTest() {
        testStatus = .testing
        testMessage = "Testing…"
        Task {
            do {
                try await engine.testConnection()
                testStatus = .success
                testMessage = "Connection OK."
            } catch {
                testStatus = .failure
                testMessage = error.localizedDescription
            }
        }
    }

    private func connectWithPastedKey() {
        let token = Self.normalizedSessionToken(sessionKeyDraft)
        guard !token.isEmpty else {
            testStatus = .failure
            testMessage = "Paste a session key first."
            return
        }
        testStatus = .testing
        testMessage = "Connecting…"
        do {
            try KeyStore.saveSessionToken(token)
            sessionKeyDraft = ""
            refreshAccount(showResult: true)
        } catch {
            testStatus = .failure
            testMessage = error.localizedDescription
        }
    }

    /// Accepts a raw token or a full `ibacalao://auth?token=…` callback URL.
    private static func normalizedSessionToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed),
           url.scheme == "ibacalao",
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let token = items.first(where: { $0.name == "token" })?.value,
           !token.isEmpty {
            return token
        }
        return trimmed
    }

    private func startSignIn() {
        AppDelegate.shared?.dashboardWindow.orderOut(nil)
        AppDelegate.shared?.launchOverlay()
    }

    private func refreshAccount(showResult: Bool = false) {
        guard let token = KeyStore.loadSessionToken(),
              let url = URL(string: "\(LLMClient.resolvedNativeAPIBaseURL)/api/native/me") else {
            account = nil
            if showResult {
                testStatus = .failure
                testMessage = "No session key saved."
            }
            return
        }
        if showResult {
            testStatus = .testing
            testMessage = "Checking plan…"
        }
        Task {
            do {
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 401 {
                    account = nil
                    if showResult {
                        testStatus = .failure
                        testMessage = "Sign in inside the iBacalao window."
                    }
                    return
                }
                guard http.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let user = json["user"] as? [String: Any],
                      let email = user["email"] as? String else {
                    if showResult {
                        testStatus = .failure
                        testMessage = "Couldn't read account."
                    }
                    return
                }
                account = NativeAccount(
                    id: user["id"] as? String ?? "",
                    email: email,
                    plan: user["plan"] as? String,
                    planActive: (user["planActive"] as? Bool) ?? false,
                    entitled: (user["entitled"] as? Bool) ?? false,
                    credits: (user["credits"] as? Int)
                        ?? (user["credits"] as? NSNumber)?.intValue
                        ?? 0,
                    username: user["username"] as? String,
                    avatarB64: user["avatarB64"] as? String
                )
                if showResult {
                    testStatus = .success
                    testMessage = account?.entitled == true
                        ? "Connected."
                        : "Signed in — Pro or Ultra required."
                }
            } catch {
                dlog("[Auth] refresh failed: \(error.localizedDescription)")
                if showResult {
                    testStatus = .failure
                    testMessage = error.localizedDescription
                }
            }
        }
    }
}
