import SwiftUI

// MARK: - Quick practice

private struct PracticeOption: Decodable, Hashable, Identifiable {
    var id: String { "\(subject):\(paper):\(level)" }
    let subject: String
    let label: String
    let paper: String
    let level: String
}

private struct PracticeOptionsEnvelope: Decodable { let options: [PracticeOption] }

private struct ExamQuestion: Decodable, Identifiable {
    var id: String { questionId }
    let questionId: String
    let subject: String
    let paper: String
    let level: String
    let style: String
    let marks: Int
    let topic: String
    let prompt: String
    let stimulus: String?
    let difficulty: Int
    let options: [String]?
    let markSchemeToken: String
    let commandTerm: String?
}

private enum PracticeAPI {
    static func options() async throws -> [PracticeOption] {
        let data = try await ToolsAPI.request("/api/native/exam/options")
        return try JSONDecoder().decode(PracticeOptionsEnvelope.self, from: data).options
    }

    static func question(for option: PracticeOption) async throws -> ExamQuestion {
        let body = try ToolsAPI.jsonBody([
            "subject": option.subject,
            "paper": option.paper,
            "level": option.level,
        ])
        let data = try await ToolsAPI.request("/api/exam/question", method: "POST", body: body)
        return try JSONDecoder().decode(ExamQuestion.self, from: data)
    }

    static func grade(_ question: ExamQuestion, option: Int) async throws -> Bool {
        struct Result: Decodable { let correct: Bool }
        let body = try ToolsAPI.jsonBody([
            "markSchemeToken": question.markSchemeToken,
            "answer": String(option),
            "subject": question.subject,
            "level": question.level,
            "questionPrompt": question.prompt,
            "marks": question.marks,
            "questionId": question.questionId,
            "paper": question.paper,
            "topic": question.topic,
            "difficulty": question.difficulty,
            "mcqAwarded": 0,
            "selectedOption": option,
        ])
        let data = try await ToolsAPI.request("/api/exam/grade", method: "POST", body: body)
        return try JSONDecoder().decode(Result.self, from: data).correct
    }
}

struct NativePracticePage: View {
    @State private var options: [PracticeOption]?
    @State private var choice: PracticeOption?
    @State private var question: ExamQuestion?
    @State private var picked: Int?
    @State private var correct: Bool?
    @State private var loading = false
    @State private var grading = false
    @State private var error: String?
    @State private var requestID = UUID()

