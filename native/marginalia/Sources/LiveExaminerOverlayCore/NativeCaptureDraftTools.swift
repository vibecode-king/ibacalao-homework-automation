import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Camera feedback

private struct CameraFeedbackItem: Decodable, Identifiable {
    var id: String { "\(title):\(note)" }
    let title: String
    let note: String
}

private struct CameraFeedbackAnnotation: Decodable, Identifiable {
    let id: String
    let page: Int
    let quote: String
    let kind: String
    let severity: String?
    let comment: String
}

private struct CameraFeedbackResult: Decodable {
    let pagesRead: Int
    let summary: String
    let strengths: [CameraFeedbackItem]
    let fixes: [CameraFeedbackItem]
    let nextStep: String
    let annotations: [CameraFeedbackAnnotation]
}

private struct CameraPage: Identifiable {
    let id = UUID()
    let url: URL
    var text: String?
    var error: String?
}

struct NativeCameraFeedbackPage: View {
    @State private var pages: [CameraPage] = []
    @State private var reading = false
    @State private var submitting = false
    @State private var result: CameraFeedbackResult?
    @State private var error: String?

    var body: some View {
        ToolsPage {
            ToolsHeading(title: "Camera feedback", subtitle: "Choose up to three photographed pages. Text is read locally on your Mac before feedback is requested.")

            if let error { ToolsState(title: "Camera feedback could not continue", bodyText: error) }

            if let result {
                feedbackResult(result)
                Button("Review another set") {
                    self.result = nil
                    pages = []
                    error = nil
                }.buttonStyle(BrandGhostButtonStyle())
            } else {
                if pages.isEmpty {
                    ToolsState(
                        title: "Add a page",
                        bodyText: "Use a clear photo or scan. iBacalao reads the page locally first.",
                        action: "Choose photos"
                    ) { chooseImages() }
                } else {
                    ToolsPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("PAGES READY").font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                                Spacer()
                                Text("\(pages.count) / 3").font(BrandFont.mono(9)).foregroundStyle(Brand.secondary)
                            }
                            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                                HStack(spacing: 10) {
                                    Image(systemName: page.error == nil ? (page.text == nil ? "hourglass" : "doc.text.magnifyingglass") : "exclamationmark.triangle")
                                        .foregroundStyle(page.error == nil ? Brand.body : Brand.danger)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Page \(index + 1)").font(BrandFont.body(12, weight: .semibold)).foregroundStyle(Brand.bright)
                                        Text(page.error ?? page.text.map { "\($0.count) characters read" } ?? "Waiting to read")
                                            .font(BrandFont.body(10)).foregroundStyle(page.error == nil ? Brand.muted : Brand.danger)
                                    }
                                    Spacer()
                                    Button {
                                        pages.removeAll { $0.id == page.id }
                                    } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).foregroundStyle(Brand.muted)
                                }
                                if index < pages.count - 1 { Rectangle().fill(Brand.hairline).frame(height: 1) }
                            }
                        }
                    }

                    if pages.count < 3 {
                        Button("Add another page") { chooseImages() }.buttonStyle(BrandGhostButtonStyle())
                    }
                    Button(reading ? "Reading pages…" : submitting ? "Getting feedback…" : "Get feedback") {
                        Task { await review() }
                    }
                    .buttonStyle(BrandLargePrimaryButtonStyle())
                    .disabled(reading || submitting || pages.isEmpty)
                }
            }
        }
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.title = "Choose photographed pages"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls.prefix(max(0, 3 - pages.count)) {
                pages.append(CameraPage(url: url))
            }
        }
    }

    private func review() async {
        guard !pages.isEmpty else { return }
        reading = true
        error = nil
        var resolved = pages
        for index in resolved.indices {
            if resolved[index].text != nil { continue }
            do {
                guard let image = NSImage(contentsOf: resolved[index].url) else {
                    throw NativeAPIClientError.server("Could not read page \(index + 1).")
                }
                var rect = NSRect(origin: .zero, size: image.size)
                guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                    throw NativeAPIClientError.server("Could not decode page \(index + 1).")
                }
                let text = try await OCR.recognizeDocumentText(in: cgImage).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw NativeAPIClientError.server("No readable text was found on page \(index + 1).")
                }
                resolved[index].text = text
                resolved[index].error = nil
            } catch {
                resolved[index].error = error.localizedDescription
            }
            pages = resolved
        }
        reading = false

        let texts = resolved.compactMap(\.text)
        guard texts.count == resolved.count else {
            error = "Fix or remove any page that could not be read before requesting feedback."
            return
        }

        submitting = true
        defer { submitting = false }
        do {
            let body = try ToolsAPI.jsonBody([
                "pages": texts,
                "locale": Locale.current.language.languageCode?.identifier ?? "en",
            ])
            let data = try await ToolsAPI.request("/api/native/camera-feedback", method: "POST", body: body)
            result = try JSONDecoder().decode(CameraFeedbackResult.self, from: data)
            try? await ToolsAPI.completeDaily("camera-feedback")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func feedbackResult(_ result: CameraFeedbackResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolsPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(result.pagesRead) PAGE\(result.pagesRead == 1 ? "" : "S") READ")
                        .font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                    Text(result.summary).font(BrandFont.display(20, weight: .semibold)).foregroundStyle(Brand.bright)
                }
            }
            resultSection("WHAT'S WORKING", result.strengths, color: Brand.success)
            resultSection("FIX NEXT", result.fixes, color: Brand.warning)
            ToolsPanel {
                VStack(alignment: .leading, spacing: 5) {
                    Text("NEXT STEP").font(BrandFont.mono(9, weight: .bold)).foregroundStyle(Brand.accent)
                    Text(result.nextStep).font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
                }
            }
            if !result.annotations.isEmpty {
                ToolsPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MARGINALIA").font(BrandFont.mono(9, weight: .bold)).foregroundStyle(Brand.muted)
                        ForEach(result.annotations) { annotation in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("PAGE \(annotation.page) · \(annotation.kind.uppercased())")
                                    .font(BrandFont.mono(8, weight: .semibold)).foregroundStyle(Brand.muted)
                                Text("“\(annotation.quote)”").font(BrandFont.body(11, weight: .semibold)).foregroundStyle(Brand.body)
                                Text(annotation.comment).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func resultSection(_ title: String, _ items: [CameraFeedbackItem], color: Color) -> some View {
        ToolsPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(BrandFont.mono(9, weight: .bold)).foregroundStyle(color)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(BrandFont.body(12, weight: .semibold)).foregroundStyle(Brand.bright)
                        Text(item.note).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Audio to notes

private struct AudioNoteSection: Decodable, Identifiable {
    var id: String { heading }
    let heading: String
    let bullets: [String]
}

private struct AudioNotesResult: Decodable {
    let durationSeconds: Int
    let monthlyUsedSeconds: Int
    let monthlyLimitSeconds: Int
    let transcript: String
    let title: String
    let summary: String
    let sections: [AudioNoteSection]
    let actionItems: [String]
    let questions: [String]
}

@MainActor
private final class NativeAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var duration: Int = 0
    @Published var error: String?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private(set) var fileURL: URL?

    func start() async {
        error = nil
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else {
            error = "Allow microphone access in System Settings to record audio notes."
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ibacalao-recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.record() else {
                throw NativeAPIClientError.server("The microphone could not start recording.")
            }
            self.recorder = recorder
            fileURL = url
            startedAt = Date()
            duration = 0
            isRecording = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let startedAt = self.startedAt else { return }
                    self.duration = max(0, Int(Date().timeIntervalSince(startedAt).rounded()))
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        if let startedAt { duration = max(1, Int(Date().timeIntervalSince(startedAt).rounded())) }
        self.startedAt = nil
        isRecording = false
    }

    func discard() {
        stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        duration = 0
        error = nil
    }
}

struct NativeAudioNotesPage: View {
    @StateObject private var recorder = NativeAudioRecorder()
    @State private var notes: AudioNotesResult?
    @State private var processing = false
    @State private var error: String?

    var body: some View {
        ToolsPage {
            ToolsHeading(title: "Audio to notes", subtitle: "Record a class or lecture, then turn it into structured notes.")

            if let message = error ?? recorder.error {
                ToolsState(title: "Audio notes could not continue", bodyText: message)
            }

            if let notes {
                audioResult(notes)
                Button("New recording") {
                    self.notes = nil
                    recorder.discard()
                    error = nil
                }.buttonStyle(BrandGhostButtonStyle())
            } else {
                ToolsPanel {
                    VStack(alignment: .center, spacing: 18) {
                        Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "mic.circle")
                            .font(.system(size: 54, weight: .light))
                            .foregroundStyle(recorder.isRecording ? Brand.accent : Brand.body)
                        Text(formatDuration(recorder.duration))
                            .font(BrandFont.mono(24, weight: .semibold)).foregroundStyle(Brand.bright)
                        Text(recorder.isRecording ? "RECORDING" : recorder.fileURL == nil ? "READY" : "RECORDING SAVED")
                            .font(BrandFont.mono(9, weight: .bold)).tracking(0.8).foregroundStyle(Brand.muted)

                        if recorder.isRecording {
                            Button("Stop recording") { recorder.stop() }.buttonStyle(BrandLargePrimaryButtonStyle())
                        } else if recorder.fileURL == nil {
                            Button("Start recording") { Task { await recorder.start() } }.buttonStyle(BrandLargePrimaryButtonStyle())
                        } else {
                            HStack {
                                Button("Discard") { recorder.discard() }.buttonStyle(BrandGhostButtonStyle())
                                Spacer()
                                Button(processing ? "Turning into notes…" : "Make notes") { Task { await process() } }
                                    .buttonStyle(BrandPrimaryButtonStyle())
                                    .disabled(processing)
                            }
                        }
                    }
                }
            }
        }
        .onDisappear { if recorder.isRecording { recorder.stop() } }
    }

    private func process() async {
        guard let url = recorder.fileURL, recorder.duration > 0, !processing else { return }
        processing = true
        defer { processing = false }
        do {
            let data = try await ToolsAPI.multipart(
                "/api/native/audio-notes",
                fields: [
                    "durationSeconds": String(max(1, recorder.duration)),
                    "locale": Locale.current.language.languageCode?.identifier ?? "en",
                ],
                fileField: "audio",
                fileURL: url,
                filename: "ibacalao-recording.m4a",
                mimeType: "audio/mp4"
            )
            notes = try JSONDecoder().decode(AudioNotesResult.self, from: data)
            try? await ToolsAPI.completeDaily("audio-notes")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func audioResult(_ notes: AudioNotesResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolsPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text(notes.title).font(BrandFont.display(24, weight: .semibold)).foregroundStyle(Brand.bright)
                    Text(notes.summary).font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
                    Text("\(formatDuration(notes.durationSeconds)) · \(formatDuration(notes.monthlyUsedSeconds)) / \(formatDuration(notes.monthlyLimitSeconds)) monthly")
                        .font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                }
            }
            ForEach(notes.sections) { section in
                ToolsPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.heading.uppercased()).font(BrandFont.mono(9, weight: .bold)).foregroundStyle(Brand.muted)
                        ForEach(section.bullets, id: \.self) { bullet in
                            Text("• \(bullet)").font(BrandFont.body(12)).foregroundStyle(Brand.body)
                        }
                    }
                }
            }
            if !notes.actionItems.isEmpty {
                audioList("ACTION ITEMS", notes.actionItems, Brand.warning)
            }
            if !notes.questions.isEmpty {
                audioList("QUESTIONS", notes.questions, Brand.info)
            }
            DisclosureGroup("Transcript") {
                Text(notes.transcript).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                    .textSelection(.enabled).padding(.top, 8)
            }
            .font(BrandFont.body(12, weight: .semibold)).foregroundStyle(Brand.body)
        }
    }

    private func audioList(_ title: String, _ values: [String], _ color: Color) -> some View {
        ToolsPanel {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(BrandFont.mono(9, weight: .bold)).foregroundStyle(color)
                ForEach(values, id: \.self) { value in Text("• \(value)").font(BrandFont.body(12)).foregroundStyle(Brand.body) }
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}

// MARK: - Marginalia

struct NativeMarginaliaPage: View {
    let onLaunchOverlay: () -> Void
    let onShowDispatch: () -> Void

    var body: some View {
        ToolsPage {
            ToolsHeading(title: "Marginalia", subtitle: "The desktop feedback layer is already native on this Mac.")

            ToolsPanel {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(Brand.body)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Open Marginalia over your work")
                                .font(BrandFont.display(21, weight: .semibold)).foregroundStyle(Brand.bright)
                            Text("Use the native overlay for feedback while you write instead of opening another page inside iBacalao.")
                                .font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                        }
                    }
                    Button("Open Marginalia") { onLaunchOverlay() }.buttonStyle(BrandLargePrimaryButtonStyle())
                }
            }

            ToolsPanel {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SCHOOL DISPATCH").font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                        Text("Manage the desktop school bridge and sync status.")
                            .font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                    }
                    Spacer()
                    Button("Open Dispatch") { onShowDispatch() }.buttonStyle(BrandGhostButtonStyle())
                }
            }
        }
    }
}

