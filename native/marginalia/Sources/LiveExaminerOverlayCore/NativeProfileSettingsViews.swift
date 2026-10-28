import SwiftUI
import AppKit
import UserNotifications
import CryptoKit

struct NativeRouteBackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left")
                .font(BrandFont.body(12, weight: .medium))
        }
        .buttonStyle(BrandGhostButtonStyle())
    }
}

private struct NativeProfileSettingsHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(BrandFont.display(32, weight: .semibold))
                .tracking(-0.7)
                .foregroundStyle(Brand.bright)
            Text(subtitle)
                .font(BrandFont.body(13))
                .foregroundStyle(Brand.secondary)
        }
    }
}

private extension View {
    func profileSettingsPanel() -> some View {
        self
            .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.cornerLg))
            .overlay(RoundedRectangle(cornerRadius: Brand.cornerLg).stroke(Brand.hairline, lineWidth: 1))
    }
}

// MARK: - Profile

struct NativeProfilePage: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    @State private var account: NativeAccount?
    @State private var workspace: NativeProfileWorkspace?
    @State private var dispatch: NativeDispatchSnapshot?
    @State private var reminders: NativeRemindersResponse?
    @State private var workDays: NativeWorkDays?
    @State private var error: String?
    @State private var loading = false
    @State private var detail: Detail?

    let onOpenWeb: (String) -> Void

    private enum Detail: String, Identifiable {
        case assessments
        case plans
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    NativeProfileSettingsHeading(title: "You", subtitle: "Your IB work, progress and account in one place.")
                    Spacer()
                    Button("Account") { navigation.navigate(to: .account) }
                        .buttonStyle(BrandGhostButtonStyle())
                    Button("Settings") { navigation.navigate(to: .settings) }
                        .buttonStyle(BrandGhostButtonStyle())
                }

                if loading && account == nil {
                    ProgressView("Loading profile…")
                        .tint(Brand.accent)
                        .foregroundStyle(Brand.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .profileSettingsPanel()
                } else if let error, account == nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).font(BrandFont.body(12)).foregroundStyle(Brand.danger)
                        HStack(spacing: 10) {
                            Button("Try again") { Task { await load() } }.buttonStyle(BrandGhostButtonStyle())
                            Button("Sign in") { onOpenWeb("/native-login") }.buttonStyle(BrandPrimaryButtonStyle())
                        }
                    }
                    .padding(18)
                    .profileSettingsPanel()
                }

                if let account {
                    identityCard(account)
                }

                if let workspace {
                    summaryCard(workspace)
                    atlSkillsCard(workspace.reviews)
                    progressRows(workspace)
                }

                statusCard
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await load() }
        .sheet(item: $detail) { item in
            switch item {
            case .assessments:
                NativeAssessmentHistorySheet(reviews: workspace?.reviews ?? [], onClose: { detail = nil })
            case .plans:
                NativeStudyPlansSheet(plans: workspace?.plans ?? [], onClose: { detail = nil })
            }
        }
    }

    private func identityCard(_ account: NativeAccount) -> some View {
        HStack(spacing: 18) {
            NativeProfileAvatar(value: account.avatarB64, size: 76)
            VStack(alignment: .leading, spacing: 5) {
                Text(profileDisplayName(account))
                    .font(BrandFont.display(24, weight: .semibold))
                    .foregroundStyle(Brand.bright)
                if let username = account.username, !username.isEmpty {
                    Text("@\(username)").font(BrandFont.mono(11)).foregroundStyle(Brand.secondary)
                }
                Text("IB student").font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
            }
            Spacer()
            Text(account.planActive ? (account.plan ?? "free").uppercased() : "FREE")
                .font(BrandFont.mono(10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(account.planActive ? Brand.onAccent : Brand.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(account.planActive ? Brand.accent : Brand.active, in: Capsule())
        }
        .padding(20)
        .profileSettingsPanel()
    }

    private func summaryCard(_ workspace: NativeProfileWorkspace) -> some View {
        let average = workspace.reviews.isEmpty ? nil : Int((workspace.reviews.map(\.pct).reduce(0, +) / Double(workspace.reviews.count)).rounded())
        let subjects = Set(workspace.reviews.map(\.subject)).count
        return HStack(spacing: 0) {
            NativeProfileMetric(value: "\(workspace.reviews.count)", label: "REVIEWS")
            Divider().overlay(Brand.hairline).padding(.vertical, 8)
            NativeProfileMetric(value: average.map { "\($0)%" } ?? "—", label: "AVERAGE")
            Divider().overlay(Brand.hairline).padding(.vertical, 8)
            NativeProfileMetric(value: "\(subjects)", label: "SUBJECTS")
        }
        .padding(12)
        .profileSettingsPanel()
    }

    private func atlSkillsCard(_ reviews: [NativeProfileReview]) -> some View {
        let scores = nativeATLScores(reviews)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ATL skills").font(BrandFont.display(19, weight: .semibold)).foregroundStyle(Brand.bright)
                    Text(reviews.isEmpty ? "Your first reviewed draft unlocks this view." : "Based on \(reviews.count) review\(reviews.count == 1 ? "" : "s").")
                        .font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                }
                Spacer()
            }
            ForEach(NativeATLSkill.allCases, id: \.self) { skill in
                let score = scores[skill] ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(skill.rawValue).font(BrandFont.body(12, weight: .medium)).foregroundStyle(Brand.body)
                        Spacer()
                        Text(nativeATLLevel(score).uppercased()).font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.secondary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Brand.active)
                            Capsule().fill(Brand.accent).frame(width: proxy.size.width * max(0, min(1, score / 4)))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
        .padding(18)
        .profileSettingsPanel()
    }

    private func progressRows(_ workspace: NativeProfileWorkspace) -> some View {
        let average = workspace.reviews.isEmpty ? nil : Int((workspace.reviews.map(\.pct).reduce(0, +) / Double(workspace.reviews.count)).rounded())
        return VStack(alignment: .leading, spacing: 8) {
            Text("STUDY PROGRESS").font(BrandFont.mono(10, weight: .semibold)).tracking(0.8).foregroundStyle(Brand.muted)
            NativeProfileLinkRow(
                title: "Assessment history",
                note: workspace.reviews.isEmpty ? "No submissions yet" : "\(workspace.reviews.count) submissions · Avg \(average ?? 0)%",
                symbol: "chart.line.uptrend.xyaxis"
            ) { detail = .assessments }
            NativeProfileLinkRow(
                title: "Study plans",
                note: workspace.plans.isEmpty ? "No study plans yet" : "\(workspace.plans.count) active plan\(workspace.plans.count == 1 ? "" : "s")",
                symbol: "calendar.badge.clock"
            ) { detail = .plans }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONNECTED STUDY").font(BrandFont.mono(10, weight: .semibold)).tracking(0.8).foregroundStyle(Brand.muted)
            NativeProfileLinkRow(
                title: "School connection",
                note: schoolStatusNote,
                symbol: "building.columns"
            ) { navigation.navigate(to: .schoolConnection) }
            NativeProfileLinkRow(
                title: "This Mac",
                note: macStatusNote,
                symbol: "desktopcomputer"
            ) { navigation.navigate(to: .schoolConnection) }
            NativeProfileLinkRow(
                title: "Reminders",
                note: reminderStatusNote,
                symbol: "bell"
            ) { navigation.navigate(to: .reminders) }
            HStack {
                Image(systemName: "calendar").foregroundStyle(Brand.accent).frame(width: 20)
                Text("Work days").font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
                Spacer()
                Text(workDaysNote).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
            }
            .padding(14)
            .profileSettingsPanel()
        }
    }

    private var schoolStatusNote: String {
        guard let state = dispatch?.state else { return "Status unavailable" }
        if state.connection != "connected" { return "Not connected" }
        if let source = state.source, !source.isEmpty { return "Connected · \(source)" }
        return "Connected"
    }

    private var macStatusNote: String {
        guard let state = dispatch?.state else { return "Status unavailable" }
        let name = state.macName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if state.macOnline { return name.map { "Online · \($0)" } ?? "Online" }
        return name.map { "Offline · \($0)" } ?? "Not paired"
    }

    private var reminderStatusNote: String {
        guard let reminders else { return "Reminder status unavailable" }
        let active = reminders.reminders.filter { $0.status == "active" }.count
        return active == 0 ? "No active reminders" : "\(active) active reminder\(active == 1 ? "" : "s")"
    }

    private var workDaysNote: String {
        let labels = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        guard let days = workDays?.days, !days.isEmpty else { return "Not set" }
        return days.compactMap { labels.indices.contains($0) ? labels[$0] : nil }.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            async let accountValue = NativeAPIClient.account()
            async let workspaceValue = NativeAPIClient.profileWorkspace()
            let (loadedAccount, loadedWorkspace) = try await (accountValue, workspaceValue)
            account = loadedAccount
            workspace = loadedWorkspace
            dispatch = try? await NativeAPIClient.dispatchSnapshot()
            reminders = try? await NativeAPIClient.reminders()
            workDays = try? await NativeAPIClient.workDays()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NativeProfileMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(BrandFont.display(24, weight: .semibold)).foregroundStyle(Brand.bright)
            Text(label).font(BrandFont.mono(9, weight: .semibold)).tracking(0.7).foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct NativeProfileLinkRow: View {
    let title: String
    let note: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol).foregroundStyle(Brand.accent).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
                    Text(note).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.muted)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .profileSettingsPanel()
    }
}

