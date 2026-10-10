import Foundation

/// Keeps the job's origin while the listener reviews data-sharing consent.
struct PendingProviderJob {
    let kind: String
    let itemId: String
    let turnId: String
    let messages: [String]
    let force: Bool
}

struct Gate1ProviderRequestFactory {
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
            Return only a text-to-speech friendly spoken response. Do not include XML tags, JSON, or Markdown fences.
            """
        case "assistant_response":
            return """
            You are continuing a Spoken Margins listening session.
            The user's current follow-up is the primary request. Answer it first, before re-summarizing prior context.
            If the user asks for a specific format, length, or consolidation, satisfy that request at the beginning of the response.

            Return only the spoken answer. Make it useful for immediate text-to-speech and do not include XML tags, JSON, or Markdown fences.
            """
        default:
            return "You are the Spoken Margins Gate 1 assistant. Preserve user source meaning, answer concisely, and make failures explicit."
        }
    }

    static func conversationPrompt(followUp: String, contextJSON: String) -> String {
        """
        Respond to the primaryUserIntent first. Treat the current target interjections inside primaryUserIntent as the current change in the conversation, whether or not they have already been summarized elsewhere.
        If the primaryUserIntent contains constraints about form, length, voice, or what not to include, treat those constraints as binding.
        Use the source, Listening Map, prior interjections, and recent session turns only as grounding context. Do not re-review the article or conversation unless the primaryUserIntent asks for that.
        If the primaryUserIntent asks for a specific deliverable, provide that deliverable directly before any optional commentary.
        \(contextJSON)
        """
    }
}
