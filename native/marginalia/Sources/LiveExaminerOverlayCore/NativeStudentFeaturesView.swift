import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

enum NativeWorkspaceTab: String, CaseIterable, Hashable, Identifiable {
    case dashboard
    case today
    case todo
    case week
    case reminders
    case progress
    case yourIB
    case toolsInbox
    case toolsCAS
    case toolsCASProject
    case toolsPractice
    case toolsMarkband
    case termle
    case toolsCamera
    case toolsAudio
    case toolsMarginalia
    case draftEditor
    case study
    case profile
    case account
    case schoolConnection
    case customization
    case sync
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Progress"
        case .today: return "Today"
        case .todo: return "To-do"
        case .week: return "Your week"
        case .reminders: return "Reminders"
        case .progress: return "Draft progress"
        case .yourIB: return "Your IB"
        case .toolsInbox: return "Inbox"
        case .toolsCAS: return "CAS"
        case .toolsCASProject: return "CAS project"
        case .toolsPractice: return "Quick practice"
        case .toolsMarkband: return "Mark the Band"
        case .termle: return "Termle"
        case .toolsCamera: return "Camera feedback"
        case .toolsAudio: return "Audio to notes"
        case .toolsMarginalia: return "Marginalia"
        case .draftEditor: return "Draft editor"
        case .study: return "Study"
        case .profile: return "Profile"
        case .account: return "Account"
        case .schoolConnection: return "School connection"
        case .customization: return "Customization"
        case .sync: return "Sync phone"
        case .settings: return "Settings"
        }
    }
}

struct NativeTodoContext: Equatable {
    var taskId: String = ""
    var missionDecisionId: String = ""
    var contextId: String?
    var title: String = "This task"
    var source: String?
}

@MainActor
final class NativeWorkspaceNavigation: ObservableObject {
    static let shared = NativeWorkspaceNavigation()

    @Published var selection: NativeWorkspaceTab = .today
    @Published var isShowing = false
    @Published var todo = NativeTodoContext()
    @Published var activeWorkContext: NativeWorkContext?
    @Published var routeQuery: [String: String] = [:]
    private var history: [NativeWorkspaceTab] = []

    func canOpenNativePath(_ path: String) -> Bool {
        route(for: path) != nil
    }

    @discardableResult
    func openNativePath(_ path: String) -> Bool {
        guard let (tab, todoContext) = route(for: path) else { return false }
        routeQuery = Self.query(for: path)
        if let todoContext { todo = todoContext }
        history.removeAll()
        selection = tab
        isShowing = true
        return true
    }

    func show(_ tab: NativeWorkspaceTab) {
        if selection != tab { history.append(selection) }
        selection = tab
        routeQuery = [:]
        isShowing = true
    }

    private static func query(for path: String) -> [String: String] {
        guard let components = URLComponents(string: "https://ibacalao.invalid\(path)") else { return [:] }
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func route(for path: String) -> (NativeWorkspaceTab, NativeTodoContext?)? {
        guard let components = URLComponents(string: "https://ibacalao.invalid\(path)") else { return nil }
        let query = Self.query(for: path)

        switch components.path {
        case "/dashboard":
            if query["view"] == "dispatch" { return nil }
            return (.dashboard, nil)
        case "/today": return (.today, nil)
        case "/week", "/dashboard/week": return (.week, nil)
        case "/reminders": return (.reminders, nil)
        case "/todo":
            return (.todo, NativeTodoContext(
                taskId: query["taskId"] ?? "",
                missionDecisionId: query["missionDecisionId"] ?? "",
                contextId: query["contextId"],
                title: query["title"] ?? "This task",
                source: query["source"]
            ))
        case "/review-progress", "/dashboard/review-progress": return (.progress, nil)
        case "/dashboard/your-ib": return (.yourIB, nil)
        case "/tools/inbox", "/tools/hub/inbox": return (.toolsInbox, nil)
        case "/tools/cas-log": return (.toolsCAS, nil)
        case "/tools/cas-project": return (.toolsCASProject, nil)
        case "/tools/practice": return (.toolsPractice, nil)
        case "/tools/markband": return (.toolsMarkband, nil)
        case "/termle": return (.termle, nil)
        case "/tool/camera", "/tools/camera", "/tools/hub/camera": return (.toolsCamera, nil)
        case "/tool/audio", "/tools/audio", "/tools/hub/audio": return (.toolsAudio, nil)
        case "/tool/marginalia", "/tools/hub/marginalia": return (.toolsMarginalia, nil)
        case "/draft-editor": return (.draftEditor, nil)
        case "/study": return (.study, nil)
        case "/profile": return (.profile, nil)
        case "/account": return (.account, nil)
        case "/school-connection": return (.schoolConnection, nil)
        case "/customization": return (.customization, nil)
        case "/sync": return (.sync, nil)
        case "/settings": return (.settings, nil)
        default: return nil
        }
    }

    func navigate(to tab: NativeWorkspaceTab) {
        if selection != tab { history.append(selection) }
        selection = tab
        isShowing = true
    }

    func goBack(fallback: NativeWorkspaceTab) {
        selection = history.popLast() ?? fallback
    }

    func dismiss() { history.removeAll(); isShowing = false }
}

struct NativeStudentFeaturesView: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    @State private var account: NativeAccount?
    @State private var accountError: String?

    let onReturnToApp: () -> Void
    let onOpenWeb: (String) -> Void
    let onSignOut: () -> Void
    let onShowDispatch: () -> Void
    let onLaunchOverlay: () -> Void
    let onSetAnalyticsConsent: (Bool) -> Void
    let onSessionEstablished: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onReturnToApp) {
                    Label("Back to iBacalao", systemImage: "chevron.left")
                }
                .buttonStyle(BrandGhostButtonStyle())
                Spacer()
                Text(navigation.selection.title)
                    .font(BrandFont.mono(10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Brand.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Brand.card)

            Rectangle().fill(Brand.hairline).frame(height: 1)
            featureContent
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Brand.ground)
        .preferredColorScheme(.dark)
        .task { await refreshAccount() }
        .onReceive(NotificationCenter.default.publisher(for: .nativeAuthDidChange)) { _ in
            Task { await refreshAccount() }
        }
    }

    @ViewBuilder
    private var featureContent: some View {
        switch navigation.selection {
        case .dashboard:
            NativeDashboardHomePage(onOpenWeb: onOpenWeb)
        case .today:
            NativeTodayPage(onOpenWeb: onOpenWeb)
        case .todo:
            NativeTodoPage()
        case .week:
            NativeWeekPage(onOpenWeb: onOpenWeb)
        case .reminders:
            NativeRemindersPage(onOpenWeb: onOpenWeb)
        case .progress:
            NativeReviewProgressPage()
        case .yourIB:
            NativeYourIBPage()
        case .toolsInbox:
            NativeInboxPage(onOpenWeb: onOpenWeb)
        case .toolsCAS:
            NativeCASLogPage()
        case .toolsCASProject:
            NativeCASProjectPage()
        case .toolsPractice:
            NativePracticePage()
        case .toolsMarkband:
            NativeMarkbandPage()
        case .termle:
            NativeTermlePage()
        case .toolsCamera:
            NativeCameraFeedbackPage()
        case .toolsAudio:
            NativeAudioNotesPage()
        case .toolsMarginalia:
            NativeMarginaliaPage(onLaunchOverlay: onLaunchOverlay, onShowDispatch: onShowDispatch)
        case .draftEditor:
            NativeDraftEditorPage()
        case .study:
            NativeStudyPage()
        case .profile:
            NativeProfilePage(onOpenWeb: onOpenWeb)
        case .account:
            NativeAccountPage(onOpenWeb: onOpenWeb)
        case .schoolConnection:
            NativeSchoolConnectionPage(onOpenWeb: onOpenWeb)
        case .customization:
            NativeCustomizationPage(onOpenWeb: onOpenWeb)
        case .sync:
            NativeDeviceSyncPage(onReturnToApp: onReturnToApp, onSessionEstablished: onSessionEstablished)
        case .settings:
            NativeSettingsPage(
                account: account,
                onOpenWeb: onOpenWeb,
                onSignOut: onSignOut,
                onSetAnalyticsConsent: onSetAnalyticsConsent
            )
        }
    }

    private func refreshAccount() async {
        do {
            account = try await NativeAPIClient.account()
            accountError = nil
        } catch {
            account = nil
            accountError = error.localizedDescription
        }
    }
}