private struct NativeProfileAvatar: View {
    let value: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let image = profileNSImage(value) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").resizable().scaledToFit().padding(size * 0.27).foregroundStyle(Brand.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Brand.active)
        .clipShape(Circle())
        .overlay(Circle().stroke(Brand.hairline, lineWidth: 1))
    }
}

private struct NativeAssessmentHistorySheet: View {
    let reviews: [NativeProfileReview]
    let onClose: () -> Void
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    NativeProfileSettingsHeading(title: "Assessment history", subtitle: reviews.isEmpty ? "Your first review will appear here." : "Your reviewed work, newest first.")
                    Spacer()
                    Button("Done", action: onClose).buttonStyle(BrandGhostButtonStyle())
                }
                if reviews.isEmpty {
                    Text("No assessments yet.").font(BrandFont.body(13)).foregroundStyle(Brand.secondary).padding(18).profileSettingsPanel()
                } else {
                    ForEach(reviews) { review in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profileSubjectLabel(review.subject)).font(BrandFont.body(14, weight: .semibold)).foregroundStyle(Brand.bright)
                                    Text("\(profileDate(review.date)) · \(review.level.uppercased())")
                                        .font(BrandFont.mono(9)).foregroundStyle(Brand.secondary)
                                }
                                Spacer()
                                Text("\(review.totalScore) / \(review.totalMax)").font(BrandFont.mono(13, weight: .semibold)).foregroundStyle(Brand.bright)
                            }
                            ProgressView(value: max(0, min(100, review.pct)), total: 100).tint(Brand.accent)
                            if let missing = review.missingCount, missing > 0 {
                                Text("\(missing) missing criterion item\(missing == 1 ? "" : "s")")
                                    .font(BrandFont.body(11)).foregroundStyle(Brand.danger)
                            }
                        }
                        .padding(16)
                        .profileSettingsPanel()
                    }
                    Button("Open review progress") {
                        onClose()
                        navigation.navigate(to: .progress)
                    }
                    .buttonStyle(BrandPrimaryButtonStyle())
                }
            }
            .padding(24)
        }
        .frame(width: 720, height: 620)
        .background(Brand.ground)
    }
}

