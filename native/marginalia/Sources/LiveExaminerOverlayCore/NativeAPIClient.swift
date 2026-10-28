import Foundation

enum NativeAPIClientError: LocalizedError {
    case missingSession
    case invalidURL
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Sign in to use this feature."
        case .invalidURL:
            return "The iBacalao service URL is invalid."
        case .server(let message):
            return message
        }
    }
}

enum NativeAPIClient {
    private static var baseURL: URL {
        URL(string: LLMClient.resolvedNativeAPIBaseURL) ?? URL(string: LLMClient.defaultNativeAPIBaseURL)!
    }

    static func account() async throws -> NativeAccount {
        let data = try await request(path: "/api/native/me")
        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let user = payload["user"] as? [String: Any],
            let email = user["email"] as? String
        else {
            throw NativeAPIClientError.server("Couldn't read your account.")
        }
        return NativeAccount(
            id: user["id"] as? String ?? "",
            email: email,
            plan: user["plan"] as? String,
            planActive: user["planActive"] as? Bool ?? false,
            entitled: user["entitled"] as? Bool ?? false,
            credits: (user["credits"] as? Int) ?? (user["credits"] as? NSNumber)?.intValue ?? 0,
            username: user["username"] as? String,
            avatarB64: user["avatarB64"] as? String
        )
    }

    static func profileWorkspace() async throws -> NativeProfileWorkspace {
        let data = try await request(path: "/api/native/profile-workspace")
        return try JSONDecoder().decode(NativeProfileWorkspace.self, from: data)
    }

    static func dispatchSnapshot() async throws -> NativeDispatchSnapshot {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/native/dispatch"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "timeZone", value: TimeZone.current.identifier)]
        guard let url = components?.url else { throw NativeAPIClientError.invalidURL }
        let data = try await request(url: url)
        return try JSONDecoder().decode(NativeDispatchSnapshot.self, from: data)
    }

    static func workDays() async throws -> NativeWorkDays {
        let data = try await request(path: "/api/native/work-days")
        return try JSONDecoder().decode(NativeWorkDays.self, from: data)
    }

    static func usernameAvailability(_ username: String) async throws -> NativeUsernameAvailability {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/native/username/availability"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "u", value: username)]
        guard let url = components?.url else { throw NativeAPIClientError.invalidURL }
        let data = try await request(url: url)
        return try JSONDecoder().decode(NativeUsernameAvailability.self, from: data)
    }

