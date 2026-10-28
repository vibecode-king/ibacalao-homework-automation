import SwiftUI
import AppKit

private enum CASStrand: String, CaseIterable, Codable, Identifiable {
    case creativity, activity, service
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

private struct CASExperienceEnvelope: Decodable { let experience: CASExperience }
private struct CASExperience: Decodable, Identifiable {
    let id: String
    let title: String
    let strand: String
    let learning_outcomes: [Int]
    let start_date: String
    let status: String
    let description: String?
}

private struct CASSuggestion: Decodable {
    let suggested: [Int]
    let rationale: String
}

private struct CASProjectEnvelope: Decodable { let project: CASProject }
private struct CASProjectsEnvelope: Decodable { let projects: [CASProject] }
private struct CASProject: Decodable, Identifiable {
    let id: String
    let title: String
    let strands: [String]
    let stage: String
    let start_date: String
    let end_date: String?
    let collaborators: String?
    let outcome: String?
    let description: String?
}

private enum CASAPI {
    static func suggest(title: String, strand: CASStrand, description: String) async throws -> CASSuggestion {
        let body = try ToolsAPI.jsonBody([
            "title": title,
            "strand": strand.rawValue,
            "description": description,
        ])
        let data = try await ToolsAPI.request("/api/cas/ai/suggest-lo", method: "POST", body: body)
        return try JSONDecoder().decode(CASSuggestion.self, from: data)
    }

    static func createExperience(sentence: String, strand: CASStrand, outcomes: [Int], contextID: String?) async throws -> CASExperience {
        var payload: [String: Any] = [
            "title": titleFrom(sentence),
            "strand": strand.rawValue,
            "description": sentence.trimmingCharacters(in: .whitespacesAndNewlines),
            "learning_outcomes": outcomes,
            "type": "experience",
            "status": "completed",
            "start_date": localDateKey(),
        ]
        if let contextID, !contextID.isEmpty { payload["workContextId"] = contextID }
        let data = try await ToolsAPI.request("/api/cas/experiences", method: "POST", body: ToolsAPI.jsonBody(payload))
        return try JSONDecoder().decode(CASExperienceEnvelope.self, from: data).experience
    }

    static func uploadEvidence(experienceID: String, fileURL: URL, label: String, contextID: String?) async throws {
        var fields = [
            "experience_id": experienceID,
            "label": String(label.prefix(120)),
            "locale": Locale.current.language.languageCode?.identifier ?? "en",
        ]
        if let contextID, !contextID.isEmpty { fields["workContextId"] = contextID }
        _ = try await ToolsAPI.multipart(
            "/api/cas/evidence/upload",
            fields: fields,
            fileField: "file",
            fileURL: fileURL,
            filename: fileURL.lastPathComponent,
            mimeType: mimeType(for: fileURL)
        )
    }

    static func projects() async throws -> [CASProject] {
        let data = try await ToolsAPI.request("/api/cas/projects")
        return try JSONDecoder().decode(CASProjectsEnvelope.self, from: data).projects
    }

    static func createProject(title: String, strands: [CASStrand], contextID: String?) async throws {
        var payload: [String: Any] = [
            "title": title,
            "strands": strands.map(\.rawValue),
            "start_date": localDateKey(),
        ]
        if let contextID, !contextID.isEmpty { payload["workContextId"] = contextID }
        _ = try await ToolsAPI.request("/api/cas/projects", method: "POST", body: ToolsAPI.jsonBody(payload))
    }

    static func endProject(id: String, contextID: String?) async throws {
        var payload: [String: Any] = ["end_date": localDateKey()]
        if let contextID, !contextID.isEmpty { payload["workContextId"] = contextID }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await ToolsAPI.request("/api/cas/projects/\(encoded)", method: "PATCH", body: ToolsAPI.jsonBody(payload))
    }

    private static func titleFrom(_ text: String) -> String {
        NativeCASTools.titleFrom(text)
    }

    private static func localDateKey() -> String {
        NativeCASTools.localDateKey()
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "heic", "heif": return "image/heic"
        default: return "image/jpeg"
        }
    }
}

