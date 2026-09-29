import Foundation
import XCTest
@testable import SessionKit

final class BridgeFollowingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func manifest(essaysHosts: [String] = ["essays.example.org"], status: String = "active", extraItems: String = "") throws -> BridgeManifest {
        let hosts = essaysHosts.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"""
        {"schema":"spokenmargins.bridge-manifest","version":1,"generatedAt":"2026-09-28T12:00:00Z","sources":[
          {"id":"example-essays","title":"Example Essays","homepage":"https://\#(essaysHosts[0])/",
           "match":{"hosts":[\#(hosts)],"pathPrefixes":["/p/"]},"status":"\#(status)",
           "checkedAt":"2026-09-28T11:40:00Z","updatedAt":"2026-09-27T10:00:00Z",
           "items":[
             {"url":"https://essays.example.org/p/older","title":"Older","publishedAt":"2026-09-20T09:00:00Z","firstSeenAt":"2026-09-20T10:00:00Z"},
             {"url":"https://essays.example.org/p/newer","title":"Newer","publishedAt":"2026-09-27T09:00:00Z","firstSeenAt":"2026-09-27T10:00:00Z"},
             {"url":"https://essays.example.org/p/newer","title":"Duplicate","firstSeenAt":"2026-09-27T10:00:00Z"}\#(extraItems)
           ],
           "recipe":{"version":1,"extract":"selectors","content":["article .post-body"]}}
        ]}
        """#
        return try BridgeManifestVerifier.manifest(from: Data(json.utf8))
    }

    private func on(_ manifest: BridgeManifest?) -> BridgeSnapshot { BridgeSnapshot(state: .on, manifest: manifest) }

    private func follow(host: String = "essays.example.org") -> BridgeFollow {
        BridgeFollow(id: "f1", sourceId: "example-essays", followedHost: host, title: "Example Essays", homepage: "https://essays.example.org/", createdAt: now)
    }

    // MARK: Offering a follow

    func testASharedLinkOnABridgedSiteOffersAFollowPinnedToItsHost() throws {
        let link = URL(string: "https://Essays.Example.org/p/a-post")!
        let candidate = try XCTUnwrap(BridgeFollowing.candidate(for: link, snapshot: on(try manifest())))
        XCTAssertEqual(candidate.source.id, "example-essays")
        XCTAssertEqual(candidate.followedHost, "essays.example.org")
        let follow = candidate.follow(id: "f1", at: now)
        XCTAssertEqual(follow.followedHost, "essays.example.org")
        XCTAssertEqual(follow.sourceId, "example-essays")
    }

    func testNoOfferWhenTheBridgeIsOffTheSiteIsNotBridgedOrPaused() throws {
        let link = URL(string: "https://essays.example.org/p/a-post")!
        XCTAssertNil(BridgeFollowing.candidate(for: link, snapshot: BridgeSnapshot(state: .off(.switchedOff), manifest: nil)))
        XCTAssertNil(BridgeFollowing.candidate(for: link, snapshot: on(nil)), "on, but no manifest yet")
        XCTAssertNil(BridgeFollowing.candidate(for: URL(string: "https://other.example.org/p/x")!, snapshot: on(try manifest())))
        XCTAssertNil(BridgeFollowing.candidate(for: URL(string: "http://essays.example.org/p/x")!, snapshot: on(try manifest())))
        XCTAssertNil(BridgeFollowing.candidate(for: link, snapshot: on(try manifest(status: "paused"))))
    }

    // MARK: Updating

    func testItemsAreNewestFirstDedupedAndCarryTheRecipe() throws {
        let update = BridgeFollowing.update(for: follow(), snapshot: on(try manifest()))
        XCTAssertEqual(update.status, .updating)
        XCTAssertEqual(update.items.map(\.title), ["Newer", "Older"])
        XCTAssertEqual(update.items.first?.recipe.extract, .selectors)
        XCTAssertEqual(update.items.first?.followId, "f1")
    }

    func testItemsOnlyEverComeFromThePinnedHost() throws {
        // The manifest now lists a second host for the source, with an item on it.
        let m = try manifest(
            essaysHosts: ["essays.example.org", "cdn.example.net"],
            extraItems: #",{"url":"https://cdn.example.net/p/elsewhere","title":"Elsewhere","firstSeenAt":"2026-09-28T10:00:00Z"}"#
        )
        let update = BridgeFollowing.update(for: follow(), snapshot: on(m))
        XCTAssertEqual(update.status, .updating)
        XCTAssertFalse(update.items.contains { $0.url.host == "cdn.example.net" }, "never fetch from a host the listener didn't follow")
    }

    func testAHostChangeStopsUpdatingUntilTheListenerConfirms() throws {
        let moved = try manifest(essaysHosts: ["essays.example.com"])
        let update = BridgeFollowing.update(for: follow(), snapshot: on(moved))
        XCTAssertEqual(update.status, .notUpdating(.hostChanged(newHosts: ["essays.example.com"])))
        XCTAssertTrue(update.items.isEmpty)

        XCTAssertNil(BridgeFollowing.confirmHostChange(follow(), to: "tracker.example.net", snapshot: on(moved)), "only a host the source lists")
        let confirmed = try XCTUnwrap(BridgeFollowing.confirmHostChange(follow(), to: "Essays.Example.com", snapshot: on(moved)))
        XCTAssertEqual(confirmed.followedHost, "essays.example.com")
    }

    func testEveryReasonToPauseKeepsTheFollowAndShowsNotUpdating() throws {
        let cases: [(String, BridgeFollow, BridgeSnapshot, BridgeFollowPause)] = [
            ("kill switch", follow(), BridgeSnapshot(state: .off(.switchedOff), manifest: nil), .bridgeOff(.switchedOff)),
            ("stale config", follow(), BridgeSnapshot(state: .off(.staleConfig), manifest: nil), .bridgeOff(.staleConfig)),
            ("no manifest yet", follow(), on(nil), .noManifest),
            ("site removed", BridgeFollow(id: "f2", sourceId: "gone", followedHost: "gone.example.org", title: "Gone", homepage: "https://gone.example.org/", createdAt: now), on(try manifest()), .sourceUnavailable),
            ("owner paused the site", follow(), on(try manifest(status: "paused")), .sourcePaused),
            ("muted", { var f = follow(); f.muted = true; return f }(), on(try manifest()), .muted),
        ]
        for (name, f, snapshot, reason) in cases {
            let update = BridgeFollowing.update(for: f, snapshot: snapshot)
            XCTAssertEqual(update.status, .notUpdating(reason), name)
            XCTAssertTrue(update.items.isEmpty, name)
            XCTAssertEqual(update.follow, f, "\(name): the follow itself is untouched")
        }
    }

    func testAtMostTwentyFiveItemsPerSite() throws {
        let extra = (0..<40).map { #",{"url":"https://essays.example.org/p/n\#($0)","title":"N\#($0)","firstSeenAt":"2026-09-28T10:00:00Z"}"# }.joined()
        let update = BridgeFollowing.update(for: follow(), snapshot: on(try manifest(extraItems: extra)))
        XCTAssertEqual(update.items.count, BridgeFollowing.maximumItemsPerSource)
    }

    func testAFollowRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(follow())
        XCTAssertEqual(try JSONDecoder().decode(BridgeFollow.self, from: data), follow())
    }
}