    static func claimUsername(_ username: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["username": username])
        _ = try await request(path: "/api/native/username", method: "POST", body: body)
    }

    static func saveAvatar(_ avatarB64: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["avatarB64": avatarB64])
        _ = try await request(path: "/api/native/onboarding/avatar", method: "POST", body: body)
    }

    static func today() async throws -> NativeTodayResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/native/bootstrap/today"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "timeZone", value: TimeZone.current.identifier),
            URLQueryItem(name: "locale", value: "en"),
        ]
        guard let url = components?.url else { throw NativeAPIClientError.invalidURL }
        let data = try await request(url: url)
        return try JSONDecoder().decode(NativeTodayResponse.self, from: data)
    }
    static func selectMission(taskId: String) async throws -> NativeTodayModel {
        let body = try JSONSerialization.data(withJSONObject: [
            "taskId": taskId,
            "timeZone": TimeZone.current.identifier,
            "locale": "en",
        ])
        let data = try await request(path: "/api/retention/mission/select", method: "POST", body: body)
        return try JSONDecoder().decode(NativeTodayModel.self, from: data)
    }

    static func swapMission(taskId: String, reason: String) async throws -> NativeTodayModel {
        let body = try JSONSerialization.data(withJSONObject: [
            "taskId": taskId,
            "reason": reason,
            "timeZone": TimeZone.current.identifier,
            "locale": "en",
        ])
        let data = try await request(path: "/api/retention/mission/swap", method: "POST", body: body)
        return try JSONDecoder().decode(NativeTodayModel.self, from: data)
    }

    static func correctMission(taskId: String, note: String) async throws -> NativeTodayModel {
        let body = try JSONSerialization.data(withJSONObject: [
            "taskId": taskId,
            "note": note,
            "timeZone": TimeZone.current.identifier,
            "locale": "en",
        ])
        let data = try await request(path: "/api/retention/mission/correct", method: "POST", body: body)
        return try JSONDecoder().decode(NativeTodayModel.self, from: data)
    }

    static func startWorkContext(for mission: NativeMission) async throws -> NativeWorkContext {
        var payload: [String: Any] = [
            "missionDecisionId": mission.missionDecisionId,
            "taskId": mission.taskId,
            "subject": mission.subject,
            "subjectLabel": mission.subjectLabel,
            "workType": mission.workType,
            "title": mission.title,
            "action": mission.action,
            "estMinutes": mission.estMinutes,
            "sourceSurface": "mac_today",
            "resumeUrl": mission.launch.path,
            "lastRoute": mission.launch.path,
        ]
        if let target = mission.criterionTarget {
            payload["criterion"] = target.criterion
            payload["target"] = ["before": target.before, "after": target.after]
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request(path: "/api/native/work-context", method: "POST", body: body)
        return try JSONDecoder().decode(NativeWorkContextResponse.self, from: data).context
    }

    static func workContext(id: String) async throws -> NativeWorkContext? {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/native/work-context"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components?.url else { throw NativeAPIClientError.invalidURL }
        let data = try await request(url: url)
        return try JSONDecoder().decode(NativeOptionalWorkContextResponse.self, from: data).context
    }

    static func advanceMissionExecution(_ mission: NativeMission) async throws {
        guard mission.execution.steps.indices.contains(mission.execution.currentStepIndex) else { return }
        let step = mission.execution.steps[mission.execution.currentStepIndex]
        let body = try JSONSerialization.data(withJSONObject: [
            "missionDecisionId": mission.missionDecisionId,
            "expectedStepIndex": mission.execution.currentStepIndex,
            "stepId": step.id,
        ])
        _ = try await request(path: "/api/retention/mission/execution", method: "POST", body: body)
    }

    static func latestCompletion() async throws -> NativeCompletionCeremony? {
        let data = try await request(path: "/api/retention/completion/latest")
        return try JSONDecoder().decode(NativeLatestCompletionResponse.self, from: data).ceremony
    }

    static func uploadMissionHomework(
        missionDecisionId: String,
        contextId: String?,
        fileURL: URL
    ) async throws -> NativeMissionHomeworkUploadResponse {
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }

        let fileData = try Data(contentsOf: fileURL)
        let boundary = "ibacalao-\(UUID().uuidString)"
        var multipart = Data()
        func append(_ string: String) { multipart.append(Data(string.utf8)) }
        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        appendField(name: "missionDecisionId", value: missionDecisionId)
        if let contextId { appendField(name: "contextId", value: contextId) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        append("Content-Type: \(mimeType(for: fileURL))\r\n\r\n")
        multipart.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        let data = try await request(
            path: "/api/native/mission/homework-upload",
            method: "POST",
            body: multipart,
            additionalHeaders: ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        )
        return try JSONDecoder().decode(NativeMissionHomeworkUploadResponse.self, from: data)
    }


    static func week() async throws -> NativeWeekResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/native/week"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "timeZone", value: TimeZone.current.identifier)]
        guard let url = components?.url else { throw NativeAPIClientError.invalidURL }
        let data = try await request(url: url)
        return try JSONDecoder().decode(NativeWeekResponse.self, from: data)
    }

    static func addWeekGoal(title: String, subject: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "title": title,
            "subject": subject,
            "timeZone": TimeZone.current.identifier,
            "idempotencyKey": UUID().uuidString,
        ])
        _ = try await request(path: "/api/native/week", method: "POST", body: body)
    }

    static func setWeekGoal(_ goal: NativeWeekGoal, done: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "goalId": goal.id,
            "done": done,
            "title": goal.title,
            "subject": goal.subject,
            "timeZone": TimeZone.current.identifier,
        ])
        _ = try await request(path: "/api/native/week", method: "PATCH", body: body)
    }

    static func reminders() async throws -> NativeRemindersResponse {
        let data = try await request(path: "/api/native/reminders")
        return try JSONDecoder().decode(NativeRemindersResponse.self, from: data)
    }

    static func createReminder(title: String, subject: String, importance: String, dueDate: String, remindAt: Date) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "title": title,
            "subject": subject,
            "importance": importance,
            "dueDate": dueDate,
            "remindAt": ISO8601DateFormatter().string(from: remindAt),
            "clientRequestId": UUID().uuidString,
        ])
        _ = try await request(path: "/api/native/reminders", method: "POST", body: body)
    }

    static func reviewProgress() async throws -> [NativeSubjectProgress] {
        let data = try await request(path: "/api/native/review-progress")
        return try JSONDecoder().decode(NativeReviewProgressResponse.self, from: data).subjects
    }

    static func missionPreferences() async throws -> NativeMissionPreferencesResponse {
        let data = try await request(path: "/api/native/mission-preferences")
        return try JSONDecoder().decode(NativeMissionPreferencesResponse.self, from: data)
    }

    static func saveMissionPreferences(_ preferences: NativeMissionPreferences) async throws {
        let body = try JSONEncoder().encode(["preferences": preferences])
        _ = try await request(path: "/api/native/mission-preferences", method: "PUT", body: body)
    }

    static func saveSubjects(_ subjects: [String]) async throws -> [String] {
        let body = try JSONSerialization.data(withJSONObject: ["subjects": subjects])
        let data = try await request(path: "/api/native/subjects", method: "PUT", body: body)
        return try JSONDecoder().decode(NativeSubjectCatalogResponse.self, from: data).subjects
    }

    static func workPreferences() async throws -> NativeWorkPreferences {
        let data = try await request(path: "/api/accessibility/preferences")
        return try JSONDecoder().decode(NativeWorkPreferencesResponse.self, from: data).preferences
    }

    static func updateWorkPreferences(_ patch: [String: String]) async throws -> NativeWorkPreferences {
        let body = try JSONSerialization.data(withJSONObject: patch)
        let data = try await request(path: "/api/accessibility/preferences", method: "PATCH", body: body)
        return try JSONDecoder().decode(NativeWorkPreferencesResponse.self, from: data).preferences
    }

    static func resetWorkPreferences() async throws -> NativeWorkPreferences {
        let data = try await request(path: "/api/accessibility/preferences", method: "DELETE")
        return try JSONDecoder().decode(NativeWorkPreferencesResponse.self, from: data).preferences
    }

    static func startDeviceSync() async throws -> NativeSyncStarted {
        let body = try JSONSerialization.data(withJSONObject: [
            "device": ["platform": "mac", "label": "Mac"],
        ])
        let data = try await request(
            path: "/api/sync/start",
            method: "POST",
            body: body,
            requiresSession: false
        )
        return try JSONDecoder().decode(NativeSyncStarted.self, from: data)
    }

    static func decideDeviceSync(_ started: NativeSyncStarted, approve: Bool) async throws -> NativeSyncStatus {
        let body = try JSONSerialization.data(withJSONObject: [
            "requestId": started.requestId,
            "approve": approve,
        ])
        let data = try await request(
            path: "/api/sync/decide",
            method: "POST",
            body: body,
            additionalHeaders: ["x-sync-token": started.token]
        )
        return try JSONDecoder().decode(NativeSyncStatus.self, from: data)
    }

    static func pollDeviceSync(_ started: NativeSyncStarted) async throws -> NativeSyncStatus {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("api/sync/status"), resolvingAgainstBaseURL: false) else {
            throw NativeAPIClientError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "requestId", value: started.requestId)]
        guard let url = components.url else { throw NativeAPIClientError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(started.token, forHTTPHeaderField: "x-sync-token")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeAPIClientError.server("iBacalao returned an unreadable response.")
        }
        let payload = try JSONDecoder().decode(NativeSyncStatus.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            throw NativeAPIClientError.server(payload.error ?? "Couldn't check device sync.")
        }

        var result = payload
        if payload.status == "signed_in" {
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { values, pair in
                values[String(describing: pair.key)] = String(describing: pair.value)
            }
            result.sessionToken = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                .first(where: { $0.name == "ib_session" })?.value
        }
        return result
    }

    static func completeMission(_ task: NativeTodoContext) async throws -> NativeMissionCompletionResponse {
        var payload: [String: Any] = [
            "missionDecisionId": task.missionDecisionId,
            "mode": "manual",
        ]
        if !task.taskId.isEmpty { payload["taskId"] = task.taskId }
        if let contextId = task.contextId { payload["contextId"] = contextId }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request(path: "/api/native/mission/complete", method: "POST", body: body)
        return try JSONDecoder().decode(NativeMissionCompletionResponse.self, from: data)
    }

    static func deleteAccount() async throws {
        _ = try await request(path: "/api/native/account/delete", method: "DELETE")
    }

    static func signOut() async {
        guard let token = KeyStore.loadSessionToken(),
              let url = URL(string: "/api/auth/logout", relativeTo: baseURL)?.absoluteURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("ib_session=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue(baseURL.origin, forHTTPHeaderField: "Origin")
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func request(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        requiresSession: Bool = true,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw NativeAPIClientError.invalidURL
        }
        return try await request(
            url: url,
            method: method,
            body: body,
            requiresSession: requiresSession,
            additionalHeaders: additionalHeaders
        )
    }

    private static func request(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        requiresSession: Bool = true,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Data {
        let token = KeyStore.loadSessionToken()
        if requiresSession && token == nil { throw NativeAPIClientError.missingSession }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if method != "GET" { request.setValue(baseURL.origin, forHTTPHeaderField: "Origin") }
        for (name, value) in additionalHeaders { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeAPIClientError.server("iBacalao returned an unreadable response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message: String
            if http.statusCode == 401 {
                message = "Sign in to use this feature."
            } else {
                message = (payload?["message"] as? String)
                    ?? (payload?["error"] as? String)
                    ?? "Request failed (\(http.statusCode))."
            }
            throw NativeAPIClientError.server(message)
        }
        return data
    }
    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

}

private extension URL {
    var origin: String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        return components.string ?? absoluteString
    }
}

struct NativeProfileWorkspace: Decodable {
    let reviews: [NativeProfileReview]
    let plans: [NativeProfilePlan]
}

struct NativeProfileCriterion: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let score: Int
    let scoreMax: Int
}

