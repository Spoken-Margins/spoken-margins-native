import Foundation
@testable import SessionKit
import XCTest

/// The two gates the 2026-11-19 lane T4 run on the Margins tab found closed with the UI-test fixture (#3216): the arrival
/// preview on the item screen and the Autoplay menu on the Margins tab. Both read the open item's own state.
final class MarginsTabSeedGatesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_777_000_000)

    private func seededItem() -> ItemDetailState {
        var item = ItemDetailState()
        item.id = UITestingLaunchSeed.podcastItemId
        item.interjections = MarginsTabUITestSeed.ownMargins(createdAt: t0) { "UITestMarginsTab/\($0).caf" }
        item.importedCommentaryLayers = MarginsTabUITestSeed.layers(importedAt: t0)
        for layer in item.importedCommentaryLayers {
            item.importedCommentaryInterjections[layer.id] = MarginsTabUITestSeed.friendMargins(
                layerId: layer.id, createdAt: t0) { "UITestMarginsTab/\($0).caf" }
        }
        return item
    }

    func testTheSeededFriendsLayersCountForTheAutoplayMenu() {
        let item = seededItem()
        let eligible = item.importedCommentaryLayers.filter {
            SharedMarginPrompts.isLayerPlaybackEligible($0, records: item.importedCommentaryInterjections[$0.id] ?? [])
        }
        XCTAssertEqual(eligible.map(\.id), [MarginsTabUITestSeed.samLayerId, MarginsTabUITestSeed.raeLayerId])
    }

    func testTheArrivalPreviewShowsForTheSeededItemAtZero() {
        let rows = MarginsControlCenter.rows(item: seededItem())
        XCTAssertTrue(MarginsControlCenter.opensOnMarginsTab(rows))
        let atZero = Position(charOffset: 0, mediaTimeMs: 0, chapterId: nil)
        XCTAssertTrue(MarginsArrivalPreview.shows(rows, resumePlace: atZero, hasFinishedSession: false))
        let atPlace = Position(charOffset: 0, mediaTimeMs: MarginsTabUITestSeed.placeSeconds * 1_000, chapterId: nil)
        XCTAssertFalse(MarginsArrivalPreview.shows(rows, resumePlace: atPlace, hasFinishedSession: false))
    }
}