private struct NativeStudyPlansSheet: View {
    let plans: [NativeProfilePlan]
    let onClose: () -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    NativeProfileSettingsHeading(title: "Study plans", subtitle: plans.isEmpty ? "No study plans yet." : "Deadlines, targets and planned steps.")
                    Spacer()
                    Button("Done", action: onClose).buttonStyle(BrandGhostButtonStyle())
                }
                ForEach(plans) { plan in
                    let tasks = plan.plan.schedule.filter { $0.type == "task" }
                    let done = tasks.filter { $0.status == "done" }.count
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            if expanded.contains(plan.id) { expanded.remove(plan.id) } else { expanded.insert(plan.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(profileSubjectLabel(plan.subject)) \(plan.plan.essayType)")
                                        .font(BrandFont.body(14, weight: .semibold)).foregroundStyle(Brand.bright)
                                    Text("\(plan.level.uppercased()) · \(plan.plan.intensity.uppercased())")
                                        .font(BrandFont.mono(9)).foregroundStyle(Brand.secondary)
                                }
                                Spacer()
                                Text("\(plan.plan.currentTotal) → \(plan.plan.targetTotal)").font(BrandFont.mono(12, weight: .semibold)).foregroundStyle(Brand.bright)
                                Image(systemName: expanded.contains(plan.id) ? "minus" : "plus").foregroundStyle(Brand.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        HStack {
                            Text("\(done) / \(tasks.count) tasks").font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                            Spacer()
                            Text("Due \(profileDate(plan.plan.deadline))").font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                        }
                        ProgressView(value: tasks.isEmpty ? 0 : Double(done), total: Double(max(tasks.count, 1))).tint(Brand.accent)
                        if expanded.contains(plan.id) {
                            Divider().overlay(Brand.hairline)
                            ForEach(plan.plan.schedule) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(profileDate(item.date).uppercased()).font(BrandFont.mono(9)).foregroundStyle(Brand.muted).frame(width: 75, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.type.uppercased() + (item.criterion.map { " · \($0.uppercased())" } ?? ""))
                                            .font(BrandFont.mono(8, weight: .semibold)).foregroundStyle(Brand.secondary)
                                        Text(item.instruction ?? "Plan step").font(BrandFont.body(11)).foregroundStyle(Brand.body)
                                    }
                                    Spacer()
                                    Text(item.status == "done" ? "✓" : item.status == "missed" ? "!" : "○").font(BrandFont.mono(11)).foregroundStyle(Brand.secondary)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .profileSettingsPanel()
                }
            }
            .padding(24)
        }
        .frame(width: 760, height: 640)
        .background(Brand.ground)
    }
}

// MARK: - Account