struct NativeProfileReview: Decodable, Identifiable {
    let id: String
    let subject: String
    let level: String
    let totalScore: Int
    let totalMax: Int
    let pct: Double
    let date: String
    let missingCount: Int?
    let criteria: [NativeProfileCriterion]
}

struct NativeProfilePlanItem: Decodable, Identifiable {
    let id: String
    let date: String
    let type: String
    let criterion: String?
    let instruction: String?
    let status: String
}

struct NativeProfilePlanBody: Decodable {
    let essayType: String
    let deadline: String
    let targetTotal: Int
    let currentTotal: Int
    let intensity: String
    let schedule: [NativeProfilePlanItem]
}

struct NativeProfilePlan: Decodable, Identifiable {
    let id: String
    let subject: String
    let level: String
    let plan: NativeProfilePlanBody
}

struct NativeDispatchCounts: Decodable {
    let assignment: Int
    let message: Int
    let grade: Int
    let submission: Int
    let deadline: Int

    var total: Int { assignment + message + grade + submission + deadline }
}

struct NativeDispatchState: Decodable {
    let connection: String
    let hasConnectedBefore: Bool?
    let macOnline: Bool
    let phonePaired: Bool
    let macName: String?
    let source: String?
    let lastSeenAt: String?
    let lastSyncAt: String?
    let lastSyncError: String?
    let counts: NativeDispatchCounts
}

