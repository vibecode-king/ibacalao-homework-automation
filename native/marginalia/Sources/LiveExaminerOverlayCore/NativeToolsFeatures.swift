import SwiftUI
import AppKit

// MARK: - Shared Tools API

enum ToolsAPI {
    private static var baseURL: URL {
        URL(string: LLMClient.resolvedNativeAPIBaseURL) ?? URL(string: LLMClient.defaultNativeAPIBaseURL)!
    }

    static func request(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        requiresSession: Bool = true,
        contentType: String? = nil
    ) async throws -> Data {
        let token = KeyStore.loadSessionToken()
        if requiresSession && token == nil { throw NativeAPIClientError.missingSession }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw NativeAPIClientError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        else if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
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
            throw NativeAPIClientError.server(message)
        }
        return data
    }

    static func jsonBody(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    static func multipart(
        _ path: String,
        fields: [String: String],
        fileField: String,
        fileURL: URL,
        filename: String,
        mimeType: String
    ) async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        append("\r\n--\(boundary)--\r\n")
        return try await request(
            path,
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    static func completeDaily(_ providerID: String) async throws {
        let body = try jsonBody(["providerId": providerID, "timeZone": TimeZone.current.identifier])
        _ = try await request("/api/native/daily/complete", method: "POST", body: body)
    }

    static func openExternalPath(_ path: String) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Shared Tools UI

struct ToolsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Brand.ground)
    }
}

struct ToolsHeading: View {
    let title: String
    var subtitle: String?
    var back: NativeWorkspaceTab? = .today

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
                Text(title)
                    .font(BrandFont.display(31, weight: .semibold))
                    .tracking(-0.7)
                    .foregroundStyle(Brand.bright)
                if let subtitle {
                    Text(subtitle).font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
                }
            }
        }
    }
}

struct ToolsPanel<Content: View>: View {
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

struct ToolsState: View {
    let title: String
    let bodyText: String
    var action: String?
    var onAction: (() -> Void)?

    var body: some View {
        ToolsPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(BrandFont.display(21, weight: .semibold)).foregroundStyle(Brand.bright)
                Text(bodyText).font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
                if let action, let onAction {
                    Button(action, action: onAction).buttonStyle(BrandPrimaryButtonStyle())
                }
            }
        }
    }
}

struct ToolsLoading: View {
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: Brand.cornerLg)
                    .fill(Brand.skeleton.opacity(index == 0 ? 0.9 : 0.6))
                    .frame(height: index == 0 ? 120 : 72)
                    .overlay(RoundedRectangle(cornerRadius: Brand.cornerLg).stroke(Brand.hairline))
            }
        }
        .accessibilityLabel("Loading")
    }
}

// MARK: - Inbox

struct ToolsDispatchRecord: Decodable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let source: String
    let subject: String?
    let detail: String?
    let url: String?
    let dueAt: String?
    let occurredAt: String?
    let status: String?
    let grade: String?
    let teacher: String?
    let urgency: String?
    let updatedAt: String
}

struct ToolsDispatchSnapshot: Decodable {
    struct InboxGroup: Decodable {
        let key: String
        let records: [ToolsDispatchRecord]
    }

    struct State: Decodable {
        let connection: String
        let hasConnectedBefore: Bool?
        let macOnline: Bool
        let phonePaired: Bool
        let macName: String?
        let source: String?
        let lastSeenAt: String?
        let lastSyncAt: String?
        let lastSyncError: String?
        let counts: [String: Int]
    }
    let state: State
    let records: [ToolsDispatchRecord]
    let inbox: [InboxGroup]?
}

enum ToolsInboxAPI {
    static func fetch() async throws -> ToolsDispatchSnapshot {
        let data = try await ToolsAPI.request("/api/native/dispatch")
        return try JSONDecoder().decode(ToolsDispatchSnapshot.self, from: data)
    }
}

struct NativeInboxPage: View {
    let onOpenWeb: (String) -> Void

    enum Filter: String, CaseIterable { case all = "ALL", action = "NEEDS ACTION", messages = "MESSAGES", grades = "GRADES" }

    @State private var snapshot: ToolsDispatchSnapshot?
    @State private var selected: ToolsDispatchRecord?
    @State private var filter: Filter = .all
    @State private var error: String?