struct NativeAccountPage: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    @State private var account: NativeAccount?
    @State private var username = ""
    @State private var availability = UsernameAvailability.idle
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?

    let onOpenWeb: (String) -> Void

    private enum UsernameAvailability {
        case idle, checking, available, unavailable
    }

    private var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var usernameChanged: Bool {
        !normalizedUsername.isEmpty && normalizedUsername != (account?.username ?? "")
    }

    private var canSaveUsername: Bool {
        usernameChanged && availability == .available && !saving
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                NativeRouteBackButton(title: "Back") { navigation.goBack(fallback: .profile) }
                NativeProfileSettingsHeading(title: "Account", subtitle: "Profile, identity and account details.")

                if account == nil && error == nil {
                    ProgressView("Loading account…").tint(Brand.accent).foregroundStyle(Brand.secondary)
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading).profileSettingsPanel()
                }

                if let account {
                    VStack(spacing: 12) {
                        NativeProfileAvatar(value: account.avatarB64, size: 88)
                        Button(account.avatarB64 == nil ? "Add photo" : "Change photo") { Task { await choosePhoto() } }
                            .buttonStyle(BrandGhostButtonStyle())
                        if account.avatarB64 != nil {
                            Text("Profile photos may be reviewed before they appear in social surfaces.")
                                .font(BrandFont.body(11)).foregroundStyle(Brand.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .profileSettingsPanel()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("USERNAME").font(BrandFont.mono(10, weight: .semibold)).tracking(0.7).foregroundStyle(Brand.muted)
                        HStack(spacing: 4) {
                            Text("@").font(BrandFont.mono(13)).foregroundStyle(Brand.secondary)
                            TextField("username", text: $username)
                                .textFieldStyle(.plain)
                                .font(BrandFont.body(14))
                                .onChange(of: username) { _, value in
                                    let cleaned = String(value.lowercased().filter { !$0.isWhitespace }.prefix(20))
                                    if cleaned != value { username = cleaned }
                                }
                        }
                        .padding(.horizontal, 12).frame(height: 42).profileSettingsPanel()
                        Text(availabilityText).font(BrandFont.body(11)).foregroundStyle(availability == .unavailable ? Brand.danger : Brand.secondary)
                        HStack {
                            Button(saving ? "Saving…" : "Save username") { Task { await saveUsername() } }
                                .buttonStyle(BrandPrimaryButtonStyle()).disabled(!canSaveUsername)
                            if saved { Text("Saved").font(BrandFont.body(11, weight: .semibold)).foregroundStyle(Brand.success) }
                        }
                    }

                    NativeAccountFact(label: "EMAIL", value: account.email)
                    NativeAccountFact(label: "PLAN", value: account.planActive ? (account.plan ?? "free").uppercased() : "FREE")
                }

                if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(BrandFont.body(12)).foregroundStyle(Brand.danger)
                        if account == nil { Button("Sign in") { onOpenWeb("/native-login") }.buttonStyle(BrandPrimaryButtonStyle()) }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await load() }
        .task(id: normalizedUsername) { await checkUsername() }
    }

    private var availabilityText: String {
        switch availability {
        case .checking: return "Checking username…"
        case .available: return "Username available."
        case .unavailable: return "Use 3–20 lowercase letters, numbers or underscores; this username may also already be taken."
        case .idle: return "3–20 lowercase letters, numbers or underscores."
        }
    }

    private func load() async {
        do {
            let value = try await NativeAPIClient.account()
            account = value
            username = value.username ?? ""
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func checkUsername() async {
        saved = false
        guard usernameChanged else { availability = .idle; return }
        guard normalizedUsername.range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil else {
            availability = .unavailable
            return
        }
        availability = .checking
        do {
            try await Task.sleep(for: .milliseconds(400))
            try Task.checkCancellation()
            let result = try await NativeAPIClient.usernameAvailability(normalizedUsername)
            availability = result.available ? .available : .unavailable
        } catch is CancellationError {
            return
        } catch {
            availability = .idle
        }
    }

    private func saveUsername() async {
        guard canSaveUsername else { return }
        saving = true
        saved = false
        error = nil
        defer { saving = false }
        do {
            try await NativeAPIClient.claimUsername(normalizedUsername)
            let value = try await NativeAPIClient.account()
            account = value
            username = value.username ?? normalizedUsername
            availability = .idle
            saved = true
            try? await Task.sleep(for: .seconds(2))
            saved = false
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func choosePhoto() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let value = profileAvatarDataURL(url) else {
            error = "That image could not be prepared. Choose a JPEG, PNG or HEIC image."
            return
        }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await NativeAPIClient.saveAvatar(value)
            account = try await NativeAPIClient.account()
        } catch { self.error = error.localizedDescription }
    }
}

private struct NativeAccountFact: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(BrandFont.mono(10, weight: .semibold)).tracking(0.7).foregroundStyle(Brand.muted)
            Text(value).font(BrandFont.body(14)).foregroundStyle(Brand.bright)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .profileSettingsPanel()
    }
}

// MARK: - School connection