// MARK: - Draft editor

private struct DraftCriterion: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let score: Int
    let score_max: Int
    let verdict: String
    let finding: String
    let suggestion: String
    let missing: Bool?
}

private struct DraftReviewResult: Decodable {
    let criteria: [DraftCriterion]
    let reviewId: String?
    let remaining: Int
    let documentText: String?
}

private struct DraftSubjectEnvelope: Decodable { let subjects: [String] }

private enum DraftAPI {
    static func subjects() async throws -> [String] {
        let data = try await ToolsAPI.request("/api/native/subjects")
        return try JSONDecoder().decode(DraftSubjectEnvelope.self, from: data).subjects
            .filter { !["TOK", "EE", "CAS"].contains($0.uppercased()) }
    }

    static func upload(file: URL, subject: String, level: String, baselineID: String? = nil) async throws -> DraftReviewResult {
        var fields = ["subject": subject, "level": level]
        if let baselineID, !baselineID.isEmpty { fields["baselineReviewId"] = baselineID }
        let data = try await ToolsAPI.multipart(
            "/api/feedback",
            fields: fields,
            fileField: "file",
            fileURL: file,
            filename: file.lastPathComponent.isEmpty ? "draft.pdf" : file.lastPathComponent,
            mimeType: "application/pdf"
        )
        return try JSONDecoder().decode(DraftReviewResult.self, from: data)
    }

