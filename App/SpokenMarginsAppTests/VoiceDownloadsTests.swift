import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// The app's side of Settings › Voices (#1819): the chip table and the snapshot bundled in this build. The model's rules
/// (install, Storage, Stop, Wi-Fi-only restarts) are `VoiceDownloadsModelTests` in SessionKit (#318).
@MainActor
final class VoiceDownloadsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheDeviceProbeReadsAModelTheChipTableKnows() {
        // The simulator reports the simulated iPhone; every one iOS 26 runs on is in the table.
        XCTAssertNotNil(VoiceDeviceProbe.chipGeneration(), VoiceDeviceProbe.machineIdentifier())
    }

    func testTheBundledSnapshotOffersSupertonicWithItsLicenceAndKittenAsIncluded() async throws {
        let voices = VoiceDownloadsModel.make(supportDirectory: root, repository: nil)
        await voices.reload()
        XCTAssertEqual(voices.source, .bundledSnapshot)
        let supertonic = try XCTUnwrap(voices.rows.first { $0.id == SupertonicAssetResolver.catalogVoiceId })
        XCTAssertEqual(supertonic.state, .notInstalled)
        XCTAssertGreaterThan(supertonic.entry.downloadByteCount, 140_000_000)
        let restricted = try XCTUnwrap(supertonic.licensesNeedingAgreement.first)
        XCTAssertNotNil(VoiceLicenseView.bundledText(sha256: restricted.textSHA256), "the Open RAIL-M text opens offline")
        XCTAssertEqual(voices.rows.first { $0.entry.bundled }?.state, .bundled)
        XCTAssertFalse(voices.rows.contains { $0.id.hasPrefix("pocket") }, "no player for Pocket TTS in this build")
    }
}
