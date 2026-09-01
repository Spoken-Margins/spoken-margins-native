import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

final class SpokenMarginsPackageHandoffTests: XCTestCase {
    func testPackageHandoffPreservesExactBytesUntilConsumed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-package-handoff-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Shared Session.spokenmargins")
        let expected = Data([0x50, 0x4b, 0x03, 0x04, 0x00, 0xff, 0x10])
        try expected.write(to: source)
        let store = SpokenMarginsPackageHandoffStore(baseDirectory: root)

        let payloadID = try store.savePackage(from: source)

        XCTAssertEqual(try store.pendingPayloadIDs(), [payloadID])
        XCTAssertEqual(try Data(contentsOf: store.packageURL(payloadID: payloadID)), expected)
        try store.deletePackage(payloadID: payloadID)
        XCTAssertTrue(try store.pendingPayloadIDs().isEmpty)
    }

    func testPackageHandoffRejectsAFileWithoutTheOwnedExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-package-handoff-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("manifest.json")
        try Data("{}".utf8).write(to: source)
        let store = SpokenMarginsPackageHandoffStore(baseDirectory: root)

        XCTAssertThrowsError(try store.savePackage(from: source)) { error in
            XCTAssertEqual(
                error as? SpokenMarginsPackageHandoffStoreError,
                .invalidPackage("the file extension is not .spokenmargins")
            )
        }
    }

    @MainActor
    func testSystemShareDeclaresTheOwnedPackageType() {
        let url = URL(fileURLWithPath: "/tmp/shared-session.spokenmargins")
        let item = SpokenMarginsPackageActivityItem(packageURL: url)
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)

        XCTAssertEqual(
            item.activityViewController(controller, dataTypeIdentifierForActivityType: nil),
            SpokenMarginsPackageHandoffStore.uniformTypeIdentifier
        )
        XCTAssertEqual(
            item.activityViewController(controller, itemForActivityType: nil) as? URL,
            url
        )
    }

    @MainActor
    func testAppConsumesShareExtensionPackageIntoRecipientImportFlow() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.selectedItem.interjections = [Interjection(
            id: "margin-package-handoff",
            itemId: itemID,
            sessionId: "session-package-handoff",
            targetType: .item,
            targetId: itemID,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 25,
            anchor: Anchor(
                anchorType: .text,
                startChar: 0,
                endChar: 5,
                anchorBefore: "Before",
                anchorAfter: "After"
            ),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "A shared Margin.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )]
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        coordinator.send(.advanceToReview)
        coordinator.send(.buildRecipientPreview)
        for _ in 0..<100 where coordinator.snapshot.previewState != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        let packageURL = try XCTUnwrap(coordinator.verifiedShareFileURL)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-package-consumption-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpokenMarginsPackageHandoffStore(baseDirectory: root)
        _ = try store.savePackage(from: packageURL)

        try model.consumePendingSpokenMarginsPackageHandoffs(from: store)

        XCTAssertNotNil(model.spokenMarginsPackageImportReview)
        XCTAssertTrue(try store.pendingPayloadIDs().isEmpty)
        XCTAssertTrue(model.diagnostics.values.contains("opened"))
        model.cancelSpokenMarginsPackageImport()
    }
}
