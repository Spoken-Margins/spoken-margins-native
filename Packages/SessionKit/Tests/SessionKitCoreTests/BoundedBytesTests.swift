import Foundation
import XCTest
@testable import SessionKit

/// `BoundedBytes.collect`, which the public and club transports read answers with (#4675): chunked, with the cap and
/// cancellation checked per chunk, and the same limits the byte-at-a-time loop had.
final class BoundedBytesTests: XCTestCase {
    /// A stream of `count` bytes (0, 1, 2, … wrapping) that records how many it handed out.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct Bytes: AsyncSequence {
        typealias Element = UInt8
        let count: Int?
        let counter: Counter
        struct AsyncIterator: AsyncIteratorProtocol {
            let count: Int?
            let counter: Counter
            var index = 0
            mutating func next() async -> UInt8? {
                if let count, index >= count { return nil }
                defer { index += 1 }
                counter.increment()
                return UInt8(truncatingIfNeeded: index)
            }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(count: count, counter: counter) }
    }

    private func expected(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0) }) }

    func testEveryLengthAroundAChunkComesBackWhole() async throws {
        for length in [0, 1, 7, 8, 9, 16, 23, 100] {
            let data = try await BoundedBytes.collect(
                Bytes(count: length, counter: Counter()), maximumBytes: 100, chunkBytes: 8)
            XCTAssertEqual(data, expected(length), "length \(length)")
        }
    }

    func testTheExactCapIsAcceptedAndOneMoreIsRefusedWithoutReadingOn() async throws {
        let exact = try await BoundedBytes.collect(Bytes(count: 50, counter: Counter()), maximumBytes: 50, chunkBytes: 16)
        XCTAssertEqual(exact, expected(50))

        let counter = Counter()
        do {
            _ = try await BoundedBytes.collect(Bytes(count: nil, counter: counter), maximumBytes: 50, chunkBytes: 16)
            XCTFail("an endless stream past the cap must be refused")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
        XCTAssertEqual(counter.count, 51, "stops one byte past the cap, as the byte-at-a-time loop did")
    }

    func testTheDefaultChunkReadsAMegabyteAndRefusesOneByteMore() async throws {
        let cap = 1024 * 1024 + 5 // not a whole number of chunks
        let data = try await BoundedBytes.collect(Bytes(count: cap, counter: Counter()), maximumBytes: cap)
        XCTAssertEqual(data.count, cap)
        do {
            _ = try await BoundedBytes.collect(Bytes(count: cap + 1, counter: Counter()), maximumBytes: cap)
            XCTFail("one byte over the cap must be refused")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
    }

    func testACancelledReadStopsAtTheNextChunk() async throws {
        let counter = Counter()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BoundedBytes.collect(Bytes(count: nil, counter: counter), maximumBytes: .max, chunkBytes: 32)
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled read must throw")
        } catch is CancellationError {}
        XCTAssertEqual(counter.count, 32, "cancellation is checked once per chunk")
    }
}
