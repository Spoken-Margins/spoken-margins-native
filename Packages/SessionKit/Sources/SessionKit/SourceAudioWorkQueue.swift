import Foundation

/// Bounds source-audio decoding and speech analysis across clients, items and Margin windows.
/// Actor isolation alone does not serialize async work: the permit stays held across suspension.
public actor SourceAudioWorkQueue {
    public static let shared = SourceAudioWorkQueue()

    private var busy = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    var waitingJobCount: Int { waiting.count }

    public init() {}

    public func run<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if busy {
                    waiting.append((id, continuation))
                } else {
                    busy = true
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
