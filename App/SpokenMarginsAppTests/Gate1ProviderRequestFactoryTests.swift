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

    /// The fallback is used when a configured model is blank (APM-14). The test above gives every activity a
    /// model and a fallback that equals the Listening Map model, so neither the fallback nor a wrong fallback
    /// source could show.
    func testABlankModelForAnActivityFallsBackToTheProviderModel() {
        for kind in ["listening_map", "interjection_summary", "assistant_response"] {
            for blank in ["", "   ", "\n\t "] {
                XCTAssertEqual(
                    modelForAIJob(
                        kind: kind,
                        listeningMapModel: kind == "listening_map" ? blank : "map-model",
                        summaryModel: kind == "interjection_summary" ? blank : "summary-model",
                        conversationModel: kind == "assistant_response" ? blank : "conversation-model"
                    ),
                    "legacy-model",
                    "\(kind) with a model of \(blank.debugDescription)"
                )
            }
        }
        XCTAssertEqual(
            modelForAIJob(kind: "unknown", listeningMapModel: " ", summaryModel: "summary-model", conversationModel: "conversation-model"),
            "legacy-model",
            "an unknown activity uses the Listening Map model, and a blank one falls back"
        )
    }

    func testConfiguredModelsAreTrimmedForEveryActivity() {
        XCTAssertEqual(
            modelForAIJob(kind: "listening_map", listeningMapModel: " map-model\n", summaryModel: "", conversationModel: ""),
            "map-model"
        )
        XCTAssertEqual(
            modelForAIJob(kind: "interjection_summary", listeningMapModel: "", summaryModel: "\tsummary-model ", conversationModel: ""),
            "summary-model"
        )
        XCTAssertEqual(
            modelForAIJob(kind: "assistant_response", listeningMapModel: "", summaryModel: "", conversationModel: "  conversation-model"),
            "conversation-model"
        )
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

    // The Responses request shape and SSE parsing are host-tested in SessionKit
    // (ResponsesRequestBuilderTests, #548).

    func testSpokenPromptsContainNoStructuredTags() {
        for kind in ["interjection_summary", "assistant_response"] {
            let prompt = Gate1ProviderRequestFactory.systemPromptForAIJob(kind: kind)
            XCTAssertFalse(prompt.contains("<sm_"))
            XCTAssertTrue(prompt.contains("text-to-speech") || prompt.contains("spoken answer"))
        }
    }

    private func modelForAIJob(kind: String, listeningMapModel: String, summaryModel: String, conversationModel: String) -> String {
        Gate1ProviderRequestFactory.modelForAIJob(
            kind: kind,
            listeningMapModel: listeningMapModel,
            summaryModel: summaryModel,
            conversationModel: conversationModel,
            fallbackProviderModel: "legacy-model"
        )
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
