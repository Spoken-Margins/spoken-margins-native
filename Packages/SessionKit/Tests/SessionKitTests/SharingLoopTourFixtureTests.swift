import XCTest
@testable import SessionKit
@testable import SessionKitSharing
import SessionKitTestInputs

/// #3237: the screen tour opens two checked-in packets from "Sam" on the seeded podcast. They must still match the
/// episode the tour seeds, and the reply must still name the identity the tour marks on the listener's Margin, or the
/// tour would capture a "find this item" screen and an unlinked reply instead of the loop.
final class SharingLoopTourFixtureTests: XCTestCase {
    private func fixture(_ name: String) throws -> VerifiedSpokenMarginsPackage {
        let url = try TestInputs.url(.appTestFixtures, "\(name).spokenmargins")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: folder)
    }

    private var seededEpisode: SharedItemIdentity {
        get throws {
            let item = try XCTUnwrap(UITestingLaunchSeed.offlinePodcast(title: "UI Test Episode", durationSeconds: 1_500).item)
            return SharedItemIdentityBuilder.exportIdentity(for: item, draftEditionDigests: [nil])
        }
    }

    func testSamsPacketsAreForTheEpisodeTheTourSeeds() throws {
        for name in ["sharing-loop-sam-margin", "sharing-loop-sam-reply"] {
            let packet = try fixture(name)
            XCTAssertEqual(packet.manifest.item, try seededEpisode, name)
            XCTAssertTrue(packet.manifest.senderDisplayLabel?.contains("synthetic") ?? false, name)
        }
    }

    func testSamsMarginSitsAtFiveMinutes() throws {
        let margins = try fixture("sharing-loop-sam-margin").commentaryLayers.first?.interjections ?? []
        XCTAssertEqual(margins.map(\.anchor.mediaTimeMs), [300_000])
    }

    func testSamsReplyAnswersTheMarginTheTourMarksAsSent() throws {
        let packet = try fixture("sharing-loop-sam-reply")
        let links = packet.conversations.flatMap { $0.linksByPackageScopedId.values.flatMap { $0 } }
        XCTAssertEqual(links.map(\.parent), [UITestingLaunchSeed.listenerSharedIdentity])
    }
}
