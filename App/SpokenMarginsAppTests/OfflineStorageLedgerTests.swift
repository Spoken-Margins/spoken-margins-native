import Foundation
import SessionKit
import XCTest
@testable import SpokenMarginsApp

final class OfflineStorageLedgerTests: XCTestCase {
    func testReservationPreventsWriterFromExceedingBudget() async throws {
        let fixture = try makeFixture(limit: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.ledger.reserve(ownerId: "first", byteCount: 8)
        do {
            _ = try await fixture.ledger.reserve(ownerId: "second", byteCount: 3)
            XCTFail("Expected insufficient space")
        } catch let error as OfflineStorageLedgerError {
            XCTAssertEqual(error, .insufficientSpace(requiredBytes: 3, availableBytes: 2))
        }
    }

    func testCommitRejectsOutputLargerThanReservation() async throws {
        let fixture = try makeFixture(limit: 100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reservation = try await fixture.ledger.reserve(ownerId: "writer", byteCount: 4)
        do {
            try await fixture.ledger.commit(
                reservationId: reservation.id,
                asset: OwnedOfflineAsset(id: "asset", category: .podcast, relativePath: "file", byteCount: 5, isReproducible: true)
            )
            XCTFail("Expected reservation overrun")
        } catch let error as OfflineStorageLedgerError {
            XCTAssertEqual(error, .reservationExceeded(reservedBytes: 4, actualBytes: 5))
        }
    }

    func testAdoptionIsIdempotentAndLedgerMatchesTrackedFiles() async throws {
        let fixture = try makeFixture(limit: 100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let podcast = fixture.root.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: podcast, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: podcast.appending(path: "episode.m4a"))

        try await fixture.ledger.adoptExistingAssets()
        try await fixture.ledger.adoptExistingAssets()

        let inventoryBytes = try await fixture.ledger.inventoryBytes()
        let trackedBytes = try await fixture.ledger.trackedFilesystemBytes()
        XCTAssertEqual(inventoryBytes, 4)
        XCTAssertEqual(trackedBytes, 4)
    }

    func testAdoptionToleratesHistoricalDuplicatePaths() async throws {
        let fixture = try makeFixture(limit: 100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let relativePath = "GuidedOnboarding/guided-onboarding-1.m4a"
        let audio = fixture.root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3, 4]).write(to: audio)
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "guided-legacy",
            category: .guidedTour,
            relativePath: relativePath,
            byteCount: 4,
            isReproducible: true
        ))
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "guided-current",
            category: .guidedTour,
            relativePath: relativePath,
            byteCount: 4,
            isReproducible: true
        ))

        try await fixture.ledger.adoptExistingAssets()

        XCTAssertEqual(try fixture.repository.loadOwnedOfflineAssets().count, 2)
    }

    func testLocalSourceImporterCoordinatesFileSizeAndCopy() async throws {
        let fixture = try makeFixture(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appending(path: "provider-source.epub")
        let destination = fixture.root.appending(path: "provider-copy.epub")
        let contents = Data("provider-backed bytes".utf8)
        try contents.write(to: source)
        let importer = LocalSourceImporter(
            repository: fixture.repository,
            ledger: fixture.ledger,
            applicationSupportDirectory: fixture.root
        )

        let size = try await importer.fileSize(source)
        try await importer.copySecurityScoped(source, to: destination)

        XCTAssertEqual(size, Int64(contents.count))
        XCTAssertEqual(try Data(contentsOf: destination), contents)
    }

    func testEPUBImporterRejectsNonFileURLBeforeLoading() async throws {
        let fixture = try makeFixture(limit: 1_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let importer = LocalSourceImporter(
            repository: fixture.repository,
            ledger: fixture.ledger,
            applicationSupportDirectory: fixture.root
        )

        do {
            _ = try await importer.importEPUB(from: XCTUnwrap(URL(string: "https://example.com/book.epub")))
            XCTFail("Expected non-file URL rejection")
        } catch let error as LocalSourceImportError {
            XCTAssertEqual(error, .unsupportedURL)
        }
    }

    func testBudgetUsesDecimalGigabytesMatchingSettingsLabel() {
        XCTAssertEqual(OfflineStorageBudget.bytesPerGigabyte, 1_000_000_000)
        XCTAssertEqual(OfflineStorageBudget().limitBytes, 5_000_000_000)
    }

    func testLoweredBudgetImmediatelyEvictsReproducibleAssets() async throws {
        let fixture = try makeFixture(limit: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audio = fixture.root.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 7).write(to: audio.appending(path: "episode.m4a"))
        try fixture.repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "episode",
            category: .podcast,
            relativePath: "PodcastAudio/episode.m4a",
            byteCount: 7,
            isReproducible: true
        ))

        let residual = try await fixture.ledger.enforceBudget()
        let inventory = try await fixture.ledger.inventoryBytes()

        XCTAssertEqual(residual, 0)
        XCTAssertEqual(inventory, 0)
    }

    private struct Fixture {
        let root: URL
        let repository: InMemorySessionRepository
        let ledger: OfflineStorageLedger
    }

    private func makeFixture(limit: Int64) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-ledger-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = InMemorySessionRepository()
        try repository.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: limit))
        return Fixture(
            root: root,
            repository: repository,
            ledger: OfflineStorageLedger(repository: repository, rootDirectory: root)
        )
    }

}