private enum NativeCASTools {
    static func titleFrom(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = cleaned.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? cleaned
        return String(first.prefix(80))
    }

    static func localDateKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

private let casOutcomeCopy: [Int: String] = [
    1: "Identify own strengths and develop areas for growth",
    2: "Demonstrate that challenges were undertaken",
    3: "Demonstrate how to initiate and plan a CAS experience",
    4: "Show commitment to and perseverance in CAS experiences",
    5: "Demonstrate collaborative skills",
    6: "Engage with issues of global significance",
    7: "Recognize and consider the ethics of choices and actions",
]

// MARK: - Quick CAS log

struct NativeCASLogPage: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    @State private var sentence = ""
    @State private var strand: CASStrand?
    @State private var outcomes: Set<Int> = []
    @State private var rationale: String?
    @State private var evidenceURL: URL?
    @State private var saving = false
    @State private var suggesting = false
    @State private var savedExperienceID: String?
    @State private var saved = false
    @State private var evidenceFailed = false
    @State private var error: String?

    private var contextID: String? { navigation.routeQuery["contextId"] }
    private var ready: Bool { sentence.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 && strand != nil }

    var body: some View {
        ToolsPage {
            ToolsHeading(title: "CAS", subtitle: "Capture the experience now. You can enrich the record later.")

            if saved {
                ToolsState(title: "CAS experience saved", bodyText: "The experience is in your CAS record.", action: "Log another") {
                    reset()
                }
                Button("Done") { navigation.show(.today) }.buttonStyle(BrandGhostButtonStyle())
            } else if evidenceFailed {
                ToolsState(
                    title: "Experience saved. Evidence did not upload.",
                    bodyText: "Your CAS record is safe. Retry only the evidence upload—this will not create a duplicate experience.",
                    action: saving ? "Retrying…" : "Retry evidence"
                ) { Task { await retryEvidence() } }
                Button("Continue without evidence") { saved = true; evidenceFailed = false }
                    .buttonStyle(BrandGhostButtonStyle())
            } else {
                if let error {
                    ToolsState(title: "CAS could not continue", bodyText: error)
                }

                ToolsPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        Button { chooseEvidence() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: evidenceURL == nil ? "camera" : "photo")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Brand.body)
                                    .frame(width: 42, height: 42)
                                    .background(Brand.active)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(evidenceURL == nil ? "Add evidence" : "Change evidence")
                                        .font(BrandFont.body(14, weight: .semibold)).foregroundStyle(Brand.bright)
                                    Text(evidenceURL?.lastPathComponent ?? "Photo optional")
                                        .font(BrandFont.mono(9)).foregroundStyle(Brand.muted).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Brand.muted)
                            }
                        }
                        .buttonStyle(.plain)

                        Rectangle().fill(Brand.hairline).frame(height: 1)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("WHAT HAPPENED?")
                                .font(BrandFont.mono(9, weight: .semibold)).tracking(0.6).foregroundStyle(Brand.muted)
                            TextEditor(text: $sentence)
                                .font(BrandFont.body(14))
                                .foregroundStyle(Brand.bright)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 120)
                                .padding(10)
                                .background(Brand.active.opacity(0.45))
                                .overlay(RoundedRectangle(cornerRadius: Brand.cornerMd).stroke(Brand.hairline))
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            Text("PRIMARY STRAND")
                                .font(BrandFont.mono(9, weight: .semibold)).tracking(0.6).foregroundStyle(Brand.muted)
                            HStack(spacing: 8) {
                                ForEach(CASStrand.allCases) { item in
                                    Button {
                                        strand = item
                                        rationale = nil
                                    } label: {
                                        Text(item.label)
                                            .font(BrandFont.body(12, weight: .semibold))
                                            .foregroundStyle(strand == item ? Brand.onAccent : Brand.body)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 9)
                                            .background(strand == item ? Brand.accent : Brand.active)
                                            .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                ToolsPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("LEARNING OUTCOMES")
                                    .font(BrandFont.mono(9, weight: .semibold)).tracking(0.6).foregroundStyle(Brand.muted)
                                Text(outcomes.isEmpty ? "Optional. Select only what this experience actually shows." : "\(outcomes.count) selected")
                                    .font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await suggest() }
                            } label: {
                                Label(suggesting ? "Suggesting…" : "Suggest", systemImage: "sparkles")
                            }
                            .buttonStyle(BrandGhostButtonStyle())
                            .disabled(!ready || suggesting)
                        }

                        ForEach(1...7, id: \.self) { number in
                            Button {
                                if outcomes.contains(number) { outcomes.remove(number) } else { outcomes.insert(number) }
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: outcomes.contains(number) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(outcomes.contains(number) ? Brand.accent : Brand.muted)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("LO \(number)").font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.secondary)
                                        Text(casOutcomeCopy[number] ?? "").font(BrandFont.body(11)).foregroundStyle(Brand.body)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if let rationale, !rationale.isEmpty {
                            Text(rationale).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                                .padding(.top, 4)
                        }
                    }
                }

                Button(saving ? "Saving…" : "Save experience") { Task { await save() } }
                    .buttonStyle(BrandLargePrimaryButtonStyle())
                    .disabled(!ready || saving)
            }

            if !saved && !evidenceFailed {
                Button("CAS project") { navigation.show(.toolsCASProject) }
                    .buttonStyle(BrandGhostButtonStyle())
            }
        }
    }

    private func chooseEvidence() {
        let panel = NSOpenPanel()
        panel.title = "Choose CAS evidence"
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { evidenceURL = panel.url }
    }

    private func suggest() async {
        guard ready, let strand, !suggesting else { return }
        suggesting = true
        defer { suggesting = false }
        do {
            let result = try await CASAPI.suggest(
                title: NativeCASTools.titleFrom(sentence),
                strand: strand,
                description: sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            outcomes = Set(result.suggested)
            rationale = result.rationale.isEmpty ? nil : result.rationale
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard ready, let strand, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let experience = try await CASAPI.createExperience(
                sentence: sentence,
                strand: strand,
                outcomes: outcomes.sorted(),
                contextID: contextID
            )
            savedExperienceID = experience.id
            if let evidenceURL {
                do {
                    try await CASAPI.uploadEvidence(
                        experienceID: experience.id,
                        fileURL: evidenceURL,
                        label: NativeCASTools.titleFrom(sentence),
                        contextID: contextID
                    )
                } catch {
                    evidenceFailed = true
                    self.error = nil
                    return
                }
            }
            saved = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func retryEvidence() async {
        guard let savedExperienceID, let evidenceURL, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await CASAPI.uploadEvidence(
                experienceID: savedExperienceID,
                fileURL: evidenceURL,
                label: NativeCASTools.titleFrom(sentence),
                contextID: contextID
            )
            evidenceFailed = false
            saved = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        sentence = ""
        strand = nil
        outcomes = []
        rationale = nil
        evidenceURL = nil
        savedExperienceID = nil
        saved = false
        evidenceFailed = false
        error = nil
    }
}

// MARK: - CAS project

struct NativeCASProjectPage: View {
    @ObservedObject private var navigation = NativeWorkspaceNavigation.shared
    @State private var projects: [CASProject]?
    @State private var loadError: String?
    @State private var creating = false
    @State private var title = ""
    @State private var strands: Set<CASStrand> = []
    @State private var saving = false
    @State private var endingID: String?
    @State private var confirmProject: CASProject?
    @State private var error: String?

    private var contextID: String? { navigation.routeQuery["contextId"] }

    var body: some View {
        ToolsPage {
            ToolsHeading(title: "CAS project", subtitle: "Track the sustained 30+ day commitment separately from quick CAS logs.", back: .toolsCAS)

            if let loadError, projects == nil {
                ToolsState(title: "Projects unavailable", bodyText: loadError, action: "Try again") { Task { await load() } }
            } else if projects == nil {
                ToolsLoading()
            } else {
                if let error { ToolsState(title: "CAS project could not continue", bodyText: error) }

                let loaded = projects ?? []
                if loaded.isEmpty && !creating {
                    ToolsState(
                        title: "No CAS project yet",
                        bodyText: "Create the sustained project you intend to carry for at least 30 days.",
                        action: "New project"
                    ) { creating = true }
                }

                ForEach(loaded) { project in
                    projectCard(project)
                }

                if creating {
                    createCard
                } else if !loaded.isEmpty {
                    Button("New project") { creating = true }.buttonStyle(BrandPrimaryButtonStyle())
                }
            }
        }
        .task { await load() }
        .alert("Mark this project ended?", isPresented: Binding(
            get: { confirmProject != nil },
            set: { if !$0 { confirmProject = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmProject = nil }
            Button("Mark ended") {
                if let id = confirmProject?.id { Task { await end(id) } }
                confirmProject = nil
            }
        } message: {
            Text("Ending it records today as the end date. Only projects spanning 30 or more days satisfy the duration requirement.")
        }
    }

    private func projectCard(_ project: CASProject) -> some View {
        let days = projectDuration(start: project.start_date, end: project.end_date)
        let complete = (days ?? 0) >= 30
        return ToolsPanel {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.title).font(BrandFont.display(19, weight: .semibold)).foregroundStyle(Brand.bright)
                        HStack(spacing: 8) {
                            Text(project.stage.uppercased())
                            if !project.strands.isEmpty { Text("· " + project.strands.map { $0.uppercased() }.joined(separator: " · ")) }
                        }
                        .font(BrandFont.mono(8, weight: .semibold)).foregroundStyle(Brand.muted)
                    }
                    Spacer()
                    Text(project.end_date == nil ? "ONGOING" : complete ? "COMPLETE" : "\(days ?? 0) DAYS")
                        .font(BrandFont.mono(9, weight: .semibold))
                        .foregroundStyle(complete ? Brand.success : Brand.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Brand.active)
                        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                }

                if let description = project.description, !description.isEmpty {
                    Text(description).font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                }
                Text(complete ? "30-day duration reached." : "A CAS project counts as sustained once it spans at least 30 days.")
                    .font(BrandFont.body(11)).foregroundStyle(Brand.muted)

                if project.end_date == nil {
                    Button(endingID == project.id ? "Ending…" : "Mark ended") { confirmProject = project }
                        .buttonStyle(BrandGhostButtonStyle())
                        .disabled(endingID != nil)
                }
            }
        }
    }

    private var createCard: some View {
        ToolsPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("New project").font(BrandFont.display(20, weight: .semibold)).foregroundStyle(Brand.bright)
                TextField("Project name", text: $title).textFieldStyle(BrandOutlinedFieldStyle())
                HStack(spacing: 8) {
                    ForEach(CASStrand.allCases) { item in
                        Button {
                            if strands.contains(item) { strands.remove(item) } else { strands.insert(item) }
                        } label: {
                            HStack(spacing: 5) {
                                if strands.contains(item) { Image(systemName: "checkmark") }
                                Text(item.label)
                            }
                            .font(BrandFont.body(11, weight: .semibold))
                            .foregroundStyle(strands.contains(item) ? Brand.onAccent : Brand.body)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(strands.contains(item) ? Brand.accent : Brand.active)
                            .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Button("Cancel") {
                        creating = false
                        title = ""
                        strands = []
                    }.buttonStyle(BrandGhostButtonStyle())
                    Spacer()
                    Button(saving ? "Saving…" : "Create project") { Task { await create() } }
                        .buttonStyle(BrandPrimaryButtonStyle())
                        .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func load() async {
        do {
            projects = try await CASAPI.projects()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func create() async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await CASAPI.createProject(title: trimmed, strands: strands.sorted { $0.rawValue < $1.rawValue }, contextID: contextID)
            title = ""
            strands = []
            creating = false
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func end(_ id: String) async {
        guard endingID == nil else { return }
        endingID = id
        defer { endingID = nil }
        do {
            try await CASAPI.endProject(id: id, contextID: contextID)
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func projectDuration(start: String, end: String?) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let first = formatter.date(from: start) else { return nil }
        let last = end.flatMap(formatter.date(from:)) ?? Date()
        return max(0, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0)
    }
}