struct NativeDispatchRecord: Decodable {
    let id: String
    let kind: String
    let source: String
    let updatedAt: String
    let revision: Int?
}

struct NativeDispatchSnapshot: Decodable {
    let state: NativeDispatchState
    let records: [NativeDispatchRecord]?
}

struct NativeWorkDays: Decodable {
    let days: [Int]?
    let setAt: String?
}

struct NativeUsernameAvailability: Decodable {
    let available: Bool
    let reason: String?
}

struct NativeReviewProgressResponse: Decodable {
    let subjects: [NativeSubjectProgress]
}

struct NativeMissionPreferencesResponse: Decodable {
    let preferences: NativeMissionPreferences
    let subjects: [String]
}

struct NativeMissionPreferences: Codable, Equatable {
    var availableTimeMinutes: Int
    var challengeLevel: String
    var recommendationStyle: String
    var subjectConfidence: [String: String]

    static let balanced = NativeMissionPreferences(
        availableTimeMinutes: 30,
        challengeLevel: "balanced",
        recommendationStyle: "balanced",
        subjectConfidence: [:]
    )
}

struct NativeSelectableSubject: Decodable, Identifiable {
    let id: String
    let label: String

    static let catalog = [
        NativeSelectableSubject(id: "biology", label: "Biology"),
        NativeSelectableSubject(id: "chemistry", label: "Chemistry"),
        NativeSelectableSubject(id: "physics", label: "Physics"),
        NativeSelectableSubject(id: "math_aa", label: "Math AA"),
        NativeSelectableSubject(id: "math_ai", label: "Math AI"),
        NativeSelectableSubject(id: "history", label: "History"),
        NativeSelectableSubject(id: "english_ll", label: "English A: Lang & Lit"),
        NativeSelectableSubject(id: "english_lit", label: "English A: Literature"),
        NativeSelectableSubject(id: "english_b", label: "English B"),
        NativeSelectableSubject(id: "spanish_ll", label: "Spanish A: Lang & Lit"),
        NativeSelectableSubject(id: "spanish_lit", label: "Spanish A: Literature"),
        NativeSelectableSubject(id: "spanish_b", label: "Spanish B"),
        NativeSelectableSubject(id: "business", label: "Business"),
        NativeSelectableSubject(id: "economics", label: "Economics"),
        NativeSelectableSubject(id: "psychology", label: "Psychology"),
        NativeSelectableSubject(id: "ess", label: "ESS"),
        NativeSelectableSubject(id: "visual_arts", label: "Visual Arts"),
        NativeSelectableSubject(id: "global_politics", label: "Global Politics"),
        NativeSelectableSubject(id: "geography", label: "Geography"),
        NativeSelectableSubject(id: "computer_science", label: "Computer Science"),
        NativeSelectableSubject(id: "sehs", label: "Sports, Exercise & Health Science"),
        NativeSelectableSubject(id: "film", label: "Film"),
        NativeSelectableSubject(id: "philosophy", label: "Philosophy"),
        NativeSelectableSubject(id: "theatre", label: "Theatre"),
        NativeSelectableSubject(id: "music", label: "Music"),
        NativeSelectableSubject(id: "sca", label: "Social & Cultural Anthropology"),
    ]
}