    var body: some View {
        ToolsPage {
            ToolsHeading(title: "Quick practice", subtitle: "Get a question, answer it, get the next one.")

            if let error {
                ToolsState(title: "Practice could not continue", bodyText: error, action: choice == nil ? "Try again" : "Retry") {
                    Task {
                        if let choice { await nextQuestion(choice) } else { await loadOptions() }
                    }
                }
            }

            if choice == nil {
                if options == nil && error == nil {
                    ToolsLoading()
                } else if let options {
                    ToolsPanel {
                        Text("Pick a paper. You’ll get one multiple-choice question and an immediate verdict.")
                            .font(BrandFont.body(13)).foregroundStyle(Brand.secondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(options) { option in
                            Button {
                                choice = option
                                Task { await nextQuestion(option) }
                            } label: {
                                HStack {
                                    Text("\(option.label) · \(paperLabel(option.paper)) · \(option.level)")
                                        .font(BrandFont.body(14, weight: .medium)).foregroundStyle(Brand.bright)
                                    Spacer()
                                    Image(systemName: "arrow.right").foregroundStyle(Brand.secondary)
                                }
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Rectangle().fill(Brand.hairline).frame(height: 1)
                        }
                    }
                }
            } else {
                if loading {
                    ToolsLoading()
                } else if let question {
                    ToolsPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(question.topic.uppercased()).font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                                Spacer()
                                Text("\(question.marks) MARK\(question.marks == 1 ? "" : "S")").font(BrandFont.mono(9)).foregroundStyle(Brand.muted)
                            }
                            if let stimulus = question.stimulus, !stimulus.isEmpty {
                                Text(stimulus).font(BrandFont.body(12)).foregroundStyle(Brand.secondary)
                            }
                            Text(question.prompt).font(BrandFont.display(20, weight: .semibold)).foregroundStyle(Brand.bright)
                        }
                    }

                    VStack(spacing: 8) {
                        ForEach(Array((question.options ?? []).enumerated()), id: \.offset) { index, text in
                            Button {
                                Task { await answer(question, index: index) }
                            } label: {
                                HStack(spacing: 12) {
                                    Text(optionLetter(index))
                                        .font(BrandFont.mono(11, weight: .bold)).foregroundStyle(Brand.secondary)
                                        .frame(width: 26)
                                    Text(text).font(BrandFont.body(13)).foregroundStyle(Brand.bright)
                                    Spacer()
                                    if picked == index {
                                        Image(systemName: correct == nil ? "ellipsis" : correct == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(correct == true ? Brand.success : correct == false ? Brand.danger : Brand.secondary)
                                    }
                                }
                                .padding(13)
                                .background(picked == index ? Brand.active : Brand.card)
                                .overlay(RoundedRectangle(cornerRadius: Brand.cornerMd).stroke(
                                    picked == index && correct == true ? Brand.success :
                                    picked == index && correct == false ? Brand.danger : Brand.hairline
                                ))
                                .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                            }
                            .buttonStyle(.plain)
                            .disabled(picked != nil || grading)
                        }
                    }

                    if grading {
                        Text("MARKING…").font(BrandFont.mono(10, weight: .semibold)).foregroundStyle(Brand.secondary)
                    } else if let correct {
                        Text(correct ? "CORRECT" : "NOT THIS ONE")
                            .font(BrandFont.mono(11, weight: .bold))
                            .foregroundStyle(correct ? Brand.success : Brand.danger)
                        Button("Next question") {
                            if let choice { Task { await nextQuestion(choice) } }
                        }
                        .buttonStyle(BrandLargePrimaryButtonStyle())
                    }
                }

                Button("Change paper") {
                    requestID = UUID()
                    choice = nil
                    question = nil
                    picked = nil
                    correct = nil
                    grading = false
                    loading = false
                    error = nil
                }
                .buttonStyle(BrandGhostButtonStyle())
            }
        }
        .task { if options == nil { await loadOptions() } }
    }

