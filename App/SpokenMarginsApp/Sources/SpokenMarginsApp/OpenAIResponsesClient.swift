import Foundation
import SessionKit

/// The URLSession transport for OpenAI Responses requests. The request shape, SSE parsing and
/// credentials live in SessionKit (`ResponsesRequestBuilder`, `ResponsesCredentialProvider`).
struct OpenAIResponsesClient: Sendable {
    static let endpoint = ResponsesRequestBuilder.endpoint

    func stream<Credentials: ResponsesCredentialProvider>(
        credentials: Credentials,
        model: String,
        instructions: String,
        messages: [String]
    ) -> AsyncThrowingStream<OpenAIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await ResponsesRequestBuilder.makeRequest(
                        credentials: credentials,
                        model: model,
                        instructions: instructions,
                        messages: messages
                    )
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
                        if let event = try ResponsesRequestBuilder.event(fromSSELine: line) {
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

    /// The whole answer at once, collected from the same streamed request.
    func complete<Credentials: ResponsesCredentialProvider>(
        credentials: Credentials,
        model: String,
        instructions: String,
        messages: [String]
    ) async throws -> String {
        try await ResponsesRequestBuilder.collectText(from: stream(
            credentials: credentials,
            model: model,
            instructions: instructions,
            messages: messages
        ))
    }
}
