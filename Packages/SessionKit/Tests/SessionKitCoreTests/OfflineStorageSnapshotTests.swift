import Foundation
import XCTest
@testable import SessionKit

/// The Storage screen's numbers (moved from the app-hosted ExperiencePresentationTests, #318).
final class OfflineStorageSnapshotTests: XCTestCase {
    func testOfflineStorageSnapshotAccountsForReservationsCategoriesAndProtection() {
        let now = Date(timeIntervalSince1970: 1_000)
        let assets = [
            offlineAsset(
                id: "prepared",
                category: .preparedAudio,
                byteCount: 400,
                isReproducible: true
            ),
            offlineAsset(
                id: "playing-podcast",
                category: .podcast,
                byteCount: 300,
                isReproducible: true,
                protections: [.activePlayback]
            ),
            offlineAsset(
                id: "audiobook",
                category: .audiobook,
                byteCount: 200,
                isReproducible: false
            ),
            offlineAsset(
                id: "margin",
                category: .interjection,
                byteCount: 100,
                isReproducible: false,
                protections: [.interjection]
            )
        ]
        let reservations = [
            OfflineStorageReservation(
                id: "active",
                ownerId: "render",
                byteCount: 350,
                createdAt: now.addingTimeInterval(-10),
                expiresAt: now.addingTimeInterval(10)
            ),
            OfflineStorageReservation(
                id: "expired",
                ownerId: "old-render",
                byteCount: 500,
                createdAt: now.addingTimeInterval(-20),
                expiresAt: now
            )
        ]

        let snapshot = OfflineStorageSnapshot.make(
            budget: OfflineStorageBudget(limitBytes: 700),
            assets: assets,
            reservations: reservations,
            now: now
        )

        XCTAssertEqual(snapshot.budgetBytes, 700)
        XCTAssertEqual(snapshot.usedBytes, 1_000)
        XCTAssertEqual(snapshot.reservedBytes, 350)
        XCTAssertEqual(snapshot.totalCommittedAndReservedBytes, 1_350)
        XCTAssertEqual(snapshot.protectedBytes, 600)
        XCTAssertEqual(snapshot.reproducibleBytes, 700)
        XCTAssertEqual(snapshot.clearableBytes, 400)
        XCTAssertEqual(snapshot.currentOverageBytes, 650)
        XCTAssertEqual(snapshot.residualOverageBytes, 250)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.category, $0.byteCount) }),
            [
                .preparedAudio: 400,
                .podcast: 300,
                .audiobook: 200,
                .interjection: 100
            ]
        )
    }

    func testAnEmptyLibraryGivesAnEmptySnapshotWithTheBudgetAndNoOverage() {
        let snapshot = OfflineStorageSnapshot.make(
            budget: OfflineStorageBudget(limitBytes: 5_000),
            assets: [],
            reservations: []
        )

        var expected = OfflineStorageSnapshot()
        expected.budgetBytes = 5_000
        XCTAssertEqual(snapshot, expected)
        XCTAssertEqual(OfflineStorageSnapshot().totalCommittedAndReservedBytes, 0)
    }

    func testUsageInsideTheBudgetHasNoOverageEvenWithReservations() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = OfflineStorageSnapshot.make(
            budget: OfflineStorageBudget(limitBytes: 1_000),
            assets: [offlineAsset(id: "a", category: .podcast, byteCount: 600, isReproducible: true)],
            reservations: [
                OfflineStorageReservation(
                    id: "r", ownerId: "render", byteCount: 400,
                    createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(1))
            ],
            now: now
        )

        XCTAssertEqual(snapshot.totalCommittedAndReservedBytes, 1_000)
        XCTAssertEqual(snapshot.currentOverageBytes, 0)
        XCTAssertEqual(snapshot.residualOverageBytes, 0)
    }

    func testCategoryRowsFollowTheCategoryOrderAndSumEachCategory() {
        // `.preparedAudio` (raw "prepared_audio") precedes `.audiobook` in `allCases` but sorts after it by
        // raw value, so a snapshot that sorts rows by raw value or by byte count fails here.
        let order = OfflineAssetCategory.allCases
        XCTAssertLessThan(order.firstIndex(of: .preparedAudio)!, order.firstIndex(of: .audiobook)!)
        XCTAssertGreaterThan(OfflineAssetCategory.preparedAudio.rawValue, OfflineAssetCategory.audiobook.rawValue)

        let snapshot = OfflineStorageSnapshot.make(
            budget: OfflineStorageBudget(limitBytes: 10_000),
            assets: [
                offlineAsset(id: "book", category: .audiobook, byteCount: 500, isReproducible: false),
                offlineAsset(id: "pa1", category: .preparedAudio, byteCount: 100, isReproducible: true),
                offlineAsset(id: "pa2", category: .preparedAudio, byteCount: 50, isReproducible: true),
                offlineAsset(id: "empty", category: .recording, byteCount: 0, isReproducible: false)
            ],
            reservations: []
        )

        XCTAssertEqual(snapshot.categories.map(\.category), [.preparedAudio, .audiobook])
        XCTAssertEqual(snapshot.categories.map(\.byteCount), [150, 500])
    }

    func testEveryCategoryHasAListenerFacingTitleAndTheRowIDIsTheRawValue() {
        for category in OfflineAssetCategory.allCases {
            let row = OfflineStorageCategoryRow(category: category, byteCount: 1)
            XCTAssertFalse(row.title.isEmpty, "\(category) has no title")
            XCTAssertEqual(row.id, category.rawValue)
        }
        XCTAssertEqual(OfflineStorageCategoryRow(category: .interjection, byteCount: 1).title, "Margins")
    }

    private func offlineAsset(
        id: String,
        category: OfflineAssetCategory,
        byteCount: Int64,
        isReproducible: Bool,
        protections: Set<OfflineProtectionReason> = []
    ) -> OwnedOfflineAsset {
        OwnedOfflineAsset(
            id: id,
            itemId: "item",
            category: category,
            relativePath: "Offline/\(id)",
            byteCount: byteCount,
            isReproducible: isReproducible,
            protections: protections,
            lastAccessedAt: Date(timeIntervalSince1970: 1),
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}
