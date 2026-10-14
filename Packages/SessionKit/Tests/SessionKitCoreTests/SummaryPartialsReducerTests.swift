import XCTest
@testable import SessionKit

/// Records every prompt and answers with a numbered summary, so tests can count calls and read
/// what each reduce pass sent.
private actor FakeSummarizer {
    private(set) var prompts: [String] = []
    private let failOnCall: Int?
    private let longFirstPass: Int?

    /// `longFirstPass`: the first-pass calls answer with that many `x` characters instead.
    init(failOnCall: Int? = nil, longFirstPass: Int? = nil) {
        self.failOnCall = failOnCall
        self.longFirstPass = longFirstPass
    }

    func summarize(_ context: String) throws -> String {
        prompts.append(context)
        if prompts.count == failOnCall { throw FakeError.failed }
        if let longFirstPass, !context.hasPrefix("PARTIAL ") {
            return String(repeating: "x", count: longFirstPass)
        }
        return "summary \(prompts.count)"
    }
}

private enum FakeError: Error { case failed }

final class SummaryPartialsReducerTests: XCTestCase {
    private func run(_ contexts: [String], _ fake: FakeSummarizer) async throws -> [String] {
        try await SummaryPartialsReducer.reduce(contexts: contexts) { try await fake.summarize($0) }
    }

    private func reducePrompts(_ fake: FakeSummarizer) async -> [String] {
        await fake.prompts.filter { $0.hasPrefix("PARTIAL 1:\n") }
    }

    func testOneContextReturnsItsSummaryWithoutAReduceCall() async throws {
        let fake = FakeSummarizer()
        let result = try await run(["only"], fake)
        XCTAssertEqual(result, ["summary 1"])
        let prompts = await fake.prompts
        XCTAssertEqual(prompts, ["only"])
    }

    func testNoContextsReturnsAnEmptyList() async throws {
        let fake = FakeSummarizer()
        let result = try await run([], fake)
        XCTAssertEqual(result, [])
        let prompts = await fake.prompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testFivePartialsTakeTwoGroupsThenOne() async throws {
        let fake = FakeSummarizer()
        let result = try await run((1...5).map { "context \($0)" }, fake)
        let prompts = await fake.prompts
        // 5 first-pass calls, 2 groups (4 + 1), then 1 group of the 2 reduced summaries.
        guard prompts.count == 8 else { return XCTFail("expected 8 calls, got \(prompts.count)") }
        XCTAssertEqual(Array(prompts.prefix(5)), (1...5).map { "context \($0)" })
        XCTAssertEqual(prompts[5], "PARTIAL 1:\nsummary 1\n\nPARTIAL 2:\nsummary 2\n\nPARTIAL 3:\nsummary 3\n\nPARTIAL 4:\nsummary 4")
        XCTAssertEqual(prompts[6], "PARTIAL 1:\nsummary 5")
        XCTAssertEqual(prompts[7], "PARTIAL 1:\nsummary 6\n\nPARTIAL 2:\nsummary 7")
        XCTAssertEqual(result, ["summary 8"])
    }

    func testSeventeenPartialsTakeThreeReducePasses() async throws {
        let fake = FakeSummarizer()
        let result = try await run((1...17).map { "context \($0)" }, fake)
        let prompts = await fake.prompts
        // 17 -> 5 groups -> 2 groups -> 1 group: 17 + 5 + 2 + 1 calls.
        XCTAssertEqual(prompts.count, 25)
        let reduces = await reducePrompts(fake)
        XCTAssertEqual(reduces.count, 8)
        XCTAssertEqual(result, ["summary 25"])
    }

    func testALongPartialIsClippedInTheReduceTextButNotInTheFirstPass() async throws {
        let longContext = String(repeating: "c", count: 1_500)
        let fake = FakeSummarizer(longFirstPass: 1_500)
        _ = try await run([longContext, "short"], fake)
        let prompts = await fake.prompts
        guard prompts.count == 3 else { return XCTFail("expected 3 calls, got \(prompts.count)") }
        XCTAssertEqual(prompts[0], longContext, "the first pass sends each context whole")
        let clipped = String(repeating: "x", count: 1_200)
        XCTAssertEqual(prompts[2], "PARTIAL 1:\n\(clipped)\n\nPARTIAL 2:\n\(clipped)")
    }

    func testASummarizerErrorReachesTheCaller() async {
        for failing in [1, 3] {
            let fake = FakeSummarizer(failOnCall: failing)
            do {
                _ = try await run(["a", "b"], fake)
                XCTFail("expected an error from call \(failing)")
            } catch FakeError.failed {
                let prompts = await fake.prompts
                XCTAssertEqual(prompts.count, failing, "nothing runs after the failing call")
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }
}
