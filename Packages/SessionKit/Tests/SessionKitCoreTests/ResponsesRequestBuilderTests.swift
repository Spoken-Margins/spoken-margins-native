import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit

/// #548: the OpenAI Responses request always uses the shape Sign in with ChatGPT accepts (#269),
/// and its Authorization header comes from a credential provider.
final class ResponsesRequestBuilderTests: XCTestCase {
    private struct FailingProvider: ResponsesCredentialProvider {
        struct SignInExpired: LocalizedError {
            var errorDescription: String? { "Your ChatGPT sign-in expired." }
        }

        func authorizationHeaderValue() async throws -> String { throw SignInExpired() }
    }

    private struct TokenProvider: ResponsesCredentialProvider {
        func authorizationHeaderValue() async throws -> String { "Bearer chatgpt-token" }
    }

    private func payload(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func request(
        credentials: some ResponsesCredentialProvider = .apiKey(" secret \n"),
        messages: [String] = ["First message", "Second message"]
    ) async throws -> URLRequest {
        try await ResponsesRequestBuilder.makeRequest(
            credentials: credentials,
            model: " conversation-model ",
            instructions: "System prompt",
            messages: messages
        )
    }

    func testRequestIsAlwaysStreamedAndNeverStored() async throws {
        let request = try await request()
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 90)
        let json = try payload(request)
        XCTAssertEqual(json["model"] as? String, "conversation-model")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["store"] as? Bool, false)
    }

    func testInputIsAnArrayOfUserMessageItems() async throws {
        let json = try payload(try await request())
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        for (item, text) in zip(input, ["First message", "Second message"]) {
            XCTAssertEqual(item["type"] as? String, "message")
            XCTAssertEqual(item["role"] as? String, "user")
            let content = try XCTUnwrap(item["content"] as? [[String: Any]])
            XCTAssertEqual(content.count, 1)
            XCTAssertEqual(content.first?["type"] as? String, "input_text")
            XCTAssertEqual(content.first?["text"] as? String, text)
        }
    }

    func testSystemPromptGoesOnlyInInstructions() async throws {
        let built = try await request()
        let json = try payload(built)
        XCTAssertEqual(json["instructions"] as? String, "System prompt")
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertFalse(input.contains { ($0["role"] as? String) == "system" || ($0["role"] as? String) == "developer" })
        let body = String(decoding: try XCTUnwrap(built.httpBody), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: "System prompt").count - 1, 1)
    }

    func testRejectedFieldsNeverAppear() async throws {
        let json = try payload(try await request())
        XCTAssertEqual(Set(json.keys), ["model", "instructions", "input", "stream", "store"])
        for rejected in ["temperature", "max_output_tokens", "previous_response_id", "metadata"] {
            XCTAssertNil(json[rejected], rejected)
        }
    }

    func testAuthorizationHeaderComesFromTheCredentialProvider() async throws {
        let withKey = try await request()
        XCTAssertEqual(withKey.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let withToken = try await request(credentials: TokenProvider())
        XCTAssertEqual(withToken.value(forHTTPHeaderField: "Authorization"), "Bearer chatgpt-token")
    }

    func testProviderErrorBecomesAReadableError() async {
        do {
            _ = try await request(credentials: FailingProvider())
            XCTFail("Expected the provider's failure")
        } catch {
            XCTAssertEqual(error as? OpenAIResponsesError, .credentialUnavailable("Your ChatGPT sign-in expired."))
            XCTAssertEqual(
                error.localizedDescription,
                "Spoken Margins couldn't get your OpenAI credential: Your ChatGPT sign-in expired."
            )
        }
    }

    func testMissingAPIKeyIsAReadableErrorNotAnEmptyHeader() async {
        do {
            _ = try await request(credentials: .apiKey("  "))
            XCTFail("Expected a missing-key error")
        } catch {
            XCTAssertEqual(
                error as? OpenAIResponsesError,
                .credentialUnavailable("No OpenAI API key is saved. Add one in Settings.")
            )
        }
    }

    func testSSEParserEmitsTextAndSurfacesErrors() throws {
        XCTAssertEqual(
            try ResponsesRequestBuilder.event(fromSSELine: #"data: {"type":"response.created","response":{"id":"resp-1"}}"#),
            .started(responseId: "resp-1")
        )
        XCTAssertEqual(
            try ResponsesRequestBuilder.event(fromSSELine: #"data: {"type":"response.output_text.delta","delta":"Hello."}"#),
            .textDelta("Hello.")
        )
        XCTAssertEqual(
            try ResponsesRequestBuilder.event(fromSSELine: #"data: {"type":"response.completed","response":{"id":"resp-1"}}"#),
            .completed(responseId: "resp-1")
        )
        XCTAssertNil(try ResponsesRequestBuilder.event(fromSSELine: "event: response.output_text.delta"))
        XCTAssertNil(try ResponsesRequestBuilder.event(fromSSELine: "data: [DONE]"))
        XCTAssertThrowsError(try ResponsesRequestBuilder.event(
            fromSSELine: #"data: {"type":"error","error":{"message":"rate limited"}}"#
        )) { error in
            XCTAssertEqual(error as? OpenAIResponsesError, .api("rate limited"))
        }
    }

    private func events(_ events: [OpenAIStreamEvent]) -> AsyncThrowingStream<OpenAIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func testCompleteCollectsTheStreamedText() async throws {
        let text = try await ResponsesRequestBuilder.collectText(from: events([
            .started(responseId: "resp-1"),
            .textDelta(" Hello"),
            .textDelta(", world. "),
            .completed(responseId: "resp-1"),
        ]))
        XCTAssertEqual(text, "Hello, world.")
    }

    func testCompleteRejectsAStreamThatStopsEarlyOrHasNoText() async {
        do {
            _ = try await ResponsesRequestBuilder.collectText(from: events([.textDelta("Half")]))
            XCTFail("Expected an incomplete-stream error")
        } catch {
            XCTAssertEqual(error as? OpenAIResponsesError, .incompleteStream)
        }
        do {
            _ = try await ResponsesRequestBuilder.collectText(from: events([.completed(responseId: nil)]))
            XCTFail("Expected an empty-response error")
        } catch {
            XCTAssertEqual(error as? OpenAIResponsesError, .emptyResponse)
        }
    }
}
