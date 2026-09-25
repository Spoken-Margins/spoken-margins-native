import Foundation
import SessionKit

public enum SourceSpeechRecognitionFailure: String, Error, LocalizedError, Sendable {
    case serviceUnavailable = "speech_recognition_service_suspended"
    case inputUnavailable = "source_audio_input_unavailable"
    case emptyWindow = "source_audio_window_has_no_recognized_speech"

    public var errorDescription: String? { rawValue }
}

/// One process-wide recognizer lease, shared by Margin, source-map and recipient
/// transcription. Recipient jobs release it after each window, joining the tail
/// for the next one so another item cannot be starved by a whole episode sweep.
public actor SpeechRecognitionQueue {
    public static let shared = SpeechRecognitionQueue()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var occupied = false
    private var waiters: [Waiter] = []
    private enum SourceRoute { case preferred, legacy, suspended }
    private var sourceRoute: SourceRoute = .preferred

    public init() {}

    public func resetSourceRecognitionAfterExplicitRetry() async throws {
        try await run { await self.resetSourceRoute() }
    }

    private func resetSourceRoute() { sourceRoute = .preferred }

    public func run<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if !occupied {
                    occupied = true
                    continuation.resume()
                } else if waiters.count < 64 {
                    waiters.append(Waiter(id: id, continuation: continuation))
                } else {
                    continuation.resume(throwing: SessionKitError.persistenceFailed("speech_queue_full"))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id: id) }
        }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func cancelWaiting(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    /// Called only while holding this queue's lease. One failed preferred
    /// recognizer switches source work to the supported on-device legacy route.
    /// A failed legacy service suspends source recognition across all items.
    func recognizeSource<Value: Sendable>(
        preferred: (@Sendable () async throws -> Value)?,
        legacy: @Sendable () async throws -> Value
    ) async throws -> Value {
        guard sourceRoute != .suspended else {
            throw SourceSpeechRecognitionFailure.serviceUnavailable
        }
        if sourceRoute == .preferred, let preferred {
            do { return try await preferred() }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                if let inputFailure = Self.inputFailure(error) { throw inputFailure }
                sourceRoute = .legacy
            }
        }
        do { return try await legacy() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            if let inputFailure = Self.inputFailure(error) { throw inputFailure }
            sourceRoute = .suspended
            throw SourceSpeechRecognitionFailure.serviceUnavailable
        }
    }

    private static func inputFailure(_ error: Error) -> SourceSpeechRecognitionFailure? {
        if let failure = error as? SourceSpeechRecognitionFailure,
           failure != .serviceUnavailable { return failure }
        let reason = String(describing: error)
        if reason.contains("transcript_empty") || reason.contains("chunk_empty") {
            return .emptyWindow
        }
        if reason.contains("audio_file_unreadable") || reason.contains("audio_file_missing") {
            return .inputUnavailable
        }
        return nil
    }

    // Read-only deterministic synchronization for focused queue tests.
    var waitingCount: Int { waiters.count }
}
