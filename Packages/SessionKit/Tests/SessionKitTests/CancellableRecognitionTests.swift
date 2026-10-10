import XCTest
@testable import SessionKitAudio

/// #1037: a speech chunk that never finishes must stop when its task is cancelled, so the job queue gets its slot back.
final class CancellableRecognitionTests: XCTestCase {
    /// Stands in for `SFSpeechRecognitionTask`: it never finishes by itself, and says when it was cancelled. Like the
    /// real task, cancelling it makes it report an error through the same callback a result would use.
    private final class StuckRecognizer: @unchecked Sendable {
        private let lock = NSLock()
        private var finish: (@Sendable (Result<String, Error>) -> Void)?
        private var started = 0
        private var cancelled = 0
        var startCount: Int { lock.withLock { started } }
        var cancelCount: Int { lock.withLock { cancelled } }

        func start(_ finish: @escaping @Sendable (Result<String, Error>) -> Void) -> RecognitionHandle {
            lock.withLock { started += 1; self.finish = finish }
            return RecognitionHandle { [self] in
                lock.withLock { cancelled += 1 }
                let report = lock.withLock { self.finish }
                report?(.failure(NSError(domain: "kLSRErrorDomain", code: 301)))
            }
        }

        /// What a recognizer that wakes up after being cancelled would do.
        func finishLate(_ text: String) {
            let report = lock.withLock { finish }
            report?(.success(text))
        }
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    func testAFinishedJobReturnsItsResult() async throws {
        let text = try await CancellableRecognition.run { (finish: @escaping @Sendable (Result<String, Error>) -> Void) in
            finish(.success("hello"))
            return RecognitionHandle {}
        }
        XCTAssertEqual(text, "hello")
    }

    func testAFailedJobThrowsItsError() async {
        struct Boom: Error {}
        do {
            _ = try await CancellableRecognition.run { (finish: @escaping @Sendable (Result<String, Error>) -> Void) in
                finish(.failure(Boom()))
                return RecognitionHandle {}
            }
            XCTFail("expected the job's error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testCancellingTheTaskCancelsTheRecognitionAndThrowsCancellationErrorOnce() async {
        let recognizer = StuckRecognizer()
        let task = Task { try await CancellableRecognition.run(start: recognizer.start) }
        await waitUntil("the recognition started") { recognizer.startCount == 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled job must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "not the recognizer's own error: \(error)")
        }
        XCTAssertEqual(recognizer.cancelCount, 1, "the recognition task itself was cancelled, not just abandoned")
        // The recognizer's callbacks after the cancel (its error, then even a late result) must not resume again.
        recognizer.finishLate("too late")
    }

    func testATaskCancelledBeforeItStartsNeverStartsTheRecognizer() async {
        let recognizer = StuckRecognizer()
        let gate = Gate()
        let task = Task {
            await gate.wait()
            return try await CancellableRecognition.run(start: recognizer.start)
        }
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("a cancelled job must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recognizer.startCount, 0)
    }

    /// The task is cancelled while the job is still starting, before the handle exists to be stored: the handle must
    /// still be cancelled once `start` returns.
    func testACancellationDuringStartStillCancelsTheRecognition() async {
        let recognizer = StuckRecognizer()
        let holder = TaskHolder()
        let task = Task {
            try await CancellableRecognition.run { (finish: @escaping @Sendable (Result<String, Error>) -> Void) in
                holder.cancel()
                return recognizer.start(finish)
            }
        }
        holder.set(task)
        do {
            _ = try await task.value
            XCTFail("a cancelled job must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recognizer.cancelCount, 1)
    }

    /// The real stuck chunk, end to end through the queue: the 600 second timeout (shortened here) cancels the job, the
    /// recognizer stops, and the next job gets the slot without waiting for the app to restart.
    @MainActor
    func testTheQueueSlotComesBackWhenTheTimedOutRecognitionIsCancelled() async {
        let recognizer = StuckRecognizer()
        let queue = SourceWindowJobQueue(maxConcurrent: 1, jobTimeout: .milliseconds(50))
        let order = Order()
        queue.enqueue(id: "stuck", anchorMediaTimeMs: 0, playhead: { 0 }) {
            _ = try? await CancellableRecognition.run(start: recognizer.start)
            order.add("stuck returned")
        }
        queue.enqueue(id: "after", anchorMediaTimeMs: 1, playhead: { 0 }) { order.add("after ran") }
        await queue.waitUntilIdle()
        XCTAssertEqual(order.events, ["stuck returned", "after ran"])
        XCTAssertEqual(queue.timedOutCount, 1)
        XCTAssertEqual(recognizer.cancelCount, 1)
        XCTAssertEqual(queue.runningCount, 0)
    }
}

@MainActor
private final class Order {
    var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Lets a job cancel its own task: the task is stored after it starts, so `cancel()` waits for it.
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var task: Task<String, Error>?

    func set(_ task: Task<String, Error>) {
        lock.withLock { self.task = task }
        ready.signal()
    }

    func cancel() {
        ready.wait()
        lock.withLock { task }?.cancel()
    }
}
