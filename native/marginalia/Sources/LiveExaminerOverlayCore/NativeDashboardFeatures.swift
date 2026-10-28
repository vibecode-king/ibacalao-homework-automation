import SwiftUI
import AppKit

// MARK: - Dashboard API models

private struct DashboardProgressBootstrap: Decodable {
    let overview: DashboardStudentOverview?
    let week: DashboardWeekEnvelope?
    let reviewProgress: DashboardReviewEnvelope?
}

private struct DashboardWeekEnvelope: Decodable {
    let week: DashboardWeek
    let subjects: [String]
}

private struct DashboardReviewEnvelope: Decodable {
    let subjects: [DashboardSubjectProgress]
}

private struct DashboardStudentOverview: Decodable {
    struct Stats: Decodable {
        let reviewsCompleted: Int?
        let subjectsCovered: Int?
        let averageScorePct: Int?
        let planCompletionPct: Int?
        let tasksDone: Int?
        let tasksTotal: Int?
    }

    struct CAS: Decodable {
        let source: String
        let status: String
        let completedExperiences: Int?
        let learningOutcomesCovered: Int?
        let learningOutcomesTotal: Int
        let interviewsCompleted: Int?
        let interviewsTotal: Int
    }

    struct ActivePlan: Decodable {
        let subject: String
        let essayType: String
        let deadline: String
        let targetTotal: Int
        let currentTotal: Int
        let tasksDone: Int
        let tasksTotal: Int
    }

    struct ScorePoint: Decodable, Identifiable {
        var id: String { "\(date):\(pct)" }
        let date: String
        let pct: Int
    }

    let stats: Stats
    let scoreHistory: [ScorePoint]
    let cas: CAS
    let activePlan: ActivePlan?
}

private struct DashboardCriterionDelta: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let fromScore: Int
    let toScore: Int
    let scoreMax: Int
    let change: Int
}

private struct DashboardReviewPoint: Decodable, Identifiable {
    let id: String
    let date: String
    let totalScore: Int
    let totalMax: Int
    let pct: Int
}

private struct DashboardSubjectProgress: Decodable, Identifiable {
    var id: String { "\(subject):\(level)" }
    let subject: String
    let level: String
    let latest: DashboardReviewPoint
    let totalChange: Int?
    let improved: [DashboardCriterionDelta]
    let regressed: [DashboardCriterionDelta]
    let unchanged: [DashboardCriterionDelta]
    let history: [DashboardReviewPoint]
}

private struct DashboardWeekResponse: Decodable {
    let week: DashboardWeek
    let subjects: [String]
}

private struct DashboardWeek: Decodable {
    let weekStart: String
    let weekEnd: String
    let total: Int
    let done: Int
    let pct: Int?
    let goals: [DashboardWeekGoal]
}

private struct DashboardWeekGoal: Decodable, Identifiable {
    let id: String
    let title: String
    let subject: String
    let date: String
    let done: Bool
    let source: String
}

private struct DashboardWeekMutation: Decodable {
    struct Experience: Decodable {
        struct Gratification: Decodable { let id: String }
        let gratification: Gratification?
    }
    let week: DashboardWeek
    let experience: Experience?
}

private struct DashboardPlanEvent: Decodable, Identifiable {
    let id: String
    let date: String
    let kind: String
    let title: String
    let subject: String
    let notes: String?
}

private enum DashboardAPI {
    private struct HTTPError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    private static var baseURL: URL {
        URL(string: LLMClient.resolvedNativeAPIBaseURL) ?? URL(string: LLMClient.defaultNativeAPIBaseURL)!
    }