struct NativeSchoolConnectionPage: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    @State private var snapshot: NativeDispatchSnapshot?
    @State private var localStatus: SchoolPlatformStatus?
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var disconnectOpen = false

    let onOpenWeb: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NativeRouteBackButton(title: "Back") { navigation.goBack(fallback: .profile) }
                NativeProfileSettingsHeading(title: "School connection", subtitle: "Your school portal, this Mac and your phone in one status view.")

                if loading && snapshot == nil {
                    ProgressView("Loading school connection…").tint(Brand.accent).foregroundStyle(Brand.secondary)
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading).profileSettingsPanel()
                }
                if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(BrandFont.body(12)).foregroundStyle(Brand.danger)
                        HStack {
                            Button("Try again") { Task { await load() } }.buttonStyle(BrandGhostButtonStyle())
                            if snapshot == nil { Button("Sign in") { onOpenWeb("/native-login") }.buttonStyle(BrandPrimaryButtonStyle()) }
                        }
                    }
                    .padding(16).profileSettingsPanel()
                }

                if let snapshot {
                    schoolHero(snapshot)
                    healthCard(snapshot)
                    actionCard(snapshot)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await load() }
        .confirmationDialog("Disconnect school from this Mac?", isPresented: $disconnectOpen) {
            Button("Disconnect", role: .destructive) { disconnectSchool() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved school connection on this Mac. It will not delete your iBacalao account.")
        }
    }

    private func schoolHero(_ snapshot: NativeDispatchSnapshot) -> some View {
        let state = snapshot.state
        let connected = localStatus?.connected ?? (state.connection == "connected")
        let hasSyncError = !(state.lastSyncError?.isEmpty ?? true)
        let healthy = connected && state.macOnline && state.phonePaired && !hasSyncError
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text((localStatus?.schoolLabel ?? localStatus?.platformLabel ?? state.source ?? "School portal").uppercased())
                    .font(BrandFont.mono(10, weight: .semibold)).tracking(0.7).foregroundStyle(Brand.secondary)
                Spacer()
                Label(healthy ? "CONNECTED" : "NEEDS ATTENTION", systemImage: healthy ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(healthy ? Brand.success : Brand.warning)
            }
            Text(schoolHeadline(state: state, connected: connected))
                .font(BrandFont.display(28, weight: .semibold)).foregroundStyle(Brand.bright)
            Text(schoolBody(state: state, connected: connected))
                .font(BrandFont.body(13)).foregroundStyle(Brand.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LAST SYNC").font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                    Text(profileDateTime(state.lastSyncAt)).font(BrandFont.body(12, weight: .medium)).foregroundStyle(Brand.bright)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("ITEMS").font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                    Text("\(state.counts.total)").font(BrandFont.body(12, weight: .medium)).foregroundStyle(Brand.bright)
                }
            }
        }
        .padding(20).profileSettingsPanel()
    }

    private func healthCard(_ snapshot: NativeDispatchSnapshot) -> some View {
        let state = snapshot.state
        let schoolConnected = localStatus?.connected ?? (state.connection == "connected")
        return VStack(spacing: 0) {
            NativeSchoolHealthRow(symbol: "building.columns", title: localStatus?.platformLabel ?? state.source ?? "School portal", note: localStatus?.schoolLabel ?? "School connection", value: schoolConnected ? "CONNECTED" : "DISCONNECTED", ok: schoolConnected)
            NativeSchoolHealthRow(symbol: "desktopcomputer", title: state.macName ?? Host.current().localizedName ?? "This Mac", note: state.lastSeenAt.map { "Last seen \(profileDateTime($0))" } ?? "School bridge device", value: state.macOnline ? "ONLINE" : "OFFLINE", ok: state.macOnline)
            NativeSchoolHealthRow(symbol: "iphone", title: "Phone", note: "iBacalao mobile", value: state.phonePaired ? "PAIRED" : "NOT PAIRED", ok: state.phonePaired)
        }
        .profileSettingsPanel()
    }

    private func actionCard(_ snapshot: NativeDispatchSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(busy ? "Working…" : primaryActionTitle(snapshot.state)) { runPrimaryAction(snapshot.state) }
                .buttonStyle(BrandPrimaryButtonStyle()).disabled(busy)
            if SchoolWatcherService.shared.loadConnection() != nil {
                Button("Disconnect school from this Mac") { disconnectOpen = true }
                    .buttonStyle(.plain).font(BrandFont.body(11, weight: .semibold)).foregroundStyle(Brand.danger)
            }
            Text("Your school password and cookies stay in the browser profile on this Mac; iBacalao receives normalized academic records, not your login credentials.")
                .font(BrandFont.body(11)).foregroundStyle(Brand.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).profileSettingsPanel()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        localStatus = SchoolWatcherService.shared.loadStatus()
        do {
            snapshot = try await NativeAPIClient.dispatchSnapshot()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func primaryActionTitle(_ state: NativeDispatchState) -> String {
        guard SchoolWatcherService.shared.loadConnection() != nil else { return "Connect school" }
        switch localStatus?.actionReason {
        case "reauth_required", "challenge_paused", "connector_stale": return "Reconnect school"
        case "manual_learning_required": return "Finish setup"
        default: return state.macOnline ? "Open school portal" : "Reconnect school"
        }
    }

    private func runPrimaryAction(_ state: NativeDispatchState) {
        guard !busy else { return }
        busy = true
        error = nil
        do {
            if SchoolWatcherService.shared.loadConnection() == nil {
                try SchoolWatcherService.shared.openDiscovery { _ in
                    Task { @MainActor in await load(); busy = false }
                }
                return
            }
            switch localStatus?.actionReason {
            case "manual_learning_required":
                try SchoolWatcherService.shared.openLearning()
            case "reauth_required", "challenge_paused", "connector_stale":
                try SchoolWatcherService.shared.openReconnect {
                    Task { @MainActor in await load() }
                }
            default:
                if state.macOnline { try SchoolWatcherService.shared.openLearning() }
                else { try SchoolWatcherService.shared.openReconnect { Task { @MainActor in await load() } } }
            }
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func disconnectSchool() {
        SchoolWatcherService.shared.disconnect()
        localStatus = nil
        Task { await load() }
    }

    private func schoolHeadline(state: NativeDispatchState, connected: Bool) -> String {
        if !connected { return "Connect your school" }
        if !state.macOnline { return "Your Mac needs attention" }
        if !state.phonePaired { return "Pair your phone" }
        if state.lastSyncError != nil { return "School sync needs attention" }
        return "School is connected"
    }

    private func schoolBody(state: NativeDispatchState, connected: Bool) -> String {
        if !connected { return "Use the school portal in a normal browser window. iBacalao keeps the session local and watches for academic updates." }
        if !state.macOnline { return "Reconnect the saved school portal on this Mac so assignments, messages and deadlines can sync again." }
        if !state.phonePaired { return "The Mac connection is working. Pair iBacalao on your phone to see the same school context there." }
        if let syncError = state.lastSyncError, !syncError.isEmpty { return syncError }
        return "Assignments, messages, grades, submissions and deadlines can flow into your iBacalao study context."
    }
}

private struct NativeSchoolHealthRow: View {
    let symbol: String
    let title: String
    let note: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Brand.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(BrandFont.body(12, weight: .semibold)).foregroundStyle(Brand.bright)
                Text(note).font(BrandFont.body(10)).foregroundStyle(Brand.secondary)
            }
            Spacer()
            Circle().fill(ok ? Brand.success : Brand.warning).frame(width: 7, height: 7)
            Text(value).font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.secondary)
        }
        .padding(14)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 46) }
    }
}