    private func loadOptions() async {
        do {
            options = try await PracticeAPI.options()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func nextQuestion(_ option: PracticeOption) async {
        let currentRequest = UUID()
        requestID = currentRequest
        loading = true
        error = nil
        picked = nil
        correct = nil
        do {
            let next = try await PracticeAPI.question(for: option)
            guard requestID == currentRequest else { return }
            question = next
        } catch {
            guard requestID == currentRequest else { return }
            self.error = error.localizedDescription
            question = nil
        }
        if requestID == currentRequest { loading = false }
    }

    private func answer(_ question: ExamQuestion, index: Int) async {
        guard picked == nil, !grading else { return }
        let currentRequest = requestID
        picked = index
        grading = true
        do {
            let result = try await PracticeAPI.grade(question, option: index)
            guard requestID == currentRequest else { return }
            correct = result
            error = nil
        } catch {
            guard requestID == currentRequest else { return }
            self.error = error.localizedDescription
            picked = nil
        }
        if requestID == currentRequest { grading = false }
    }
}

private func paperLabel(_ paper: String) -> String {
    switch paper {
    case "paper1": return "Paper 1"
    case "paper2": return "Paper 2"
    case "paper3": return "Paper 3"
    default: return paper
    }
}

private func optionLetter(_ index: Int) -> String {
    ["A", "B", "C", "D"].indices.contains(index) ? ["A", "B", "C", "D"][index] : "\(index + 1)"
}

// MARK: - Termle

private struct TermleGuess: Decodable, Identifiable {
    var id: String { word }
    let word: String
    let marks: [String]
}

private struct TermleAttempt: Decodable {
    let date: String
    let puzzleNumber: Int
    let length: Int
    let category: String
    let hint: String?
    let guesses: [TermleGuess]
    let status: String
    let usedHint: Bool
    let maxGuesses: Int
    let answer: String?
}

private enum TermleAPI {
    static func fetch() async throws -> TermleAttempt {
        try await decode("/api/native/games/termle")
    }

    static func guess(_ guess: String) async throws -> TermleAttempt {
        try await decode(
            "/api/native/games/termle/guess",
            method: "POST",
            body: ToolsAPI.jsonBody(["guess": guess])
        )
    }

    static func hint() async throws -> TermleAttempt {
        try await decode("/api/native/games/termle/hint", method: "POST")
    }

    private static func decode(_ path: String, method: String = "GET", body: Data? = nil) async throws -> TermleAttempt {
        let data = try await ToolsAPI.request(path, method: method, body: body)
        return try JSONDecoder().decode(TermleAttempt.self, from: data)
    }
}

struct NativeTermlePage: View {
    @State private var attempt: TermleAttempt?
    @State private var input = ""
    @State private var notice: String?
    @State private var loadError: String?
    @State private var submitting = false
    @State private var reported = false

    var body: some View {
        ToolsPage {
            ToolsHeading(title: "Termle", subtitle: attempt.map { "#\($0.puzzleNumber) · \($0.category) · \($0.length) letters" })

            if let loadError, attempt == nil {
                ToolsState(title: "Termle unavailable", bodyText: loadError, action: "Try again") { Task { await load() } }
            } else if attempt == nil {
                ToolsLoading()
            } else if let attempt {
                if attempt.usedHint, let hint = attempt.hint {
                    ToolsPanel {
                        Text("DEFINITION").font(BrandFont.mono(9, weight: .semibold)).foregroundStyle(Brand.muted)
                        Text(hint).font(BrandFont.body(13)).foregroundStyle(Brand.body)
                    }
                }

                termleBoard(attempt)

                if let notice {
                    Text(notice).font(BrandFont.body(12)).foregroundStyle(Brand.danger)
                }

                if attempt.status == "playing" {
                    HStack(spacing: 10) {
                        TextField("\(attempt.length)-letter term", text: $input)
                            .textFieldStyle(BrandOutlinedFieldStyle())
                            .onChange(of: input) { _, value in
                                let upper = value.uppercased().filter { $0.isLetter }
                                if upper != value || upper.count > attempt.length {
                                    input = String(upper.prefix(attempt.length))
                                }
                            }
                            .onSubmit { Task { await submit() } }
                        Button(submitting ? "Checking…" : "Enter") { Task { await submit() } }
                            .buttonStyle(BrandPrimaryButtonStyle())
                            .disabled(submitting || input.count != attempt.length)
                        Button(attempt.usedHint ? "Hint used" : "Hint") { Task { await useHint() } }
                            .buttonStyle(BrandGhostButtonStyle())
                            .disabled(attempt.usedHint)
                    }
                } else {
                    ToolsPanel {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(attempt.status == "won" ? "SOLVED" : "TODAY'S TERM")
                                .font(BrandFont.mono(9, weight: .bold)).tracking(0.6).foregroundStyle(Brand.muted)
                            Text(attempt.answer ?? "—")
                                .font(BrandFont.display(35, weight: .semibold)).tracking(-0.8).foregroundStyle(Brand.bright)
                            if let hint = attempt.hint { Text(hint).font(BrandFont.body(13)).foregroundStyle(Brand.secondary) }
                            HStack {
                                ShareLink(item: termleShare(attempt)) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(BrandPrimaryButtonStyle())
                                Spacer()
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("NEXT TERM").font(BrandFont.mono(8)).foregroundStyle(Brand.muted)
                                        Text(termleRollover()).font(BrandFont.mono(10, weight: .semibold)).foregroundStyle(Brand.body)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: attempt?.status) { _, status in
            if status != nil && status != "playing" { Task { await reportFinish() } }
        }
    }

    private func termleBoard(_ attempt: TermleAttempt) -> some View {
        VStack(spacing: 5) {
            ForEach(0..<attempt.maxGuesses, id: \.self) { row in
                HStack(spacing: 5) {
                    let guess = row < attempt.guesses.count ? attempt.guesses[row] : nil
                    ForEach(0..<attempt.length, id: \.self) { column in
                        let chars = Array(guess?.word ?? "")
                        let letter = column < chars.count ? String(chars[column]) : ""
                        let mark = guess.flatMap { column < $0.marks.count ? $0.marks[column] : nil }
                        Text(letter)
                            .font(BrandFont.display(18, weight: .bold))
                            .foregroundStyle(mark == nil ? Brand.bright : .white)
                            .frame(width: 48, height: 48)
                            .background(termleColor(mark))
                            .overlay(RoundedRectangle(cornerRadius: Brand.cornerSm).stroke(mark == nil ? Brand.edge : Color.clear, lineWidth: 1.5))
                            .clipShape(RoundedRectangle(cornerRadius: Brand.cornerSm))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func termleColor(_ mark: String?) -> Color {
        switch mark {
        case "correct": return Brand.success
        case "present": return Brand.warning
        case "absent": return Brand.raised
        default: return Brand.ground
        }
    }

    private func load() async {
        do {
            attempt = try await TermleAPI.fetch()
            reported = attempt?.status != "playing"
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func submit() async {
        guard let attempt, attempt.status == "playing", input.count == attempt.length, !submitting else {
            notice = "Enter all \(attempt?.length ?? 0) letters."
            return
        }
        submitting = true
        defer { submitting = false }
        let guess = input
        input = ""
        do {
            self.attempt = try await TermleAPI.guess(guess)
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    private func useHint() async {
        guard attempt?.usedHint == false else { return }
        do {
            attempt = try await TermleAPI.hint()
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    private func reportFinish() async {
        guard !reported else { return }
        reported = true
        do {
            try await ToolsAPI.completeDaily("game")
        } catch {
            notice = "Your result is saved, but Today could not sync the completion."
        }
    }

    private func termleShare(_ attempt: TermleAttempt) -> String {
        let rows = attempt.guesses.map { guess in
            guess.marks.map { mark in
                mark == "correct" ? "🟩" : mark == "present" ? "🟨" : "⬛"
            }.joined()
        }.joined(separator: "\n")
        let score = attempt.status == "won" ? "\(attempt.guesses.count)/\(attempt.maxGuesses)" : "X/\(attempt.maxGuesses)"
        return "iBacalao Termle #\(attempt.puzzleNumber) · \(score)\(attempt.usedHint ? " · hint" : "")\n\(rows)"
    }

    private func termleRollover() -> String {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: now)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        let seconds = max(0, Int(next.timeIntervalSince(now)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

// MARK: - Mark the Band

private struct MarkBandChoice: Hashable {
    let label: String
    let range: String
}

private struct MarkBandRound {
    let excerpt: String
    let subject: String
    let criterion: String
    let bands: [MarkBandChoice]
    let correctBand: String
    let rationale: String
}

private struct MarkBandPuzzle {
    let date: String
    let number: Int
    let rounds: [MarkBandRound]
}

private let markBandsEN = [
    MarkBandChoice(label: "1–2", range: "Limited"),
    MarkBandChoice(label: "3–4", range: "Adequate"),
    MarkBandChoice(label: "5–6", range: "Good"),
]
private let markBandsES = [
    MarkBandChoice(label: "1–2", range: "Limitado"),
    MarkBandChoice(label: "3–4", range: "Adecuado"),
    MarkBandChoice(label: "5–6", range: "Bueno"),
]

private let markBandSeedsEN: [[MarkBandRound]] = [
    [
        .init(excerpt: "The student copied raw measurements into a neat table but never calculated uncertainties and processed the data no further than one mean. No graph appears.", subject: "Biology", criterion: "Analysis", bands: markBandsEN, correctBand: "1–2", rationale: "Raw data with no uncertainty and no meaningful processing sits in the lowest band for Analysis."),
        .init(excerpt: "Six sources are used; two are evaluated for origin, purpose, value and limitations, and the investigation is organised tightly around the research question.", subject: "History", criterion: "Criterion B: Investigation", bands: markBandsEN, correctBand: "5–6", rationale: "Critical OPVL evaluation plus a focused, well-organised investigation reaches the top band."),
        .init(excerpt: "The exploration reproduces a textbook example almost verbatim, with no personal context, independent reasoning or evidence of curiosity.", subject: "Mathematics", criterion: "Personal engagement", bands: markBandsEN, correctBand: "1–2", rationale: "Little independent thinking or personal context keeps personal engagement in the lowest band."),
    ],
    [
        .init(excerpt: "The methodology is described step by step so it could be repeated exactly, with controlled variables justified and a clear, relevant research question.", subject: "Chemistry", criterion: "Exploration", bands: markBandsEN, correctBand: "5–6", rationale: "A focused question and a fully reproducible, well-justified method meet the highest Exploration descriptors."),
        .init(excerpt: "The conclusion restates the result but does not compare it to accepted values, discuss limitations, or suggest improvements.", subject: "Physics", criterion: "Evaluation", bands: markBandsEN, correctBand: "1–2", rationale: "No comparison to context and no discussion of limitations leaves Evaluation in the lowest band."),
        .init(excerpt: "The commentary links the text's imagery to its themes with some textual support, though analysis of stylistic effect is uneven across paragraphs.", subject: "Language A", criterion: "Analysis", bands: markBandsEN, correctBand: "3–4", rationale: "Some supported analysis but inconsistent attention to stylistic effect fits the middle band."),
    ],
]

private let markBandSeedsES: [[MarkBandRound]] = [
    [
        .init(excerpt: "El alumno copió las mediciones en una tabla ordenada, pero nunca calculó las incertidumbres y no procesó los datos más allá de una media. No hay gráfico.", subject: "Biología", criterion: "Análisis", bands: markBandsES, correctBand: "1–2", rationale: "Datos brutos sin incertidumbre ni procesamiento significativo corresponden a la banda más baja de Análisis."),
        .init(excerpt: "Se usan seis fuentes; dos se evalúan por origen, propósito, valor y limitaciones, y la investigación se organiza en torno a la pregunta.", subject: "Historia", criterion: "Criterio B: Investigación", bands: markBandsES, correctBand: "5–6", rationale: "La evaluación crítica (OPVL) y una investigación enfocada alcanzan la banda superior."),
        .init(excerpt: "La exploración reproduce un ejemplo del libro de texto casi literalmente, sin contexto personal ni razonamiento propio.", subject: "Matemáticas", criterion: "Compromiso personal", bands: markBandsES, correctBand: "1–2", rationale: "El escaso pensamiento independiente mantiene el compromiso personal en la banda más baja."),
    ],
    [
        .init(excerpt: "La metodología se describe paso a paso de forma reproducible, con variables controladas justificadas y una pregunta de investigación clara y pertinente.", subject: "Química", criterion: "Exploración", bands: markBandsES, correctBand: "5–6", rationale: "Una pregunta enfocada y un método reproducible y justificado cumplen los descriptores más altos de Exploración."),
        .init(excerpt: "La conclusión repite el resultado pero no lo compara con valores aceptados ni analiza limitaciones o mejoras.", subject: "Física", criterion: "Evaluación", bands: markBandsES, correctBand: "1–2", rationale: "Sin comparación con el contexto ni análisis de limitaciones, la Evaluación queda en la banda más baja."),
        .init(excerpt: "El comentario vincula las imágenes del texto con sus temas con cierto apoyo textual, aunque el análisis del efecto estilístico es desigual.", subject: "Lengua A", criterion: "Análisis", bands: markBandsES, correctBand: "3–4", rationale: "Algún análisis con apoyo pero atención desigual al efecto estilístico corresponde a la banda media."),
    ],
]

private func markBandToday() -> MarkBandPuzzle {
    let epoch = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0), year: 2025, month: 1, day: 1).date!
    let utc = Calendar(identifier: .gregorian)
    let now = Date()
    let components = utc.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: now)
    let midnight = DateComponents(calendar: utc, timeZone: TimeZone(secondsFromGMT: 0), year: components.year, month: components.month, day: components.day).date!
    let days = Int(midnight.timeIntervalSince(epoch) / 86_400)
    let spanish = Locale.current.language.languageCode?.identifier == "es"
    let bank = spanish ? markBandSeedsES : markBandSeedsEN
    let rounds = bank[((days % bank.count) + bank.count) % bank.count]
    let date = ISO8601DateFormatter.string(from: midnight, timeZone: TimeZone(secondsFromGMT: 0)!, formatOptions: [.withFullDate])
    return MarkBandPuzzle(date: date, number: days + 1, rounds: rounds)
}

struct NativeMarkbandPage: View {
    private let puzzle = markBandToday()
    @State private var answers: [String?] = []
    @State private var current = 0

    var body: some View {
        ToolsPage {
            ToolsHeading(title: "Mark the Band", subtitle: "#\(puzzle.number) · round \(current + 1) of \(puzzle.rounds.count)")

            let round = puzzle.rounds[current]
            let revealed = answers.indices.contains(current) && answers[current] != nil

            Text("\(round.subject) · \(round.criterion)")
                .font(BrandFont.mono(10, weight: .semibold)).foregroundStyle(Brand.muted)

            ToolsPanel {
                Text(round.excerpt).font(BrandFont.body(16)).foregroundStyle(Brand.bright)
            }

            VStack(spacing: 9) {
                ForEach(round.bands, id: \.label) { band in
                    let chosen = answers.indices.contains(current) && answers[current] == band.label
                    let correct = band.label == round.correctBand
                    Button {
                        answer(band.label)
                    } label: {
                        HStack {
                            Text(band.label).font(BrandFont.mono(12, weight: .bold)).foregroundStyle(Brand.bright).frame(width: 52, alignment: .leading)
                            Text(band.range).font(BrandFont.body(13)).foregroundStyle(Brand.body)
                            Spacer()
                            if revealed && correct { Image(systemName: "checkmark").foregroundStyle(Brand.success) }
                            if revealed && chosen && !correct { Image(systemName: "xmark").foregroundStyle(Brand.danger) }
                        }
                        .padding(13)
                        .background(revealed && correct ? Brand.success.opacity(0.12) : Brand.card)
                        .overlay(RoundedRectangle(cornerRadius: Brand.cornerMd).stroke(
                            revealed && correct ? Brand.success : revealed && chosen && !correct ? Brand.danger : Brand.hairline
                        ))
                        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                    }
                    .buttonStyle(.plain)
                    .disabled(revealed)
                }
            }

            if revealed {
                ToolsPanel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WHY").font(BrandFont.mono(9, weight: .bold)).foregroundStyle(Brand.muted)
                        Text(round.rationale).font(BrandFont.body(13)).foregroundStyle(Brand.body)
                    }
                }

                if current < puzzle.rounds.count - 1 {
                    Button("Next round") { current += 1 }.buttonStyle(BrandLargePrimaryButtonStyle())
                } else {
                    ToolsPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("DONE").font(BrandFont.display(25, weight: .semibold)).foregroundStyle(Brand.bright)
                            Text("\(score) / \(puzzle.rounds.count * 2)")
                                .font(BrandFont.mono(20, weight: .bold)).foregroundStyle(Brand.body)
                            ShareLink(item: shareText) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(BrandPrimaryButtonStyle())
                        }
                    }
                }
            }
        }
        .onAppear { restore() }
    }

    private var score: Int {
        puzzle.rounds.enumerated().reduce(0) { total, pair in
            let index = pair.offset
            let round = pair.element
            guard answers.indices.contains(index), let answer = answers[index] else { return total }
            let correct = round.bands.firstIndex(where: { $0.label == round.correctBand }) ?? 0
            let guess = round.bands.firstIndex(where: { $0.label == answer }) ?? -99
            return total + (guess == correct ? 2 : abs(guess - correct) == 1 ? 1 : 0)
        }
    }

    private var shareText: String {
        let squares = puzzle.rounds.enumerated().map { index, round in
            guard answers.indices.contains(index), let answer = answers[index] else { return "⬛" }
            let correct = round.bands.firstIndex(where: { $0.label == round.correctBand }) ?? 0
            let guess = round.bands.firstIndex(where: { $0.label == answer }) ?? -99
            return guess == correct ? "🟩" : abs(guess - correct) == 1 ? "🟨" : "⬛"
        }.joined()
        return "\(squares) · iBacalao Mark the Band #\(puzzle.number) · \(score)/\(puzzle.rounds.count * 2) · 🐟"
    }

    private func answer(_ label: String) {
        guard answers.indices.contains(current), answers[current] == nil else { return }
        answers[current] = label
        UserDefaults.standard.set(answers.map { $0 ?? "" }, forKey: "ibacalao:markband:\(puzzle.date)")
    }

    private func restore() {
        let saved = UserDefaults.standard.stringArray(forKey: "ibacalao:markband:\(puzzle.date)")
        if let saved, saved.count == puzzle.rounds.count {
            answers = saved.map { $0.isEmpty ? nil : $0 }
            current = answers.firstIndex(where: { $0 == nil }) ?? (puzzle.rounds.count - 1)
        } else {
            answers = Array(repeating: nil, count: puzzle.rounds.count)
        }
    }
}
