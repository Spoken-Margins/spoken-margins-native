import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4046 PR 6: what a list address now offers against what the listener already took from it.
final class ListLinkDiffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func show(_ n: Int, guid: String? = nil, via: String? = nil) -> ProposedShow {
        ProposedShow(member: ListLinkFixture.member(n, guid: guid), feedURL: ListLinkFixture.feedURL(n), title: "Show \(n)", viaTitle: via)
    }

    private func proposal(
        resolved: [ProposedShow], accepted: [ListMember] = [], rejected: [ListMember] = [], suppress: Bool = false
    ) -> ListProposal? {
        ListLinkDiff.proposal(resolved: resolved, accepted: accepted, rejected: rejected, suppressRemovals: suppress, checkedAt: now)
    }

    func testNothingChangedIsNoProposal() {
        XCTAssertNil(proposal(resolved: [show(1), show(2)], accepted: [ListLinkFixture.member(1), ListLinkFixture.member(2)]))
        XCTAssertNil(proposal(resolved: [], accepted: []))
    }

    func testAnAddIsProposed() throws {
        let result = try XCTUnwrap(proposal(resolved: [show(1), show(2, via: "Friend’s picks")], accepted: [ListLinkFixture.member(1)]))
        XCTAssertEqual(result.added.map(\.title), ["Show 2"])
        XCTAssertEqual(result.added.first?.viaTitle, "Friend’s picks")
        XCTAssertEqual(result.removed, [])
        XCTAssertEqual(result.checkedAt, now)
    }

    func testARemovalIsProposed() throws {
        let result = try XCTUnwrap(proposal(resolved: [show(1)], accepted: [ListLinkFixture.member(1), ListLinkFixture.member(2)]))
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.removed, [ListLinkFixture.member(2)])
    }

    func testTheFirstReadProposesEveryShow() throws {
        let result = try XCTUnwrap(proposal(resolved: [show(1), show(2), show(3)]))
        XCTAssertEqual(result.added.map(\.title), ["Show 1", "Show 2", "Show 3"], "every change from a link is a proposal, the first add included")
    }

    func testAShowRejectedThenAddedAgainStaysRejected() {
        // The list dropped show 2 and put it back; the listener turned it down once.
        XCTAssertNil(proposal(resolved: [show(1), show(2)], accepted: [ListLinkFixture.member(1)], rejected: [ListLinkFixture.member(2)]))
        // Rejected under a GUID, offered again under a new feed address.
        let moved = ProposedShow(member: ListLinkFixture.member(9, guid: "G-2"), feedURL: ListLinkFixture.feedURL(9), title: "Moved")
        XCTAssertNil(proposal(resolved: [moved], rejected: [ListLinkFixture.member(2, guid: "g-2")]), "a GUID match is the same show, in any case")
    }

    func testAddThenRemoveBeforeReviewNetsToNothing() throws {
        let accepted = [ListLinkFixture.member(1)]
        let first = try XCTUnwrap(proposal(resolved: [show(1), show(2)], accepted: accepted))
        XCTAssertEqual(first.added.count, 1)
        // The next check is against the accepted copy again, not against the proposal, so the show that left is gone from it.
        XCTAssertNil(proposal(resolved: [show(1)], accepted: accepted))
    }

    func testAGUIDMatchAfterAFeedAddressChangeIsTheSameShow() {
        let accepted = [ListLinkFixture.member(1, guid: "guid-one")]
        let moved = ProposedShow(member: ListLinkFixture.member(7, guid: "GUID-ONE"), feedURL: ListLinkFixture.feedURL(7), title: "Moved")
        XCTAssertNil(proposal(resolved: [moved], accepted: accepted), "same GUID: not an add, not a removal")
        // Without a GUID on both sides a new address is a different show.
        let plain = ProposedShow(member: ListLinkFixture.member(7), feedURL: ListLinkFixture.feedURL(7), title: "Moved")
        let result = proposal(resolved: [plain], accepted: [ListLinkFixture.member(1)])
        XCTAssertEqual(result?.added.count, 1)
        XCTAssertEqual(result?.removed.count, 1)
    }

    func testARepeatInTheResolvedSetIsOneAdd() throws {
        let result = try XCTUnwrap(proposal(resolved: [show(1), show(1), show(2, guid: "g"), show(3, guid: "G")]))
        XCTAssertEqual(result.added.map(\.title), ["Show 1", "Show 2"], "show 3 shares show 2's GUID")
    }

    func testAShowTheListenerAlreadyRejectedAfterAcceptingIsNotARemovalToOffer() {
        // Accepted earlier, taken out of the list by hand since (it joined the rejected set), and the file dropped it too.
        XCTAssertNil(proposal(resolved: [], accepted: [ListLinkFixture.member(1)], rejected: [ListLinkFixture.member(1)]))
    }

    func testRemovalsAreHeldBackWhenPartOfTheListWasNotRead() throws {
        let accepted = [ListLinkFixture.member(1), ListLinkFixture.member(2)]
        let result = try XCTUnwrap(proposal(resolved: [show(1), show(3)], accepted: accepted, suppress: true))
        XCTAssertEqual(result.added.map(\.title), ["Show 3"], "adds from what was read are still offered")
        XCTAssertEqual(result.removed, [], "a show that is missing may only be unread")
        XCTAssertNil(proposal(resolved: [show(1)], accepted: accepted, suppress: true))
    }
}
