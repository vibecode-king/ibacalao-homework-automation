import XCTest
@testable import LiveExaminerOverlayCore

final class LLMClientTests: XCTestCase {
    func testReleaseBaseURLIgnoresPersistedLocalhostOverride() {
        XCTAssertEqual(
            LLMClient.resolveNativeAPIBaseURL(
                rawValue: "http://127.0.0.1:3000",
                allowInsecureDevelopmentOverride: false
            ),
            LLMClient.defaultNativeAPIBaseURL
        )
        XCTAssertEqual(
            LLMClient.resolveNativeAPIBaseURL(
                rawValue: "http://localhost:3000/chat",
                allowInsecureDevelopmentOverride: false
            ),
            LLMClient.defaultNativeAPIBaseURL
        )
    }

    func testDebugBaseURLCanUseLocalhostOverride() {
        XCTAssertEqual(
            LLMClient.resolveNativeAPIBaseURL(
                rawValue: "http://127.0.0.1:3000/",
                allowInsecureDevelopmentOverride: true
            ),
            "http://127.0.0.1:3000"
        )
    }

    func testReleaseBaseURLStillAcceptsHTTPSPreviewOverride() {
        XCTAssertEqual(
            LLMClient.resolveNativeAPIBaseURL(
                rawValue: " https://ibacalao-preview.vercel.app/ ",
                allowInsecureDevelopmentOverride: false
            ),
            "https://ibacalao-preview.vercel.app"
        )
    }

    func testOnlyTheIbacalaoProjectPreviewHostIsTrusted() {
        XCTAssertTrue(NativeHostPolicy.isTrustedPreviewHost(
            "ibacalao-git-dev-vanos-projects-91d1222a.vercel.app"
        ))
        XCTAssertTrue(NativeHostPolicy.isTrustedPreviewHost(
            "ibacalao-git-fix-homework-worker-vanos-projects-91d1222a.vercel.app"
        ))
        XCTAssertFalse(NativeHostPolicy.isTrustedPreviewHost("anything.vercel.app"))
        XCTAssertFalse(NativeHostPolicy.isTrustedPreviewHost(
            "ibacalao-git-dev-other-team-91d1222a.vercel.app"
        ))
    }

    func testTipDisplayIsPlainAndActionFirst() throws {
        let raw = """
        {"subject":"Biology","confidence":"high","problem":"The conclusion is too broad — it ignores uncertainty","section":"Conclusion","whyItMatters":"The result may not support the claim","fix":"Rewrite the final sentence using the uncertainty range","doneWhen":"The final sentence names the range and answers the question"}
        """

        let tip = try XCTUnwrap(TipResult.parse(from: raw))
        XCTAssertFalse(tip.displayText.contains("*"))
        XCTAssertFalse(tip.displayText.contains("—"))
        XCTAssertFalse(tip.displayText.contains("–"))
        XCTAssertTrue(tip.displayText.contains("Do this:"))
        XCTAssertTrue(tip.displayText.contains("Done when:"))
    }

    func testChatFeedbackRemovesFormattingMarks() {
        let cleaned = PlainFeedback.clean("Fix this — now *with evidence*.")
        XCTAssertEqual(cleaned, "Fix this. now with evidence.")
    }