private struct NativeTodayPage: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    @State private var model: NativeTodayModel?
    @State private var isLoading = false
    @State private var isSignedOut = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var busy = false
    @State private var browseIndex = 0
    @State private var showingInstructions = false
    @State private var expanded = false
    @State private var whyOpen = false
    @State private var notRightOpen = false
    @State private var correction = ""
    @State private var fileMission: NativeMission?
    @State private var showingFileImporter = false
    @State private var ceremony: NativeCompletionCeremony?

    let onOpenWeb: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    NativePageHeading(title: "Today", subtitle: "One useful next step for your IB work.")
                    Spacer()
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(BrandGhostButtonStyle())
                    .disabled(isLoading || busy)
                }

                if let day = model?.dayState {
                    daySummary(day)
                }

                if let notice = stateNotice {
                    NativeTodayNotice(title: notice.title, message: notice.message)
                }

                stateContent

                if let quickWin = model?.quickWin, model?.mission == nil {
                    quickWinCard(quickWin)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await reconcileAndLoad() }
        .sheet(isPresented: $notRightOpen) {
            correctionSheet
        }
        .sheet(item: $ceremony) { value in
            NativeCompletionCeremonyView(ceremony: value) {
                ceremony = nil
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.pdf, .image, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let mission = fileMission else { return }
                Task { await uploadHomework(mission, fileURL: url) }
            case .failure(let error):
                actionError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        if let loadError {
            NativeMessagePanel(title: "Today did not load.", message: loadError) {
                Task { await load() }
            }
        } else if isLoading && model == nil && !isSignedOut {
            ProgressView("Loading today's move…")
                .tint(Brand.accent)
                .foregroundStyle(Brand.secondary)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nativePanel()
        } else if isSignedOut || model?.kind == "signedOut" {
            VStack(alignment: .leading, spacing: 14) {
                Text("One clear next move.")
                    .font(BrandFont.display(22, weight: .semibold))
                    .foregroundStyle(Brand.bright)
                Text("Sign in for live data.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(Brand.secondary)
                Button("Sign in for live data") { onOpenWeb("/native-login") }
                    .buttonStyle(BrandPrimaryButtonStyle())
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nativePanel()
        } else if model?.kind == "noDataYet" {
            noDataCard
        } else if isClearDay {
            clearDayCard
        } else if let mission = model?.mission {
            missionCard(mission)
        } else {
            fallbackState
        }
    }

    private var isClearDay: Bool {
        model?.kind == "dayAlreadySecured" && model?.mission == nil
    }

    private var stateNotice: (title: String, message: String)? {
        guard model?.mission != nil else { return nil }
        switch model?.kind {
        case "dayAlreadySecured":
            return ("Day secured.", "Nothing important needs your attention. You can leave it here.")
        case "streakBroken":
            return ("Streak reset.", "Yesterday was missed. There is one useful move waiting today.")
        case "recoveryUsed":
            return ("Recovery used.", "A freeze covered yesterday — your streak is intact.")
        default:
            return nil
        }
    }

    private func daySummary(_ day: NativeDayState) -> some View {
        HStack(spacing: 24) {
            NativeMetric(value: "\(day.streak)", label: "DAY STREAK")
            NativeMetric(value: "\(day.momentum.completed)/\(day.momentum.ofLast)", label: "RECENT DAYS")
            NativeMetric(value: "\(day.weeklySprint.completed)/\(day.weeklySprint.target)", label: "WEEKLY SPRINT")
            if day.secured {
                Text("TODAY SECURED")
                    .font(BrandFont.mono(10, weight: .semibold))
                    .foregroundStyle(Brand.success)
            } else if day.protected {
                Text("PROTECTED")
                    .font(BrandFont.mono(10, weight: .semibold))
                    .foregroundStyle(Brand.success)
            }
            Spacer()
            Button("Add reminder") {
                _ = navigation.openNativePath("/reminders")
            }
            .buttonStyle(BrandGhostButtonStyle())
        }
        .padding(18)
        .nativePanel()
    }

    private var noDataCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            ZStack {
                Circle().fill(Brand.raised)
                Image(systemName: "plus").font(.system(size: 20, weight: .medium)).foregroundStyle(Brand.bright)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing to rank yet.")
                    .font(BrandFont.display(30, weight: .semibold))
                    .foregroundStyle(Brand.bright)
                Text("Add something you need to get done and iBacalao will decide what should come first.")
                    .font(BrandFont.body(14))
                    .foregroundStyle(Brand.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("ADD A TASK") {
                _ = navigation.openNativePath("/reminders")
            }
            .buttonStyle(BrandLargePrimaryButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: 680, minHeight: 320, alignment: .leading)
        .nativePanel()
    }

    private var clearDayCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Spacer()
                Text("0 LEFT")
                    .font(BrandFont.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Brand.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Brand.raised, in: Capsule())
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Today is clear.")
                    .font(BrandFont.display(32, weight: .semibold))
                    .foregroundStyle(Brand.bright)
                Text("You can stop here, or work ahead.")
                    .font(BrandFont.body(16))
                    .foregroundStyle(Brand.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                Button("WORK AHEAD") {
                    onOpenWeb("/dashboard/week")
                }
                .buttonStyle(BrandLargePrimaryButtonStyle())

                Button("ADD REMINDER") {
                    _ = navigation.openNativePath("/reminders")
                }
                .buttonStyle(BrandGhostButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: 680, minHeight: 316, alignment: .leading)
        .nativePanel()
    }

    @ViewBuilder
    private var fallbackState: some View {
        switch model?.kind {
        case "missionUnavailable":
            NativeEmptyState(
                title: "Still getting your school state.",
                message: "Connect Dispatch or upload a draft so today's move can be trusted.",
                actionTitle: "Connect school"
            ) {
                _ = navigation.openNativePath("/school-connection")
            }
        case "firstEverUse":
            NativeTodayNotice(title: "Today is clear.", message: "Nothing else important needs your attention.")
        case "dayAlreadySecured":
            clearDayCard
        case "streakBroken":
            VStack(alignment: .leading, spacing: 14) {
                NativeTodayNotice(title: "Streak reset.", message: "Yesterday was missed. There is one useful move waiting today.")
                NativeTodayNotice(title: "Today is clear.", message: "Nothing else important needs your attention.")
            }
        case "recoveryUsed":
            VStack(alignment: .leading, spacing: 14) {
                NativeTodayNotice(title: "Recovery used.", message: "A freeze covered yesterday — your streak is intact.")
                NativeTodayNotice(title: "Today is clear.", message: "Nothing else important needs your attention.")
            }
        default:
            NativeEmptyState(
                title: "No task to show right now",
                message: "Add a task or check your week.",
                actionTitle: "Add a task"
            ) {
                _ = navigation.openNativePath("/reminders")
            }
        }
    }

    private func quickWinCard(_ quickWin: NativeQuickWin) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "note.text")
                .font(.system(size: 20))
                .foregroundStyle(Brand.bright)
                .frame(width: 48, height: 48)
                .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.cornerMd))
            VStack(alignment: .leading, spacing: 4) {
                Text("QUICK WIN")
                    .font(BrandFont.mono(9, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Brand.muted)
                Text(quickWin.title)
                    .font(BrandFont.display(17, weight: .semibold))
                    .foregroundStyle(Brand.bright)
                Text(quickWin.action)
                    .font(BrandFont.body(12))
                    .foregroundStyle(Brand.secondary)
            }
            Spacer()
            Text("\(quickWin.estMinutes) MIN")
                .font(BrandFont.mono(9, weight: .semibold))
                .foregroundStyle(Brand.muted)
            Button("Open in chat") { onOpenWeb("/chat") }
                .buttonStyle(BrandGhostButtonStyle())
        }
        .padding(18)
        .nativePanel()
    }

    private func queue(for mission: NativeMission) -> [NativeMissionQueueItem] {
        if let queue = model?.missionQueue, !queue.isEmpty { return queue }
        return [
            NativeMissionQueueItem(
                taskId: mission.taskId,
                subject: mission.subject,
                subjectLabel: mission.subjectLabel,
                title: mission.title,
                action: mission.action,
                estMinutes: mission.estMinutes,
                whyThis: mission.whyThis
            ),
        ]
    }

    private func safeBrowseIndex(for queue: [NativeMissionQueueItem]) -> Int {
        guard !queue.isEmpty else { return 0 }
        return ((browseIndex % queue.count) + queue.count) % queue.count
    }

    private func missionCard(_ mission: NativeMission) -> some View {
        let items = queue(for: mission)
        let index = safeBrowseIndex(for: items)
        let browsed = items[index]
        let browsedIsSelected = browsed.taskId == mission.taskId
        let started = browsedIsSelected && (
            mission.completion.state != "NOT_STARTED"
            || navigation.activeWorkContext?.missionDecisionId == mission.missionDecisionId
        )

        return VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                if items.count > 2 {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Brand.active)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.edge, lineWidth: 1))
                        .offset(x: 10, y: 14)
                }
                if items.count > 1 {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Brand.raised)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.edge, lineWidth: 1))
                        .offset(x: 5, y: 7)
                }

                VStack(alignment: .leading, spacing: 18) {
                    if showingInstructions {
                        instructionFace(mission: mission, browsed: browsed)
                    } else {
                        frontFace(mission: mission, browsed: browsed, started: started)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: showingInstructions ? 440 : 316, alignment: .topLeading)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.edge, lineWidth: 1.2))
            }
            .padding(.trailing, items.count > 1 ? 10 : 0)
            .padding(.bottom, items.count > 1 ? 14 : 0)

            if !showingInstructions {
                HStack(spacing: 12) {
                    Button {
                        whyOpen.toggle()
                    } label: {
                        Label("WHY THIS?", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .font(BrandFont.mono(10, weight: .semibold))
                    .foregroundStyle(Brand.secondary)

                    Button("NOT RIGHT?") {
                        correction = ""
                        actionError = nil
                        notRightOpen = true
                    }
                    .buttonStyle(.plain)
                    .font(BrandFont.mono(10, weight: .semibold))
                    .foregroundStyle(Brand.secondary)

                    Spacer()

                    if items.count > 1 {
                        Button {
                            cycleMission(-1, count: items.count)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(BrandGhostButtonStyle())
                        .disabled(busy)
                        Text("\(index + 1) / \(items.count)")
                            .font(BrandFont.mono(9))
                            .foregroundStyle(Brand.muted)
                        Button {
                            cycleMission(1, count: items.count)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(BrandGhostButtonStyle())
                        .disabled(busy)
                    } else {
                        Text("ONE THING LEFT")
                            .font(BrandFont.mono(9, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(Brand.muted)
                    }
                }

                if whyOpen {
                    Text(browsed.whyThis)
                        .font(BrandFont.body(12))
                        .foregroundStyle(Brand.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let actionError {
                Text(actionError)
                    .font(BrandFont.body(12))
                    .foregroundStyle(Brand.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func frontFace(mission: NativeMission, browsed: NativeMissionQueueItem, started: Bool) -> some View {
        let frontSummary = summarizeCardText(browsed.taskId == mission.taskId ? mission.instructions.summary : browsed.action)

        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(browsed.estMinutes) MIN")
                    .font(BrandFont.mono(10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Brand.muted)
                Spacer()
                Text("1 LEFT")
                    .font(BrandFont.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Brand.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Brand.raised, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(frontSummary)
                    .font(BrandFont.display(28, weight: .semibold))
                    .foregroundStyle(Brand.bright)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if started {
                Button(primaryLabel(for: mission)) {
                    Task { await runPrimary(mission) }
                }
                .buttonStyle(BrandLargePrimaryButtonStyle())
                .disabled(busy)
            } else {
                Button(busy ? "OPENING…" : "START") {
                    Task { await startBrowsed(current: mission, taskId: browsed.taskId) }
                }
                .buttonStyle(BrandLargePrimaryButtonStyle())
                .disabled(busy)
            }

            HStack {
                Button("SEE MORE") {
                    showingInstructions = true
                    expanded = false
                }
                .buttonStyle(.plain)
                .font(BrandFont.mono(10, weight: .semibold))
                .foregroundStyle(Brand.secondary)

                Spacer()

                if started && mission.launch.kind != "manual" && mission.completion.manualAllowed {
                    Button("LOG AS DONE") {
                        Task { await completeMission(mission) }
                    }
                    .buttonStyle(.plain)
                    .font(BrandFont.mono(10, weight: .semibold))
                    .foregroundStyle(Brand.secondary)
                    .disabled(busy)
                }
            }
        }
    }

    private func instructionFace(mission: NativeMission, browsed: NativeMissionQueueItem) -> some View {
        let execution = mission.execution
        let step = execution.steps.indices.contains(execution.currentStepIndex)
            ? execution.steps[execution.currentStepIndex]
            : nil

        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                if expanded {
                    Button("LESS DETAIL") { expanded = false }
                        .buttonStyle(.plain)
                        .font(BrandFont.mono(9, weight: .semibold))
                        .foregroundStyle(Brand.secondary)
                }
                Spacer()
                Button("← TASK") {
                    showingInstructions = false
                    expanded = false
                }
                .buttonStyle(.plain)
                .font(BrandFont.mono(10, weight: .semibold))
                .foregroundStyle(Brand.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("FULL TASK")
                    .font(BrandFont.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Brand.muted)
                Text(browsed.title)
                    .font(BrandFont.display(23, weight: .semibold))
                    .foregroundStyle(Brand.bright)
                Text(browsed.action)
                    .font(BrandFont.body(13))
                    .foregroundStyle(Brand.secondary)
            }

            if let step {
                Text("STEP \(min(execution.currentStepIndex + 1, execution.steps.count)) OF \(execution.steps.count)")
                    .font(BrandFont.mono(9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Brand.muted)
                Text(step.action)
                    .font(BrandFont.body(execution.textSpacing == "comfortable" ? 17 : 15, weight: .semibold))
                    .foregroundStyle(Brand.bright)
                    .fixedSize(horizontal: false, vertical: true)
                if execution.estimateIsGuide, let minutes = step.estMinutes {
                    Text("ABOUT \(minutes) MIN · ESTIMATE IS A GUIDE")
                        .font(BrandFont.mono(9))
                        .foregroundStyle(Brand.muted)
                }
            } else {
                Text("All execution steps reviewed.")
                    .font(BrandFont.body(15, weight: .semibold))
                    .foregroundStyle(Brand.bright)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("WHERE")
                    .font(BrandFont.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Brand.muted)
                Text(mission.instructions.whereLabel)
                    .font(BrandFont.body(12))
                    .foregroundStyle(Brand.secondary)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("STEP BY STEP")
                        .font(BrandFont.mono(9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Brand.muted)
                    ForEach(Array(mission.instructions.steps.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(BrandFont.mono(9, weight: .semibold))
                                .foregroundStyle(Brand.muted)
                                .frame(width: 18, alignment: .leading)
                            Text(item)
                                .font(BrandFont.body(12))
                                .foregroundStyle(Brand.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let step, execution.steps.count > 1 {
                if execution.breakSuggestionAfterStepIds.contains(step.id) {
                    Text("A short break after this step may help.")
                        .font(BrandFont.body(11))
                        .foregroundStyle(Brand.secondary)
                }
                Button(busy ? "Saving…" : "NEXT STEP") {
                    Task { await advanceExecution(mission) }
                }
                .buttonStyle(BrandPrimaryButtonStyle())
                .disabled(busy)
            }

            if !expanded {
                Button("More detailed explanation") { expanded = true }
                    .buttonStyle(.plain)
                    .font(BrandFont.body(12, weight: .medium))
                    .foregroundStyle(Brand.secondary)
                    .underline()
            }
        }
    }

    private var correctionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Not right?")
                .font(BrandFont.display(24, weight: .semibold))
                .foregroundStyle(Brand.bright)
            Text("Choose why this task should change.")
                .font(BrandFont.body(12))
                .foregroundStyle(Brand.secondary)

            VStack(spacing: 8) {
                swapButton("Not relevant", reason: "not_relevant")
                swapButton("Wrong deadline", reason: "wrong_deadline")
                swapButton("Already done", reason: "already_done")
                swapButton("Too hard right now", reason: "too_hard_right_now")
                swapButton("Other", reason: "other")
            }

            Rectangle().fill(Brand.hairline).frame(height: 1)

            Text("Is the data wrong?")
                .font(BrandFont.body(12, weight: .semibold))
                .foregroundStyle(Brand.bright)
            TextEditor(text: $correction)
                .font(BrandFont.body(13))
                .foregroundStyle(Brand.bright)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 90)
                .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.cornerMd))
                .overlay(RoundedRectangle(cornerRadius: Brand.cornerMd).stroke(Brand.edge, lineWidth: 1))
            if let actionError {
                Text(actionError).font(BrandFont.body(11)).foregroundStyle(Brand.danger)
            }
            HStack {
                Button("Cancel") { notRightOpen = false }
                    .buttonStyle(BrandGhostButtonStyle())
                Spacer()
                Button(busy ? "Sending…" : "Send correction") {
                    Task { await sendCorrection() }
                }
                .buttonStyle(BrandPrimaryButtonStyle())
                .disabled(busy || correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Brand.ground)
    }

    private func swapButton(_ title: String, reason: String) -> some View {
        Button {
            Task { await swapMission(reason: reason) }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text("→")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(BrandFont.body(13, weight: .medium))
        .foregroundStyle(Brand.body)
        .padding(.vertical, 7)
        .disabled(busy)
    }

    private func primaryLabel(for mission: NativeMission) -> String {
        switch mission.launch.kind {
        case "school_upload":
            return mission.completion.homeworkUploaded == true ? "REPLACE HOMEWORK" : "UPLOAD HOMEWORK"
        case "manual":
            return busy ? "SAVING…" : "LOG AS DONE"
        default:
            return busy ? "OPENING…" : mission.instructions.launchLabel.uppercased()
        }
    }

    private func summarizeCardText(_ value: String) -> String {
        let text = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 72
        guard text.count > maxLength else { return text }

        let characters = Array(text)
        for index in characters.indices where index < maxLength {
            let character = characters[index]
            guard character == "." || character == "!" || character == "?" else { continue }
            let next = characters.index(after: index)
            if next == characters.endIndex || characters[next].isWhitespace {
                return String(characters[...index]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let window = String(characters.prefix(maxLength + 1))
        if let space = window.lastIndex(of: " "), space != window.startIndex {
            return String(window[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(characters.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cycleMission(_ direction: Int, count: Int) {
        guard !busy, count > 1 else { return }
        browseIndex = (browseIndex + direction + count) % count
        showingInstructions = false
        expanded = false
        whyOpen = false
        actionError = nil
    }

    private func startBrowsed(current mission: NativeMission, taskId: String) async {
        guard !busy else { return }
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            let selected: NativeMission
            if mission.taskId == taskId {
                selected = mission
            } else {
                let next = try await NativeAPIClient.selectMission(taskId: taskId)
                guard let picked = next.mission, picked.taskId == taskId else {
                    throw NativeAPIClientError.server("That mission is no longer available.")
                }
                model = next
                browseIndex = 0
                selected = picked
            }
            _ = try await ensureWorkContext(selected)
            showingInstructions = true
            expanded = false
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func ensureWorkContext(_ mission: NativeMission) async throws -> NativeWorkContext {
        if let active = navigation.activeWorkContext,
           active.missionDecisionId == mission.missionDecisionId,
           active.status != "completed",
           active.status != "abandoned" {
            return active
        }
        let context = try await NativeAPIClient.startWorkContext(for: mission)
        navigation.activeWorkContext = context
        return context
    }

    private func runPrimary(_ mission: NativeMission) async {
        guard !busy else { return }
        switch mission.launch.kind {
        case "school_upload":
            fileMission = mission
            showingFileImporter = true
        case "manual":
            await completeMission(mission)
        default:
            busy = true
            actionError = nil
            defer { busy = false }
            do {
                let context = try await ensureWorkContext(mission)
                if mission.launch.kind == "web" {
                    navigation.todo = NativeTodoContext(
                        taskId: mission.taskId,
                        missionDecisionId: mission.missionDecisionId,
                        contextId: context.id,
                        title: mission.title,
                        source: mission.subjectLabel
                    )
                    navigation.selection = .todo
                } else if !navigation.openNativePath(context.lastRoute) {
                    onOpenWeb(context.lastRoute)
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func uploadHomework(_ mission: NativeMission, fileURL: URL) async {
        guard !busy else { return }
        busy = true
        actionError = nil
        defer {
            busy = false
            fileMission = nil
        }
        do {
            let context = try await ensureWorkContext(mission)
            _ = try await NativeAPIClient.uploadMissionHomework(
                missionDecisionId: mission.missionDecisionId,
                contextId: context.id,
                fileURL: fileURL
            )
            navigation.activeWorkContext = nil
            await load()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func completeMission(_ mission: NativeMission) async {
        guard !busy else { return }
        busy = true
        actionError = nil
        defer { busy = false }
        let contextId = navigation.activeWorkContext?.missionDecisionId == mission.missionDecisionId
            ? navigation.activeWorkContext?.id
            : nil
        do {
            let result = try await NativeAPIClient.completeMission(
                NativeTodoContext(
                    taskId: mission.taskId,
                    missionDecisionId: mission.missionDecisionId,
                    contextId: contextId,
                    title: mission.title,
                    source: mission.subjectLabel
                )
            )
            navigation.activeWorkContext = nil
            ceremony = result.ceremony?.hasGratification == true ? result.ceremony : nil
            await load()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func advanceExecution(_ mission: NativeMission) async {
        guard !busy else { return }
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            try await NativeAPIClient.advanceMissionExecution(mission)
            await load()
            showingInstructions = true
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func swapMission(reason: String) async {
        guard !busy, let mission = model?.mission else { return }
        let items = queue(for: mission)
        guard !items.isEmpty else { return }
        let browsed = items[safeBrowseIndex(for: items)]
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            model = try await NativeAPIClient.swapMission(taskId: browsed.taskId, reason: reason)
            browseIndex = 0
            showingInstructions = false
            notRightOpen = false
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func sendCorrection() async {
        guard !busy, let mission = model?.mission else { return }
        let note = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        let items = queue(for: mission)
        guard !items.isEmpty else { return }
        let browsed = items[safeBrowseIndex(for: items)]
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            model = try await NativeAPIClient.correctMission(taskId: browsed.taskId, note: note)
            correction = ""
            browseIndex = 0
            showingInstructions = false
            notRightOpen = false
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func reconcileAndLoad() async {
        if let active = navigation.activeWorkContext,
           let latest = try? await NativeAPIClient.workContext(id: active.id) {
            navigation.activeWorkContext = latest
            if latest.status == "completed" {
                navigation.activeWorkContext = nil
                let latestCeremony = try? await NativeAPIClient.latestCompletion()
                await load()
                if let latestCeremony, latestCeremony.hasGratification, completion(latestCeremony, isAtOrAfter: active.startedAt) {
                    ceremony = latestCeremony
                }
                return
            }
        }
        await load()
    }

    private func completion(_ ceremony: NativeCompletionCeremony, isAtOrAfter startedAt: String) -> Bool {
        let parser = ISO8601DateFormatter()
        guard let completed = parser.date(from: ceremony.completedAt),
              let started = parser.date(from: startedAt) else {
            return ceremony.completedAt >= startedAt
        }
        return completed >= started
    }

    private func load() async {
        isLoading = true
        loadError = nil
        isSignedOut = false
        defer { isLoading = false }
        do {
            let next = try await NativeAPIClient.today().today
            model = next
            isSignedOut = next.kind == "signedOut"
            if let mission = next.mission {
                let count = queue(for: mission).count
                if browseIndex >= count { browseIndex = 0 }
            } else {
                browseIndex = 0
                showingInstructions = false
            }
        } catch NativeAPIClientError.missingSession {
            model = nil
            isSignedOut = true
        } catch {
            if model == nil {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct NativeTodayNotice: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrandFont.display(17, weight: .semibold))
                .foregroundStyle(Brand.bright)
            Text(message)
                .font(BrandFont.body(12))
                .foregroundStyle(Brand.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativePanel()
    }
}

private struct NativeCompletionCeremonyView: View {
    let ceremony: NativeCompletionCeremony
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 16)

            if let change = ceremony.stateChange {
                VStack(spacing: 5) {
                    Text(change.headline.uppercased())
                        .font(BrandFont.mono(9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Brand.muted)
                    Text("\(change.before) → \(change.after)")
                        .font(BrandFont.display(28, weight: .semibold))
                        .foregroundStyle(Brand.bright)
                }
            }

            if ceremony.dayState.after.secured {
                Text("DAY SECURED")
                    .font(BrandFont.mono(10, weight: .semibold))
                    .foregroundStyle(Brand.success)
            }

            let before = ceremony.dayState.before.streak
            let after = ceremony.dayState.after.streak
            Text(before == after ? "\(after)" : "\(before) → \(after)")
                .font(BrandFont.display(42, weight: .semibold))
                .foregroundStyle(Brand.bright)
            Text("DAY STREAK")
                .font(BrandFont.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Brand.muted)
            Text("SPRINT \(ceremony.dayState.after.weeklySprint.completed)/\(ceremony.dayState.after.weeklySprint.target)")
                .font(BrandFont.mono(10, weight: .semibold))
                .foregroundStyle(Brand.secondary)

            if let tomorrow = ceremony.tomorrowPreview {
                Text("Tomorrow · \(tomorrow.subjectLabel) · ~\(tomorrow.estMinutes) min")
                    .font(BrandFont.body(13))
                    .foregroundStyle(Brand.secondary)
            } else {
                Text("Tomorrow currently looks clear.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(Brand.secondary)
            }

            Spacer(minLength: 16)

            Button("DONE") { onClose() }
                .buttonStyle(BrandLargePrimaryButtonStyle())
        }
        .padding(28)
        .frame(width: 520)
        .frame(minHeight: 430)
        .background(Brand.ground)
    }
}

private struct NativeRemindersPage: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    let onOpenWeb: (String) -> Void

    @State private var response: NativeRemindersResponse?
    @State private var title = ""
    @State private var subject = ""
    @State private var importance = "normal"
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var remindTime = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var error: String?
    @State private var saved = false
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                NativeRouteBackButton(title: "Back") { navigation.goBack(fallback: .settings) }
                NativePageHeading(title: "Reminders", subtitle: "Save a task with a due date so it can inform Today’s plan.")

                if let error {
                    NativeMessagePanel(title: "Reminders unavailable", message: error) { Task { await load() } }
                } else if response == nil {
                    ProgressView("Loading reminders…")
                        .tint(Brand.accent).foregroundStyle(Brand.secondary)
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading).nativePanel()
                }

                if let response {
                    if response.subjects.isEmpty {
                        NativeEmptyState(title: "Choose your subjects first", message: "Reminders attach to a subject so Today can rank them in the right context.", actionTitle: "Choose subjects") {
                            navigation.navigate(to: .customization)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("NEW REMINDER").font(BrandFont.mono(10, weight: .semibold)).tracking(0.8).foregroundStyle(Brand.muted)
                            TextField("What do you want to remember?", text: $title)
                                .textFieldStyle(.roundedBorder)
                            Picker("Subject", selection: $subject) {
                                ForEach(response.subjects) { item in Text(item.label).tag(item.id) }
                            }
                            Picker("Importance", selection: $importance) {
                                Text("Low").tag("low")
                                Text("Normal").tag("normal")
                                Text("High").tag("high")
                            }
                            .pickerStyle(.segmented)
                            HStack(spacing: 20) {
                                DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                                DatePicker("Reminder time", selection: $remindTime, displayedComponents: .hourAndMinute)
                            }
                            if saved { Text("Reminder saved.").font(BrandFont.body(12, weight: .semibold)).foregroundStyle(Brand.success) }
                            if let error { Text(error).font(BrandFont.body(12)).foregroundStyle(Brand.danger) }
                            HStack {
                                Spacer()
                                Button(saving ? "Saving…" : "Save reminder") { Task { await saveReminder() } }
                                    .buttonStyle(BrandPrimaryButtonStyle())
                                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || subject.isEmpty)
                            }
                        }
                        .padding(18).nativePanel()

                        let active = response.reminders.filter { $0.status == "active" }
                        if !active.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("UPCOMING").font(BrandFont.mono(10, weight: .semibold)).tracking(0.8).foregroundStyle(Brand.muted)
                                ForEach(active) { reminder in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(reminder.title).font(BrandFont.body(13, weight: .medium)).foregroundStyle(Brand.bright)
                                        Text("\(response.subjects.first(where: { $0.id == reminder.subject })?.label ?? subjectLabel(reminder.subject)) · due \(formattedDate(reminder.dueDate)) · \(formattedDateTime(reminder.remindAt))")
                                            .font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14).nativePanel()
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await load() }
    }

    private func load() async {
        error = nil
        do {
            response = try await NativeAPIClient.reminders()
            if subject.isEmpty { subject = response?.subjects.first?.id ?? "" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveReminder() async {
        guard !saving else { return }
        saving = true
        error = nil
        saved = false
        defer { saving = false }
        do {
            let calendar = Calendar.current
            let dueParts = calendar.dateComponents([.year, .month, .day], from: dueDate)
            let timeParts = calendar.dateComponents([.hour, .minute], from: remindTime)
            var reminderParts = dueParts
            reminderParts.hour = timeParts.hour
            reminderParts.minute = timeParts.minute
            guard let remindAt = calendar.date(from: reminderParts), remindAt > Date() else {
                throw NativeAPIClientError.server("Choose a future reminder time.")
            }
            try await NativeAPIClient.createReminder(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                subject: subject,
                importance: importance,
                dueDate: localDateKey(dueDate),
                remindAt: remindAt
            )
            title = ""
            saved = true
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NativeCustomizationPage: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    let onOpenWeb: (String) -> Void

    @State private var preferences: NativeMissionPreferences?
    @State private var workPreferences: NativeWorkPreferences?
    @State private var subjects: [String] = []
    @State private var savedSubjects: [String] = []
    @State private var subjectCatalog: [NativeSelectableSubject] = []
    @State private var error: String?
    @State private var status: String?
    @State private var isLoading = false
    @State private var isSaving = false

    private let confidenceOptions = [
        NativePreferenceOption(value: "struggling", label: "Struggling"),
        NativePreferenceOption(value: "okay", label: "Okay"),
        NativePreferenceOption(value: "confident", label: "Confident"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NativeRouteBackButton(title: "Back") { navigation.goBack(fallback: .settings) }
                NativePageHeading(title: "Customization", subtitle: "Personalize Today, not the rules.")
                Text("These preferences break ties when several tasks are equally useful. Deadlines, required fixes and urgent school work still take priority.")
                    .font(BrandFont.body(13)).foregroundStyle(Brand.secondary)

                if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        NativeMessagePanel(title: "Customization unavailable", message: error) {
                            Task { await load() }
                        }
                        Button("Sign in") { onOpenWeb("/native-login") }
                            .buttonStyle(BrandGhostButtonStyle())
                    }
                } else if isLoading && preferences == nil {
                    ProgressView("Loading preferences…").tint(Brand.accent).foregroundStyle(Brand.secondary)
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading).nativePanel()
                }

                if preferences != nil {
                    subjectPicker
                    missionPreferences
                    workPreferencesSection
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await load() }
    }

    @ViewBuilder
    private var subjectPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your subjects").font(BrandFont.display(19, weight: .semibold)).foregroundStyle(Brand.bright)
            Text("Keep this list aligned with the subjects you study. Week goals and reminders use it.")
                .font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(subjectCatalog) { item in
                    let selected = subjects.contains(item.id)
                    Button {
                        if selected {
                            subjects.removeAll { $0 == item.id }
                        } else if subjects.count < 12 {
                            subjects.append(item.id)
                        }
                        status = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selected ? "checkmark.square.fill" : "square")
                            Text(item.label).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(BrandFont.body(12, weight: .medium))
                        .foregroundStyle(selected ? Brand.accentBright : Brand.body)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(Brand.active, in: RoundedRectangle(cornerRadius: Brand.cornerMd))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                Button(isSaving ? "Saving…" : "Save subjects") { Task { await saveSubjects() } }
                    .buttonStyle(BrandPrimaryButtonStyle())
                    .disabled(isSaving || subjects == savedSubjects)
                if let status { Text(status).font(BrandFont.body(12)).foregroundStyle(Brand.success) }
                if subjects.count >= 12 { Text("Up to 12 subjects").font(BrandFont.body(11)).foregroundStyle(Brand.muted) }
                Spacer()
            }
        }
        .padding(18).nativePanel()
    }

    @ViewBuilder
    private var missionPreferences: some View {
        if let preferences {
            VStack(alignment: .leading, spacing: 14) {
                Text("Today recommendations").font(BrandFont.display(19, weight: .semibold)).foregroundStyle(Brand.bright)
                NativePreferenceSelector(
                    title: "Time available",
                    note: "How much focused time do you usually have on a study day?",
                    options: [15, 30, 45, 60].map { NativePreferenceOption(value: String($0), label: $0 == 60 ? "60+ min" : "\($0) min") },
                    selected: String(preferences.availableTimeMinutes),
                    disabled: isSaving,
                    onSelect: { value in updatePreferences { $0.availableTimeMinutes = Int(value) ?? 30 } }
                )
                NativePreferenceSelector(
                    title: "Challenge level",
                    note: "How demanding should optional practice feel?",
                    options: ["light", "balanced", "challenge"].map { NativePreferenceOption(value: $0, label: ["light": "Light", "balanced": "Balanced", "challenge": "Challenge me"][$0] ?? $0) },
                    selected: preferences.challengeLevel,
                    disabled: isSaving,
                    onSelect: { value in updatePreferences { $0.challengeLevel = value } }
                )
                NativePreferenceSelector(
                    title: "Recommendation style",
                    note: "When several useful tasks fit, what should Today favor?",
                    options: ["quick", "balanced", "deep"].map { NativePreferenceOption(value: $0, label: $0.capitalized) },
                    selected: preferences.recommendationStyle,
                    disabled: isSaving,
                    onSelect: { value in updatePreferences { $0.recommendationStyle = value } }
                )
                Text(styleHelp(preferences.recommendationStyle))
                    .font(BrandFont.body(11)).foregroundStyle(Brand.muted)

                if !subjects.isEmpty {
                    Divider().overlay(Brand.hairline)
                    Text("Subject confidence").font(BrandFont.body(14, weight: .semibold)).foregroundStyle(Brand.bright)
                    Text("Your own read of each subject. Grades, reviews and teacher signals remain stronger evidence.")
                        .font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                    ForEach(subjects, id: \.self) { subject in
                        NativePreferenceSelector(
                            title: subjectCatalog.first(where: { $0.id == subject })?.label ?? subjectLabel(subject),
                            note: nil,
                            options: confidenceOptions,
                            selected: preferences.subjectConfidence[subject] ?? "okay",
                            disabled: isSaving,
                            onSelect: { value in
                                updatePreferences { $0.subjectConfidence[subject] = value }
                            }
                        )
                    }
                }

                HStack {
                    Button("Reset to balanced") { Task { await resetMissionPreferences() } }
                        .buttonStyle(BrandGhostButtonStyle())
                        .disabled(isSaving || preferences == .balanced)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small).tint(Brand.accent) }
                }
            }
            .padding(18).nativePanel()
        }
    }

    @ViewBuilder
    private var workPreferencesSection: some View {
        if let workPreferences {
            VStack(alignment: .leading, spacing: 14) {
                Text("Work setup").font(BrandFont.display(19, weight: .semibold)).foregroundStyle(Brand.bright)
                Text("Choose how study tasks are presented. These are explicit preferences, not a diagnosis.")
                    .font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                NativePreferenceSelector(title: "Task size", note: nil, options: [
                    .init(value: "standard", label: "Standard"), .init(value: "smaller", label: "Smaller steps"),
                ], selected: workPreferences.taskSteps, disabled: isSaving) { updateWork("taskSteps", $0) }
                NativePreferenceSelector(title: "While working", note: nil, options: [
                    .init(value: "standard", label: "Standard view"), .init(value: "focus", label: "Focus view"),
                ], selected: workPreferences.focus, disabled: isSaving) { updateWork("focus", $0) }
                NativePreferenceSelector(title: "Time estimate", note: nil, options: [
                    .init(value: "estimate", label: "Show estimate"), .init(value: "estimate_is_guide", label: "Estimate is a guide"),
                ], selected: workPreferences.estimate, disabled: isSaving) { updateWork("estimate", $0) }
                NativePreferenceSelector(title: "Break support", note: nil, options: [
                    .init(value: "off", label: "Off"), .init(value: "suggest", label: "Suggest breaks"),
                ], selected: workPreferences.breaks, disabled: isSaving) { updateWork("breaks", $0) }
                NativePreferenceSelector(title: "Reading", note: nil, options: [
                    .init(value: "standard", label: "System spacing"), .init(value: "comfortable", label: "Comfortable spacing"),
                ], selected: workPreferences.textSpacing, disabled: isSaving) { updateWork("textSpacing", $0) }
                NativePreferenceSelector(title: "Motion", note: nil, options: [
                    .init(value: "system", label: "Follow system"), .init(value: "reduce", label: "Reduce motion"),
                ], selected: workPreferences.motion, disabled: isSaving) { updateWork("motion", $0) }
                HStack {
                    Button("Reset work setup") { Task { await resetWorkPreferences() } }
                        .buttonStyle(BrandGhostButtonStyle())
                        .disabled(isSaving)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small).tint(Brand.accent) }
                }
            }
            .padding(18).nativePanel()
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            async let mission = NativeAPIClient.missionPreferences()
            async let work = NativeAPIClient.workPreferences()
            let (missionData, workData) = try await (mission, work)
            preferences = missionData.preferences
            subjects = missionData.subjects
            savedSubjects = missionData.subjects
            subjectCatalog = NativeSelectableSubject.catalog
            workPreferences = workData
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func saveSubjects() async {
        guard !isSaving, subjects != savedSubjects else { return }
        isSaving = true
        error = nil
        status = nil
        defer { isSaving = false }
        do {
            let saved = try await NativeAPIClient.saveSubjects(subjects)
            subjects = saved
            savedSubjects = saved
            status = "Subjects saved."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func updatePreferences(_ mutate: (inout NativeMissionPreferences) -> Void) {
        guard !isSaving, var next = preferences else { return }
        let previous = next
        mutate(&next)
        preferences = next
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await NativeAPIClient.saveMissionPreferences(next)
            } catch {
                preferences = previous
                self.error = error.localizedDescription
            }
        }
    }

    private func resetMissionPreferences() async {
        guard !isSaving else { return }
        let previous = preferences
        preferences = .balanced
        isSaving = true
        error = nil
        defer { isSaving = false }
        do { try await NativeAPIClient.saveMissionPreferences(.balanced) }
        catch {
            preferences = previous
            self.error = error.localizedDescription
        }
    }

    private func updateWork(_ key: String, _ value: String) {
        guard !isSaving, var next = workPreferences else { return }
        switch key {
        case "taskSteps": next.taskSteps = value
        case "focus": next.focus = value
        case "estimate": next.estimate = value
        case "breaks": next.breaks = value
        case "textSpacing": next.textSpacing = value
        case "motion": next.motion = value
        default: return
        }
        let previous = workPreferences
        workPreferences = next
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do { workPreferences = try await NativeAPIClient.updateWorkPreferences([key: value]) }
            catch {
                workPreferences = previous
                self.error = error.localizedDescription
            }
        }
    }

    private func resetWorkPreferences() async {
        guard !isSaving else { return }
        let previous = workPreferences
        isSaving = true
        error = nil
        defer { isSaving = false }
        do { workPreferences = try await NativeAPIClient.resetWorkPreferences() }
        catch {
            workPreferences = previous
            self.error = error.localizedDescription
        }
    }

    private func styleHelp(_ style: String) -> String {
        switch style {
        case "quick": return "Prefer shorter wins when two recommendations have similar academic value."
        case "deep": return "Prefer longer focused work when it is equally useful."
        default: return "Balance quick progress with deeper work."
        }
    }
}

private struct NativePreferenceOption: Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

private struct NativePreferenceSelector: View {
    let title: String
    let note: String?
    let options: [NativePreferenceOption]
    let selected: String
    var disabled = false
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
            if let note { Text(note).font(BrandFont.body(11)).foregroundStyle(Brand.secondary) }
            HStack(spacing: 6) {
                ForEach(options) { option in
                    Button { onSelect(option.value) } label: {
                        Text(option.label)
                            .font(BrandFont.body(11, weight: .medium))
                            .foregroundStyle(selected == option.value ? Brand.onAccent : Brand.secondary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(selected == option.value ? Brand.accent : Brand.active, in: RoundedRectangle(cornerRadius: Brand.cornerMd))
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                }
            }
        }
    }
}

private struct NativeDeviceSyncPage: View {
    let onReturnToApp: () -> Void
    let onSessionEstablished: (String) -> Void

    @State private var started: NativeSyncStarted?
    @State private var syncStatus: NativeSyncStatus?
    @State private var secondsLeft = 0
    @State private var error: String?
    @State private var isStarting = false
    @State private var isDeciding = false
    @State private var pollTask: Task<Void, Never>?

    private static let qrContext = CIContext()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                NativePageHeading(
                    title: started?.mode == "grant" ? "Add your phone" : "Continue from your phone",
                    subtitle: "Pair this Mac and your iBacalao phone app with one short approval."
                )

                if let error {
                    NativeMessagePanel(title: "Device sync unavailable", message: error) {
                        Task { await start() }
                    }
                } else if started == nil {
                    ProgressView(isStarting ? "Creating a code…" : "Preparing device sync…")
                        .tint(Brand.accent).foregroundStyle(Brand.secondary)
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading).nativePanel()
                } else if let started {
                    statusContent(started)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await start() }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder
    private func statusContent(_ started: NativeSyncStarted) -> some View {
        let status = syncStatus?.status ?? "pending"
        let grant = started.mode == "grant"
        if (status == "approved" || status == "consumed") && grant {
            VStack(alignment: .leading, spacing: 12) {
                NativePageHeading(title: "Phone synced", subtitle: "\(syncStatus?.otherDevice?.label ?? "Your phone") can now use this iBacalao account.")
                Button("Back to iBacalao") { onReturnToApp() }.buttonStyle(BrandPrimaryButtonStyle())
            }
            .padding(20).nativePanel()
        } else if status == "claimed", syncStatus?.awaitingYourApproval == true {
            VStack(alignment: .leading, spacing: 12) {
                Text("Allow \(syncStatus?.otherDevice?.label ?? "this phone")?")
                    .font(BrandFont.display(22, weight: .semibold)).foregroundStyle(Brand.bright)
                Text("It will sign in to your iBacalao account. Only allow a phone you own.")
                    .font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
                HStack(spacing: 10) {
                    Button(isDeciding ? "Saving…" : "Allow") { Task { await decide(approve: true, started: started) } }
                        .buttonStyle(BrandPrimaryButtonStyle()).disabled(isDeciding)
                    Button("Deny") { Task { await decide(approve: false, started: started) } }
                        .buttonStyle(BrandGhostButtonStyle()).disabled(isDeciding)
                }
            }
            .padding(20).nativePanel()
        } else if status == "claimed" {
            NativeMessagePanel(title: "Code scanned", message: "Confirm the request on \(syncStatus?.otherDevice?.label ?? "your phone") to continue here.") {}
        } else if status == "denied" || status == "expired" || (status == "consumed" && !grant) || secondsLeft == 0 {
            VStack(alignment: .leading, spacing: 12) {
                NativeMessagePanel(title: status == "denied" ? "Sync was declined" : "This code expired", message: "Create a fresh code to try again.") {}
                Button(isStarting ? "Creating…" : "Show a new code") { Task { await start() } }
                    .buttonStyle(BrandPrimaryButtonStyle()).disabled(isStarting)
            }
            .padding(20).nativePanel()
        } else {
            pairingCard(started, grant: grant)
        }
    }

    private func pairingCard(_ started: NativeSyncStarted, grant: Bool) -> some View {
        HStack(alignment: .top, spacing: 28) {
            if let image = qrImage(started.qrUrl) {
                Image(nsImage: image)
                    .resizable().interpolation(.none).frame(width: 220, height: 220)
                    .padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: Brand.cornerMd))
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("1. Open iBacalao on your phone\(grant ? "" : " and sign in")")
                Text("2. Go to Settings → School & devices and scan this code")
                Text(grant ? "3. Tap Allow here when your phone appears" : "3. Confirm the request on your phone")
                Divider().overlay(Brand.hairline)
                Text("OR ENTER THIS CODE").font(BrandFont.mono(10, weight: .semibold)).tracking(0.8).foregroundStyle(Brand.muted)
                Text(started.code.map(String.init).joined(separator: " "))
                    .font(BrandFont.mono(27, weight: .semibold)).tracking(2).foregroundStyle(Brand.bright)
                Text("Expires in \(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60))")
                    .font(BrandFont.mono(10)).foregroundStyle(Brand.secondary)
            }
            .font(BrandFont.body(13)).foregroundStyle(Brand.body)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20).nativePanel()
    }

    private func start() async {
        pollTask?.cancel()
        started = nil
        syncStatus = nil
        error = nil
        isStarting = true
        defer { isStarting = false }
        do {
            let value = try await NativeAPIClient.startDeviceSync()
            started = value
            secondsLeft = value.expiresInSeconds
            pollTask = Task { await poll(value) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func poll(_ started: NativeSyncStarted) async {
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            if syncStatus == nil || syncStatus?.status == "pending" {
                secondsLeft = max(0, secondsLeft - 2)
            }
            do {
                let next = try await NativeAPIClient.pollDeviceSync(started)
                syncStatus = next
                if next.status == "signed_in" {
                    guard let token = next.sessionToken, !token.isEmpty else {
                        error = "The phone approved this Mac, but its sign-in session could not be read. Start a new sync."
                        return
                    }
                    onSessionEstablished(token)
                    return
                }
                if ["denied", "expired", "consumed"].contains(next.status) { return }
            } catch {
                // Keep polling through short network interruptions.
            }
            if secondsLeft == 0 && (syncStatus == nil || syncStatus?.status == "pending") { return }
        }
    }

    private func decide(approve: Bool, started: NativeSyncStarted) async {
        isDeciding = true
        error = nil
        defer { isDeciding = false }
        do { syncStatus = try await NativeAPIClient.decideDeviceSync(started, approve: approve) }
        catch { self.error = error.localizedDescription }
    }

    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = Self.qrContext.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

private struct NativeTodoPage: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    @State private var busy = false
    @State private var error: String?
    @State private var ceremony: NativeCompletionCeremony?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                NativePageHeading(title: "To-do", subtitle: "Complete the task you opened from Today.")

                if navigation.todo.missionDecisionId.isEmpty {
                    NativeEmptyState(
                        title: "Choose a task first",
                        message: "Open Today and choose a task to mark it complete here.",
                        actionTitle: "Go to Today"
                    ) {
                        navigation.selection = .today
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        if let source = navigation.todo.source, !source.isEmpty {
                            Text(source.uppercased())
                                .font(BrandFont.mono(10, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(Brand.muted)
                        }

                        Text(navigation.todo.title)
                            .font(BrandFont.display(28, weight: .semibold))
                            .foregroundStyle(Brand.bright)
                            .fixedSize(horizontal: false, vertical: true)

                        if let error {
                            Text(error)
                                .font(BrandFont.body(12))
                                .foregroundStyle(Brand.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 12) {
                            Button("Back to Today") {
                                navigation.selection = .today
                            }
                            .buttonStyle(BrandGhostButtonStyle())

                            Spacer()

                            Button(busy ? "SAVING…" : "MARK DONE") {
                                Task { await markDone() }
                            }
                            .buttonStyle(BrandPrimaryButtonStyle())
                            .disabled(busy || navigation.todo.missionDecisionId.isEmpty)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 680, alignment: .leading)
                    .nativePanel()
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: navigation.todo) { _, _ in
            error = nil
            ceremony = nil
        }
        .sheet(item: $ceremony) { value in
            NativeCompletionCeremonyView(ceremony: value) {
                ceremony = nil
                navigation.selection = .today
            }
        }
    }

    private func markDone() async {
        guard !busy,
              !navigation.todo.taskId.isEmpty,
              !navigation.todo.missionDecisionId.isEmpty else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result = try await NativeAPIClient.completeMission(navigation.todo)
            if navigation.activeWorkContext?.id == navigation.todo.contextId
                || navigation.activeWorkContext?.missionDecisionId == navigation.todo.missionDecisionId {
                navigation.activeWorkContext = nil
            }
            if let completion = result.ceremony {
                ceremony = completion
            } else {
                navigation.selection = .today
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NativePageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(BrandFont.display(32, weight: .semibold)).tracking(-0.7).foregroundStyle(Brand.bright)
            Text(subtitle).font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
        }
        .padding(.bottom, 4)
    }
}

private struct NativeMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(BrandFont.mono(19, weight: .semibold)).foregroundStyle(Brand.bright)
            Text(label).font(BrandFont.mono(9)).tracking(0.6).foregroundStyle(Brand.muted)
        }
    }
}

private struct NativeMessagePanel: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(BrandFont.display(17, weight: .semibold)).foregroundStyle(Brand.bright)
            Text(message).font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
            Button("Try again", action: retry).buttonStyle(BrandGhostButtonStyle())
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).nativePanel()
    }
}

private struct NativeEmptyState: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(BrandFont.display(19, weight: .semibold)).foregroundStyle(Brand.bright)
            Text(message).font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
            Button(actionTitle, action: action).buttonStyle(BrandPrimaryButtonStyle())
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading).nativePanel()
    }
}

private extension View {
    func nativePanel() -> some View {
        background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.cornerLg))
            .overlay(RoundedRectangle(cornerRadius: Brand.cornerLg).stroke(Brand.hairline, lineWidth: 1))
    }
}

private func subjectLabel(_ id: String) -> String {
    id.replacingOccurrences(of: "_", with: " ").capitalized
}

private func changeLabel(_ change: Int?) -> String {
    guard let change else { return "First review — no baseline yet" }
    if change > 0 { return "+\(change) since first review" }
    return "\(change) since first review"
}

private func changeColor(_ change: Int?) -> Color {
    guard let change else { return Brand.muted }
    if change > 0 { return Brand.success }
    if change < 0 { return Brand.danger }
    return Brand.muted
}

private func formattedDate(_ value: String) -> String {
    if value.count == 10 {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        if let date = parser.date(from: value) {
            let display = DateFormatter()
            display.dateStyle = .medium
            return display.string(from: date)
        }
    }
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) else { return value }
    let display = DateFormatter()
    display.dateStyle = .short
    return display.string(from: date)
}

private func formattedDateTime(_ value: String) -> String {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) else { return value }
    let display = DateFormatter()
    display.dateStyle = .medium
    display.timeStyle = .short
    return display.string(from: date)
}

private func localDateKey(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: value)
}
