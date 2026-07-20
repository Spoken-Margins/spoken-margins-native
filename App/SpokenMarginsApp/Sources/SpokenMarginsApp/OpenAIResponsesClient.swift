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

struct ReviewDemoAIClient: Sendable {
    func stream(kind: String, messages: [String]) -> AsyncThrowingStream<OpenAIStreamEvent, Error> {
        let response = response(kind: kind, messages: messages)
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(responseId: "review-demo"))
                let words = response.split(separator: " ", omittingEmptySubsequences: false)
                for start in stride(from: 0, to: words.count, by: 8) {
                    try Task.checkCancellation()
                    let end = min(start + 8, words.count)
                    let chunk = words[start..<end].joined(separator: " ") + (end < words.count ? " " : "")
                    continuation.yield(.textDelta(chunk))
                    try? await Task.sleep(for: .milliseconds(35))
                }
                continuation.yield(.completed(responseId: "review-demo"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(kind: String, messages: [String]) async -> String {
        response(kind: kind, messages: messages)
    }

    private func response(kind: String, messages: [String]) -> String {
        let prompt = messages.joined(separator: "\n\n")
        switch kind {
        case "listening_map":
            return listeningMapResponse(prompt: prompt)
        case "assistant_chapters":
            return assistantChapterResponse(prompt: prompt)
        case "interjection_summary":
            return "Review demo summary: your interjections question the source's assumptions and ask for clearer evidence. The strongest next step is to compare the claim with the surrounding passage and identify what would change your conclusion."
        default:
            return "Review demo response: I hear the concern in your follow-up. The source's main idea should be evaluated against the evidence immediately around the point you marked. A useful next step is to separate the claim, the supporting example, and the assumption connecting them. This response is simulated locally and no content was sent off device."
        }
    }

    private func listeningMapResponse(prompt: String) -> String {
        let source = delimitedSection(named: "ITEM CONTENT", in: prompt)
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidates = paragraphs.isEmpty ? [normalized] : Array(paragraphs.prefix(3))
        let chapters: [[String: String]] = candidates.enumerated().compactMap { index, paragraph in
            let words = paragraph.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { return nil }
            let anchor = words.prefix(min(10, words.count)).joined(separator: " ")
            return [
                "id": "demo-ch-\(index + 1)",
                "title": "Section \(index + 1)",
                "description": "A locally generated navigation point for review.",
                "anchor": anchor
            ]
        }
        let object: [String: Any] = [
            "schemaVersion": "listening-map.v1",
            "overview": "A deterministic on-device Listening Map created for TestFlight review.",
            "claims": [["id": "demo-claim-1", "text": "Review the source's central claim and supporting evidence."]],
            "chapters": chapters
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"schemaVersion":"listening-map.v1","overview":"Review demo","claims":[],"chapters":[]}"#
        }
        return string
    }

    private func assistantChapterResponse(prompt: String) -> String {
        let response = delimitedSection(named: "RESPONSE", in: prompt)
        let words = response.split(whereSeparator: \.isWhitespace)
        guard words.count >= 12 else {
            return #"{"schemaVersion":"assistant-response-map.v1","chapters":[]}"#
        }
        let anchor = words.prefix(min(8, words.count)).joined(separator: " ")
        let object: [String: Any] = [
            "schemaVersion": "assistant-response-map.v1",
            "chapters": [["id": "demo-response-ch-1", "title": "Review response", "anchor": anchor]]
        ]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"schemaVersion":"assistant-response-map.v1","chapters":[]}"#
    }

    private func delimitedSection(named name: String, in prompt: String) -> String {
        guard let header = prompt.range(of: "\(name):", options: .backwards),
              let startMarker = prompt.range(of: "<<<", range: header.upperBound..<prompt.endIndex),
              let endMarker = prompt.range(of: ">>>", range: startMarker.upperBound..<prompt.endIndex) else {
            return prompt
        }
        return String(prompt[startMarker.upperBound..<endMarker.lowerBound])
    }
}
