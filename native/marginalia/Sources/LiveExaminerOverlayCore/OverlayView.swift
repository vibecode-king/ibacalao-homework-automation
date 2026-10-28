import SwiftUI

struct OverlayView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: FeedbackEngine

    @State private var chatInput = ""
    @FocusState private var chatFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            permissionBanners
            statusRow
            sentenceFixCard
            Divider().opacity(0.35)
            chatSection
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 360)
        // Glass is the window host — keep SwiftUI transparent so blur shows through.
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .onAppear {
            DispatchQueue.main.async { chatFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlayDidBecomeKey)) { _ in
            DispatchQueue.main.async { chatFocused = true }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Brand.secondary)
                .frame(width: 6, height: 6)
            Text("iBacalao")
                .font(BrandFont.display(13, weight: .semibold))
                .foregroundStyle(Brand.bright)
                .tracking(-0.3)
            Text("⌘RETURN")
                .font(BrandFont.mono(9))
                .foregroundStyle(Brand.faint)
                .tracking(0.8)
            Spacer()
            spokenToggle
            Button("Check") { engine.checkNow() }
                .font(BrandFont.body(11, weight: .medium))
                .foregroundStyle(Brand.secondary)
                .buttonStyle(.plain)
                .disabled(engine.isBusy)
            Button("Practice") { engine.practiceTip() }
                .font(BrandFont.body(11, weight: .medium))
                .foregroundStyle(Brand.muted)
                .buttonStyle(.plain)
                .disabled(engine.isBusy)
                .help("Show a sample tip — no screen read needed. For demos/recordings.")
            Button(action: { AppDelegate.shared?.hideOverlay() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.muted)
        }
    }

    /// Mini speak on/off — same preference as Settings → Speak tips aloud.
    private var spokenToggle: some View {
        Button {
            settings.spokenTipsEnabled.toggle()
            if !settings.spokenTipsEnabled {
                TipSpeaker.shared.reset()
            }
        } label: {
            Image(systemName: settings.spokenTipsEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(settings.spokenTipsEnabled ? Brand.accent : Brand.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(settings.spokenTipsEnabled ? "Spoken tips on — click to mute" : "Spoken tips off — click to enable")
        .accessibilityLabel(settings.spokenTipsEnabled ? "Mute spoken tips" : "Enable spoken tips")
    }

    @ViewBuilder
    private var permissionBanners: some View {
        if !engine.accessibilityTrusted {
            banner(
                message: "Enable Accessibility for iBacalao to read your writing.",
                actionTitle: "Open Settings",
                action: { AccessibilityTextExtractor.openSettingsForGrant() }
            )
        }
        if let mismatch = engine.subjectMismatch {
            banner(
                message: "This looks like \(mismatch.detected.label), not \(settings.subject.label) — switch?",
                actionTitle: "Switch",
                action: { engine.acceptSubjectMismatch() },
                onDismiss: { engine.dismissSubjectMismatch() }
            )
        }
    }

    private func banner(
        message: String,
        actionTitle: String,
        action: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Brand.warning)
                .font(.system(size: 10))
            Text(message)
                .font(BrandFont.body(11))
                .foregroundStyle(Brand.body)
            Spacer()
            Button(actionTitle, action: action)
                .font(BrandFont.body(11, weight: .medium))
                .foregroundStyle(Brand.accentTeal)
                .buttonStyle(.plain)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.muted)
            }
        }
        .padding(8)
        .background(Brand.active)
        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
    }

    @ViewBuilder
    private var statusRow: some View {
        if let app = engine.lastCapturedApp, !engine.lastTipWasPractice {
            Text("LAST · \(app.uppercased())")
                .font(BrandFont.mono(9))
                .foregroundStyle(Brand.faint)
                .tracking(0.6)
        }
        statusText
            .font(BrandFont.body(12))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusText: some View {
        switch engine.stage {
        case .idle, .tip:
            Text("Write in any app, then press ⌘Return.")
                .foregroundStyle(Brand.muted)
        case .capturing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(Brand.accent)
                Text("Reading your document…")
                    .foregroundStyle(Brand.secondary)
            }
        case .noNewText:
            Text("No new writing since the last check.")
                .foregroundStyle(Brand.secondary)
        case .streaming:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(Brand.accent)
                Text("Coach thinking…")
                    .foregroundStyle(Brand.secondary)
            }
        case .tooShort:
            Text("Only a little new text — keep writing, then try again.")
                .foregroundStyle(Brand.secondary)
        case .couldNotRead:
            Text(FeedbackEngine.couldNotReadMessage)
                .foregroundStyle(Brand.warning)
        case .error(let message):
            Text(message).foregroundStyle(Brand.danger)
        }
    }

    @ViewBuilder
    private var sentenceFixCard: some View {
        if case .tip = engine.stage,
           let tip = engine.lastParsedTip,
           let fix = tip.sentenceFix(in: engine.lastTipSourceText) {
            SentenceFixCard(tip: tip, fix: fix)
        }
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chat")
                .font(BrandFont.body(11, weight: .medium))
                .foregroundStyle(Brand.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(engine.chatMessages) { message in
                            chatBubble(message)
                                .id(message.id)
                        }
                        if engine.chatStreaming {
                            streamingBubble
                                .id("streaming")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 140, maxHeight: 220)
                .onChange(of: engine.chatStreamPartial) { _, _ in
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
                .onChange(of: engine.chatMessages.count) { _, _ in
                    if let last = engine.chatMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            BrandGlassChatField(
                placeholder: "Ask about your draft…",
                text: $chatInput,
                onSubmit: sendChat,
                focused: $chatFocused
            )
            .disabled(engine.chatStreaming)
            .opacity(engine.chatStreaming ? 0.7 : 1)
            .contentShape(Rectangle())
            .onTapGesture { chatFocused = true }
        }
    }

    private var streamingBubble: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("COACH")
                .font(BrandFont.mono(9))
                .foregroundStyle(Brand.faint)
                .tracking(0.6)
            HStack(alignment: .top, spacing: 6) {
                ProgressView().controlSize(.mini).tint(Brand.accent)
                Text(engine.chatStreamPartial.isEmpty ? "…" : engine.chatStreamPartial)
                    .font(BrandFont.body(12))
                    .foregroundStyle(Brand.body)
            }
            .padding(8)
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chatBubble(_ message: ChatTurn) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
            Text(message.role == .user ? "YOU" : "COACH")
                .font(BrandFont.mono(9))
                .foregroundStyle(Brand.faint)
                .tracking(0.6)
            Text(message.content)
                .font(BrandFont.body(12))
                .foregroundStyle(Brand.bright)
                .padding(8)
                .background(message.role == .user ? Brand.accent.opacity(0.18) : .white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.cornerMd)
                        .stroke(message.role == .user ? Brand.accent.opacity(0.35) : Color.white.opacity(0.12), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatInput = ""
        Task { await engine.sendChat(text) }
    }
}
