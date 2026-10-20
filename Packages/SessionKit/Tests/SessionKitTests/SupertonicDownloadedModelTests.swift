import Foundation
import SessionKitTestInputs
import XCTest
@testable import SessionKit
@testable import SessionKitSupertonic

/// #1820: Supertonic's model is a download, so its files arrive and leave while the app runs. The PR's audit found two
/// cases of one flaw: the player fixed "is the model there?" when it was built. After a download the listener kept
/// hearing Kitten until a relaunch, and with no model saved audio couldn't be found, because its identity was hashed
/// from the files. These tests hold both to the files as they are now.
final class SupertonicDownloadedModelTests: XCTestCase {
    private final class Rendered: Sendable {
        let location: SupertonicAssetLocation
        init(_ location: SupertonicAssetLocation) { self.location = location }
    }

    private final class Phone: @unchecked Sendable {
        private let lock = NSLock()
        private var _model: SupertonicAssetLocation?
        private var _retired: [SupertonicAssetLocation] = []
        var model: SupertonicAssetLocation? {
            get { lock.withLock { _model } }
            set { lock.withLock { _model = newValue } }
        }
        var retired: [SupertonicAssetLocation] { lock.withLock { _retired } }
        func retire(_ renderer: Rendered) { lock.withLock { _retired.append(renderer.location) } }
    }

    private func follower(_ phone: Phone) -> SupertonicModelFollower<Rendered> {
        SupertonicModelFollower(locate: { phone.model }, retire: { phone.retire($0) })
    }

    private let downloaded = SupertonicAssetLocation(rootURL: URL(fileURLWithPath: "/voices/supertonic-3-int8/1"))

    // Finding 1: the player, built before the download, renders Supertonic once it lands, with no rebuild.
    func testADownloadAfterThePlayerWasBuiltIsUsedWithoutRebuildingIt() throws {
        let phone = Phone()
        let model = follower(phone)
        let allowed = model.renderingAllowed(when: { true })
        XCTAssertFalse(allowed(), "no model: Kitten reads")
        XCTAssertThrowsError(try model.renderer { Rendered($0) }) { error in
            XCTAssertEqual(error as? SupertonicNarrationError, .missingAsset("Supertonic"))
        }

        phone.model = downloaded
        XCTAssertTrue(allowed(), "the same closure the player was built with now allows Supertonic")
        XCTAssertEqual(try model.renderer { Rendered($0) }.location, downloaded)
    }

    // Finding 1 in reverse: after a Remove the player stops asking for Supertonic and the old renderer is unloaded.
    func testARemoveStopsSupertonicAndRetiresItsRenderer() throws {
        let phone = Phone()
        phone.model = downloaded
        let model = follower(phone)
        let allowed = model.renderingAllowed(when: { true })
        let first = try model.renderer { Rendered($0) }
        XCTAssertTrue(model.current === first)

        phone.model = nil
        XCTAssertFalse(allowed())
        model.retireIfReplaced()
        XCTAssertNil(model.current)
        XCTAssertEqual(phone.retired, [downloaded])
        XCTAssertThrowsError(try model.renderer { Rendered($0) })
    }

    func testTheSameFilesKeepTheirRendererAndNewFilesGetANewOne() throws {
        let phone = Phone()
        phone.model = downloaded
        let model = follower(phone)
        var builds = 0
        let first = try model.renderer { builds += 1; return Rendered($0) }
        XCTAssertTrue(try model.renderer { builds += 1; return Rendered($0) } === first)
        XCTAssertEqual(builds, 1)

        let update = SupertonicAssetLocation(rootURL: URL(fileURLWithPath: "/voices/supertonic-3-int8/2"))
        phone.model = update
        XCTAssertEqual(try model.renderer { builds += 1; return Rendered($0) }.location, update)
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(phone.retired, [downloaded])
    }

    func testThePhonesConditionStillDecidesOnceTheModelIsThere() {
        let phone = Phone()
        phone.model = downloaded
        XCTAssertFalse(follower(phone).renderingAllowed(when: { false })(), "a hot phone still hands over to Kitten")
    }

