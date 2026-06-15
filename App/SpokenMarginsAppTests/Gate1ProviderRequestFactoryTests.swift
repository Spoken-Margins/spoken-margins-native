import XCTest
@testable import SpokenMarginsApp

final class Gate1ProviderRequestFactoryTests: XCTestCase {
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
            contextJSON: #"{"currentFollowUp":"\#(followUp)","recentTurns":[]}"#
        )

        XCTAssertTrue(prompt.contains("current follow-up first"))
        XCTAssertTrue(prompt.contains(followUp))
    }

    func testChatCompletionsRequestEncodesSystemThenUserMessages() throws {
        let request = try XCTUnwrap(Gate1ProviderRequestFactory.makeChatCompletionsRequest(
            baseURL: " https://provider.example/v1/ ",
            apiKey: "secret",
            messages: ["User request"],
            model: "conversation-model",
            systemPrompt: "System prompt"
        ))
        XCTAssertEqual(request.url?.absoluteString, "https://provider.example/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "conversation-model")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages.map { $0["content"] as? String }, ["System prompt", "User request"])
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