    static func recheck(text: String, subject: String, level: String, baselineID: String?) async throws -> DraftReviewResult {
        var payload: [String: Any] = ["text": text, "subject": subject, "level": level]
        if let baselineID, !baselineID.isEmpty { payload["baselineReviewId"] = baselineID }
        let data = try await ToolsAPI.request("/api/feedback", method: "POST", body: ToolsAPI.jsonBody(payload))
        return try JSONDecoder().decode(DraftReviewResult.self, from: data)
    }
}

struct NativeDraftEditorPage: View {
    @State private var subjects: [String]?
    @State private var subject = ""
    @State private var level = "HL"
    @State private var sourceURL: URL?
    @State private var documentText = ""
    @State private var review: DraftReviewResult?
    @State private var loading = false
    @State private var error: String?
    @State private var saved = true

    var body: some View {
        ToolsPage {
            ToolsHeading(title: "Draft editor", subtitle: review == nil ? "Choose the subject, upload the draft PDF, then edit the extracted text." : "Edit the same draft, then recheck it against the same baseline.")

            if let error { ToolsState(title: "Draft review could not continue", bodyText: error) }

            if subjects == nil {
                ToolsLoading()
            } else if review == nil {
                ToolsPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("SUBJECT").font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                        Picker("Subject", selection: $subject) {
                            ForEach(subjects ?? [], id: \.self) { item in
                                Text(draftSubjectLabel(item)).tag(item)
                            }
                        }
                        .labelsHidden()

                        Text("LEVEL").font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                        HStack(spacing: 6) {
                            ForEach(["SL", "HL"], id: \.self) { item in
                                Button(item) { level = item }
                                    .buttonStyle(.plain)
                                    .font(BrandFont.mono(10, weight: .bold))
                                    .foregroundStyle(level == item ? Brand.onAccent : Brand.body)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(level == item ? Brand.accent : Brand.active)
                                    .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                            }
                        }

                        Button {
                            choosePDF()
                        } label: {
                            HStack {
                                Image(systemName: "doc.badge.plus")
                                Text(sourceURL?.lastPathComponent ?? "Choose PDF")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                        }
                        .buttonStyle(BrandGhostButtonStyle())

                        Button(loading ? "Reviewing…" : "Review draft") { Task { await upload() } }
                            .buttonStyle(BrandLargePrimaryButtonStyle())
                            .disabled(loading || subject.isEmpty || sourceURL == nil)
                    }
                }
            } else if let review {
                HStack {
                    Text("\(review.remaining) REVIEWS LEFT")
                        .font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                    Spacer()
                    Text(saved ? "SAVED" : "EDITED")
                        .font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(saved ? Brand.success : Brand.warning)
                }

                TextEditor(text: $documentText)
                    .font(BrandFont.body(13))
                    .foregroundStyle(Brand.bright)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 300)
                    .padding(12)
                    .background(Brand.card)
                    .overlay(RoundedRectangle(cornerRadius: Brand.cornerMd).stroke(Brand.hairline))
                    .onChange(of: documentText) { _, _ in saved = false }

                Button(loading ? "Rechecking…" : "Recheck draft") { Task { await recheck() } }
                    .buttonStyle(BrandLargePrimaryButtonStyle())
                    .disabled(loading || documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                VStack(spacing: 10) {
                    ForEach(review.criteria) { criterion in
                        ToolsPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(criterion.name).font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.bright)
                                    Spacer()
                                    Text("\(criterion.score) / \(criterion.score_max)")
                                        .font(BrandFont.mono(11, weight: .bold)).foregroundStyle(Brand.body)
                                }
                                Text(criterion.verdict.uppercased()).font(BrandFont.mono(8, weight: .semibold)).foregroundStyle(Brand.muted)
                                Text(criterion.finding).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                                Text("Fix first: \(criterion.suggestion)").font(BrandFont.body(11, weight: .semibold)).foregroundStyle(Brand.bright)
                            }
                        }
                    }
                }

                Button("Choose another draft") {
                    self.review = nil
                    sourceURL = nil
                    documentText = ""
                    error = nil
                }.buttonStyle(BrandGhostButtonStyle())
            }
        }
        .task { await loadSubjects() }
    }

    private func loadSubjects() async {
        guard subjects == nil else { return }
        do {
            subjects = try await DraftAPI.subjects()
            if subject.isEmpty { subject = subjects?.first ?? "" }
            error = nil
        } catch {
            self.error = error.localizedDescription
            subjects = []
        }
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.title = "Choose draft PDF"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { sourceURL = panel.url }
    }

    private func upload() async {
        guard let sourceURL, !subject.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await DraftAPI.upload(file: sourceURL, subject: subject, level: level)
            guard let text = result.documentText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw NativeAPIClientError.server("The PDF did not contain readable text.")
            }
            documentText = text
            review = result
            saved = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func recheck() async {
        guard !loading else { return }
        let text = documentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            review = try await DraftAPI.recheck(text: text, subject: subject, level: level, baselineID: review?.reviewId)
            saved = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func draftSubjectLabel(_ value: String) -> String {
        value.split(separator: "_").map { part in
            let item = String(part)
            return item.count <= 2 ? item.uppercased() : item.prefix(1).uppercased() + item.dropFirst()
        }.joined(separator: " ")
    }
}
