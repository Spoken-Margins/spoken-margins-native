import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

final class ExperiencePresentationTests: XCTestCase {
    @MainActor
    func testTimelineDistinguishesPublisherSceneOwnAndSharedMargins() throws {
        var item = ItemDetailState()
        item.id = "item"
        item.title = "Episode"
        item.mediaDurationMs = 100_000
        item.chapters = [Chapter(id: "chapter", title: "Publisher", startChar: 0, endChar: 1, percent: 0)]
        item.listeningMapScenes = [MediaTimelineChapter(id: "scene", title: "Generated", startMs: 20_000, transcriptSegmentId: "segment")]
        item.interjections = [interjection(id: "own", transcript: "My thought")]
        let layer = ImportedCommentaryLayer(id: "layer", itemId: item.id, packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"), importedAt: Date(),
            sourceResolutionStatus: .resolved, isEnabled: true)
        let margin = ImportedCommentaryInterjection(id: "own", layerId: layer.id, packageScopedId: "margin-1", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 30_000), approvedTranscript: "Someone else's thought",
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 30_000, confidence: 1))
        item.importedCommentaryLayers = [layer]
        item.importedCommentaryInterjections = [layer.id: [margin]]
        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: "session")
        XCTAssertEqual(Set(entries.map(\.provenance)), [.source, .listeningMap, .myMargin, .sharedMargin])
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "Imported and own IDs may collide")
        let shared = try XCTUnwrap(entries.first { $0.provenance == .sharedMargin })
        XCTAssertEqual(shared.position, 30)
        XCTAssertTrue(shared.detail.hasPrefix("Shared by "))
        guard case .sharedMargin(let row) = shared.action else { return XCTFail("Must open shared context, not seek a chapter") }
        XCTAssertEqual(row.interjection.approvedTranscript, "Someone else's thought")
    }

    /// #473: a reply sits directly under the Margin it answers at that Margin's place, indented, and says what it answers.
    @MainActor
    func testTimelineThreadsRepliesUnderTheSharedMarginTheyAnswer() throws {
        var item = ItemDetailState()
        item.id = "item"
        item.title = "Episode"
        item.mediaDurationMs = 100_000
        let layer = ImportedCommentaryLayer(id: "layer", itemId: item.id, packageDigest: "digest-a", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"), displayLabel: "Ana", importedAt: Date(),
            sourceResolutionStatus: .resolved, isEnabled: true)
        func shared(_ id: String, scoped: String, at ms: Int, offset: TimeInterval) -> ImportedCommentaryInterjection {
            ImportedCommentaryInterjection(id: id, layerId: layer.id, packageScopedId: scoped, createdAt: Date(timeIntervalSince1970: offset),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: ms), approvedTranscript: "Ana says \(id)",
                resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: ms, confidence: 1))
        }
        let parent = shared("parent", scoped: "m-1", at: 30_000, offset: 10)
        let elsewhere = shared("elsewhere", scoped: "m-2", at: 30_500, offset: 11)
        var reply = interjection(id: "my-reply", transcript: "My reply")
        reply.anchor = Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 34_000)
        reply.createdAt = Date(timeIntervalSince1970: 20)
        reply.replyTo = parent.replyLink(in: layer)
        item.interjections = [reply]
        item.importedCommentaryLayers = [layer]
        item.importedCommentaryInterjections = [layer.id: [elsewhere, parent]]

        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: "session")
            .filter { $0.reference != nil }

        XCTAssertEqual(entries.map(\.reference), [.imported("parent"), .local("my-reply"), .imported("elsewhere")],
                       "the reply follows its parent even though it was made later and the other Margin is closer in time")
        XCTAssertEqual(entries.map(\.depth), [0, 1, 0])
        XCTAssertEqual(entries[1].position, entries[0].position, "a reply sits at the place it answers")
        XCTAssertTrue(entries[1].detail.hasPrefix("Reply to Ana · "), entries[1].detail)
        XCTAssertFalse(entries[0].detail.contains("Reply to"))
    }

    /// The audit of #1570: the rail shows one session's Margins, so a reply to a Margin from an earlier session has
    /// nothing to indent under. It must stand at its own place and say what it answers, not hang under whatever
    /// entry happens to come before it.
    @MainActor
    func testTimelineShowsAReplyOnItsOwnWhenItsParentIsFromAnEarlierSession() throws {
        var item = ItemDetailState()
        item.id = "item"
        item.title = "Episode"
        item.mediaDurationMs = 100_000
        let layer = ImportedCommentaryLayer(id: "layer", itemId: item.id, packageDigest: "digest-a", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"), displayLabel: "Ana", importedAt: Date(),
            sourceResolutionStatus: .resolved, isEnabled: true)
        let sharedIdentity = MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "mine-1")
        var earlier = interjection(id: "earlier", sessionId: "old-session", transcript: "From last week")
        earlier.anchor = Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 10_000)
        earlier = earlier.recordingShare(as: sharedIdentity)
        var current = interjection(id: "current", transcript: "Today")
        current.anchor = Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 20_000)
        let reply = ImportedCommentaryInterjection(id: "ana-reply", layerId: layer.id, packageScopedId: "a-1",
            createdAt: Date(timeIntervalSince1970: 30), anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 50_000),
            approvedTranscript: "Ana answers last week", resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 50_000, confidence: 1),
            replyLinks: [MarginReplyLink.replying(to: sharedIdentity, parentConversationId: nil)])
        item.interjections = [earlier, current]
        item.importedCommentaryLayers = [layer]
        item.importedCommentaryInterjections = [layer.id: [reply]]

        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: "session").filter { $0.reference != nil }

        XCTAssertEqual(entries.map(\.reference), [.local("current"), .imported("ana-reply")], "the earlier session's Margin is not on this rail")
        let shown = try XCTUnwrap(entries.last)
        XCTAssertEqual(shown.depth, 0, "nothing on the rail to indent under")
        XCTAssertEqual(shown.position, 50, "it stays at its own place")
        XCTAssertTrue(shown.detail.hasPrefix("Reply to you · "), shown.detail)
    }

    @MainActor
    func testTimelineIncludesAllGeneratedScenesWithDistinctProvenanceAndSeekTargets() throws {
        var item = ItemDetailState()
        item.id = "episode"
        item.mediaDurationMs = 24 * 60_000
        item.mediaChapters = [MediaTimelineChapter(id: "publisher", title: "Publisher opening", startMs: 0, transcriptSegmentId: "publisher-segment")]
        item.listeningMapScenes = (0..<24).reversed().map { index in
            MediaTimelineChapter(id: "scene-\(index)", title: "Scene \(index + 1)", description: "Summary for scene \(index + 1)", startMs: index * 60_000, transcriptSegmentId: "segment-\(index)")
        }
        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil)
        let scenes = entries.filter { $0.provenance == .listeningMap }
        XCTAssertEqual(scenes.count, 24)
        XCTAssertEqual(scenes.map(\.title), (1...24).map { "Scene \($0)" })
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertEqual(entries.filter { $0.provenance == .source }.map(\.title), ["Publisher opening"])
        XCTAssertTrue(try XCTUnwrap(scenes.first).detail.contains("Generated scene · 0:00"))
        XCTAssertTrue(try XCTUnwrap(scenes.last).detail.contains("Summary for scene 24"))
        for (index, entry) in scenes.enumerated() {
            guard case .listeningMapScene(let scene) = entry.action else {
                return XCTFail("A generated scene must use its projected timestamp seek action")
            }
            XCTAssertEqual(scene.startMs, index * 60_000)
            XCTAssertEqual(entry.accessibilityIdentifier, "timeline.listeningMapScene.jump.scene-\(index)")
        }
        item.listeningMapScenes.removeAll()
        XCTAssertFalse(ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil).contains { $0.provenance == .listeningMap })
    }

    @MainActor
    func testTimelineKeepsEachAssistantMarginsInItsOwnCoordinateSpace() throws {
        var item = ItemDetailState()
        item.id = "item"
        item.title = "Source"
        var source = interjection(id: "source-note", transcript: "Source note")
        source.roughPercent = 70
        let first = ConversationTurn(id: "first", sessionId: "session", role: "assistant", turnType: "assistant_response", status: "complete", text: "First response", sourceInterjectionIds: [source.id])
        let second = ConversationTurn(id: "second", sessionId: "session", role: "assistant", turnType: "assistant_response", status: "complete", text: "Second response", sourceInterjectionIds: [])
        item.turns = [first, second]
        item.interjections = [source]
        for turn in item.turns {
            for percent in [99, 50, 25, 0] {
                var note = interjection(id: "\(turn.id)-\(percent)", transcript: "A response note")
                note.targetType = .assistantTurn
                note.targetId = turn.id
                note.roughPercent = percent
                item.interjections.append(note)
            }
        }
        // A colliding note ID in another session must not move the parent.
        var unrelated = source
        unrelated.sessionId = "other-session"
        unrelated.roughPercent = 5
        item.interjections.append(unrelated)
        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: "session")
        let ids = entries.map(\.id)
        XCTAssertEqual(ids, ["source.beginning", "session::source-note", "turn.first", "session::first-0", "session::first-25", "session::first-50", "session::first-99", "turn.second", "session::second-0", "session::second-25", "session::second-50", "session::second-99"])
        XCTAssertEqual(entries.first { $0.id == "turn.first" }?.position, 70)
        XCTAssertEqual(entries.first { $0.id == "session::first-25" }?.detail, "Within assistant response · 25%")
        item.turns.removeLast()
        let orphan = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: "session")
        XCTAssertTrue(try XCTUnwrap(orphan.first { $0.id == "session::second-25" }).detail.contains("Response unavailable"))
    }

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

    func testTimelinePullMeasuresShortContentFromItsInsetRestingPosition() {
        // A short player rests above zero because navigation owns the top inset.
        // The fixed dock also reserves space at the bottom of the scroll view.
        func distance(_ offset: CGFloat) -> CGFloat {
            TimelinePullPresentation.overscrollDistance(
                contentOffsetY: offset, contentHeight: 280,
                containerHeight: 874, bottomInset: 342, topInset: 116
            )
        }
        XCTAssertEqual(distance(-116), 0, "Resting short content must not open Timeline")
        XCTAssertEqual(distance(-45), 71)
        XCTAssertFalse(TimelinePullPresentation.shouldOpenTimeline(overscrollDistance: distance(-45)))
        XCTAssertEqual(distance(-44), 72)
        XCTAssertTrue(TimelinePullPresentation.shouldOpenTimeline(overscrollDistance: distance(-44)))
        XCTAssertEqual(TimelinePullPresentation.overscrollDistance(
            contentOffsetY: 700, contentHeight: 1_200,
            containerHeight: 874, bottomInset: 342, topInset: 116
        ), 32, "Long content must still reach its real bottom before the pull counts")
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

        // A hard cut at 80 characters ends mid-word and also avoids " margin…", so check where the excerpt stops.
        let normalized = longMargin.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        let kept = String(excerpt.dropLast())
        XCTAssertTrue(normalized.hasPrefix(kept), "The excerpt is the start of the Margin, whitespace collapsed.")
        XCTAssertEqual(normalized[normalized.index(normalized.startIndex, offsetBy: kept.count)], " ", "The excerpt ends where a word ends, not inside one.")
    }

    func testTimelineTextExcerptCutsAtWordBoundariesForNeighbouringInputs() {
        let cases: [(text: String, limit: Int, expected: String)] = [
            ("", 10, ""),
            ("short", 10, "short"),
            ("exactly ten", 11, "exactly ten"),
            ("aaaa bbbb cccc", 9, "aaaa bbbb…"),
            ("aaaa bbbb cccc", 10, "aaaa bbbb…"),
            ("aaaa bbbb cccc", 11, "aaaa bbbb…"),
            ("supercalifragilistic", 8, "supercal…"),
            ("  leading   and\ttrailing  ", 100, "leading and trailing"),
            ("caf\u{E9} \u{FC}ni\u{EF}code w\u{F6}rds", 9, "caf\u{E9}…"),
            ("cafe\u{301} \u{FC}ni\u{EF}code w\u{F6}rds", 9, "cafe\u{301}…")
        ]
        for (text, limit, expected) in cases {
            XCTAssertEqual(TimelineTextPresentation.excerpt(text, characterLimit: limit), expected, "\(text.debugDescription) at \(limit)")
        }
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

    func testContinueItemDoesNotSuggestNinetyNinePercentItems() throws {
        let activeNearComplete = libraryRow(
            id: "active-near-complete",
            title: "Near complete",
            progress: 99,
            lastListenedAt: Date(timeIntervalSince1970: 30)
        )
        let eligible = libraryRow(
            id: "eligible",
            title: "Eligible",
            progress: 98,
            lastListenedAt: Date(timeIntervalSince1970: 20)
        )

        let selected = try XCTUnwrap(
            LibraryPresentation.continueItem(
                in: [activeNearComplete, eligible],
                activeItemId: activeNearComplete.id
            )
        )

        XCTAssertEqual(selected.id, eligible.id)
        XCTAssertNil(
            LibraryPresentation.continueItem(
                in: [activeNearComplete],
                activeItemId: activeNearComplete.id
            )
        )
    }

    func testMarkedCompleteItemIsExcludedEvenWhenActiveSessionStillHasProgress() {
        let completed = LibraryItemRow(id: "done", title: "Done", status: "Ready", canDelete: true, hasContinuationSession: true, continuationProgressPercent: 35, isCompleted: true)
        XCTAssertNil(LibraryPresentation.continueItem(in: [completed], activeItemId: completed.id))
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

    func testWrittenMediaMarginHasNoAudioRepairOrPendingContextWork() {
        var note = interjection(transcript: "Keep my words.", audioStatus: "discarded", anchorContextStatus: .unavailable)
        note.captureKind = .written
        note.audioPath = nil
        note.anchor = Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 12_000)
        let written = MarginRow(interjection: note, itemTitle: "Source", sessionDate: nil)
        XCTAssertEqual(written.fullText, "Keep my words.")
        XCTAssertFalse(written.needsAttention)
        XCTAssertFalse(written.canPlayRecording)
        XCTAssertFalse(written.canRetryTranscription)
        note.captureKind = nil
        note.audioStatus = "missing"
        let legacy = MarginRow(interjection: note, itemTitle: "Source", sessionDate: nil)
        XCTAssertTrue(legacy.needsAttention, "An absent recording must still be distinguished from a written note")
    }

    func testACutShortMarginLeadsItsRowCaptionWithTheMarkUntilItIsCleared() {
        let note = interjection(transcript: "I was saying")
        let row = MarginRow(interjection: note, itemTitle: "Source", sessionDate: nil)
        let marks = CutShortMargins.shared
        defer { marks.clear(sessionId: note.sessionId, interjectionId: note.id) }
        XCTAssertEqual(row.captionDescription(), row.placeDescription(), "An ordinary Margin's caption is unchanged")
        marks.set(.interrupted, sessionId: note.sessionId, interjectionId: note.id)
        XCTAssertEqual(row.captionDescription(), "Cut short · \(row.placeDescription())")
        let waiting = MarginRow(interjection: interjection(transcriptionStatus: "failed"), itemTitle: "Source", sessionDate: nil)
        XCTAssertTrue(waiting.needsAttention)
        XCTAssertEqual(waiting.captionDescription(), "Cut short · \(waiting.attentionDescription)", "A Margin waiting on its transcript still shows the mark")
        marks.clear(sessionId: note.sessionId, interjectionId: note.id)
        XCTAssertEqual(row.captionDescription(), row.placeDescription())
        XCTAssertEqual(waiting.captionDescription(), waiting.attentionDescription)
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
        XCTAssertEqual(pending.preview, "Transcribing…")
        XCTAssertTrue(unavailableContext.needsAttention)
        XCTAssertEqual(unavailableContext.attentionDescription, "Context needs retry")
        XCTAssertTrue(missingRecording.needsAttention)
        XCTAssertEqual(missingRecording.attentionDescription, "Recording is unavailable")
    }

    /// The classifier lives in SessionKit with its own copy of the two seeded ids (#1019), so the
    /// ids this app seeds must be in it, or seeding would count as the listener adding a source.
    @MainActor
    func testTheClassifiersSeededIdsIncludeTheSampleAndTourThisAppSeeds() {
        XCTAssertTrue(OnboardingEvidenceClassifier.defaultSeededItemIDs.contains(Gate1AppModel.welcomeSampleItemId))
        XCTAssertTrue(OnboardingEvidenceClassifier.defaultSeededItemIDs.contains(Gate1AppModel.guidedOnboardingItemId))
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
}