    func testHostedAIConsentErrorIsNotMisreportedAsPlanRequired() {
        let consent = LLMClientError.httpError(403, #"{"reason":"ai_consent_required"}"#).errorDescription
        XCTAssertEqual(consent, "AI processing permission is required. Open iBacalao, review the AI processing notice, then try again.")

        let plan = LLMClientError.httpError(403, #"{"reason":"plan_required"}"#).errorDescription
        XCTAssertEqual(plan, "Marginalia is available on Pro and Ultra plans.")
    }

    func testSentenceFixRequiresGroundedChangedRevision() throws {
        let raw = """
        {"subject":"Biology","confidence":"high","problem":"The conclusion overclaims certainty","section":"Criterion C · Conclusion","whyItMatters":"The evidence does not prove certainty","fix":"Qualify the claim","doneWhen":"The conclusion states a limitation","quote":"This proves the hypothesis was fully correct.","revision":"The results support the hypothesis, although the small sample limits certainty."}
        """
        let tip = try XCTUnwrap(TipResult.parse(from: raw))
        let fix = try XCTUnwrap(tip.sentenceFix(in: "Earlier text. This proves the hypothesis was fully correct. Later text."))
        XCTAssertEqual(fix.quote, "This proves the hypothesis was fully correct.")
        XCTAssertEqual(fix.revision, "The results support the hypothesis, although the small sample limits certainty.")
    }

    func testSentenceFixMatchesAcrossOCRWhitespaceDifferences() throws {
        let raw = """
        {"subject":"Biology","confidence":"high","problem":"Overclaim","section":"Conclusion","whyItMatters":null,"fix":"Qualify it","doneWhen":null,"quote":"This proves the hypothesis was fully correct.","revision":"The results support the hypothesis with some uncertainty."}
        """
        let tip = try XCTUnwrap(TipResult.parse(from: raw))
        XCTAssertNotNil(tip.sentenceFix(in: "This proves the hypothesis\nwas fully correct."))
    }

    func testSentenceFixRejectsQuoteNotFound() throws {
        let raw = """
        {"subject":null,"confidence":null,"problem":"Overclaim","section":"Conclusion","whyItMatters":null,"fix":"Qualify it","doneWhen":null,"quote":"This proves the hypothesis was fully correct.","revision":"The results support the hypothesis with some uncertainty."}
        """
        let tip = try XCTUnwrap(TipResult.parse(from: raw))
        XCTAssertNil(tip.sentenceFix(in: "The visible document contains a different sentence."))
    }

    func testSentenceFixRejectsMissingEmptyOrIdenticalRevision() throws {
        let missing = try XCTUnwrap(TipResult.parse(from: """
        {"subject":null,"confidence":null,"problem":"Overclaim","section":"Conclusion","whyItMatters":null,"fix":"Qualify it","doneWhen":null}
        """))
        XCTAssertNil(missing.sentenceFix(in: "This proves the hypothesis was fully correct."))

        let empty = try XCTUnwrap(TipResult.parse(from: """
        {"subject":null,"confidence":null,"problem":"Overclaim","section":"Conclusion","whyItMatters":null,"fix":"Qualify it","doneWhen":null,"quote":"This proves the hypothesis was fully correct.","revision":"   "}
        """))
        XCTAssertNil(empty.sentenceFix(in: "This proves the hypothesis was fully correct."))

        let identical = try XCTUnwrap(TipResult.parse(from: """
        {"subject":null,"confidence":null,"problem":"Overclaim","section":"Conclusion","whyItMatters":null,"fix":"Qualify it","doneWhen":null,"quote":"This proves the hypothesis was fully correct.","revision":"This   proves the hypothesis was fully correct."}
        """))
        XCTAssertNil(identical.sentenceFix(in: "This proves the hypothesis was fully correct."))
    }

    func testSentenceFixAllowsLongAndMultilineGroundedSentence() throws {
        let sentence = String(repeating: "Evidence ", count: 40) + "supports the claim."
        let raw = """
        {"subject":null,"confidence":null,"problem":"Too broad","section":"Conclusion","whyItMatters":null,"fix":"Qualify it","doneWhen":null,"quote":"\(sentence)","revision":"The evidence supports the claim, but the conclusion remains limited by the sample."}
        """
        let tip = try XCTUnwrap(TipResult.parse(from: raw))
        let multilineDocument = sentence.replacingOccurrences(of: "Evidence Evidence", with: "Evidence\nEvidence")
        XCTAssertNotNil(tip.sentenceFix(in: multilineDocument))
    }


    func testHostedSentenceFixCanaryWhenEnabled() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["IBACALAO_HOSTED_SENTENCE_FIX_CANARY"] == "1" else {
            throw XCTSkip("set IBACALAO_HOSTED_SENTENCE_FIX_CANARY=1 to run the real hosted-model canary")
        }
        guard let token = KeyStore.loadSessionToken(), !token.isEmpty else {
            throw XCTSkip("a signed-in native iBacalao session is required for the live canary")
        }

        let defaults = UserDefaults.standard
        let previousBase = defaults.string(forKey: "ShellBaseURLOverride")
        let base = env["IBACALAO_HOSTED_SENTENCE_FIX_BASE_URL"] ?? LLMClient.defaultNativeAPIBaseURL
        defaults.set(base, forKey: "ShellBaseURLOverride")
        defer {
            if let previousBase {
                defaults.set(previousBase, forKey: "ShellBaseURLOverride")
            } else {
                defaults.removeObject(forKey: "ShellBaseURLOverride")
            }
        }

        let document = """
        In this Biology investigation, catalase activity increased as hydrogen peroxide concentration increased. \
        The final trial was faster than the control, but only three repeats were collected. \
        This proves the hypothesis was fully correct.
        """
        let client = LLMClient(provider: .hosted, customInstructions: "", subject: .biology)
        let result = try await client.streamTip(documentText: document, sessionToken: token, onDelta: { _ in })
        let tip = try XCTUnwrap(TipResult.parse(from: result.text), "hosted model must return the structured tip schema")
        let fix = try XCTUnwrap(tip.sentenceFix(in: document), "hosted model must return a grounded quote/revision pair")
        XCTAssertNotEqual(fix.quote, fix.revision)
        XCTAssertTrue(document.contains(fix.quote))
    }

}