struct NativeSubjectCatalogResponse: Decodable {
    let subjects: [String]
}

struct NativeWorkPreferencesResponse: Decodable {
    let preferences: NativeWorkPreferences
}

struct NativeWorkPreferences: Codable, Equatable {
    var version: Int
    var taskSteps: String
    var focus: String
    var estimate: String
    var breaks: String
    var textSpacing: String
    var motion: String
    var updatedAt: String
}

struct NativeSyncStarted: Decodable, Equatable {
    let requestId: String
    let token: String
    let mode: String
    let code: String
    let qrUrl: String
    let expiresInSeconds: Int
}

struct NativeSyncDevice: Decodable {
    let label: String
    let platform: String
}

struct NativeSyncStatus: Decodable {
    let status: String
    let otherDevice: NativeSyncDevice?
    let awaitingYourApproval: Bool?
    let error: String?
    var sessionToken: String?
}

struct NativeSubjectProgress: Decodable, Identifiable {
    var id: String { "\(subject):\(level)" }
    let subject: String
    let level: String
    let latest: NativeReviewPoint
    let totalChange: Int?
    let improved: [NativeCriterionDelta]
    let regressed: [NativeCriterionDelta]
    let unchanged: [NativeCriterionDelta]
    let history: [NativeReviewPoint]
}

struct NativeReviewPoint: Decodable, Identifiable {
    let id: String
    let date: String
    let totalScore: Int
    let totalMax: Int
}

struct NativeCriterionDelta: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let fromScore: Int
    let toScore: Int
    let scoreMax: Int
    let change: Int
}

struct NativeTodayResponse: Decodable {
    let today: NativeTodayModel
}

struct NativeTodayModel: Decodable {
    let kind: String
    let mission: NativeMission?
    let quickWin: NativeQuickWin?
    let dayState: NativeDayState?
    let tools: [NativeTodayTool]?
    let missionQueue: [NativeMissionQueueItem]?
    let reason: String?
}

struct NativeTodayTool: Decodable, Identifiable {
    let id: String
    let label: String
    let href: String
}

struct NativeMissionQueueItem: Decodable, Identifiable {
    var id: String { taskId }
    let taskId: String
    let subject: String
    let subjectLabel: String
    let title: String
    let action: String
    let estMinutes: Int
    let whyThis: String
}

struct NativeCriterionTarget: Decodable {
    let criterion: String
    let before: String
    let after: String
}

struct NativeMissionInstructions: Decodable {
    let summary: String
    let whereLabel: String
    let steps: [String]
    let launchLabel: String
}

struct NativeMissionLaunch: Decodable {
    let kind: String
    let path: String
    let title: String
}

struct NativeMissionCompletionPublic: Decodable {
    let state: String
    let manualAllowed: Bool
    let verified: Bool
    let awaitingSchoolSubmission: Bool
    let homeworkUploaded: Bool?
}

struct NativeMissionExecutionStep: Decodable, Identifiable {
    let id: String
    let action: String
    let estMinutes: Int?
    let order: Int
}