// MARK: - Settings

struct NativeSettingsPage: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    let account: NativeAccount?
    let onOpenWeb: (String) -> Void
    let onSignOut: () -> Void
    let onSetAnalyticsConsent: (Bool) -> Void

    @State private var analyticsOn = UserDefaults.standard.string(forKey: "ibacalao:analytics-consent-v1") == "granted"
    @State private var schoolUpdatesOn = UserDefaults.standard.bool(forKey: NativeMacSchoolNotifications.preferenceKey)
    @State private var schoolUpdatesBusy = false
    @State private var schoolUpdatesNote: String?
    @State private var deleteOpen = false
    @State private var deleteBusy = false
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                NativeRouteBackButton(title: "Profile") { navigation.goBack(fallback: .profile) }
                NativeProfileSettingsHeading(title: "Settings", subtitle: "Account, preferences and privacy.")

                NativeSettingsGroup(title: "ACCOUNT") {
                    NativeSettingsLinkRow(title: "Account", note: account?.email ?? "Profile, identity and account details", symbol: "person.crop.circle") { navigation.navigate(to: .account) }
                    NativeSettingsLinkRow(title: "School connection", note: "School portal, this Mac and phone pairing", symbol: "laptopcomputer.and.iphone") { navigation.navigate(to: .schoolConnection) }
                }

                NativeSettingsGroup(title: "PREFERENCES") {
                    NativeSettingsLinkRow(title: "Customization", note: "Subjects, Today tuning and study preferences", symbol: "slider.horizontal.3") { navigation.navigate(to: .customization) }
                    NativeSettingsLinkRow(title: "Reminders", note: "Create and review reminders used by Today", symbol: "bell") { navigation.navigate(to: .reminders) }
                    NativeSettingsToggleRow(
                        title: "School updates",
                        note: schoolUpdatesNote ?? (schoolUpdatesOn ? "On for this Mac" : "Off for this Mac"),
                        symbol: "antenna.radiowaves.left.and.right",
                        value: $schoolUpdatesOn,
                        disabled: schoolUpdatesBusy,
                        onChange: { value in Task { await setSchoolUpdates(value) } }
                    )
                    NativeSettingsLinkRow(title: "Device accessibility", note: "Manage macOS Accessibility permission", symbol: "accessibility") {
                        AccessibilityTextExtractor.openSettingsForGrant()
                    }
                }

                NativeSettingsGroup(title: "PRIVACY") {
                    NativeSettingsLinkRow(title: "Privacy", note: "How iBacalao handles your data", symbol: "hand.raised") {
                        if let url = URL(string: "https://www.ibacalao.com/privacy") { NSWorkspace.shared.open(url) }
                    }
                    NativeSettingsToggleRow(
                        title: "Product analytics",
                        note: "Optional product usage analytics",
                        symbol: "chart.bar.xaxis",
                        value: $analyticsOn,
                        onChange: { value in setAnalytics(value) }
                    )
                    NativeSettingsLinkRow(title: "Help", note: "Email iBacalao support", symbol: "questionmark.circle") {
                        if let url = URL(string: "mailto:support@ibacalao.com?subject=iBacalao%20support") { NSWorkspace.shared.open(url) }
                    }
                }

                if account != nil {
                    HStack(spacing: 20) {
                        Button("Sign out") { Task { await signOut() } }
                            .buttonStyle(.plain).font(BrandFont.mono(10, weight: .bold)).foregroundStyle(Brand.secondary)
                        Button("Delete account") {
                            deleteError = nil
                            deleteOpen = true
                        }
                        .buttonStyle(.plain).font(BrandFont.mono(10, weight: .bold)).foregroundStyle(Brand.danger)
                    }
                    .padding(.top, 4)
                } else {
                    Button("Sign in") { onOpenWeb("/native-login") }.buttonStyle(BrandPrimaryButtonStyle())
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $deleteOpen) { deleteAccountSheet }
        .task { await refreshSchoolNotificationState() }
    }

    private var deleteAccountSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete account?").font(BrandFont.display(22, weight: .semibold)).foregroundStyle(Brand.bright)
            Text("This permanently removes your iBacalao account and data.")
                .font(BrandFont.body(13)).foregroundStyle(Brand.body).fixedSize(horizontal: false, vertical: true)
            if account?.planActive == true {
                Text("Deleting your account does not cancel an active App Store subscription. Manage or cancel it with Apple before deleting if you do not want billing to continue.")
                    .font(BrandFont.body(12, weight: .medium)).foregroundStyle(Brand.danger).fixedSize(horizontal: false, vertical: true)
                Button("Manage App Store subscription") {
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.plain).underline().foregroundStyle(Brand.accentTeal)
            }
            if let deleteError { Text(deleteError).font(BrandFont.body(12)).foregroundStyle(Brand.danger) }
            HStack {
                Spacer()
                Button("Cancel") { if !deleteBusy { deleteOpen = false } }.keyboardShortcut(.cancelAction).disabled(deleteBusy)
                Button(deleteBusy ? "Deleting…" : "Delete permanently") { Task { await deleteAccount() } }
                    .keyboardShortcut(.defaultAction).tint(Brand.danger).disabled(deleteBusy)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Brand.ground)
    }

    private func setAnalytics(_ enabled: Bool) {
        UserDefaults.standard.set(enabled ? "granted" : "denied", forKey: "ibacalao:analytics-consent-v1")
        onSetAnalyticsConsent(enabled)
    }

    private func refreshSchoolNotificationState() async {
        let state = await NativeMacSchoolNotifications.currentState()
        schoolUpdatesOn = state.enabled
        schoolUpdatesNote = state.note
    }

    private func setSchoolUpdates(_ enabled: Bool) async {
        schoolUpdatesBusy = true
        defer { schoolUpdatesBusy = false }
        let state = await NativeMacSchoolNotifications.setEnabled(enabled)
        schoolUpdatesOn = state.enabled
        schoolUpdatesNote = state.note
    }

    private func signOut() async {
        _ = await NativeMacSchoolNotifications.setEnabled(false)
        await NativeAPIClient.signOut()
        onSignOut()
    }

    private func deleteAccount() async {
        deleteBusy = true
        deleteError = nil
        defer { deleteBusy = false }
        do {
            try await NativeAPIClient.deleteAccount()
            _ = await NativeMacSchoolNotifications.setEnabled(false)
            deleteOpen = false
            onSignOut()
        } catch { deleteError = error.localizedDescription }
    }
}

