import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #4339 PR 3: the app's side of the tidy proposal. The model's own rewrite is judged on a phone with Apple Intelligence;
/// what runs here is the seam: a client that can't tidy throws, so the proposer falls back to the filler-only version,
/// and the UI-test stub gives a proposal that passes the guard.
final class MarginTidyModelClientTests: XCTestCase {
    private struct NoModel: LocalFoundationModelClient {
        func availability() -> LocalFoundationModelAvailability { .unavailable("test") }
        func summarizeInterjections(context: String) async throws -> String { throw LocalFoundationModelError.unavailable("test") }
        func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
            throw LocalFoundationModelError.unavailable("test")
        }
        func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
            throw LocalFoundationModelError.unavailable("test")
        }
    }

    func testAClientThatCannotTidyThrowsAndTheProposerOffersFillers() async {
        let client = NoModel()
        do {
            _ = try await client.tidyMargin(transcript: "um it held", before: "", after: "")
            XCTFail("a client without a model must not return a tidy version")
        } catch {}
        let proposer = MarginTidyProposer(model: { try await client.tidyMargin(transcript: $0, before: $1, after: $2) })
        let proposal = await proposer.proposal(marginId: "m1", transcript: "um so the the result was not 12 percent")
        XCTAssertEqual(proposal, MarginTidyProposal(text: "The result was not 12 percent", source: .fillers))
    }

    #if DEBUG
    func testTheUITestStubGivesAProposalThatPassesTheGuard() async {
        let client = UITestingLocalFoundationModelClient(mode: .succeed)
        let proposer = MarginTidyProposer(model: { try await client.tidyMargin(transcript: $0, before: $1, after: $2) })
        let proposal = await proposer.proposal(marginId: "m1", transcript: "um so the the result was not 12 percent")
        XCTAssertEqual(proposal, MarginTidyProposal(text: "The result was not 12 percent.", source: .onDeviceAI))
    }

    func testTheFailingUITestStubFallsBackToFillers() async {
        let client = UITestingLocalFoundationModelClient(mode: .fail)
        let proposer = MarginTidyProposer(model: { try await client.tidyMargin(transcript: $0, before: $1, after: $2) })
        let proposal = await proposer.proposal(marginId: "m1", transcript: "um so the the result was not 12 percent")
        XCTAssertEqual(proposal?.source, .fillers)
    }
    #endif
}