struct NativeMissionExecutionPlan: Decodable {
    let taskId: String
    let baseEstMinutes: Int
    let estimateIsGuide: Bool
    let presentation: String
    let steps: [NativeMissionExecutionStep]
    let currentStepIndex: Int
    let completedStepIds: [String]
    let breakSuggestionAfterStepIds: [String]
    let textSpacing: String
    let reduceMotion: Bool
    let adaptationReasons: [String]
}

struct NativeMission: Decodable {
    let missionDecisionId: String
    let taskId: String
    let subject: String
    let subjectLabel: String
    let title: String
    let action: String
    let estMinutes: Int
    let whyThis: String
    let workType: String
    let criterionTarget: NativeCriterionTarget?
    let instructions: NativeMissionInstructions
    let launch: NativeMissionLaunch
    let completion: NativeMissionCompletionPublic
    let execution: NativeMissionExecutionPlan
}

struct NativeQuickWin: Decodable {
    let taskId: String
    let subjectLabel: String
    let title: String
    let action: String
    let estMinutes: Int
}

struct NativeDayState: Decodable {
    let streak: Int
    let momentum: NativeMomentum
    let weeklySprint: NativeWeeklySprint
    let secured: Bool
    let protected: Bool
}

struct NativeMomentum: Decodable {
    let completed: Int
    let ofLast: Int
}

struct NativeWeeklySprint: Decodable {
    let completed: Int
    let target: Int
}

struct NativeWorkContextResponse: Decodable {
    let context: NativeWorkContext
}

struct NativeOptionalWorkContextResponse: Decodable {
    let context: NativeWorkContext?
}

struct NativeWorkContext: Decodable, Equatable {
    let id: String
    let missionDecisionId: String
    let userId: String
    let taskId: String
    let subject: String
    let subjectLabel: String
    let workType: String
    let title: String
    let action: String
    let criterion: String?
    let target: NativeWorkContextTarget?
    let estMinutes: Int?
    let sourceSurface: String
    let startedAt: String
    let lastRoute: String
    let status: String
    let resumeUrl: String
    let updatedAt: String
}

struct NativeWorkContextTarget: Decodable, Equatable {
    let before: String
    let after: String
}

struct NativeMissionCompletionResponse: Decodable {
    let completion: NativeMissionCompletionRecord
    let ceremony: NativeCompletionCeremony?
}

struct NativeMissionHomeworkUploadResponse: Decodable {
    let completion: NativeMissionCompletionRecord
    let filename: String
}

struct NativeMissionCompletionRecord: Decodable {
    let userId: String
    let missionDecisionId: String
    let taskId: String
    let state: String
    let verified: Bool
    let completedAt: String?
    let completionSource: String?
}

struct NativeLatestCompletionResponse: Decodable {
    let ceremony: NativeCompletionCeremony?
}

struct NativeCompletionCeremony: Decodable, Identifiable {
    var id: String { completedAt }
    let experience: NativeCompletionExperience?
    let providerId: String
    let verified: Bool
    let stateChange: NativeCompletionStateChange?
    let dayState: NativeCompletionDayState
    let tomorrowPreview: NativeTomorrowPreview?
    let completedAt: String

    var hasGratification: Bool { experience?.gratification != nil }
}

struct NativeCompletionExperience: Decodable {
    let gratification: NativeGratificationPayload?
}

struct NativeGratificationPayload: Decodable {
    let id: String
    let type: String
}

struct NativeCompletionStateChange: Decodable {
    let headline: String
    let before: String
    let after: String
}

struct NativeCompletionDayState: Decodable {
    let before: NativeDayState
    let after: NativeDayState
}

struct NativeTomorrowPreview: Decodable {
    let subjectLabel: String
    let estMinutes: Int
}

struct NativeWeekResponse: Decodable {
    let week: NativeWeekModel
    let subjects: [String]
}

struct NativeWeekModel: Decodable {
    let weekStart: String
    let weekEnd: String
    let total: Int
    let done: Int
    let pct: Int?
    let goals: [NativeWeekGoal]
}

struct NativeWeekGoal: Decodable, Identifiable {
    let id: String
    let title: String
    let subject: String
    let date: String
    let done: Bool
    let source: String
}

struct NativeRemindersResponse: Decodable {
    let reminders: [NativeReminder]
    let subjects: [NativeReminderSubject]
}

struct NativeReminderSubject: Decodable, Identifiable {
    let id: String
    let label: String
}

struct NativeReminder: Decodable, Identifiable {
    let id: String
    let title: String
    let subject: String
    let importance: String
    let dueDate: String
    let remindAt: String
    let status: String
}
