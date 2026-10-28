import Foundation

struct ChatTurn: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    let content: String

    enum Role: String {
        case user
        case assistant
    }
}

enum PlainFeedback {
    static func clean(_ value: String, max: Int = 2400) -> String {
        value
            .replacingOccurrences(of: " — ", with: ". ")
            .replacingOccurrences(of: " – ", with: ". ")
            .replacingOccurrences(of: "—", with: ". ")
            .replacingOccurrences(of: "–", with: ". ")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: " .", with: ".")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(max)
            .description
    }
}

/// Structured repair contract: names the problem, where it appears, why it
/// matters, and the smallest fix the student can complete now.
struct TipResult: Decodable {
    let subject: String?
    let confidence: String?
    let problem: String
    let section: String
    let fix: String
    let whyItMatters: String?
    let doneWhen: String?
    let quote: String?
    let revision: String?

    /// Returns a safe sentence-fix pair only when both fields are meaningful, the revision
    /// actually changes the sentence, and the quote is grounded in the text sent to the model.
    /// Whitespace is normalized because OCR can split one visible sentence across lines.
    func sentenceFix(in documentText: String) -> (quote: String, revision: String)? {
        guard let quote, let revision else { return nil }

        let trimmedQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRevision = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuote.isEmpty, !trimmedRevision.isEmpty else { return nil }

        let normalizedQuote = Self.normalizedWhitespace(trimmedQuote)
        let normalizedRevision = Self.normalizedWhitespace(trimmedRevision)
        let normalizedDocument = Self.normalizedWhitespace(documentText)

        guard !normalizedQuote.isEmpty,
              normalizedQuote != normalizedRevision,
              normalizedDocument.range(
                of: normalizedQuote,
                options: [.caseInsensitive, .diacriticInsensitive]
              ) != nil else {
            return nil
        }

        return (trimmedQuote, trimmedRevision)
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(from raw: String) -> TipResult? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            return nil
        }
        let jsonSlice = raw[start...end]
        guard let data = jsonSlice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TipResult.self, from: data)
    }

    var displayText: String {
        func cap(_ s: String, _ n: Int) -> String {
            s.count > n ? String(s.prefix(n)).trimmingCharacters(in: .whitespacesAndNewlines) + "..." : s
        }
        var output = "Section: \(PlainFeedback.clean(cap(section, 60), max: 120))\n\nProblem: \(PlainFeedback.clean(cap(problem, 240)))"
        if let whyItMatters, !whyItMatters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output += "\n\nWhy it matters: \(PlainFeedback.clean(cap(whyItMatters, 180)))"
        }
        output += "\n\nDo this: \(PlainFeedback.clean(cap(fix, 240)))"
        if let doneWhen, !doneWhen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output += "\n\nDone when: \(PlainFeedback.clean(cap(doneWhen, 180)))"
        }
        return output
    }
}

