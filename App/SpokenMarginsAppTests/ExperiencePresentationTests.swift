import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

final class ExperiencePresentationTests: XCTestCase {
    func testTimelinePullRequiresDeliberateBottomOverscroll() {
        XCTAssertEqual(
            TimelinePullPresentation.overscrollDistance(
                contentOffsetY: 540,
                contentHeight: 1_200,
                containerHeight: 640,
                bottomInset: 0
            ),
            0
        )
        XCTAssertEqual(
            TimelinePullPresentation.overscrollDistance(
                contentOffsetY: 650,
                contentHeight: 1_200,
                containerHeight: 640,
                bottomInset: 0
            ),
            90
        )
        XCTAssertEqual(
            TimelinePullPresentation.overscrollDistance(
                contentOffsetY: 0,
                contentHeight: 500,
                containerHeight: 640,
                bottomInset: 0
            ),
            0,
            "Unused viewport space is not overscroll"
        )
        XCTAssertFalse(TimelinePullPresentation.shouldOpenTimeline(overscrollDistance: 71))
        XCTAssertTrue(TimelinePullPresentation.shouldOpenTimeline(overscrollDistance: 72))
    }

    func testAddSourceStartsWithFourObjectRoutesAndKeepsFolderManagementSecondary() {
        XCTAssertEqual(
            AddSourcePresentation.primaryObjectRoutes,
            [.linkOrPodcast, .pastedText, .documentOrBook, .audiobook]
        )
        XCTAssertFalse(AddSourcePresentation.primaryObjectRoutes.contains(.quickFolder))
    }

    func testTimelineRailOrdersBySourcePositionThenProvenanceRank() {
        let keys = [
            TimelineRailSortKey(position: 60, rank: 0, id: "chapter-later"),
            TimelineRailSortKey(position: 25, rank: 2, id: "assistant"),
            TimelineRailSortKey(position: 25, rank: 1, id: "margin"),
            TimelineRailSortKey(position: 25, rank: 0, id: "chapter"),
            TimelineRailSortKey(position: 0, rank: 0, id: "beginning")
        ]

        XCTAssertEqual(
            keys.sorted().map(\.id),
            ["beginning", "chapter", "margin", "assistant", "chapter-later"]
        )
    }

    func testTimelineTextExcerptCollapsesWhitespaceAndBoundsLongMargins() {
        let longMargin = Array(repeating: "This is a deliberately long spoken margin", count: 20)
            .joined(separator: " \n\t")

        let excerpt = TimelineTextPresentation.excerpt(longMargin, characterLimit: 80)

        XCTAssertLessThanOrEqual(excerpt.count, 81)
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertFalse(excerpt.contains("\n"))
        XCTAssertFalse(excerpt.contains("\t"))
        XCTAssertFalse(excerpt.hasSuffix(" margin…"), "The excerpt should use the last complete word inside its limit.")
    }

    @MainActor
    func testItemDetailRetainsNestedCanonicalNavigation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-nested-navigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("library.sqlite")
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let item = Item(
            id: "nested-item",
            title: "Nested Book",
            mediaType: "epub",
            text: "Chapter one. Chapter two.",
            externalReference: "nested.epub",
            status: "Ready",
            externalReferenceType: "file"
        )
        let firstLocator = SourceLocator(
            documentId: "nested-document",
            spineItemId: "spine-1",
            segmentId: "segment-1",
            utf8Start: 0,
            utf8End: 13
        )
        let secondLocator = SourceLocator(
            documentId: "nested-document",
            spineItemId: "spine-2",
            segmentId: "segment-2",
            utf8Start: 13,
            utf8End: 25
        )
        let canonical = CanonicalSourcePackage(
            id: "canonical-nested-item",
            itemId: item.id,
            sourceDocumentId: "nested-document",
            format: .epub,
            title: item.title,
            navigation: [
                CanonicalNavigationNode(
                    id: "book",
                    title: "Nested Book",
                    children: [
                        CanonicalNavigationNode(
                            id: "part-one",
                            title: "Part One",
                            children: [
                                CanonicalNavigationNode(id: "chapter-one", title: "Chapter One", locator: firstLocator),
                                CanonicalNavigationNode(id: "chapter-two", title: "Chapter Two", locator: secondLocator)
                            ]
                        )
                    ]
                )
            ],
            segments: [
                SpeakableSegment(id: "segment-1", text: "Chapter one. ", locator: firstLocator),
                SpeakableSegment(id: "segment-2", text: "Chapter two.", locator: secondLocator)
            ]
        )
        try store.saveItem(item)
        try store.saveCanonicalSource(canonical)
        try store.saveListeningMap(XCTUnwrap(canonical.derivedListeningMap()))

        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.bootstrapLibraryIfNeeded()
        model.openItem(id: item.id)

