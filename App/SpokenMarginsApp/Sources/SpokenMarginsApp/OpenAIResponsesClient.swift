import Foundation

enum OpenAIStreamEvent: Equatable, Sendable {
    case started(responseId: String?)
    case textDelta(String)
    case completed(responseId: String?)
}

enum OpenAIResponsesError: LocalizedError, Equatable {
    case invalidRequest
    case http(status: Int, body: String)
    case api(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "The OpenAI request could not be created."
        case .http(let status, let body):
            return "OpenAI returned HTTP \(status): \(body)"
        case .api(let message):
            return message
        case .emptyResponse:
            return "OpenAI returned no response text."
        }
    }
}

struct OpenAIResponsesClient: Sendable {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    func stream(
        apiKey: String,
        model: String,
        instructions: String,
        messages: [String]
    ) -> AsyncThrowingStream<OpenAIStreamEvent, Error> {
        guard let request = Self.makeRequest(
            apiKey: apiKey,
            model: model,
            instructions: instructions,
            messages: messages,
            stream: true
        ) else {
            return AsyncThrowingStream { $0.finish(throwing: OpenAIResponsesError.invalidRequest) }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                        }
                        let body = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                        throw OpenAIResponsesError.http(status: status, body: body)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = try Self.event(fromSSELine: line) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(
        apiKey: String,
        model: String,
        instructions: String,
        messages: [String]
    ) async throws -> String {
        guard let request = Self.makeRequest(
            apiKey: apiKey,
            model: model,
            instructions: instructions,
            messages: messages,
            stream: false
        ) else {
            throw OpenAIResponsesError.invalidRequest
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw OpenAIResponsesError.http(
                status: status,
                body: String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            )
        }
        let envelope = try JSONDecoder().decode(CompletionEnvelope.self, from: data)
        let text = envelope.output
            .flatMap(\.content)
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAIResponsesError.emptyResponse }
        return text
    }

    static func makeRequest(
        apiKey: String,
        model: String,
        instructions: String,
        messages: [String],
        stream: Bool
    ) -> URLRequest? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedModel.isEmpty else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // URLSession treats this as the request inactivity timeout; incoming SSE data resets progress.
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(RequestPayload(
            model: trimmedModel,
            instructions: instructions,
            input: messages.joined(separator: "\n\n"),
            stream: stream,
            store: false
        ))
        return request
    }

    static func event(fromSSELine line: String) throws -> OpenAIStreamEvent? {
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

    private struct RequestPayload: Encodable {
        var model: String
        var instructions: String
        var input: String
        var stream: Bool
        var store: Bool
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

    private struct CompletionEnvelope: Decodable {
        var output: [Output]
    }

    private struct Output: Decodable {
        var content: [Content]
    }

    private struct Content: Decodable {
        var type: String
        var text: String?
    }
}
