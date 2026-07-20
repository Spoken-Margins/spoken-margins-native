import XCTest
import Security
@testable import SpokenMarginsApp

final class Gate1ProviderRequestFactoryTests: XCTestCase {
    func testKeychainStoreAddsUpdatesAndDeletesProtectedSecret() {
        let service = "SpokenMarginsTests.\(UUID().uuidString)"
        let account = "api-key"
        defer { KeychainStore.save("", service: service, account: account) }

        XCTAssertEqual(KeychainStore.save("first", service: service, account: account), errSecSuccess)
        XCTAssertEqual(KeychainStore.load(service: service, account: account), "first")
        XCTAssertEqual(KeychainStore.save("second", service: service, account: account), errSecSuccess)
        XCTAssertEqual(KeychainStore.load(service: service, account: account), "second")
        XCTAssertEqual(KeychainStore.save("", service: service, account: account), errSecSuccess)
        XCTAssertNil(KeychainStore.load(service: service, account: account))
    }

    func testModelRoutingUsesThreeGate1ActivitiesAndListeningMapFallback() {
        XCTAssertEqual(model(kind: "listening_map"), "map-model")
        XCTAssertEqual(model(kind: "interjection_summary"), "summary-model")
        XCTAssertEqual(model(kind: "assistant_response"), "conversation-model")
        XCTAssertEqual(Gate1ProviderRequestFactory.modelForAIJob(
            kind: "unknown",
            listeningMapModel: " map-model ",
            summaryModel: "",
            conversationModel: "",
            fallbackProviderModel: "legacy-model"
        ), "map-model")
    }

    func testConversationPromptMakesCurrentFollowupPrimary() {
        let followUp = "Please consolidate my point in two sentences."
        let prompt = Gate1ProviderRequestFactory.conversationPrompt(
            followUp: followUp,
            contextJSON: #"{"primaryUserIntent":{"request":"\#(followUp)"},"recentTurns":[]}"#
        )

        XCTAssertTrue(prompt.contains("Respond to the primaryUserIntent first"))
        XCTAssertTrue(prompt.contains("Do not re-review the article or conversation unless the primaryUserIntent asks for that"))
        XCTAssertTrue(prompt.contains(followUp))
    }

    func testResponsesRequestUsesFixedOpenAIEndpointAndStreamingPayload() throws {
        let request = try XCTUnwrap(OpenAIResponsesClient.makeRequest(
            apiKey: "secret",
            model: "conversation-model",
            instructions: "System prompt",
            messages: ["User request"],
            stream: true
        ))
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.timeoutInterval, 90)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "conversation-model")
        XCTAssertEqual(json["instructions"] as? String, "System prompt")
        XCTAssertEqual(json["input"] as? String, "User request")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["store"] as? Bool, false)
    }

    func testReviewDemoProducesValidMapWithoutNetwork() async throws {
        let response = await ReviewDemoAIClient().complete(
            kind: "listening_map",
            messages: ["""
            ITEM CONTENT:
            <<<
            First paragraph contains enough ordinary words for a stable navigation anchor.

            Second paragraph supplies another deterministic section for the review map.
            >>>
            """]
        )
        let data = try XCTUnwrap(response.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? String, "listening-map.v1")
        XCTAssertEqual((json["chapters"] as? [[String: Any]])?.count, 2)
    }

    func testResponsesSSEParserEmitsTextAndSurfacesErrors() throws {
        XCTAssertEqual(
            try OpenAIResponsesClient.event(fromSSELine: #"data: {"type":"response.output_text.delta","delta":"Hello."}"#),
            .textDelta("Hello.")
        )
        XCTAssertEqual(
            try OpenAIResponsesClient.event(fromSSELine: #"data: {"type":"response.completed","response":{"id":"resp-1"}}"#),
            .completed(responseId: "resp-1")
        )
        XCTAssertThrowsError(try OpenAIResponsesClient.event(
            fromSSELine: #"data: {"type":"error","error":{"message":"rate limited"}}"#
        ))
    }

    func testSpokenPromptsContainNoStructuredTags() {
        for kind in ["interjection_summary", "assistant_response"] {
            let prompt = Gate1ProviderRequestFactory.systemPromptForAIJob(kind: kind)
            XCTAssertFalse(prompt.contains("<sm_"))
            XCTAssertTrue(prompt.contains("text-to-speech") || prompt.contains("spoken answer"))
        }
    }

    private func model(kind: String) -> String {
        Gate1ProviderRequestFactory.modelForAIJob(
            kind: kind,
            listeningMapModel: "map-model",
            summaryModel: "summary-model",
            conversationModel: "conversation-model",
            fallbackProviderModel: "map-model"
        )
    }
}
