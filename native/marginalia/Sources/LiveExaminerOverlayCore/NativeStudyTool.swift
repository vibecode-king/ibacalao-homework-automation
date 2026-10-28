import SwiftUI
import Combine

private enum StudyLevelValue: Decodable {
    case scalar(Int)
    case levels(sl: Int, hl: Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .scalar(value)
            return
        }
        let values = try container.decode([String: Int].self)
        self = .levels(sl: values["SL"] ?? 0, hl: values["HL"] ?? 0)
    }

    func value(for level: String) -> Int {
        switch self {
        case .scalar(let value): return value
        case .levels(let sl, let hl): return level == "HL" ? hl : sl
        }
    }

    func display(levels: [String], unit: String) -> String {
        switch self {
        case .scalar(let value):
            return "\(value) \(unit)"
        case .levels(let sl, let hl):
            if sl == hl { return "\(sl) \(unit)" }
            if levels.count == 1 { return "\(levels[0] == "HL" ? hl : sl) \(unit)" }
            return "SL \(sl) / HL \(hl) \(unit)"
        }
    }
}

private struct StudyPaper: Decodable, Hashable, Identifiable {
    var id: String { paper }
    let paper: String
    let levels: [String]
    let style: String
    let durationMin: StudyLevelValue
    let totalMarks: StudyLevelValue
    let blurb: String

    static func == (lhs: StudyPaper, rhs: StudyPaper) -> Bool { lhs.paper == rhs.paper }
    func hash(into hasher: inout Hasher) { hasher.combine(paper) }
}

private struct StudySubject: Decodable, Identifiable {
    let id: String
    let label: String
    let papers: [StudyPaper]
}

private struct StudyCatalog: Decodable { let subjects: [StudySubject] }

private struct StudyQuestion: Decodable, Identifiable {
    var id: String { questionId }
    let questionId: String
    let subject: String
    let paper: String
    let level: String
    let style: String
    let commandTerm: String
    let marks: Int
    let topic: String
    let prompt: String
    let stimulus: String?
    let difficulty: Int
    let options: [String]?
    let markSchemeToken: String
}

private struct StudyMarkPoint: Decodable, Identifiable {
    var id: String { "\(point):\(note)" }
    let point: String
    let awarded: Bool
    let note: String
}

private struct StudyFeedback: Decodable {
    let awarded: Int
    let max: Int
    let markPoints: [StudyMarkPoint]
    let strengths: [String]
    let improvements: [String]

    enum CodingKeys: String, CodingKey { case awarded, max, markPoints, strengths, improvements }

    init(awarded: Int, max: Int, markPoints: [StudyMarkPoint], strengths: [String], improvements: [String]) {
        self.awarded = awarded
        self.max = max
        self.markPoints = markPoints
        self.strengths = strengths
        self.improvements = improvements
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        awarded = try c.decode(Int.self, forKey: .awarded)
        max = try c.decode(Int.self, forKey: .max)
        strengths = try c.decodeIfPresent([String].self, forKey: .strengths) ?? []
        improvements = try c.decodeIfPresent([String].self, forKey: .improvements) ?? []
        if let points = try? c.decode([StudyMarkPoint].self, forKey: .markPoints) {
            markPoints = points
        } else {
            let strings = try c.decodeIfPresent([String].self, forKey: .markPoints) ?? []
            markPoints = strings.map { StudyMarkPoint(point: $0, awarded: false, note: "") }
        }
    }
}

private struct StudySelfAssess: Decodable {
    let selfAssess: Bool
    let markPoints: [String]
    let max: Int
}

private struct StudyMCQResult: Decodable { let correct: Bool }

private enum StudyAPI {
    static func catalog() async throws -> StudyCatalog {
        let data = try await ToolsAPI.request("/api/native/study/catalog")
        return try JSONDecoder().decode(StudyCatalog.self, from: data)
    }

    static func question(subject: StudySubject, paper: StudyPaper, level: String) async throws -> StudyQuestion {
        let body = try ToolsAPI.jsonBody([
            "subject": subject.id,
            "paper": paper.paper,
            "level": level,
        ])
        let data = try await ToolsAPI.request("/api/exam/question", method: "POST", body: body)
        return try JSONDecoder().decode(StudyQuestion.self, from: data)
    }