    var body: some View {
        ToolsPage {
            ToolsHeading(title: "Inbox", subtitle: "School updates grouped by what needs attention.")

            if let error, snapshot == nil {
                ToolsState(title: "Inbox unavailable", bodyText: error, action: "Try again") { Task { await load() } }
            } else if snapshot == nil {
                ToolsLoading()
            } else if let snapshot {
                let records = allRecords(in: snapshot)
                let groups = filteredGroups(in: snapshot)
                let connected = snapshot.state.connection.lowercased() == "connected"
                connectionBanner(snapshot)
                if records.isEmpty {
                    if connected {
                        ToolsState(title: "You're clear", bodyText: "No assignments, messages, grades, or deadlines are waiting.")
                    } else if !(snapshot.state.hasConnectedBefore ?? (snapshot.state.lastSyncAt != nil || snapshot.state.source != nil)) {
                        ToolsState(title: "Connect your school", bodyText: "Inbox fills from the school site you choose.", action: "Open school connection") {
                            onOpenWeb("/school-connection")
                        }
                    } else {
                        ToolsState(title: "School source offline", bodyText: "Reconnect your school source to refresh Inbox.", action: "Reconnect school") {
                            onOpenWeb("/school-connection")
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ForEach(Filter.allCases, id: \.self) { item in
                            Button(item.rawValue) { filter = item }
                                .buttonStyle(.plain)
                                .font(BrandFont.mono(8, weight: .semibold))
                                .foregroundStyle(filter == item ? Brand.onAccent : Brand.secondary)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(filter == item ? Brand.accent : Brand.card)
                                .overlay(RoundedRectangle(cornerRadius: Brand.cornerMd).stroke(filter == item ? Brand.accent : Brand.hairline))
                                .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                        }
                    }
                    if !connected {
                        Text("Showing the last school sync. Reconnect to refresh.")
                            .font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                    }
                    if groups.isEmpty {
                        ToolsState(title: "Nothing here", bodyText: "No inbox items match this filter.")
                    } else {
                        recordsList(groups)
                    }
                }
            }
        }
        .task { await load() }
        .sheet(item: $selected) { record in recordDetail(record) }
    }

    private func connectionBanner(_ snapshot: ToolsDispatchSnapshot) -> some View {
        let connected = snapshot.state.connection.lowercased() == "connected"
        let unread = allRecords(in: snapshot).filter(isUnreadMessage).count
        return HStack(spacing: 10) {
            Circle().fill(connected ? Brand.success : Brand.warning).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.state.source ?? "School portal")
                    .font(BrandFont.body(12, weight: .semibold)).foregroundStyle(Brand.bright)
                Text("\(connected ? "Live" : "Offline")\(snapshot.state.lastSyncAt.map { " · \(toolsDateLabel($0))" } ?? "")")
                    .font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
            }
            Spacer()
            if unread > 0 {
                Text("\(unread) NEW").font(BrandFont.mono(8, weight: .semibold)).foregroundStyle(Brand.accent)
            }
        }
        .padding(14)
        .background(Brand.card)
        .overlay(RoundedRectangle(cornerRadius: Brand.cornerLg).stroke(Brand.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerLg))
    }

    private func recordsList(_ groups: [ToolsDispatchSnapshot.InboxGroup]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.key) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(groupLabel(group.key)).font(BrandFont.mono(9, weight: .semibold)).tracking(0.7).foregroundStyle(Brand.muted)
                        Spacer()
                        Text("\(group.records.count)").font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                    }
                    ToolsPanel {
                        VStack(spacing: 0) {
                            ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                                Button { selected = record } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Circle()
                                            .fill(isUnreadMessage(record) ? Brand.accent : Brand.hairline)
                                            .frame(width: 6, height: 6)
                                            .padding(.top, 6)
                                        Image(systemName: symbol(for: record.kind))
                                            .foregroundStyle(Brand.secondary).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(record.title).font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
                                                Spacer()
                                                if let grade = record.grade {
                                                    Text(grade).font(BrandFont.mono(10, weight: .semibold)).foregroundStyle(Brand.bright)
                                                }
                                            }
                                            HStack(spacing: 6) {
                                                Text((record.subject ?? record.source).uppercased())
                                                let status = rowStatus(record)
                                                if !status.isEmpty { Text("· \(status)") }
                                            }
                                            .font(BrandFont.mono(8)).foregroundStyle(Brand.muted)
                                            if let detail = record.detail, !detail.isEmpty {
                                                Text(detail).font(BrandFont.body(11)).foregroundStyle(Brand.secondary).lineLimit(2)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if index < group.records.count - 1 { Rectangle().fill(Brand.hairline).frame(height: 1) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func filteredGroups(in snapshot: ToolsDispatchSnapshot) -> [ToolsDispatchSnapshot.InboxGroup] {
        let raw: [ToolsDispatchSnapshot.InboxGroup]
        if let inbox = snapshot.inbox, !inbox.isEmpty {
            raw = inbox
        } else if !snapshot.records.isEmpty {
            raw = [.init(key: "recent", records: snapshot.records)]
        } else {
            raw = []
        }
        return raw.compactMap { group in
            let records = filtered(group.records)
            return records.isEmpty ? nil : .init(key: group.key, records: records)
        }
    }

    private func allRecords(in snapshot: ToolsDispatchSnapshot) -> [ToolsDispatchRecord] {
        let source = snapshot.inbox?.flatMap(\.records) ?? snapshot.records
        var seen = Set<String>()
        return source.filter { seen.insert("\($0.source):\($0.id)").inserted }
    }

    private func filtered(_ records: [ToolsDispatchRecord]) -> [ToolsDispatchRecord] {
        records.filter { record in
            switch filter {
            case .all: return true
            case .messages: return record.kind == "message"
            case .grades: return record.kind == "grade"
            case .action: return requiresAction(record)
            }
        }
    }

    private func requiresAction(_ record: ToolsDispatchRecord) -> Bool {
        if record.kind == "assignment" || record.kind == "deadline" { return true }
        if record.kind == "message" {
            let status = record.status?.lowercased() ?? ""
            return ["new", "unread", "open", "action_required"].contains(status)
        }
        return false
    }

    private func isUnreadMessage(_ record: ToolsDispatchRecord) -> Bool {
        guard record.kind == "message" else { return false }
        let status = record.status?.lowercased() ?? ""
        return status == "new" || status == "unread"
    }

    private func rowStatus(_ record: ToolsDispatchRecord) -> String {
        if let grade = record.grade, !grade.isEmpty { return grade }
        if isUnreadMessage(record) { return "NEW" }
        if let due = record.dueAt { return toolsDateLabel(due).uppercased() }
        if let occurred = record.occurredAt { return toolsDateLabel(occurred).uppercased() }
        return record.status?.uppercased() ?? ""
    }

    private func groupLabel(_ key: String) -> String {
        switch key {
        case "overdue": return "OVERDUE"
        case "today": return "TODAY"
        case "tomorrow": return "TOMORROW"
        case "thisWeek": return "THIS WEEK"
        default: return "RECENT"
        }
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "assignment": return "doc.text"
        case "message": return "message"
        case "grade": return "chart.bar"
        case "deadline": return "calendar"
        default: return "tray"
        }
    }

    private func recordDetail(_ record: ToolsDispatchRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(record.kind.uppercased()).font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                Spacer()
                Button("Close") { selected = nil }.buttonStyle(BrandGhostButtonStyle())
            }
            Text(record.title).font(BrandFont.display(24, weight: .semibold)).foregroundStyle(Brand.bright)
            if let detail = record.detail {
                Text(detail).font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                detailRow("SOURCE", record.source)
                if let subject = record.subject { detailRow("SUBJECT", subject) }
                if let grade = record.grade { detailRow("GRADE", grade) }
                if let teacher = record.teacher { detailRow("TEACHER", teacher) }
                if let due = record.dueAt { detailRow("DUE", toolsDateLabel(due)) }
            }
            if let raw = record.url, let url = URL(string: raw) {
                Button("Open in source") { NSWorkspace.shared.open(url) }
                    .buttonStyle(BrandPrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Brand.ground)
        .preferredColorScheme(.dark)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(BrandFont.mono(8)).foregroundStyle(Brand.muted).frame(width: 74, alignment: .leading)
            Text(value).font(BrandFont.body(12)).foregroundStyle(Brand.body)
        }
    }

    private func load() async {
        do {
            snapshot = try await ToolsInboxAPI.fetch()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

func toolsParseDate(_ value: String) -> Date? {
    ISO8601DateFormatter().date(from: value) ?? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }()
}

func toolsDateLabel(_ value: String) -> String {
    guard let date = toolsParseDate(value) else { return String(value.prefix(16)) }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}