private struct NativeSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(BrandFont.mono(10, weight: .semibold)).tracking(0.9).foregroundStyle(Brand.muted)
            VStack(spacing: 0) { content }
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.cornerLg))
                .overlay(RoundedRectangle(cornerRadius: Brand.cornerLg).stroke(Brand.hairline, lineWidth: 1))
        }
    }
}

private struct NativeSettingsLinkRow: View {
    let title: String
    let note: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Brand.accent).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
                    Text(note).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 48) }
    }
}

private struct NativeSettingsToggleRow: View {
    let title: String
    let note: String
    let symbol: String
    @Binding var value: Bool
    var disabled = false
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Brand.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
                Text(note).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { value },
                set: { next in
                    value = next
                    onChange(next)
                }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(disabled)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 48) }
    }
}

@MainActor
enum NativeMacSchoolNotifications {
    static let preferenceKey = "ibacalao:school-updates-enabled-mac-v1"
    private static let signatureKey = "ibacalao:school-updates-signature-mac-v1"
    private static var monitorTask: Task<Void, Never>?

    struct State {
        let enabled: Bool
        let note: String?
    }

    static func installDelegate() {
        UNUserNotificationCenter.current().delegate = AppDelegate.shared
    }

    static func startIfEnabled() {
        guard UserDefaults.standard.bool(forKey: preferenceKey) else { return }
        Task { _ = await currentState() }
    }

    static func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    static func currentState() async -> State {
        let preferred = UserDefaults.standard.bool(forKey: preferenceKey)
        guard preferred else { return State(enabled: false, note: nil) }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            startMonitor()
            return State(enabled: true, note: "On for this Mac")
        case .denied:
            UserDefaults.standard.set(false, forKey: preferenceKey)
            stop()
            return State(enabled: false, note: "Notifications are disabled in macOS Settings")
        default:
            stop()
            return State(enabled: false, note: nil)
        }
    }

    static func setEnabled(_ enabled: Bool) async -> State {
        guard enabled else {
            UserDefaults.standard.set(false, forKey: preferenceKey)
            UserDefaults.standard.removeObject(forKey: signatureKey)
            stop()
            return State(enabled: false, note: "Off for this Mac")
        }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            UserDefaults.standard.set(granted, forKey: preferenceKey)
            if granted {
                startMonitor()
                return State(enabled: true, note: "On for this Mac")
            }
            stop()
            return State(enabled: false, note: "Permission denied — enable notifications in macOS Settings")
        } catch {
            UserDefaults.standard.set(false, forKey: preferenceKey)
            stop()
            return State(enabled: false, note: "Could not enable notifications")
        }
    }

    private static func startMonitor() {
        guard monitorTask == nil || monitorTask?.isCancelled == true else { return }
        monitorTask = Task {
            while !Task.isCancelled {
                await checkForSchoolChanges()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
            }
        }
    }

    private static func checkForSchoolChanges() async {
        guard UserDefaults.standard.bool(forKey: preferenceKey), KeyStore.hasSessionToken() else { return }
        do {
            let snapshot = try await NativeAPIClient.dispatchSnapshot()
            guard let records = snapshot.records else { return }
            let nextSignature = signature(for: records)
            let previousSignature = UserDefaults.standard.string(forKey: signatureKey)
            UserDefaults.standard.set(nextSignature, forKey: signatureKey)
            guard let previousSignature, previousSignature != nextSignature else { return }

            let content = UNMutableNotificationContent()
            content.title = "School update"
            content.body = "Your school data changed. Open iBacalao to review it."
            content.sound = .default
            content.userInfo = ["destination": "/school-connection"]
            let request = UNNotificationRequest(
                identifier: "school-update-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        } catch {
            // A transient API or auth failure must not disable the student's opt-in.
        }
    }

    private static func signature(for records: [NativeDispatchRecord]) -> String {
        let material = records
            .map { "\($0.source)|\($0.kind)|\($0.id)|\($0.revision ?? 1)" }
            .sorted()
            .joined(separator: "\n")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            let destination = response.notification.request.content.userInfo["destination"] as? String
            if destination == "/school-connection" {
                _ = NativeWorkspaceNavigation.shared.openNativePath("/school-connection")
                AppDelegate.shared?.shellWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            completionHandler()
        }
    }
}