    static func gradeMCQ(_ question: StudyQuestion, selected: Int) async throws -> StudyFeedback {
        let body = try ToolsAPI.jsonBody([
            "markSchemeToken": question.markSchemeToken,
            "answer": String(selected),
            "subject": question.subject,
            "level": question.level,
            "questionPrompt": question.prompt,
            "marks": question.marks,
            "questionId": question.questionId,
            "paper": question.paper,
            "topic": question.topic,
            "difficulty": question.difficulty,
            "mcqAwarded": 0,
            "selectedOption": selected,
        ])
        let data = try await ToolsAPI.request("/api/exam/grade", method: "POST", body: body)
        let correct = try JSONDecoder().decode(StudyMCQResult.self, from: data).correct
        return StudyFeedback(
            awarded: correct ? question.marks : 0,
            max: question.marks,
            markPoints: [StudyMarkPoint(
                point: correct ? "Correct option selected." : "Incorrect option selected.",
                awarded: correct,
                note: correct ? "Your answer is correct." : "Review this topic and try again."
            )],
            strengths: correct ? ["Correct answer selected."] : [],
            improvements: correct ? [] : ["Review this topic and try again."]
        )
    }

    static func markScheme(_ question: StudyQuestion, answer: String) async throws -> StudySelfAssess {
        var payload: [String: Any] = [
            "markSchemeToken": question.markSchemeToken,
            "answer": answer,
            "subject": question.subject,
            "level": question.level,
            "questionPrompt": question.prompt,
            "marks": question.marks,
            "selfAssess": true,
        ]
        if let stimulus = question.stimulus { payload["stimulus"] = stimulus }
        let data = try await ToolsAPI.request("/api/exam/grade", method: "POST", body: ToolsAPI.jsonBody(payload))
        return try JSONDecoder().decode(StudySelfAssess.self, from: data)
    }

    static func gradeWritten(_ question: StudyQuestion, answer: String) async throws -> StudyFeedback {
        var payload: [String: Any] = [
            "markSchemeToken": question.markSchemeToken,
            "answer": answer,
            "subject": question.subject,
            "level": question.level,
            "questionPrompt": question.prompt,
            "marks": question.marks,
            "questionId": question.questionId,
            "paper": question.paper,
            "topic": question.topic,
            "difficulty": question.difficulty,
        ]
        if let stimulus = question.stimulus { payload["stimulus"] = stimulus }
        let data = try await ToolsAPI.request("/api/exam/grade", method: "POST", body: ToolsAPI.jsonBody(payload))
        return try JSONDecoder().decode(StudyFeedback.self, from: data)
    }

    static func logSelfAssessment(_ question: StudyQuestion, awarded: Int, max: Int) async throws {
        let body = try ToolsAPI.jsonBody([
            "selfAssessScore": awarded,
            "selfAssessMax": max,
            "questionId": question.questionId,
            "paper": question.paper,
            "level": question.level,
            "topic": question.topic,
            "difficulty": question.difficulty,
            "subject": question.subject,
        ])
        _ = try await ToolsAPI.request("/api/exam/grade", method: "PUT", body: body)
    }
}

private enum StudyMode: String { case practice, test }
private enum StudyPhase { case setup, loading, answering, grading, selfAssess, feedback, results, planRequired, error }

private struct StudyCompleted: Identifiable {
    let id = UUID()
    let question: StudyQuestion
    let answer: String
    let feedback: StudyFeedback
}

struct NativeStudyPage: View {
    @State private var catalog: StudyCatalog?
    @State private var catalogError: String?
    @State private var subject: StudySubject?
    @State private var paper: StudyPaper?
    @State private var level = "SL"
    @State private var mode: StudyMode?
    @State private var phase: StudyPhase = .setup
    @State private var question: StudyQuestion?
    @State private var answer = ""
    @State private var selectedOption: Int?
    @State private var feedback: StudyFeedback?
    @State private var markPoints: [String] = []
    @State private var checkedPoints: Set<Int> = []
    @State private var error: String?
    @State private var practiceTimed = false
    @State private var practiceRemaining: Int?
    @State private var testCount = 10
    @State private var testDuration = 30
    @State private var testIndex = 0
    @State private var testRemaining: Int?
    @State private var completed: [StudyCompleted] = []
    @State private var dailyReported = false