    private static func request(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        guard let token = KeyStore.loadSessionToken() else { throw NativeAPIClientError.missingSession }
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false) else {
            throw NativeAPIClientError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw NativeAPIClientError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if method != "GET" {
            var origin = URLComponents()
            origin.scheme = baseURL.scheme
            origin.host = baseURL.host
            origin.port = baseURL.port
            request.setValue(origin.string ?? baseURL.absoluteString, forHTTPHeaderField: "Origin")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeAPIClientError.server("iBacalao returned an unreadable response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (payload?["message"] as? String)
                ?? (payload?["error"] as? String)
                ?? (http.statusCode == 401 ? "Sign in to use this feature." : "Request failed (\(http.statusCode)).")
            throw HTTPError(status: http.statusCode, message: message)
        }
        return data
    }

    static func progressBootstrap() async throws -> DashboardProgressBootstrap {
        do {
            let data = try await request(
                "/api/native/bootstrap/progress",
                query: [URLQueryItem(name: "timeZone", value: TimeZone.current.identifier)]
            )
            return try JSONDecoder().decode(DashboardProgressBootstrap.self, from: data)
        } catch let error as HTTPError where error.status == 404 {
            var overview: DashboardStudentOverview?
            var weekEnvelope: DashboardWeekEnvelope?
            var reviews: DashboardReviewEnvelope?
            var firstError: Error?
            do { overview = try await studentOverview() } catch { firstError = error }
            do {
                let loaded = try await self.week()
                weekEnvelope = DashboardWeekEnvelope(week: loaded.week, subjects: loaded.subjects)
            } catch { if firstError == nil { firstError = error } }
            do { reviews = DashboardReviewEnvelope(subjects: try await reviewProgress()) } catch { if firstError == nil { firstError = error } }
            if overview == nil && weekEnvelope == nil && reviews == nil, let firstError { throw firstError }
            return DashboardProgressBootstrap(overview: overview, week: weekEnvelope, reviewProgress: reviews)
        }
    }

    static func studentOverview() async throws -> DashboardStudentOverview {
        let data = try await request("/api/dashboard/student-overview")
        return try JSONDecoder().decode(DashboardStudentOverview.self, from: data)
    }

    static func reviewProgress() async throws -> [DashboardSubjectProgress] {
        let data = try await request("/api/native/review-progress")
        return try JSONDecoder().decode(DashboardReviewEnvelope.self, from: data).subjects
    }

    static func week() async throws -> DashboardWeekResponse {
        let data = try await request(
            "/api/native/week",
            query: [URLQueryItem(name: "timeZone", value: TimeZone.current.identifier)]
        )
        return try JSONDecoder().decode(DashboardWeekResponse.self, from: data)
    }

    static func addWeekGoal(title: String, subject: String) async throws -> DashboardWeek {
        let body = try JSONSerialization.data(withJSONObject: [
            "title": title,
            "subject": subject,
            "timeZone": TimeZone.current.identifier,
            "idempotencyKey": UUID().uuidString,
        ])
        let data = try await request("/api/native/week", method: "POST", body: body)
        return try JSONDecoder().decode(DashboardWeekMutation.self, from: data).week
    }

    static func setWeekGoal(_ goal: DashboardWeekGoal, done: Bool) async throws -> DashboardWeekMutation {
        let body = try JSONSerialization.data(withJSONObject: [
            "goalId": goal.id,
            "done": done,
            "title": goal.title,
            "subject": goal.subject,
            "timeZone": TimeZone.current.identifier,
        ])
        let data = try await request("/api/native/week", method: "PATCH", body: body)
        return try JSONDecoder().decode(DashboardWeekMutation.self, from: data)
    }

    static func planCalendar() async throws -> [DashboardPlanEvent] {
        struct Response: Decodable { let events: [DashboardPlanEvent] }
        let data = try await request("/api/native/plan-calendar")
        return try JSONDecoder().decode(Response.self, from: data).events
    }

    static func openExternal(_ path: String) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Shared dashboard UI

private struct DashboardPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Brand.ground)
    }
}

private struct DashboardHeading: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    var back: NativeWorkspaceTab?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let back {
                Button { NativeWorkspaceNavigation.shared.show(back) } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(BrandGhostButtonStyle())
                .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 5) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(BrandFont.mono(9, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(Brand.muted)
                }
                Text(title)
                    .font(BrandFont.display(31, weight: .semibold))
                    .tracking(-0.7)
                    .foregroundStyle(Brand.bright)
                if let subtitle {
                    Text(subtitle)
                        .font(BrandFont.body(13))
                        .foregroundStyle(Brand.secondary)
                }
            }
        }
    }
}

private struct DashboardPanel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card)
            .overlay(RoundedRectangle(cornerRadius: Brand.cornerLg).stroke(Brand.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Brand.cornerLg))
    }
}

private struct DashboardStatePanel: View {
    let title: String
    let message: String
    var action: String?
    var onAction: (() -> Void)?

    var body: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(BrandFont.display(20, weight: .semibold)).foregroundStyle(Brand.bright)
                Text(message).font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
                if let action, let onAction {
                    Button(action, action: onAction).buttonStyle(BrandPrimaryButtonStyle())
                }
            }
        }
    }
}

private struct DashboardProgressBar: View {
    let value: Int?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Brand.hairline)
                if let value {
                    Rectangle()
                        .fill(Brand.accent)
                        .frame(width: geo.size.width * CGFloat(max(0, min(100, value))) / 100)
                }
            }
        }
        .frame(height: 4)
        .accessibilityLabel(value.map { "\($0) percent" } ?? "No progress value")
    }
}

private struct DashboardSparkline: View {
    let values: [Int]
    var height: CGFloat = 64

    var body: some View {
        GeometryReader { geo in
            let points = values.enumerated().map { index, value -> CGPoint in
                let x = values.count <= 1 ? 0 : geo.size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = geo.size.height * (1 - CGFloat(max(0, min(100, value))) / 100)
                return CGPoint(x: x, y: y)
            }
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                }
                .stroke(Brand.hairline, lineWidth: 1)
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(Brand.bright, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    Circle().fill(Brand.accent).frame(width: 6, height: 6).position(point)
                }
            }
        }
        .frame(height: height)
    }
}

private func dashboardSubjectLabel(_ subject: String, level: String? = nil) -> String {
    let base = subject
        .split(separator: "_")
        .map { part -> String in
            let value = String(part)
            return value.count <= 2 ? value.uppercased() : value.prefix(1).uppercased() + value.dropFirst()
        }
        .joined(separator: " ")
    guard let level, !level.isEmpty else { return base }
    return "\(base) · \(level)"
}

private func dashboardChangeLabel(_ value: Int?) -> String {
    guard let value else { return "—" }
    if value > 0 { return "+\(value)" }
    if value < 0 { return "−\(abs(value))" }
    return "0"
}

private func dashboardPointLabel(_ iso: String) -> String {
    let formatter = ISO8601DateFormatter()
    let date = formatter.date(from: iso) ?? {
        let simple = DateFormatter()
        simple.locale = Locale(identifier: "en_US_POSIX")
        simple.dateFormat = "yyyy-MM-dd"
        return simple.date(from: String(iso.prefix(10)))
    }()
    guard let date else { return String(iso.prefix(10)).uppercased() }
    return date.formatted(.dateTime.month(.abbreviated).day()).uppercased()
}

