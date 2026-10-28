import SwiftUI
import AppKit
import AuthenticationServices

final class NativeAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = NativeAuthPresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        AppDelegate.shared?.dashboardWindow ?? ASPresentationAnchor()
    }
}

enum DashboardTab: String, CaseIterable, Identifiable {
    case launch
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .launch: return "Launch"
        case .settings: return "Settings"
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

    @State private var account: NativeAccount?
    @State private var authSession: ASWebAuthenticationSession?
    @State private var testStatus: TestStatus = .idle
    @State private var testMessage = ""
    @State private var availableVoices: [SystemVoice] = []

    private enum TestStatus {
        case idle, testing, success, failure
    }

    private static let pricingURL = URL(string: "https://ibacalao.com/pricing")!

    var body: some View {
        ZStack {
            Brand.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                tabBar
                Rectangle().fill(Brand.hairline).frame(height: 1)
                Group {
                    switch navigation.tab {
                    case .launch:
                        launchPage
                    case .settings:
                        settingsPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 440, minHeight: 520)
        .preferredColorScheme(.dark)
        // Clear of traffic lights when title bar is transparent.
        .padding(.top, 20)
        .onAppear {
            availableVoices = TipSpeaker.availableVoices(matchingDeviceLanguages: true)
            ensureSpokenVoiceValid()
            refreshAccount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeAuthDidChange)) { _ in
            refreshAccount()
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DashboardTab.allCases) { tab in
                Button {
                    navigation.tab = tab
                } label: {
                    VStack(spacing: 10) {
                        Text(tab.label)
                            .font(BrandFont.body(13, weight: .medium))
                            .foregroundStyle(navigation.tab == tab ? Brand.bright : Brand.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                        Rectangle()
                            .fill(navigation.tab == tab ? Brand.bright : Color.clear)
                            .frame(height: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Launch

    private var launchPage: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    BrandLogo(height: 40)
                    Text("Press Launch, then ⌘Return in your writing app for a tip.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(Brand.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 8) {
                    Text("SUBJECT")
                        .font(BrandFont.mono(11, weight: .medium))
                        .foregroundStyle(Brand.faint)
                        .tracking(1.2)
                    BrandDropdownSelector(
                        options: Array(CoachingSubject.allCases),
                        selection: $settings.subject,
                        emoji: { $0.emoji },
                        title: { $0.label },
                        maxListHeight: 320
                    )
                    Text("Tips use this for IB context. Change anytime.")
                        .font(BrandFont.body(11))
                        .foregroundStyle(Brand.faint)
                }
                .padding(.horizontal, 8)

                if !engine.accessibilityTrusted {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Brand.danger)
                                .frame(width: 6, height: 6)
                            Text("Accessibility not granted — Check can't read your document.")
                                .font(BrandFont.body(11))
                                .foregroundStyle(Brand.faint)
                        }
                        Button("Grant Accessibility") {
                            AccessibilityTextExtractor.openSettingsForGrant()
                        }
                        .buttonStyle(.link)
                        .font(BrandFont.body(12))
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Brand.success)
                            .frame(width: 6, height: 6)
                        Text("Accessibility granted")
                            .font(BrandFont.body(11))
                            .foregroundStyle(Brand.faint)
                    }
                    .frame(maxWidth: .infinity)
                }

                Button("Launch") {
                    AppDelegate.shared?.launchOverlay()
                }
                .buttonStyle(BrandLiquidGlassButtonStyle())
                .padding(.horizontal, 8)

                if case .couldNotRead = engine.stage {
                    Text(FeedbackEngine.couldNotReadMessage)
                        .font(BrandFont.body(12))
                        .foregroundStyle(Brand.warning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                } else if case .error(let message) = engine.stage {
                    Text(message)
                        .font(BrandFont.body(12))
                        .foregroundStyle(Brand.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                } else if case .tip(let tip, _) = engine.stage {
                    Text(tip)
                        .font(BrandFont.body(12))
                        .foregroundStyle(Brand.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if case .noNewText = engine.stage {
                    Text("No new writing since the last check.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(Brand.secondary)
                } else if case .streaming = engine.stage {
                    Text("Coach thinking…")
                        .font(BrandFont.body(12))
                        .foregroundStyle(Brand.secondary)
                }

                VStack(spacing: 10) {
                    Button("Test connection") { runTest() }
                        .buttonStyle(BrandGhostButtonStyle())
                        .disabled(testStatus == .testing)
                    if !testMessage.isEmpty {
                        Text(testMessage)
                            .font(BrandFont.body(12))
                            .foregroundStyle(
                                testStatus == .success ? Brand.success
                                    : (testStatus == .failure ? Brand.danger : Brand.muted)
                            )
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 8)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Settings

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(BrandFont.display(22, weight: .semibold))
                        .foregroundStyle(Brand.bright)
                        .tracking(-0.5)
                    Text("Preferences for tips and chat.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(Brand.secondary)
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Account")
                        .font(BrandFont.body(12, weight: .medium))
                        .foregroundStyle(Brand.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        if let account {
                            Text("Signed in as \(account.email)")
                                .font(BrandFont.body(13))
                                .foregroundStyle(Brand.bright)
                            Text(account.entitled ? "Pro/Ultra access active." : "Upgrade to Pro or Ultra to use Marginalia.")
                                .font(BrandFont.body(12))
                                .foregroundStyle(account.entitled ? Brand.success : Brand.warning)
                        } else if KeyStore.hasSessionToken() {
                            Text("Signed in. Checking plan...")
                                .font(BrandFont.body(13))
                                .foregroundStyle(Brand.secondary)
                        } else {
                            Text("Sign in with a Pro or Ultra iBacalao account.")
                                .font(BrandFont.body(13))
                                .foregroundStyle(Brand.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.cornerMd)
                            .stroke(Brand.hairline, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))

                    HStack(spacing: 8) {
                        Button(account == nil ? "Sign in" : "Refresh") {
                            if account == nil {
                                startSignIn()
                            } else {
                                refreshAccount()
                            }
                        }
                        .buttonStyle(BrandGhostButtonStyle())
                        if account != nil || KeyStore.hasSessionToken() {
                            Button("Sign out") {
                                KeyStore.deleteSession()
                                account = nil
                                testStatus = .idle
                                testMessage = ""
                            }
                            .buttonStyle(BrandGhostButtonStyle())
                        }
                        if account?.entitled == false {
                            Button("Upgrade") {
                                NSWorkspace.shared.open(Self.pricingURL)
                            }
                            .buttonStyle(BrandGhostButtonStyle())
                        }
                    }
                    Text("The app uses your iBacalao session. Provider API keys are not accepted.")
                        .font(BrandFont.body(11))
                        .foregroundStyle(Brand.faint)
                }

                BrandBoolPillSelector(title: "Speak tips aloud", isOn: $settings.spokenTipsEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice")
                        .font(BrandFont.body(12, weight: .medium))
                        .foregroundStyle(Brand.secondary)
                    HStack(alignment: .top, spacing: 8) {
                        BrandDropdownSelector(
                            options: availableVoices,
                            selection: voiceSelectionBinding,
                            emoji: { $0.emoji },
                            title: { $0.name },
                            subtitle: { $0.locale },
                            isEnabled: settings.spokenTipsEnabled,
                            maxListHeight: 260
                        )
                        .frame(maxWidth: .infinity)

                        Button("Preview") {
                            TipSpeaker.shared.previewVoice(settings.spokenVoice)
                        }
                        .buttonStyle(BrandGhostButtonStyle())
                        .disabled(!settings.spokenTipsEnabled)
                        .padding(.top, 2)
                    }
                    Text(voiceHelpText)
                        .font(BrandFont.body(11))
                        .foregroundStyle(Brand.faint)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Instructions")
                        .font(BrandFont.body(12, weight: .medium))
                        .foregroundStyle(Brand.secondary)
                    ZStack(alignment: .topLeading) {
                        if settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Optional — sent with every tip and chat reply")
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
                            .frame(minHeight: 100)
                    }
                    .background(Brand.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.cornerMd)
                            .stroke(Brand.hairline, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                }

                if account?.entitled == false {
                    Button("Upgrade") {
                        NSWorkspace.shared.open(Self.pricingURL)
                    }
                    .buttonStyle(BrandLiquidGlassButtonStyle())
                    .padding(.top, 8)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var voiceHelpText: String {
        let langs = TipSpeaker.devicePreferredLanguageCodes().joined(separator: ", ")
        return "Voices for your Mac languages (\(langs)). Download more in System Settings → Accessibility → Spoken Content."
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

    private func startSignIn() {
        guard let url = URL(string: "\(LLMClient.defaultNativeAPIBaseURL)/native-login") else {
            testStatus = .failure
            testMessage = "Invalid sign-in URL."
            return
        }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "ibacalao") { callbackURL, error in
            Task { @MainActor in
                if let callbackURL {
                    AppDelegate.shared?.handleAuthCallback(callbackURL)
                    refreshAccount()
                } else if let error {
                    testStatus = .failure
                    testMessage = error.localizedDescription
                }
                authSession = nil
            }
        }
        session.presentationContextProvider = NativeAuthPresentationContextProvider.shared
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() {
            authSession = nil
            testStatus = .failure
            testMessage = "Couldn't start sign-in."
        }
    }

    private func refreshAccount() {
        guard let token = KeyStore.loadSessionToken(),
              let url = URL(string: "\(LLMClient.defaultNativeAPIBaseURL)/api/native/me") else {
            account = nil
            return
        }
        Task {
            do {
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 401 {
                    KeyStore.deleteSession()
                    account = nil
                    return
                }
                guard http.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let user = json["user"] as? [String: Any],
                      let email = user["email"] as? String else { return }
                account = NativeAccount(
                    email: email,
                    plan: user["plan"] as? String,
                    entitled: (user["entitled"] as? Bool) ?? false
                )
            } catch {
                dlog("[Auth] refresh failed: \(error.localizedDescription)")
            }
        }
    }
}
