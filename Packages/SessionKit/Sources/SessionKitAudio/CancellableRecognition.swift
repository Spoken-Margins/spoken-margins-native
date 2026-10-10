import Foundation

/// Stops a callback-style recognition job: the one thing `CancellableRecognition` needs from it.
struct RecognitionHandle: @unchecked Sendable {
    let cancel: () -> Void
}

/// Bridges a callback-style speech recognition job into async code that ends when the Swift task is cancelled (#1037).
///
/// `SFSpeechRecognizer.recognitionTask(with:)` knows nothing of Swift cancellation. Wrapped in a bare continuation,
/// a stuck chunk kept running after `SourceWindowJobQueue` timed it out, so its source-context slot never came back.
/// Here a cancelled task cancels the recognition job and resumes the caller once with `CancellationError`. The job's
/// own callback after that (it reports an error when cancelled) is ignored, so the continuation is resumed exactly once.
enum CancellableRecognition {
    /// `start` begins the job and returns how to cancel it. It calls `finish` when the job ends; only the first of
    /// `finish` and a task cancellation counts. If the task is already cancelled, `start` is never called.
    static func run<Output: Sendable>(
        start: (_ finish: @escaping @Sendable (Result<Output, Error>) -> Void) -> RecognitionHandle
    ) async throws -> Output {
        let state = RecognitionState<Output>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                guard state.attach(continuation) else { return }
                let handle = start { result in state.finish(result) }
                state.setHandle(handle)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class RecognitionState<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var handle: RecognitionHandle?
    private var isCancelled = false

    /// Returns false, having resumed the caller with `CancellationError`, when the task was cancelled before the job began.
    func attach(_ continuation: CheckedContinuation<Output, Error>) -> Bool {
        let alreadyCancelled = lock.withLock { () -> Bool in
            if isCancelled { return true }
            self.continuation = continuation
            return false
        }
        if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
        return !alreadyCancelled
    }

    /// Keeps the handle for `cancel()`. A cancellation that arrived while the job was starting had no handle to use,
    /// so it is applied here.
    func setHandle(_ newHandle: RecognitionHandle) {
        let cancelNow = lock.withLock { () -> Bool in
            if isCancelled { return true }
            if continuation != nil { handle = newHandle }
            return false
        }
        if cancelNow { newHandle.cancel() }
    }

    func finish(_ result: Result<Output, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Output, Error>? in
            defer { continuation = nil; handle = nil }
            return continuation
        }
        pending?.resume(with: result)
    }

    func cancel() {
        let taken = lock.withLock { () -> (pending: CheckedContinuation<Output, Error>?, handle: RecognitionHandle?)? in
            guard !isCancelled else { return nil }
            isCancelled = true
            defer { continuation = nil; handle = nil }
            return (continuation, handle)
        }
        taken?.handle?.cancel()
        taken?.pending?.resume(throwing: CancellationError())
    }
}
