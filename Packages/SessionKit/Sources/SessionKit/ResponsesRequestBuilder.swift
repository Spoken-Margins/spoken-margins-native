import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One event from an OpenAI Responses stream.
public enum OpenAIStreamEvent: Equatable, Sendable {
    case started(responseId: String?)
    case textDelta(String)
    case completed(responseId: String?)
}

public enum OpenAIResponsesError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case credentialUnavailable(String)
    case http(status: Int, body: String)
    case api(String)
    case emptyResponse
    case incompleteStream

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "The OpenAI request could not be created."
        case .credentialUnavailable(let reason):
            return "Spoken Margins couldn't get your OpenAI credential: \(reason)"
        case .http(let status, let body):
            return "OpenAI returned HTTP \(status): \(body)"
        case .api(let message):
            return message
        case .emptyResponse:
            return "OpenAI returned no response text."
        case .incompleteStream:
            return "OpenAI ended the stream before response.completed."
        }
    }
}

/// Where an OpenAI request gets its Authorization header (#548). Today that's the pasted API key;
/// a Sign in with ChatGPT token (#269) will be a second implementation.
public protocol ResponsesCredentialProvider: Sendable {
    /// The full Authorization header value, such as "Bearer sk-…".
    func authorizationHeaderValue() async throws -> String
}

/// The API key the listener pasted in Settings (stored in the Keychain as `OpenAICompatibleAPIKey`).
public struct APIKeyResponsesCredentialProvider: ResponsesCredentialProvider {
    public enum Failure: LocalizedError, Equatable, Sendable {
        case missingAPIKey

        public var errorDescription: String? {
            "No OpenAI API key is saved. Add one in Settings."
        }
    }

    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func authorizationHeaderValue() async throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.missingAPIKey }
        return "Bearer \(trimmed)"
    }
}

extension ResponsesCredentialProvider where Self == APIKeyResponsesCredentialProvider {
    public static func apiKey(_ apiKey: String) -> APIKeyResponsesCredentialProvider {
        APIKeyResponsesCredentialProvider(apiKey: apiKey)
    }
}

/// Builds OpenAI Responses requests in the one shape both the API key and the Sign in with ChatGPT
/// flow accept (#269): always streamed, never stored, `input` as message items, the system prompt
/// only in `instructions`, and none of `temperature`, `max_output_tokens`, `previous_response_id`
/// or `metadata`. There is deliberately no way to build a non-streaming request.
public enum ResponsesRequestBuilder {
    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// Asks the provider for the credential, then builds the request. A provider failure becomes
    /// `OpenAIResponsesError.credentialUnavailable` with the provider's own wording.
    public static func makeRequest<Credentials: ResponsesCredentialProvider>(
        credentials: Credentials,
        model: String,
        instructions: String,
        messages: [String]
    ) async throws -> URLRequest {
        let authorization: String
        do {
            authorization = try await credentials.authorizationHeaderValue()
        } catch {
            throw OpenAIResponsesError.credentialUnavailable(error.localizedDescription)
        }
        guard let request = makeRequest(
            authorization: authorization,
            model: model,
            instructions: instructions,
            messages: messages
        ) else {
            throw OpenAIResponsesError.invalidRequest
        }
        return request
    }

    public static func makeRequest(
        authorization: String,
        model: String,
        instructions: String,
        messages: [String]
    ) -> URLRequest? {
        let trimmedAuthorization = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAuthorization.isEmpty, !trimmedModel.isEmpty else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // URLSession treats this as the request inactivity timeout; incoming SSE data resets progress.
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedAuthorization, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(RequestPayload(
            model: trimmedModel,
            instructions: instructions,
            input: messages.map(InputMessage.init(text:))
        ))
        return request
    }

    public static func event(fromSSELine line: String) throws -> OpenAIStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        let envelope = try JSONDecoder().decode(StreamEnvelope.self, from: data)
        switch envelope.type {
        case "response.created":
            return .started(responseId: envelope.response?.id)
        case "response.output_text.delta":
            guard let delta = envelope.delta, !delta.isEmpty else { return nil }
            return .textDelta(delta)
        case "response.completed":
            return .completed(responseId: envelope.response?.id)
        case "error", "response.failed", "response.incomplete":
            throw OpenAIResponsesError.api(
                envelope.error?.message ?? envelope.response?.error?.message ?? "OpenAI streaming failed."
            )
        default:
            return nil
        }
    }

    /// Joins a stream's text into one answer, for callers that want the whole response at once.
    /// Throws when the stream ends before `response.completed` or carries no text.
    public static func collectText<Events: AsyncSequence>(
        from events: Events
    ) async throws -> String where Events.Element == OpenAIStreamEvent {
        var text = ""
        var completed = false
        for try await event in events {
            switch event {
            case .started:
                break
            case .textDelta(let delta):
                text += delta
            case .completed:
                completed = true
            }
        }
        guard completed else { throw OpenAIResponsesError.incompleteStream }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAIResponsesError.emptyResponse }
        return trimmed
    }

    private struct RequestPayload: Encodable {
        var model: String
        var instructions: String
        var input: [InputMessage]
        let stream = true
        let store = false
    }

    private struct InputMessage: Encodable {
        let type = "message"
        let role = "user"
        var content: [InputText]

        init(text: String) {
            content = [InputText(text: text)]
        }
    }

    private struct InputText: Encodable {
        let type = "input_text"
        var text: String
    }

    private struct StreamEnvelope: Decodable {
        var type: String
        var delta: String?
        var response: ResponseReference?
        var error: APIError?
    }

    private struct ResponseReference: Decodable {
        var id: String?
        var error: APIError?
    }

    private struct APIError: Decodable {
        var message: String?
    }
}