private func dashboardDateLabel(_ iso: String) -> String {
    let simple = DateFormatter()
    simple.locale = Locale(identifier: "en_US_POSIX")
    simple.dateFormat = "yyyy-MM-dd"
    guard let date = simple.date(from: String(iso.prefix(10))) else { return String(iso.prefix(10)) }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
}

// MARK: - Progress home

struct NativeDashboardHomePage: View {
    let onOpenWeb: (String) -> Void

    @State private var bootstrap: DashboardProgressBootstrap?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        DashboardPage {
            HStack(alignment: .top, spacing: 16) {
                DashboardHeading(eyebrow: "Dashboard", title: "Progress", subtitle: "One read on what is moving, what is due, and what to do next.", back: nil)
                Spacer(minLength: 16)
                Button {
                    onOpenWeb("/chat")
                } label: {
                    Label("Chat", systemImage: "message")
                }
                .buttonStyle(BrandPrimaryButtonStyle())
                .accessibilityLabel("Open iBacalao Chat")
            }

            if let error, bootstrap == nil {
                DashboardStatePanel(title: "Progress unavailable", message: error, action: "Try again") {
                    Task { await load() }
                }
                if error.localizedCaseInsensitiveContains("sign in") {
                    Button("Sign in from phone") { NativeWorkspaceNavigation.shared.show(.sync) }.buttonStyle(BrandGhostButtonStyle())
                }
            } else if loading && bootstrap == nil {
                DashboardLoadingRows()
            } else if let bootstrap {
                if hasNoReviewBaseline(bootstrap) {
                    DashboardStatePanel(
                        title: "Your progress starts with a review",
                        message: "Review a draft to establish a baseline. Your next review will show exactly what moved.",
                        action: "Review draft"
                    ) { NativeWorkspaceNavigation.shared.show(.draftEditor) }
                } else {
                    progressHome(bootstrap)
                }
                Button("Saved review history") { onOpenWeb("/record-history") }
                    .buttonStyle(BrandGhostButtonStyle())
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func progressHome(_ data: DashboardProgressBootstrap) -> some View {
        let reviews = data.reviewProgress?.subjects ?? []
        let focus = focusReview(reviews, plan: data.overview?.activePlan)

        DashboardPanel {
            VStack(alignment: .leading, spacing: 18) {
                Text("FOCUS")
                    .font(BrandFont.mono(9, weight: .semibold)).tracking(0.8).foregroundStyle(Brand.muted)
                if let focus {
                    let plan = data.overview?.activePlan
                    let usesPlan = plan != nil
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(usesPlan ? "\(dashboardSubjectLabel(plan!.subject)) \(plan!.essayType)" : dashboardSubjectLabel(focus.subject, level: focus.level))
                                .font(BrandFont.display(24, weight: .semibold)).foregroundStyle(Brand.bright)
                            Text(recommendation(for: focus))
                                .font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
                        }
                        Spacer()
                        Text(usesPlan ? "\(plan!.currentTotal)/\(plan!.targetTotal)" : "\(focus.latest.totalScore)/\(focus.latest.totalMax)")
                            .font(BrandFont.mono(19, weight: .semibold)).foregroundStyle(Brand.bright)
                        Text(dashboardChangeLabel(focus.totalChange))
                            .font(BrandFont.mono(11, weight: .semibold))
                            .foregroundStyle((focus.totalChange ?? 0) > 0 ? Brand.success : (focus.totalChange ?? 0) < 0 ? Brand.danger : Brand.muted)
                    }
                    Rectangle().fill(Brand.hairline).frame(height: 1)
                    Button {
                        if usesPlan && plan?.essayType == "IA" {
                            NativeWorkspaceNavigation.shared.show(.draftEditor)
                        } else {
                            NativeWorkspaceNavigation.shared.show(.progress)
                        }
                    } label: {
                        HStack {
                            Text(usesPlan && plan?.essayType == "IA" ? "Open draft editor" : "Review draft progress")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(BrandFont.body(12, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                } else {
                    Text("Review a draft to get a criterion-level next move.")
                        .font(BrandFont.body(14)).foregroundStyle(Brand.secondary)
                    Button("Review draft") { NativeWorkspaceNavigation.shared.show(.draftEditor) }
                        .buttonStyle(BrandPrimaryButtonStyle())
                }
            }
        }

        HStack(alignment: .top, spacing: 12) {
            statusCard(
                label: "THIS WEEK",
                value: data.week.map { "\($0.week.done)/\($0.week.total)" } ?? "—",
                note: data.week.map { envelope in
                    let remaining = max(0, envelope.week.total - envelope.week.done)
                    return envelope.week.total == 0 ? "Set your week" : remaining == 0 ? "Week closed" : "\(remaining) left"
                } ?? "Set your week",
                action: { NativeWorkspaceNavigation.shared.show(.week) }
            )
            statusCard(
                label: "TARGET",
                value: data.overview?.activePlan.map { "\($0.currentTotal)/\($0.targetTotal)" } ?? "—",
                note: data.overview?.activePlan.map { "\(max(0, $0.targetTotal - $0.currentTotal)) points away" } ?? "No active target",
                action: { NativeWorkspaceNavigation.shared.show(.yourIB) }
            )
        }

        if let focus {
            DashboardPanel {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WHY THIS")
                            .font(BrandFont.mono(9, weight: .semibold)).tracking(0.7).foregroundStyle(Brand.muted)
                        Text(focus.totalChange == nil ? "This is your baseline review." : "This uses your latest criterion movement, not a generic study recommendation.")
                            .font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                    }
                    Spacer()
                    Button("See why") { NativeWorkspaceNavigation.shared.show(.progress) }
                        .buttonStyle(BrandGhostButtonStyle())
                }
            }
        }
    }

    private func statusCard(label: String, value: String, note: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(BrandFont.mono(9, weight: .semibold)).tracking(0.7).foregroundStyle(Brand.muted)
                Text(value).font(BrandFont.display(28, weight: .semibold)).foregroundStyle(Brand.bright)
                Text(note).font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card)
            .overlay(RoundedRectangle(cornerRadius: Brand.cornerLg).stroke(Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func focusReview(_ reviews: [DashboardSubjectProgress], plan: DashboardStudentOverview.ActivePlan?) -> DashboardSubjectProgress? {
        if let plan {
            let target = normalizedSubject(plan.subject)
            if let matched = reviews.first(where: {
                let subject = normalizedSubject($0.subject)
                return subject.hasPrefix(target) || target.hasPrefix(subject)
            }) {
                return matched
            }
        }
        return reviews.sorted { abs($0.totalChange ?? 0) > abs($1.totalChange ?? 0) }.first
    }

    private func normalizedSubject(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func recommendation(for progress: DashboardSubjectProgress) -> String {
        let candidates = (progress.improved + progress.regressed + progress.unchanged)
            .filter { $0.toScore < $0.scoreMax }
            .sorted {
                let leftGap = $0.scoreMax - $0.toScore
                let rightGap = $1.scoreMax - $1.toScore
                return leftGap == rightGap ? $0.name.localizedCompare($1.name) == .orderedAscending : leftGap > rightGap
            }
        if let criterion = candidates.first {
            return "Fix \(criterion.name) first · \(criterion.toScore)/\(criterion.scoreMax)"
        }
        if progress.totalChange == nil { return "First review saved. The next one will show movement." }
        if (progress.totalChange ?? 0) > 0 { return "Keep the gain. Recheck the criterion with the largest remaining gap." }
        return "Use the latest criterion change to choose the next revision."
    }

    private func hasNoReviewBaseline(_ data: DashboardProgressBootstrap) -> Bool {
        let reviews = data.overview?.stats.reviewsCompleted ?? data.reviewProgress?.subjects.reduce(0) { $0 + $1.history.count } ?? 0
        return reviews == 0 && (data.reviewProgress?.subjects.isEmpty ?? true)
    }

    private func load() async {
        loading = true
        do {
            bootstrap = try await DashboardAPI.progressBootstrap()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct DashboardLoadingRows: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: Brand.cornerLg)
                    .fill(Brand.skeleton.opacity(index == 0 ? 0.95 : 0.65))
                    .frame(height: index == 0 ? 150 : 92)
                    .overlay(RoundedRectangle(cornerRadius: Brand.cornerLg).stroke(Brand.hairline))
            }
        }
        .accessibilityLabel("Loading progress")
    }
}

// MARK: - Week

struct NativeWeekPage: View {
    let onOpenWeb: (String) -> Void

    @State private var response: DashboardWeekResponse?
    @State private var error: String?
    @State private var busy = false
    @State private var showingDone = false
    @State private var showingAdd = false
    @State private var newTitle = ""
    @State private var selectedSubject = ""
    @State private var calendarNote: String?

    var body: some View {
        DashboardPage {
            DashboardHeading(eyebrow: "Dashboard", title: "Your week", subtitle: "The remaining work, grouped by the day it belongs to.", back: .dashboard)

            if let error {
                DashboardStatePanel(title: "Week unavailable", message: error, action: "Try again") { Task { await load() } }
            }
            if response == nil && error == nil {
                DashboardLoadingRows()
            } else if let response {
                let week = response.week
                if week.total == 0 {
                    DashboardStatePanel(
                        title: response.subjects.isEmpty ? "Choose subjects first" : "Nothing planned yet",
                        message: response.subjects.isEmpty
                            ? "Your week uses your IB subjects to keep goals attached to the right course."
                            : "Add one useful thing. You can keep the week deliberately small.",
                        action: response.subjects.isEmpty ? "Choose subjects" : "Add first goal"
                    ) {
                        if response.subjects.isEmpty {
                            NativeWorkspaceNavigation.shared.show(.customization)
                        } else {
                            selectedSubject = response.subjects.first ?? ""
                            showingAdd = true
                        }
                    }
                } else {
                    weekHero(week)
                    openAgenda(week.goals.filter { !$0.done })
                    completedBlock(week.goals.filter(\.done))
                    actionPanel(subjects: response.subjects)
                }
                if let calendarNote {
                    Text(calendarNote).font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingAdd) { addGoalSheet }
    }

    private func weekHero(_ week: DashboardWeek) -> some View {
        let remaining = max(0, week.total - week.done)
        return DashboardPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(remaining == 0 && week.total > 0 ? "Week closed" : "\(remaining) left")
                            .font(BrandFont.display(30, weight: .semibold)).foregroundStyle(Brand.bright)
                        Text("\(week.done) of \(week.total) complete")
                            .font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                    }
                    Spacer()
                    Text(week.pct.map { "\($0)%" } ?? "—")
                        .font(BrandFont.mono(14, weight: .semibold)).foregroundStyle(Brand.bright)
                }
                DashboardProgressBar(value: week.pct)
                weekStrip(week)
            }
        }
    }

    private func weekStrip(_ week: DashboardWeek) -> some View {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.date(from: week.weekStart) ?? Date()
        return HStack(spacing: 8) {
            ForEach(0..<7, id: \.self) { offset in
                let date = Calendar.current.date(byAdding: .day, value: offset, to: start) ?? start
                let key = formatter.string(from: date)
                let dayGoals = week.goals.filter { $0.date == key }
                VStack(spacing: 6) {
                    Text(date.formatted(.dateTime.weekday(.narrow)).uppercased())
                        .font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                    Text("\(Calendar.current.component(.day, from: date))")
                        .font(BrandFont.mono(11)).foregroundStyle(Brand.body)
                    HStack(spacing: 2) {
                        ForEach(0..<min(3, dayGoals.count), id: \.self) { index in
                            Circle().fill(dayGoals[index].done ? Brand.accent : Brand.edge).frame(width: 5, height: 5)
                        }
                    }.frame(height: 5)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Brand.active.opacity(key == dashboardLocalDateKey() ? 0.8 : 0))
            }
        }
    }

    @ViewBuilder
    private func openAgenda(_ goals: [DashboardWeekGoal]) -> some View {
        if !goals.isEmpty {
            let grouped = Dictionary(grouping: goals.sorted { $0.date < $1.date }, by: \.date)
            VStack(alignment: .leading, spacing: 16) {
                Text("REMAINING").font(BrandFont.mono(9, weight: .semibold)).tracking(0.8).foregroundStyle(Brand.muted)
                ForEach(grouped.keys.sorted(), id: \.self) { date in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dayHeading(date))
                            .font(BrandFont.mono(9, weight: .semibold)).tracking(0.6).foregroundStyle(Brand.muted)
                            .padding(.bottom, 8)
                        DashboardPanel {
                            VStack(spacing: 0) {
                                ForEach(Array((grouped[date] ?? []).enumerated()), id: \.element.id) { index, goal in
                                    Button { Task { await toggle(goal) } } label: {
                                        HStack(spacing: 14) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(dashboardSubjectLabel(goal.subject).uppercased())
                                                    .font(BrandFont.mono(9, weight: .semibold)).tracking(0.5).foregroundStyle(Brand.muted)
                                                Text(goal.title).font(BrandFont.body(13, weight: .medium)).foregroundStyle(Brand.bright)
                                            }
                                            Spacer()
                                            RoundedRectangle(cornerRadius: 3).stroke(Brand.edge, lineWidth: 1).frame(width: 18, height: 18)
                                        }
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(busy)
                                    if index < (grouped[date]?.count ?? 0) - 1 {
                                        Rectangle().fill(Brand.hairline).frame(height: 1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func completedBlock(_ goals: [DashboardWeekGoal]) -> some View {
        if !goals.isEmpty {
            DashboardPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        showingDone.toggle()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("COMPLETED").font(BrandFont.mono(9, weight: .semibold)).tracking(0.6).foregroundStyle(Brand.muted)
                                Text("\(goals.count) finished this week").font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                            }
                            Spacer()
                            Image(systemName: showingDone ? "minus" : "plus").foregroundStyle(Brand.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if showingDone {
                        Rectangle().fill(Brand.hairline).frame(height: 1)
                        ForEach(goals) { goal in
                            Button { Task { await toggle(goal) } } label: {
                                HStack {
                                    Image(systemName: "checkmark.square.fill").foregroundStyle(Brand.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dashboardSubjectLabel(goal.subject).uppercased())
                                            .font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                                        Text(goal.title).font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                                            .strikethrough(true)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                        }
                    }
                }
            }
        }
    }

    private func actionPanel(subjects: [String]) -> some View {
        DashboardPanel {
            VStack(spacing: 0) {
                if !subjects.isEmpty {
                    Button {
                        selectedSubject = subjects.first ?? ""
                        showingAdd = true
                    } label: {
                        dashboardActionRow(icon: "plus", title: "Add a goal", body: "Put one more useful thing into this week.")
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(Brand.hairline).frame(height: 1)
                }
                Button { Task { await addToCalendar() } } label: {
                    dashboardActionRow(icon: "calendar.badge.plus", title: "Add plan dates", body: "Send remaining plan dates to Calendar.")
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }

    private func dashboardActionRow(icon: String, title: String, body: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Brand.body).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
                Text(body).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
            }
            Spacer()
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Brand.muted)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var addGoalSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add one thing").font(BrandFont.display(24, weight: .semibold)).foregroundStyle(Brand.bright)
            Text("Keep it concrete enough that you can mark it done this week.")
                .font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
            if let subjects = response?.subjects {
                Picker("Subject", selection: $selectedSubject) {
                    ForEach(subjects, id: \.self) { subject in Text(dashboardSubjectLabel(subject)).tag(subject) }
                }
            }
            TextField("What needs doing?", text: $newTitle)
                .textFieldStyle(BrandOutlinedFieldStyle())
            HStack {
                Button("Cancel") { showingAdd = false }.buttonStyle(BrandGhostButtonStyle())
                Spacer()
                Button(busy ? "Adding…" : "Add") { Task { await addGoal() } }
                    .buttonStyle(BrandPrimaryButtonStyle())
                    .disabled(busy || selectedSubject.isEmpty || newTitle.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Brand.ground)
        .preferredColorScheme(.dark)
    }

    private func dayHeading(_ date: String) -> String {
        let today = dashboardLocalDateKey()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: date) else { return date }
        let weekday = parsed.formatted(.dateTime.weekday(.abbreviated)).uppercased()
        let prefix = date == today ? "TODAY" : date < today ? "OVERDUE · \(weekday)" : weekday
        return "\(prefix) · \(parsed.formatted(.dateTime.month(.abbreviated).day()).uppercased())"
    }

    private func load() async {
        do {
            response = try await DashboardAPI.week()
            if selectedSubject.isEmpty { selectedSubject = response?.subjects.first ?? "" }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggle(_ goal: DashboardWeekGoal) async {
        guard !busy else { return }
        busy = true
        do {
            let result = try await DashboardAPI.setWeekGoal(goal, done: !goal.done)
            if let current = response { response = DashboardWeekResponse(week: result.week, subjects: current.subjects) }
            if let gratification = result.experience?.gratification { onOpenWeb("/gratification?experienceId=\(gratification.id)") }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func addGoal() async {
        guard !busy else { return }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2, !selectedSubject.isEmpty else { return }
        busy = true
        do {
            let week = try await DashboardAPI.addWeekGoal(title: title, subject: selectedSubject)
            if let current = response { response = DashboardWeekResponse(week: week, subjects: current.subjects) }
            newTitle = ""
            showingAdd = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func addToCalendar() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let events = try await DashboardAPI.planCalendar()
            guard !events.isEmpty else { calendarNote = "There is nothing left in your plan to add."; return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ibacalao-plan-\(UUID().uuidString).ics")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd"
            var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//iBacalao//Study Plan//EN"]
            for event in events {
                let date = event.date.replacingOccurrences(of: "-", with: "")
                lines += [
                    "BEGIN:VEVENT",
                    "UID:\(event.id)@ibacalao.com",
                    "DTSTART;VALUE=DATE:\(date)",
                    "SUMMARY:\(event.title.replacingOccurrences(of: ",", with: "\\,"))",
                    "DESCRIPTION:\((event.notes ?? event.subject).replacingOccurrences(of: "\n", with: "\\n"))",
                    "END:VEVENT",
                ]
            }
            lines.append("END:VCALENDAR")
            try lines.joined(separator: "\r\n").write(to: file, atomically: true, encoding: .utf8)
            let opened = NSWorkspace.shared.open(file)
            calendarNote = opened ? "\(events.count) date\(events.count == 1 ? "" : "s") ready to add in Calendar." : "Could not open Calendar."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private func dashboardLocalDateKey(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

// MARK: - Review progress

struct NativeReviewProgressPage: View {
    @State private var subjects: [DashboardSubjectProgress]?
    @State private var error: String?
    @State private var expanded: String?
    @State private var refreshing = false

    var body: some View {
        DashboardPage {
            DashboardHeading(eyebrow: "Dashboard", title: "Draft progress", subtitle: "Track what changed across reviews, criterion by criterion.", back: .dashboard)

            if let error, subjects == nil {
                DashboardStatePanel(title: "Progress unavailable", message: error, action: "Try again") { Task { await load() } }
            } else if subjects == nil {
                DashboardLoadingRows()
            } else if subjects?.isEmpty == true {
                DashboardStatePanel(
                    title: "Your progress starts with a review",
                    message: "Review your first draft to establish a baseline. Later reviews will show what changed.",
                    action: "Review draft"
                ) { NativeWorkspaceNavigation.shared.show(.draftEditor) }
            } else if let subjects {
                summaryCard(subjects)
                VStack(spacing: 12) {
                    ForEach(subjects) { progressCard($0) }
                }
            }
        }
        .task { await load() }
    }

    private func summaryCard(_ subjects: [DashboardSubjectProgress]) -> some View {
        let compared = subjects.filter { $0.totalChange != nil }
        let improved = compared.filter { ($0.totalChange ?? 0) > 0 }.count
        let down = compared.filter { ($0.totalChange ?? 0) < 0 }.count
        let flat = compared.filter { $0.totalChange == 0 }.count
        let title: String = {
            if compared.isEmpty { return "Your next review creates the comparison." }
            if improved == compared.count { return "Every compared draft moved up." }
            if improved > 0 { return "\(improved) of \(compared.count) compared drafts improved." }
            if down > 0 { return "No gains yet. The movement is still useful." }
            return "Your compared drafts are holding steady."
        }()

        return DashboardPanel {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(BrandFont.display(23, weight: .semibold)).foregroundStyle(Brand.bright)
                Rectangle().fill(Brand.hairline).frame(height: 1)
                HStack {
                    summaryFact(compared.isEmpty ? "—" : "\(improved)/\(compared.count)", "IMPROVED")
                    Divider().overlay(Brand.hairline)
                    summaryFact("\(down)", "MOVED DOWN")
                    Divider().overlay(Brand.hairline)
                    summaryFact("\(flat)", "UNCHANGED")
                }
                .frame(height: 45)
            }
        }
    }

    private func summaryFact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(BrandFont.body(16, weight: .bold)).foregroundStyle(Brand.bright)
            Text(label).font(BrandFont.mono(9)).tracking(0.45).foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressCard(_ progress: DashboardSubjectProgress) -> some View {
        let chronological = progress.history.sorted { $0.date < $1.date }
        let delta = progress.totalChange
        let isExpanded = expanded == progress.id
        let primary: (String, String, String) = {
            if let item = progress.improved.first { return ("BIGGEST WIN", item.name, "+\(item.change)") }
            if let item = progress.regressed.first { return ("BIGGEST SLIP", item.name, "−\(abs(item.change))") }
            if progress.totalChange == nil { return ("BASELINE", "First review", "—") }
            return ("LATEST COMPARISON", "No criterion moved", "0")
        }()

        return Button {
            expanded = isExpanded ? nil : progress.id
        } label: {
            DashboardPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dashboardSubjectLabel(progress.subject, level: progress.level).uppercased())
                                .font(BrandFont.mono(9, weight: .semibold)).tracking(0.55).foregroundStyle(Brand.muted)
                            Text("\(dashboardPointLabel(progress.latest.date)) · \(progress.history.count) REVIEW\(progress.history.count == 1 ? "" : "S")")
                                .font(BrandFont.mono(9)).tracking(0.35).foregroundStyle(Brand.faint)
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: delta == nil || delta == 0 ? "minus" : delta! > 0 ? "arrow.up.right" : "arrow.down.right")
                            Text(dashboardChangeLabel(delta))
                        }
                        .font(BrandFont.mono(10, weight: .semibold))
                        .foregroundStyle(delta == nil || delta == 0 ? Brand.secondary : delta! > 0 ? Brand.success : Brand.danger)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Brand.active)
                        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(progress.latest.totalScore)")
                            .font(BrandFont.display(44, weight: .semibold)).tracking(-1).foregroundStyle(Brand.bright)
                        Text("/ \(progress.latest.totalMax)").font(BrandFont.mono(10)).foregroundStyle(Brand.muted)
                        Spacer()
                        Text("\(progress.latest.pct)%").font(BrandFont.mono(10, weight: .semibold)).foregroundStyle(Brand.secondary)
                    }

                    if chronological.count > 1 {
                        VStack(spacing: 5) {
                            HStack {
                                Text("OLDER"); Spacer(); Text("LATEST")
                            }
                            .font(BrandFont.mono(8)).tracking(0.4).foregroundStyle(Brand.muted)
                            DashboardSparkline(values: chronological.map(\.pct), height: 62)
                        }
                    }

                    Rectangle().fill(Brand.hairline).frame(height: 1)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(primary.0).font(BrandFont.mono(9, weight: .semibold)).tracking(0.45).foregroundStyle(Brand.muted)
                            Text(primary.1).font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
                        }
                        Spacer()
                        Text(primary.2).font(BrandFont.mono(11, weight: .semibold)).foregroundStyle(Brand.body)
                    }

                    Rectangle().fill(Brand.hairline).frame(height: 1)
                    HStack {
                        Text(isExpanded ? "Hide details" : "Review details")
                            .font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                        Spacer()
                        Image(systemName: isExpanded ? "minus" : "plus").font(.system(size: 10)).foregroundStyle(Brand.secondary)
                    }

                    if isExpanded {
                        expandedDetails(progress, chronological: chronological)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func expandedDetails(_ progress: DashboardSubjectProgress, chronological: [DashboardReviewPoint]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SCORE HISTORY").font(BrandFont.mono(9, weight: .semibold)).tracking(0.45).foregroundStyle(Brand.muted)
                Spacer()
                Text("OLD → NEW").font(BrandFont.mono(8)).foregroundStyle(Brand.faint)
            }
            HStack(spacing: 8) {
                ForEach(chronological) { point in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dashboardPointLabel(point.date)).font(BrandFont.mono(8)).foregroundStyle(Brand.muted)
                        Text("\(point.totalScore)/\(point.totalMax)").font(BrandFont.mono(10, weight: .semibold)).foregroundStyle(Brand.bright)
                    }
                    .padding(8).background(Brand.active).clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                }
            }
            if let win = progress.improved.first { deltaRow("BIGGEST WIN", win, color: Brand.success) }
            if let slip = progress.regressed.first { deltaRow("BIGGEST SLIP", slip, color: Brand.danger) }
            if !progress.unchanged.isEmpty {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("STILL FLAT").font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                        Text(progress.unchanged.map(\.name).joined(separator: ", "))
                            .font(BrandFont.body(12, weight: .semibold)).foregroundStyle(Brand.body)
                    }
                    Spacer()
                    Text("0").font(BrandFont.mono(10)).foregroundStyle(Brand.secondary)
                }
                .padding(.top, 8)
            }
        }
        .padding(.top, 4)
    }

    private func deltaRow(_ label: String, _ delta: DashboardCriterionDelta, color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                Text(delta.name).font(BrandFont.body(12, weight: .semibold)).foregroundStyle(Brand.body)
            }
            Spacer()
            Text(delta.change > 0 ? "+\(delta.change)" : "−\(abs(delta.change))")
                .font(BrandFont.mono(10, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.top, 8)
    }

    private func load() async {
        refreshing = true
        do {
            subjects = try await DashboardAPI.reviewProgress()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refreshing = false
    }
}

// MARK: - Your IB

struct NativeYourIBPage: View {
    @State private var overview: DashboardStudentOverview?
    @State private var error: String?

    var body: some View {
        DashboardPage {
            DashboardHeading(eyebrow: "Dashboard", title: "Your IB", subtitle: "Your current review, plan, and CAS reality in one ledger.", back: .dashboard)

            if let error, overview == nil {
                DashboardStatePanel(title: "Your IB unavailable", message: error, action: "Try again") { Task { await load() } }
            } else if overview == nil {
                DashboardLoadingRows()
            } else if let overview {
                if isEmpty(overview) {
                    DashboardStatePanel(
                        title: "This fills in as you work",
                        message: "No week, CAS activity, or draft review has landed yet. Start with a draft review to create your first progress signal.",
                        action: "Review draft"
                    ) { NativeWorkspaceNavigation.shared.show(.draftEditor) }
                } else {
                    reviewsCard(overview)
                    planCard(overview.activePlan)
                    ledgerCard(overview)
                }
            }
        }
        .task { await load() }
    }

    private func reviewsCard(_ overview: DashboardStudentOverview) -> some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("REVIEWS").font(BrandFont.mono(9, weight: .semibold)).tracking(0.7).foregroundStyle(Brand.muted)
                        Text("\(overview.stats.reviewsCompleted ?? 0) REVIEW\((overview.stats.reviewsCompleted ?? 0) == 1 ? "" : "S")")
                            .font(BrandFont.body(12, weight: .semibold)).foregroundStyle(Brand.body)
                    }
                    Spacer()
                    Text(overview.stats.averageScorePct.map { "\($0)%" } ?? "—")
                        .font(BrandFont.display(42, weight: .semibold)).tracking(-1).foregroundStyle(Brand.bright)
                }
                Text("AVERAGE REVIEW SCORE").font(BrandFont.mono(9)).tracking(0.45).foregroundStyle(Brand.muted)
                if overview.scoreHistory.count > 1 {
                    DashboardSparkline(values: overview.scoreHistory.map(\.pct))
                }
                Rectangle().fill(Brand.hairline).frame(height: 1)
                HStack {
                    ibFact(overview.stats.reviewsCompleted.map(String.init) ?? "—", "REVIEWS")
                    ibFact(overview.stats.subjectsCovered.map(String.init) ?? "—", "SUBJECTS")
                }
            }
        }
    }

    @ViewBuilder
    private func planCard(_ plan: DashboardStudentOverview.ActivePlan?) -> some View {
        if let plan {
            DashboardPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ACTIVE PLAN").font(BrandFont.mono(9, weight: .semibold)).tracking(0.7).foregroundStyle(Brand.muted)
                            Text("\(dashboardSubjectLabel(plan.subject)) · \(plan.essayType)")
                                .font(BrandFont.display(21, weight: .semibold)).foregroundStyle(Brand.bright)
                        }
                        Spacer()
                        Text("DUE \(dashboardPointLabel(plan.deadline))").font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                    }
                    let pct = plan.tasksTotal > 0 ? Int((Double(plan.tasksDone) / Double(plan.tasksTotal) * 100).rounded()) : nil
                    DashboardProgressBar(value: pct)
                    HStack {
                        Text("\(plan.tasksDone)/\(plan.tasksTotal) tasks")
                        Spacer()
                        Text("\(plan.currentTotal) → \(plan.targetTotal) points")
                    }
                    .font(BrandFont.mono(10)).foregroundStyle(Brand.secondary)
                    Button("Open week") { NativeWorkspaceNavigation.shared.show(.week) }
                        .buttonStyle(BrandGhostButtonStyle())
                }
            }
        } else {
            DashboardStatePanel(title: "No active plan", message: "When a draft plan is active, its deadline, task completion, and score target appear here.")
        }
    }

    private func ledgerCard(_ overview: DashboardStudentOverview) -> some View {
        DashboardPanel {
            VStack(spacing: 0) {
                ledgerRow(
                    title: "CAS",
                    value: overview.cas.source == "ready"
                        ? "\(overview.cas.learningOutcomesCovered ?? 0)/\(overview.cas.learningOutcomesTotal) outcomes"
                        : "Unavailable",
                    action: { NativeWorkspaceNavigation.shared.show(.toolsCAS) }
                )
                Rectangle().fill(Brand.hairline).frame(height: 1)
                ledgerRow(
                    title: "Draft progress",
                    value: overview.stats.reviewsCompleted.map { "\($0) review\($0 == 1 ? "" : "s")" } ?? "No activity",
                    action: { NativeWorkspaceNavigation.shared.show(.progress) }
                )
                Rectangle().fill(Brand.hairline).frame(height: 1)
                ledgerRow(
                    title: "Week",
                    value: overview.stats.tasksTotal.map { "\(overview.stats.tasksDone ?? 0)/\($0) tasks" } ?? "No plan",
                    action: { NativeWorkspaceNavigation.shared.show(.week) }
                )
            }
        }
    }

    private func ledgerRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
                Spacer()
                Text(value).font(BrandFont.mono(10)).foregroundStyle(Brand.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Brand.muted)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ibFact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(BrandFont.body(15, weight: .bold)).foregroundStyle(Brand.bright)
            Text(label).font(BrandFont.mono(8)).tracking(0.4).foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isEmpty(_ overview: DashboardStudentOverview) -> Bool {
        (overview.stats.reviewsCompleted ?? 0) == 0
            && overview.activePlan == nil
            && overview.cas.source == "ready"
            && (overview.cas.completedExperiences ?? 0) == 0
            && (overview.cas.learningOutcomesCovered ?? 0) == 0
            && (overview.cas.interviewsCompleted ?? 0) == 0
    }

    private func load() async {
        do {
            overview = try await DashboardAPI.studentOverview()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