        XCTAssertEqual(model.selectedItem.navigation, canonical.navigation)
        XCTAssertEqual(model.selectedItem.navigation.first?.children.first?.title, "Part One")
        XCTAssertEqual(
            model.selectedItem.navigation.first?.children.first?.children.map(\.title),
            ["Chapter One", "Chapter Two"]
        )
        XCTAssertEqual(model.selectedItem.chapters.map(\.id), ["chapter-one", "chapter-two"])
    }

    func testContinueItemPrefersTheActiveUnfinishedItem() throws {
        let active = libraryRow(
            id: "active",
            title: "Active",
            progress: 0,
            lastListenedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = libraryRow(
            id: "newer",
            title: "Newer",
            progress: 45,
            lastListenedAt: Date(timeIntervalSince1970: 100)
        )

        let selected = try XCTUnwrap(
            LibraryPresentation.continueItem(in: [newer, active], activeItemId: active.id)
        )

        XCTAssertEqual(selected.id, active.id)
    }

    func testContinueItemFallsBackToMostRecentlyListenedUnfinishedItem() throws {
        let older = libraryRow(
            id: "older",
            title: "Older",
            progress: 20,
            lastListenedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = libraryRow(
            id: "newer",
            title: "Newer",
            progress: 30,
            lastListenedAt: Date(timeIntervalSince1970: 20)
        )
        let completed = libraryRow(
            id: "completed",
            title: "Completed",
            progress: 100,
            lastListenedAt: Date(timeIntervalSince1970: 30)
        )
        let unplayed = libraryRow(
            id: "unplayed",
            title: "Unplayed",
            progress: 0,
            lastListenedAt: Date(timeIntervalSince1970: 40)
        )

        let selected = try XCTUnwrap(
            LibraryPresentation.continueItem(
                in: [older, completed, unplayed, newer],
                activeItemId: "missing"
            )
        )

        XCTAssertEqual(selected.id, newer.id)
    }

    func testContinueItemUsesIdentifierAsStableTieBreaker() throws {
        let sameDate = Date(timeIntervalSince1970: 100)
        let zulu = libraryRow(id: "zulu", title: "Zulu", progress: 10, lastListenedAt: sameDate)
        let alpha = libraryRow(id: "alpha", title: "Alpha", progress: 10, lastListenedAt: sameDate)

        let selected = try XCTUnwrap(
            LibraryPresentation.continueItem(in: [zulu, alpha], activeItemId: nil)
        )

        XCTAssertEqual(selected.id, alpha.id)
    }

    func testCompactItemsRemoveOnlyTheContinueItemIdentity() {
        let hero = libraryRow(id: "hero", title: "Shared Title", progress: 30)
        let sameTitle = libraryRow(id: "same-title", title: "Shared Title", progress: 20)
        let other = libraryRow(id: "other", title: "Other", progress: nil)

        let compact = LibraryPresentation.compactItems(
            [hero, sameTitle, hero, other],
            excluding: hero
        )

        XCTAssertEqual(compact.map(\.id), [sameTitle.id, other.id])
    }

    func testContinueItemIsNilWithoutAnEligibleUnfinishedItem() {
        let completed = libraryRow(id: "completed", title: "Completed", progress: 100)
        let unplayed = libraryRow(id: "unplayed", title: "Unplayed", progress: 0)
        let noSession = libraryRow(id: "none", title: "No Session", progress: nil)

        XCTAssertNil(
            LibraryPresentation.continueItem(
                in: [completed, unplayed, noSession],
                activeItemId: completed.id
            )
        )
        XCTAssertNil(LibraryPresentation.continueItem(in: [], activeItemId: nil))
    }

    func testPodcastDownloadStateDrivesTruthfulLibraryOfflinePresentation() {
        XCTAssertEqual(
            Gate1AppModel.libraryOfflineState(
                preparedState: nil,
                mediaSourceType: .remoteStream,
                podcastDownloadState: .availableOffline
            ),
            .readyOffline
        )
        XCTAssertEqual(
            Gate1AppModel.libraryOfflineState(
                preparedState: nil,
                mediaSourceType: .remoteStream,
                podcastDownloadState: .downloading
            ),
            .preparing
        )
        XCTAssertEqual(
            Gate1AppModel.libraryOfflineState(
                preparedState: nil,
                mediaSourceType: .remoteStream,
                podcastDownloadState: .streamingOnly
            ),
            .onlineOnly
        )
    }

    func testMarginRowIdentityComposesSessionAndInterjectionIDs() {
        let first = MarginRow(
            interjection: interjection(id: "margin", sessionId: "session-a"),
            itemTitle: "Item",
            sessionDate: nil
        )
        let second = MarginRow(
            interjection: interjection(id: "margin", sessionId: "session-b"),
            itemTitle: "Item",
            sessionDate: nil
        )

        XCTAssertEqual(first.id, "session-a::margin")
        XCTAssertEqual(second.id, "session-b::margin")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testMarginPreviewPrefersApprovedThenCleanedThenRawText() {
        let approved = marginRow(
            displayText: "  Approved wording  ",
            cleanedTranscript: "Cleaned wording",
            transcript: "Raw wording"
        )
        let cleaned = marginRow(
            displayText: " \n ",
            cleanedTranscript: "  Cleaned wording  ",
            transcript: "Raw wording"
        )
        let raw = marginRow(
            displayText: nil,
            cleanedTranscript: nil,
            transcript: "  Raw wording  "
        )

        XCTAssertEqual(approved.preview, "Approved wording")
        XCTAssertEqual(cleaned.preview, "Cleaned wording")
        XCTAssertEqual(raw.preview, "Raw wording")
    }

    func testMarginNeedsAttentionReflectsTranscriptionContextAndRecordingState() {
        let ready = marginRow(
            transcriptionStatus: "transcribed",
            audioStatus: "saved",
            anchorContextStatus: .ready
        )
        let pending = marginRow(
            transcriptionStatus: "pending",
            audioStatus: "saved",
            anchorContextStatus: .ready
        )
        let unavailableContext = marginRow(
            transcriptionStatus: "complete",
            audioStatus: "saved",
            anchorContextStatus: .unavailable
        )
        let missingRecording = marginRow(
            transcriptionStatus: "complete",
            audioStatus: "missing",
            anchorContextStatus: .ready
        )

        XCTAssertFalse(ready.needsAttention)
        XCTAssertEqual(ready.preview, "Audio Margin")
        XCTAssertTrue(pending.needsAttention)
        XCTAssertEqual(pending.preview, "Transcription is pending")
        XCTAssertTrue(unavailableContext.needsAttention)
        XCTAssertEqual(unavailableContext.attentionDescription, "Context needs retry")
        XCTAssertTrue(missingRecording.needsAttention)
        XCTAssertEqual(missingRecording.attentionDescription, "Recording is unavailable")
    }

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

    func testSeededOnboardingItemsDoNotCountAsUserSourceEvidence() {
        let welcome = item(
            id: "item-spoken-margins-overview",
            mediaType: "text",
            externalReferenceType: "url"
        )
        let guided = item(
            id: "guided-onboarding",
            mediaType: "guided_tour",
            externalReferenceType: "file"
        )

        let steps = OnboardingEvidenceClassifier.sourceSteps(items: [welcome, guided])

        XCTAssertTrue(steps.isEmpty)
    }

    func testUserOwnedSourcesProduceTypedOnboardingEvidence() {
        let pasted = item(id: "pasted", mediaType: "text", externalReferenceType: nil)
        let webpage = item(id: "webpage", mediaType: "text", externalReferenceType: "url")
        let file = item(id: "file", mediaType: "pdf", externalReferenceType: "file")

        XCTAssertEqual(
            OnboardingEvidenceClassifier.sourceSteps(items: [pasted]),
            [.addedOwnSource]
        )
        XCTAssertEqual(
            OnboardingEvidenceClassifier.sourceSteps(items: [webpage]),
            [.addedOwnSource, .addedFromSafari]
        )
        XCTAssertEqual(
            OnboardingEvidenceClassifier.sourceSteps(items: [file]),
            [.addedOwnSource, .addedFromFiles]
        )
    }

    private func libraryRow(
        id: String,
        title: String,
        progress: Int?,
        lastListenedAt: Date? = nil
    ) -> LibraryItemRow {
        LibraryItemRow(
            id: id,
            title: title,
            status: "Ready",
            canDelete: true,
            hasContinuationSession: progress != nil,
            continuationProgressPercent: progress,
            lastListenedAt: lastListenedAt
        )
    }

    private func marginRow(
        displayText: String? = nil,
        cleanedTranscript: String? = nil,
        transcript: String? = nil,
        transcriptionStatus: String = "transcribed",
        audioStatus: String = "saved",
        anchorContextStatus: AnchorContextStatus? = .ready
    ) -> MarginRow {
        MarginRow(
            interjection: interjection(
                displayText: displayText,
                cleanedTranscript: cleanedTranscript,
                transcript: transcript,
                transcriptionStatus: transcriptionStatus,
                audioStatus: audioStatus,
                anchorContextStatus: anchorContextStatus
            ),
            itemTitle: "Item",
            sessionDate: nil
        )
    }

    private func interjection(
        id: String = "margin",
        sessionId: String = "session",
        displayText: String? = nil,
        cleanedTranscript: String? = nil,
        transcript: String? = nil,
        transcriptionStatus: String = "transcribed",
        audioStatus: String = "saved",
        anchorContextStatus: AnchorContextStatus? = .ready
    ) -> Interjection {
        Interjection(
            id: id,
            itemId: "item",
            sessionId: sessionId,
            targetType: .item,
            targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 25,
            anchor: Anchor(
                anchorType: .text,
                startChar: 10,
                endChar: 20,
                anchorBefore: "Before",
                anchorAfter: "After"
            ),
            audioPath: "Margins/\(id).m4a",
            audioStatus: audioStatus,
            transcriptionStatus: transcriptionStatus,
            transcript: transcript,
            cleanedTranscript: cleanedTranscript,
            displayText: displayText,
            status: "active",
            anchorContextStatus: anchorContextStatus
        )
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

    private func item(
        id: String,
        mediaType: String,
        externalReferenceType: String?
    ) -> Item {
        Item(
            id: id,
            title: id,
            mediaType: mediaType,
            text: "Source text",
            externalReference: "source://\(id)",
            status: "ready",
            externalReferenceType: externalReferenceType
        )
    }
}