    private let testCounts = [5, 10, 15, 20]
    private let testDurations = [15, 30, 45, 60]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ToolsPage {
            ToolsHeading(
                title: paper.map { "\(subject?.label ?? "Study") · \(studyPaperLabel($0.paper))" } ?? subject?.label ?? "Study",
                subtitle: phase == .answering ? timerLabel : "Full exam practice with immediate feedback or one test clock."
            )

            if catalog == nil && catalogError == nil {
                ToolsLoading()
            } else if let catalogError {
                ToolsState(title: "Study unavailable", bodyText: catalogError, action: "Try again") { Task { await loadCatalog() } }
            } else if subject == nil, let catalog {
                subjectPicker(catalog)
            } else if paper == nil, let subject {
                paperPicker(subject)
            } else if let paper {
                runner(paper)
            }
        }
        .task { if catalog == nil { await loadCatalog() } }
        .onReceive(timer) { _ in tick() }
    }

    @ViewBuilder
    private func subjectPicker(_ catalog: StudyCatalog) -> some View {
        ToolsPanel {
            Text("Choose a subject, then the real IB paper you want to practise.")
                .font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
            ForEach(Array(catalog.subjects.enumerated()), id: \.element.id) { index, item in
                Button {
                    subject = item
                    paper = nil
                    mode = nil
                    resetRunner()
                } label: {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(String(format: "%02d", index + 1)).font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                            Spacer()
                            Image(systemName: "arrow.up.right").foregroundStyle(Brand.secondary)
                        }
                        Text(compactSubject(item.label)).font(BrandFont.display(20, weight: .semibold)).foregroundStyle(Brand.bright)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.papers.map { studyPaperLabel($0.paper).replacingOccurrences(of: "Paper ", with: "P") }.joined(separator: " · "))
                            .font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                    }
                    .padding(16)
                    .frame(minHeight: 130)
                    .background(Brand.card)
                    .overlay(RoundedRectangle(cornerRadius: Brand.cornerLg).stroke(Brand.hairline))
                    .clipShape(RoundedRectangle(cornerRadius: Brand.cornerLg))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func paperPicker(_ subject: StudySubject) -> some View {
        Text("Choose a paper.")
            .font(BrandFont.body(13, weight: .semibold)).foregroundStyle(Brand.body)
        ForEach(subject.papers) { item in
            Button {
                paper = item
                level = item.levels.contains("SL") ? "SL" : (item.levels.first ?? "HL")
                mode = nil
                resetRunner()
            } label: {
                ToolsPanel {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(studyPaperLabel(item.paper)).font(BrandFont.display(21, weight: .semibold)).foregroundStyle(Brand.bright)
                            Text(item.blurb).font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                            Text(item.levels.joined(separator: " · ")).font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                        }
                        Spacer()
                        Text("\(item.totalMarks.display(levels: item.levels, unit: "MARKS")) · \(item.durationMin.display(levels: item.levels, unit: "MIN"))")
                            .font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        Button("Change subject") {
            self.subject = nil
            paper = nil
            resetRunner()
        }.buttonStyle(BrandGhostButtonStyle())
    }

    @ViewBuilder
    private func runner(_ paper: StudyPaper) -> some View {
        switch phase {
        case .setup:
            setup(paper)
        case .loading:
            ToolsLoading()
        case .answering, .grading:
            if let question { questionView(question) }
        case .selfAssess:
            if let question { selfAssessView(question) }
        case .feedback:
            if let question, let feedback { feedbackView(question, feedback) }
        case .results:
            resultsView
        case .planRequired:
            ToolsState(title: "This paper needs a paid Study plan", bodyText: "Choose another paper or continue with a route included in your plan.", action: "Choose another") {
                self.paper = nil
                resetRunner()
            }
        case .error:
            ToolsState(title: "Study could not continue", bodyText: error ?? "Something went wrong.", action: "Back to setup") {
                resetRunner()
            }
        }
    }

    @ViewBuilder
    private func setup(_ paper: StudyPaper) -> some View {
        ToolsPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("LEVEL").font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(paper.levels, id: \.self) { item in
                            Button(item) { level = item }
                                .buttonStyle(.plain)
                                .font(BrandFont.mono(10, weight: .semibold))
                                .foregroundStyle(level == item ? Brand.onAccent : Brand.body)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(level == item ? Brand.accent : Brand.active)
                                .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                        }
                    }
                }
                Rectangle().fill(Brand.hairline).frame(height: 1)
                Text("HOW DO YOU WANT TO PRACTISE?")
                    .font(BrandFont.mono(9, weight: .semibold)).tracking(0.5).foregroundStyle(Brand.muted)
                HStack(spacing: 10) {
                    modeCard(.practice, title: "One question", copy: "Immediate feedback")
                    modeCard(.test, title: "Exam conditions", copy: "One clock")
                }
            }
        }

        if mode == .practice {
            ToolsPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Question timer", isOn: $practiceTimed)
                        .toggleStyle(.switch)
                        .foregroundStyle(Brand.body)
                    Button("Get question") { Task { await getQuestion() } }
                        .buttonStyle(BrandLargePrimaryButtonStyle())
                }
            }
        }

        if mode == .test {
            ToolsPanel {
                VStack(alignment: .leading, spacing: 15) {
                    studyChoiceRow(title: "QUESTIONS", choices: testCounts, selection: $testCount, suffix: "")
                    studyChoiceRow(title: "TIME", choices: testDurations, selection: $testDuration, suffix: "m")
                    Button("Start test") {
                        completed = []
                        testIndex = 0
                        testRemaining = testDuration * 60
                        Task { await getQuestion(nextIndex: 0) }
                    }
                    .buttonStyle(BrandLargePrimaryButtonStyle())
                }
            }
        }

        Button("Change paper") {
            self.paper = nil
            mode = nil
            resetRunner()
        }.buttonStyle(BrandGhostButtonStyle())
    }

    private func modeCard(_ item: StudyMode, title: String, copy: String) -> some View {
        Button {
            mode = item
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(title).font(BrandFont.body(14, weight: .semibold)).foregroundStyle(Brand.bright)
                    Spacer()
                    Image(systemName: mode == item ? "checkmark" : "arrow.right")
                        .foregroundStyle(mode == item ? Brand.accent : Brand.secondary)
                }
                Text(copy).font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mode == item ? Brand.active : Brand.card)
            .overlay(RoundedRectangle(cornerRadius: Brand.cornerMd).stroke(mode == item ? Brand.edge : Brand.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
        }
        .buttonStyle(.plain)
    }

    private func studyChoiceRow(title: String, choices: [Int], selection: Binding<Int>, suffix: String) -> some View {
        HStack {
            Text(title).font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
            Spacer()
            HStack(spacing: 5) {
                ForEach(choices, id: \.self) { item in
                    Button("\(item)\(suffix)") { selection.wrappedValue = item }
                        .buttonStyle(.plain)
                        .font(BrandFont.mono(9, weight: .semibold))
                        .foregroundStyle(selection.wrappedValue == item ? Brand.onAccent : Brand.body)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(selection.wrappedValue == item ? Brand.accent : Brand.active)
                        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                }
            }
        }
    }

    @ViewBuilder
    private func questionView(_ question: StudyQuestion) -> some View {
        ToolsPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(question.topic.uppercased()).font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                    Spacer()
                    if mode == .test { Text("\(testIndex + 1) / \(testCount)").font(BrandFont.mono(9)).foregroundStyle(Brand.muted) }
                    Text("\(question.marks) MARK\(question.marks == 1 ? "" : "S")").font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                }
                if let stimulus = question.stimulus, !stimulus.isEmpty {
                    Text(stimulus).font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                }
                Text(question.prompt).font(BrandFont.display(20, weight: .semibold)).foregroundStyle(Brand.bright)
            }
        }

        if question.style == "mcq", let options = question.options {
            VStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button {
                        selectedOption = index
                        answer = String(index)
                        Task { await submitCurrent() }
                    } label: {
                        HStack(spacing: 12) {
                            Text(studyOptionLetter(index)).font(BrandFont.mono(11, weight: .bold)).foregroundStyle(Brand.secondary).frame(width: 28)
                            Text(option).font(BrandFont.body(13)).foregroundStyle(Brand.bright)
                            Spacer()
                            if selectedOption == index && phase == .grading { ProgressView().controlSize(.small).tint(Brand.accent) }
                        }
                        .padding(13)
                        .background(selectedOption == index ? Brand.active : Brand.card)
                        .overlay(RoundedRectangle(cornerRadius: Brand.cornerMd).stroke(Brand.hairline))
                        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                    }
                    .buttonStyle(.plain)
                    .disabled(phase == .grading)
                }
            }
        } else {
            TextEditor(text: $answer)
                .font(BrandFont.body(13))
                .foregroundStyle(Brand.bright)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .padding(10)
                .background(Brand.card)
                .overlay(RoundedRectangle(cornerRadius: Brand.cornerMd).stroke(Brand.hairline))
            HStack {
                Button("Skip") { Task { await skipCurrent() } }.buttonStyle(BrandGhostButtonStyle())
                Spacer()
                Button(phase == .grading ? "Marking…" : "Submit") { Task { await submitCurrent() } }
                    .buttonStyle(BrandPrimaryButtonStyle())
                    .disabled(phase == .grading || answer.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            }
        }
    }

    private func selfAssessView(_ question: StudyQuestion) -> some View {
        ToolsPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("Mark like the examiner")
                    .font(BrandFont.display(22, weight: .semibold)).foregroundStyle(Brand.bright)
                Text("Tick the mark-scheme points your answer genuinely contains.")
                    .font(BrandFont.body(13)).foregroundStyle(Brand.secondary)

                ForEach(Array(markPoints.enumerated()), id: \.offset) { index, point in
                    Button {
                        if checkedPoints.contains(index) { checkedPoints.remove(index) } else { checkedPoints.insert(index) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: checkedPoints.contains(index) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(checkedPoints.contains(index) ? Brand.accent : Brand.muted)
                            Text(point).font(BrandFont.body(12)).foregroundStyle(Brand.body)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button("See result") { Task { await finishSelfAssess(question) } }
                    .buttonStyle(BrandLargePrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func feedbackView(_ question: StudyQuestion, _ feedback: StudyFeedback) -> some View {
        ToolsPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(feedback.awarded)").font(BrandFont.display(38, weight: .semibold)).foregroundStyle(Brand.bright)
                    Text("/ \(feedback.max)").font(BrandFont.mono(11)).foregroundStyle(Brand.muted)
                    Spacer()
                    Text(question.topic.uppercased()).font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                }
                if !feedback.strengths.isEmpty {
                    feedbackList("WHAT WORKED", feedback.strengths, Brand.success)
                }
                if !feedback.improvements.isEmpty {
                    feedbackList("NEXT FIX", feedback.improvements, Brand.warning)
                }
                if !feedback.markPoints.isEmpty {
                    Rectangle().fill(Brand.hairline).frame(height: 1)
                    ForEach(feedback.markPoints) { point in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: point.awarded ? "checkmark" : "minus")
                                .foregroundStyle(point.awarded ? Brand.success : Brand.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(point.point).font(BrandFont.body(11, weight: .semibold)).foregroundStyle(Brand.body)
                                if !point.note.isEmpty { Text(point.note).font(BrandFont.body(10)).foregroundStyle(Brand.muted) }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }

        HStack {
            Button("Retry") {
                self.feedback = nil
                answer = ""
                selectedOption = nil
                phase = .answering
            }.buttonStyle(BrandGhostButtonStyle())
            Spacer()
            Button("Next question") {
                resetQuestionOnly()
                Task { await getQuestion() }
            }.buttonStyle(BrandPrimaryButtonStyle())
        }
    }

    private func feedbackList(_ title: String, _ values: [String], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(color)
            ForEach(values, id: \.self) { value in
                Text("• \(value)").font(BrandFont.body(12)).foregroundStyle(Brand.body)
            }
        }
    }

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolsPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(completed.reduce(0) { $0 + $1.feedback.awarded }) / \(completed.reduce(0) { $0 + $1.feedback.max })")
                        .font(BrandFont.display(37, weight: .semibold)).foregroundStyle(Brand.bright)
                    Text("\(completed.count) OF \(testCount) QUESTIONS ANSWERED")
                        .font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                    if completed.count < testCount {
                        Text("\(testCount - completed.count) question\(testCount - completed.count == 1 ? "" : "s") not reached before the clock ended.")
                            .font(BrandFont.body(11)).foregroundStyle(Brand.secondary)
                    }
                    Button("Start another") {
                        completed = []
                        testIndex = 0
                        testRemaining = nil
                        phase = .setup
                        mode = .test
                    }.buttonStyle(BrandPrimaryButtonStyle())
                }
            }

            ForEach(Array(completed.enumerated()), id: \.element.id) { index, item in
                ToolsPanel {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("QUESTION \(index + 1) · \(item.question.topic.uppercased())")
                                .font(BrandFont.mono(8)).foregroundStyle(Brand.muted)
                            Text(item.question.prompt).font(BrandFont.body(12)).foregroundStyle(Brand.body)
                        }
                        Spacer()
                        Text("\(item.feedback.awarded) / \(item.feedback.max)")
                            .font(BrandFont.mono(10, weight: .semibold)).foregroundStyle(Brand.bright)
                    }
                }
            }
        }
    }

    private var timerLabel: String? {
        let value = mode == .test ? testRemaining : practiceRemaining
        guard let value else { return nil }
        return String(format: "%02d:%02d", max(0, value) / 60, max(0, value) % 60)
    }

    private func loadCatalog() async {
        catalogError = nil
        do { catalog = try await StudyAPI.catalog() }
        catch { catalogError = error.localizedDescription }
    }

    private func getQuestion(nextIndex: Int? = nil) async {
        guard let subject, let paper else { return }
        phase = .loading
        error = nil
        answer = ""
        selectedOption = nil
        feedback = nil
        markPoints = []
        checkedPoints = []
        do {
            question = try await StudyAPI.question(subject: subject, paper: paper, level: level)
            if let nextIndex { testIndex = nextIndex }
            if mode == .practice && practiceTimed { practiceRemaining = (question?.marks ?? 1) * 60 }
            phase = .answering
        } catch {
            routeStudyError(error)
        }
    }

    private func submitCurrent() async {
        guard let question, phase == .answering else { return }
        let current = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .grading
        do {
            if mode == .test {
                let graded: StudyFeedback
                if question.style == "mcq" {
                    guard let selectedOption else { phase = .answering; return }
                    graded = try await StudyAPI.gradeMCQ(question, selected: selectedOption)
                } else {
                    guard current.count >= 3 else { phase = .answering; error = "Write an answer before moving on."; return }
                    graded = try await StudyAPI.gradeWritten(question, answer: current)
                }
                completed.append(StudyCompleted(question: question, answer: current, feedback: graded))
                if testIndex + 1 >= testCount {
                    phase = .results
                    testRemaining = nil
                    await reportDaily()
                } else {
                    await getQuestion(nextIndex: testIndex + 1)
                }
                return
            }

            if question.style == "mcq" {
                guard let selectedOption else { phase = .answering; return }
                feedback = try await StudyAPI.gradeMCQ(question, selected: selectedOption)
                phase = .feedback
                practiceRemaining = nil
                await reportDaily()
            } else {
                guard current.count >= 3 else { phase = .answering; error = "Write an answer before moving on."; return }
                let scheme = try await StudyAPI.markScheme(question, answer: current)
                markPoints = scheme.markPoints
                checkedPoints = []
                phase = .selfAssess
                practiceRemaining = nil
            }
        } catch {
            routeStudyError(error)
        }
    }

    private func finishSelfAssess(_ question: StudyQuestion) async {
        let awarded = min(checkedPoints.count, question.marks)
        let result = StudyFeedback(
            awarded: awarded,
            max: question.marks,
            markPoints: markPoints.enumerated().map { index, point in
                StudyMarkPoint(point: point, awarded: checkedPoints.contains(index), note: "")
            },
            strengths: awarded > 0 ? ["You matched \(awarded) mark-scheme point\(awarded == 1 ? "" : "s")."] : [],
            improvements: awarded < question.marks ? ["Rework the missing mark-scheme points, then retry the question."] : []
        )
        feedback = result
        phase = .feedback
        try? await StudyAPI.logSelfAssessment(question, awarded: awarded, max: question.marks)
        await reportDaily()
    }

    private func skipCurrent() async {
        guard let question, phase == .answering else { return }
        if mode == .test {
            let skipped = StudyFeedback(awarded: 0, max: question.marks, markPoints: [], strengths: [], improvements: ["Skipped."])
            completed.append(StudyCompleted(question: question, answer: "", feedback: skipped))
            if testIndex + 1 >= testCount {
                phase = .results
                testRemaining = nil
                await reportDaily()
            } else {
                await getQuestion(nextIndex: testIndex + 1)
            }
        } else {
            await getQuestion()
        }
    }

    private func tick() {
        if mode == .practice, phase == .answering, practiceTimed, let remaining = practiceRemaining {
            if remaining <= 1 {
                practiceRemaining = nil
                Task { await submitCurrent() }
            } else {
                practiceRemaining = remaining - 1
            }
        }
        if mode == .test, phase != .results, let remaining = testRemaining {
            if remaining <= 1 {
                testRemaining = nil
                if phase == .answering, let question {
                    let current = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !current.isEmpty {
                        Task {
                            if question.style == "mcq", selectedOption == nil {
                                completed.append(StudyCompleted(question: question, answer: "", feedback: StudyFeedback(awarded: 0, max: question.marks, markPoints: [], strengths: [], improvements: ["Time expired."])))
                            } else {
                                await submitCurrent()
                            }
                            phase = .results
                            await reportDaily()
                        }
                    } else {
                        completed.append(StudyCompleted(question: question, answer: "", feedback: StudyFeedback(awarded: 0, max: question.marks, markPoints: [], strengths: [], improvements: ["Time expired."])))
                        phase = .results
                        Task { await reportDaily() }
                    }
                } else {
                    phase = .results
                    Task { await reportDaily() }
                }
            } else {
                testRemaining = remaining - 1
            }
        }
    }

    private func reportDaily() async {
        guard !dailyReported else { return }
        dailyReported = true
        try? await ToolsAPI.completeDaily("study")
    }

    private func routeStudyError(_ error: Error) {
        let message = error.localizedDescription
        self.error = message
        if message.range(of: "plan|Pro|Ultra", options: [.regularExpression, .caseInsensitive]) != nil {
            phase = .planRequired
        } else {
            phase = .error
        }
    }

    private func resetRunner() {
        phase = .setup
        resetQuestionOnly()
        practiceRemaining = nil
        testRemaining = nil
        completed = []
        error = nil
    }

    private func resetQuestionOnly() {
        question = nil
        answer = ""
        selectedOption = nil
        feedback = nil
        markPoints = []
        checkedPoints = []
        error = nil
    }

    private func compactSubject(_ label: String) -> String {
        label
            .replacingOccurrences(of: "Mathematics: Analysis and Approaches", with: "Mathematics AA")
            .replacingOccurrences(of: "Mathematics: Applications and Interpretation", with: "Mathematics AI")
    }
}

private func studyPaperLabel(_ paper: String) -> String {
    switch paper {
    case "paper1": return "Paper 1"
    case "paper2": return "Paper 2"
    case "paper3": return "Paper 3"
    default: return paper
    }
}

private func studyOptionLetter(_ index: Int) -> String {
    let labels = ["A", "B", "C", "D"]
    return labels.indices.contains(index) ? labels[index] : "\(index + 1)"
}