enum LLMClientError: LocalizedError {
    case missingSession
    case invalidURL
    case httpError(Int, String)
    case emptyResponse
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Couldn't reach iBacalao. Try Check again in a moment."
        case .invalidURL:
            return "Invalid API URL."
        case .httpError(let code, let body):
            return Self.friendlyHTTPMessage(code: code, body: body)
        case .emptyResponse:
            return "The model returned an empty response."
        case .parseError(let detail):
            return "Couldn't parse API response: \(detail)"
        }
    }

    private static func friendlyHTTPMessage(code: Int, body: String) -> String {
        let snippet = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        if code == 401 {
            if snippet.localizedCaseInsensitiveContains("Hosted AI") || snippet.localizedCaseInsensitiveContains("provider_error") {
                return "Hosted AI is unavailable. Check the server AI configuration."
            }
            return "Couldn't reach iBacalao. Try Check again in a moment."
        }
        if code == 403 {
            if snippet.localizedCaseInsensitiveContains("ai_consent_required") {
                return "AI processing permission is required. Open iBacalao, review the AI processing notice, then try again."
            }
            return "Marginalia is available on Pro and Ultra plans."
        }
        if code == 429 {
            return "Too many requests. Wait a moment and try again."
        }
        if code == 500 || code == 502 || code == 503 || code == 504 {
            return "Hosted AI is temporarily unavailable. Try again in a moment."
        }
        return snippet.isEmpty ? "API error \(code)." : "API error \(code): \(snippet)"
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let llm = error as? LLMClientError {
            if case .httpError(let code, _) = llm {
                return code == 429 || code == 500 || code == 502 || code == 503 || code == 504
            }
            return false
        }
        let url = error as NSError
        if url.domain == NSURLErrorDomain {
            switch url.code {
            case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}

struct LLMClient {
    static let defaultNativeAPIBaseURL = "https://app.ibacalao.com"

    /// Same override the WKWebView shell uses so local testing hits next dev, not production.
    static var resolvedNativeAPIBaseURL: String {
        let rawValue = UserDefaults.standard.string(forKey: "ShellBaseURLOverride")
        #if DEBUG
        dlog("[Override] bundleId=\(Bundle.main.bundleIdentifier ?? "nil") rawValue=\(rawValue ?? "NIL") prefsPath=\(UserDefaults.standard.dictionaryRepresentation()["ShellBaseURLOverride"] ?? "MISSING")")
        #endif
        #if DEBUG
        return resolveNativeAPIBaseURL(rawValue: rawValue, allowInsecureDevelopmentOverride: true)
        #else
        // Debug and release intentionally share the same bundle/preferences so
        // sign-in and native state survive local QA. A persisted localhost
        // ShellBaseURLOverride must never make a shipped build load a dead dev
        // server, though. Release accepts HTTPS overrides only.
        return resolveNativeAPIBaseURL(rawValue: rawValue, allowInsecureDevelopmentOverride: false)
        #endif
    }

    static func resolveNativeAPIBaseURL(
        rawValue: String?,
        allowInsecureDevelopmentOverride: Bool
    ) -> String {
        let raw = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            return defaultNativeAPIBaseURL
        }
        let validScheme = scheme == "https" || (allowInsecureDevelopmentOverride && scheme == "http")
        guard validScheme, url.host?.isEmpty == false else {
            return defaultNativeAPIBaseURL
        }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    let provider: LLMProvider
    let customInstructions: String
    let subject: CoachingSubject

    private static let subjectList = CoachingSubject.allCases.map(\.rawValue).joined(separator: ", ")

    private static let systemPrompt = """
    You are a concise writing coach helping an IB student improve their draft. \
    The text is OCR of their document body. Ignore leftover UI chrome (tab titles, menus, \
    Google Docs labels like Share or document outline). Coach only the student's writing. \
    Detect the language of the student's document from the text and reply in that same language. \
    Do not ask which language to use.

    Reply with ONLY a single JSON object, no prose before or after it, no markdown fences, \
    no reasoning shown, in exactly this shape:
    {"subject": "<your best guess of the IB subject from this list: \(subjectList)>", \
    "confidence": "<low, medium, or high - how sure you are about that subject guess>", \
    "problem": "<one specific weakness in what they just wrote, under 240 characters>", \
    "section": "<short name/quote identifying where in the text this problem is, under 60 characters>", \
    "whyItMatters": "<why this weakens the relevant IB criterion, under 180 characters>", \
    "fix": "<one concrete, actionable instruction to fix it, under 240 characters>", \
    "doneWhen": "<an observable check that shows the fix is complete, under 180 characters>", \
    "quote": "<the exact weak sentence copied verbatim from their text, under 200 characters, or empty string if no single sentence shows the problem>", \
    "revision": "<a rewritten version of that same sentence that fixes the problem, under 200 characters, or empty string if quote is empty>"}

    Ground the problem and fix in the assessment conventions of the subject you detected (or the \
    subject given below, if provided). Use simple words and short sentences. Give one clear action. \
    Do not use em dashes, en dashes, asterisks, markdown, or vague advice such as "add more detail". \
    Do not include any text outside the JSON object.
    """

    private static let chatSystemPrompt = """
    You are a concise writing coach. \
    Detect the language of the student's document from the OCR context and reply in that same language. \
    Answer follow-up questions briefly and helpfully, staying focused on their writing. Use simple words. \
    Do not use em dashes, en dashes, asterisks, or markdown.
    """

    private func withPromptContext(_ base: String) -> String {
        var parts = [base]
        if let subjectLine = subject.promptContext {
            parts.append(subjectLine)
        }
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append("Additional instructions from the user:\n\(trimmed)")
        }
        return parts.joined(separator: "\n\n")
    }

    var activeModelID: String {
        ModelPricing.defaultModel(for: provider)
    }

    func streamTip(
        documentText: String,
        sessionToken: String,
        onDelta: @escaping (String) -> Void
    ) async throws -> (text: String, usage: LLMTokenUsage?) {
        let subjectHint = subject == .general
            ? "The student has not selected a subject - infer it from the text."
            : "The student selected \(subject.label) (\(subject.rawValue)) - infer the subject yourself from the text anyway so a mismatch can be caught."
        let userPrompt = """
        Here is the student's newly written text (read from their screen):

        \(documentText)

        \(subjectHint)

        Reply with only the JSON object described in your instructions.
        """
        return try await streamHosted(
            system: withPromptContext(Self.systemPrompt),
            messages: [("user", userPrompt)],
            sessionToken: sessionToken,
            maxTokens: 500,
            onDelta: onDelta
        )
    }

    func streamChat(
        messages: [ChatTurn],
        contextOCR: String,
        contextTip: String,
        sessionToken: String,
        onDelta: @escaping (String) -> Void
    ) async throws -> (text: String, usage: LLMTokenUsage?) {
        let systemWithContext = """
        \(withPromptContext(Self.chatSystemPrompt))

        Current document OCR:
        \(contextOCR)

        Latest coaching tip:
        \(contextTip)
        """
        let chatMessages = messages.map { (role: $0.role.rawValue, content: $0.content) }
        return try await streamHosted(
            system: systemWithContext,
            messages: chatMessages,
            sessionToken: sessionToken,
            maxTokens: 512,
            onDelta: onDelta
        )
    }

    func testConnection(sessionToken: String) async throws {
        _ = try await streamHosted(
            system: "Reply with exactly: OK",
            messages: [("user", "ping")],
            sessionToken: sessionToken,
            maxTokens: 8,
            onDelta: { _ in }
        )
    }

    private func streamHosted(
        system: String,
        messages: [(role: String, content: String)],
        sessionToken: String,
        maxTokens: Int,
        onDelta: @escaping (String) -> Void
    ) async throws -> (text: String, usage: LLMTokenUsage?) {
        guard !sessionToken.isEmpty else { throw LLMClientError.missingSession }

        let body: [String: Any] = [
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "maxTokens": maxTokens,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var bases: [(base: String, token: String)] = []
        #if DEBUG
        bases.append((base: "http://127.0.0.1:3000", token: "dev-local"))
        #endif
        bases.append((base: Self.resolvedNativeAPIBaseURL, token: sessionToken))

        var lastError: Error = LLMClientError.emptyResponse
        for candidate in bases {
            guard let url = URL(string: "\(candidate.base)/api/native/complete") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(candidate.token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 60
            request.httpBody = bodyData

            for attempt in 1...3 {
                do {
                    return try await consumeSSE(
                        request: request,
                        extractText: { json in
                            guard let type = json["type"] as? String else { return nil }
                            if type == "content_block_delta",
                               let delta = json["delta"] as? [String: Any],
                               let text = delta["text"] as? String {
                                return text
                            }
                            return nil
                        },
                        extractUsage: Self.extractAnthropicUsage,
                        onDelta: onDelta
                    )
                } catch {
                    lastError = error
                    if let llm = error as? LLMClientError, case .httpError(let code, _) = llm, code == 401 {
                        break
                    }
                    let ns = error as NSError
                    if ns.domain == NSURLErrorDomain,
                       ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorNetworkConnectionLost {
                        break
                    }
                    guard LLMClientError.isRetryable(error), attempt < 3 else { throw error }
                    try await Task.sleep(nanoseconds: UInt64(400_000_000 * attempt))
                }
            }
        }
        throw lastError
    }

    private static func extractAnthropicUsage(_ json: [String: Any]) -> LLMTokenUsage? {
        let type = json["type"] as? String
        if type == "message_start",
           let message = json["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            if input > 0 || output > 0 {
                return LLMTokenUsage(promptTokens: input, completionTokens: output)
            }
        }
        if type == "message_delta",
           let usage = json["usage"] as? [String: Any] {
            let output = usage["output_tokens"] as? Int ?? 0
            if output > 0 {
                return LLMTokenUsage(promptTokens: 0, completionTokens: output)
            }
        }
        return nil
    }

    private func consumeSSE(
        request: URLRequest,
        extractText: ([String: Any]) -> String?,
        extractUsage: ([String: Any]) -> LLMTokenUsage?,
        onDelta: @escaping (String) -> Void
    ) async throws -> (text: String, usage: LLMTokenUsage?) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.parseError("no HTTP response")
        }

        if http.statusCode >= 400 {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break }
            }
            throw LLMClientError.httpError(http.statusCode, errorBody)
        }

        var accumulated = ""
        var promptTokens = 0
        var completionTokens = 0
        var sawUsage = false

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let text = extractText(json) {
                accumulated += text
                onDelta(accumulated)
            }
            if let usage = extractUsage(json) {
                sawUsage = true
                if usage.promptTokens > 0 { promptTokens = usage.promptTokens }
                if usage.completionTokens > 0 { completionTokens = usage.completionTokens }
            }
        }

        guard !accumulated.isEmpty else { throw LLMClientError.emptyResponse }
        let usage: LLMTokenUsage? = sawUsage
            ? LLMTokenUsage(promptTokens: promptTokens, completionTokens: completionTokens)
            : nil
        return (accumulated, usage)
    }
}