// MARK: - Shared profile helpers

private enum NativeATLSkill: String, CaseIterable {
    case thinking = "Thinking Skills"
    case communication = "Communication Skills"
    case research = "Research Skills"
    case selfManagement = "Self-Management Skills"
    case social = "Social Skills"
}

private func nativeATLScores(_ reviews: [NativeProfileReview]) -> [NativeATLSkill: Double] {
    var totals = Dictionary(uniqueKeysWithValues: NativeATLSkill.allCases.map { ($0, (sum: 0.0, count: 0.0)) })
    for review in reviews {
        for criterion in review.criteria where criterion.scoreMax > 0 {
            guard let skill = nativeATLSkill(for: criterion.name) else { continue }
            let existing = totals[skill] ?? (0, 0)
            totals[skill] = (existing.sum + Double(criterion.score) / Double(criterion.scoreMax), existing.count + 1)
        }
    }
    var values: [NativeATLSkill: Double] = [:]
    for skill in NativeATLSkill.allCases where skill != .social {
        let value = totals[skill] ?? (0, 0)
        values[skill] = value.count == 0 ? 0 : min(4, (value.sum / value.count) * 4)
    }
    let subjectCount = Set(reviews.map(\.subject)).count
    values[.social] = min(4, min(1, Double(subjectCount) * 0.25 + Double(reviews.count) * 0.08) * 4)
    return values
}

private func nativeATLSkill(for name: String) -> NativeATLSkill? {
    let value = name.lowercased()
    let patterns: [(String, NativeATLSkill)] = [
        ("research.?design|exploration|research.?question|background|context|source|method", .research),
        ("analysis|evaluation|reflection|conclusion|discussion|mathematical.?present|data.?anal", .thinking),
        ("communication|mathematical.?comm|language|formal|expression|structure|presentation", .communication),
        ("personal.?engagement|engagement|planning|organization|process|individual", .selfManagement),
    ]
    return patterns.first(where: { value.range(of: $0.0, options: .regularExpression) != nil })?.1
}

private func nativeATLLevel(_ score: Double) -> String {
    let levels = ["Unaware", "Aware", "Working", "Practitioner", "Expert"]
    return levels[max(0, min(4, Int(score.rounded())))]
}

private func profileDisplayName(_ account: NativeAccount) -> String {
    if let username = account.username, username.rangeOfCharacter(from: .letters) != nil {
        return username.replacingOccurrences(of: "_", with: " ").capitalized
    }
    let local = account.email.split(separator: "@").first.map(String.init) ?? "Student"
    let cleaned = local.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    return cleaned.rangeOfCharacter(from: .letters) == nil ? "IB student" : cleaned.capitalized
}

private func profileNSImage(_ value: String?) -> NSImage? {
    guard let value, let comma = value.firstIndex(of: ",") else { return nil }
    let payload = String(value[value.index(after: comma)...])
    guard let data = Data(base64Encoded: payload) else { return nil }
    return NSImage(data: data)
}

@MainActor
private func profileAvatarDataURL(_ url: URL) -> String? {
    guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else { return nil }
    let side = min(source.size.width, source.size.height)
    let sourceRect = NSRect(
        x: (source.size.width - side) / 2,
        y: (source.size.height - side) / 2,
        width: side,
        height: side
    )
    let image = NSImage(size: NSSize(width: 256, height: 256))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256), from: sourceRect, operation: .copy, fraction: 1)
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return nil }
    return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
}

private func profileSubjectLabel(_ id: String) -> String {
    if let subject = NativeSelectableSubject.catalog.first(where: { $0.id == id }) { return subject.label }
    switch id.lowercased() {
    case "tok": return "Theory of Knowledge"
    case "ee": return "Extended Essay"
    case "cas": return "CAS"
    default: return id.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private func profileDate(_ value: String) -> String {
    guard let date = parseProfileDate(value) else { return value }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
}

private func profileDateTime(_ value: String?) -> String {
    guard let value, let date = parseProfileDate(value) else { return "Not synced yet" }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}

private func parseProfileDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    if let date = ISO8601DateFormatter().date(from: value) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
}
