import Foundation

struct Gate1ProviderRequestFactory {
    static func makeChatCompletionsRequest(
        baseURL: String,
        apiKey: String,
        messages: [String],
        model: String,
        systemPrompt: String
    ) -> URLRequest? {
        let trimmed = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let payload = RequestPayload(
            model: model,
            messages: [Message(role: "system", content: systemPrompt)] +
                messages.map { Message(role: "user", content: $0) },
            temperature: 0.2
        )
        request.httpBody = try? JSONEncoder().encode(payload)
        return request
    }

    static func modelForAIJob(
        kind: String,
        listeningMapModel: String,
        summaryModel: String,
        conversationModel: String,
        fallbackProviderModel: String
    ) -> String {
        let configured: String
        switch kind {
        case "listening_map":
            configured = listeningMapModel
        case "interjection_summary":
            configured = summaryModel
        case "assistant_response":
            configured = conversationModel
        default:
            configured = listeningMapModel
        }
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackProviderModel : trimmed
    }

    static func systemPromptForAIJob(kind: String) -> String {
        switch kind {
        case "listening_map":
            return "Return only strict JSON for the requested Listening Map. Do not wrap the response in Markdown."
        case "interjection_summary":
            return """
            You are having a Spoken Margins listening-session debrief with the user.
            Summarize patterns in the user's interjections and identify the key points they are making in relation to the source.
            Do not merely summarize the source. Use the source text as context.

            Respond exactly:
            <sm_summary>
            A short spoken introduction to the response.
            </sm_summary>
            <sm_response>
            A text-to-speech friendly synthesis of the user's engagement with the source.
            </sm_response>
            <sm_chapters_json>
            {"schemaVersion":"assistant-response-map.v1","chapters":[...]}
            </sm_chapters_json>

            Chapter anchors must be exact phrases from your response.
            """
        case "assistant_response":
            return """
            You are continuing a Spoken Margins listening session.
            The user's current follow-up is the primary request. Answer it first, before re-summarizing prior context.
            If the user asks for a specific format, length, or consolidation, satisfy that request at the beginning of the response.

            Respond exactly:
            <sm_summary>
            A short spoken introduction to the response.
            </sm_summary>
            <sm_response>
            Your full spoken response.
            </sm_response>
            <sm_chapters_json>
            {"schemaVersion":"assistant-response-map.v1","chapters":[...]}
            </sm_chapters_json>

            The response should be useful for immediate text-to-speech.
            If the full response has more than one meaningful section, include 2-5 useful chapters with concise titles.
            Chapter anchors must be exact phrases from the full response and should point to the section starts.
            """
        default:
            return "You are the Spoken Margins Gate 1 assistant. Preserve user source meaning, answer concisely, and make failures explicit."
        }
    }

    static func conversationPrompt(followUp: String, contextJSON: String) -> String {
        """
        Respond to the user's current follow-up first, in the context of the source, Listening Map, interjections, and recent session turns.
        Focus on the user's thinking and questions. Do not summarize the source unless needed.
        If the follow-up asks for a specific deliverable, provide that deliverable before additional commentary.
        \(contextJSON)
        """
    }

    private struct RequestPayload: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }
}