    // Finding 2: saved audio's identity without the model files equals the one hashed from them.
    func testThePinnedIdentityEqualsTheOneHashedFromTheFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "supertonic-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = SupertonicAssetLocation(rootURL: root)
        try FileManager.default.createDirectory(at: assets.onnxDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets.voiceStylesDirectoryURL, withIntermediateDirectories: true)
        try Data("graph".utf8).write(to: assets.onnxDirectoryURL.appending(path: "vocoder.onnx"))
        try Data("notice".utf8).write(to: assets.onnxDirectoryURL.appending(path: "MODIFIED.txt"))
        try Data("{}".utf8).write(to: assets.voiceStyleURL(for: .m2))

        let tree = try SupertonicModelHashes.onnxTreeHash(at: assets.onnxDirectoryURL)
        let style = try SupertonicModelHashes.fileHash(at: assets.voiceStyleURL(for: .m2))
        let fromFiles = SupertonicRenderSignature.make(onnxTreeHash: tree, voiceStyleHash: style)
        let manifest = """
        {"onnxTreeHash":"\(tree)","files":[{"path":"voice_styles/M2.json","sha256":"\(style)"}]}
        """
        let pinned = try JSONDecoder().decode(SupertonicModelHashes.self, from: Data(manifest.utf8))
        XCTAssertEqual(SupertonicRenderSignature.make(pinnedBy: pinned, voice: .m2), fromFiles)
        XCTAssertNil(SupertonicRenderSignature.make(pinnedBy: pinned, voice: .f2), "a voice the manifest doesn't pin")
    }

    // Finding 2: the app's manifest pins the tree hash and every voice style, so saved audio plays before a download.
    func testTheAppsManifestPinsTheTreeHashAndEveryVoiceStyle() throws {
        let data = try TestInputs.data(.supertonicResources, "asset-manifest.json")
        let pinned = try JSONDecoder().decode(SupertonicModelHashes.self, from: data)
        XCTAssertEqual(pinned.onnxTreeHash?.count, 64)
        for voice in SupertonicVoiceID.allCases {
            XCTAssertNotNil(SupertonicRenderSignature.make(pinnedBy: pinned, voice: voice), voice.rawValue)
        }
    }

    // Finding 2: the pinned tree hash is the downloaded model's. A wrong one would file new audio under another
    // identity and mark every chunk saved under the real one as superseded.
    func testThePinnedTreeHashIsTheDownloadedModels() throws {
        let model = try TestInputs.supertonicModel()
        let data = try TestInputs.data(.supertonicResources, "asset-manifest.json")
        let pinned = try JSONDecoder().decode(SupertonicModelHashes.self, from: data)
        let assets = SupertonicAssetLocation(rootURL: model)
        XCTAssertEqual(pinned.onnxTreeHash, try SupertonicModelHashes.onnxTreeHash(at: assets.onnxDirectoryURL))
        for voice in SupertonicVoiceID.allCases {
            XCTAssertEqual(pinned.voiceStyleHash(for: voice), try SupertonicModelHashes.fileHash(at: assets.voiceStyleURL(for: voice)))
        }
    }

    // Finding 4: the card names the download's size, the same number Settings › Voices shows.
    func testTheCardsSizeComesFromTheShippedCatalogSnapshot() throws {
        let snapshot = try TestInputs.data(.voiceCatalogSnapshot, "catalog-snapshot.json")
        let bytes = try XCTUnwrap(SupertonicDownloadNoticePolicy.downloadByteCount(catalogSnapshot: snapshot, voiceId: "supertonic-3-int8"))
        XCTAssertGreaterThan(bytes, 100_000_000)
        XCTAssertLessThan(bytes, 200_000_000)
        XCTAssertNil(SupertonicDownloadNoticePolicy.downloadByteCount(catalogSnapshot: snapshot, voiceId: "nope"))
    }
}
