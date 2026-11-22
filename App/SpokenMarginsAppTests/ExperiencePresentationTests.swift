import XCTest
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
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
        XCTAssertTrue(shared.detail.hasPrefix("From "))
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
        XCTAssertEqual(entries[1].cornerLabel, entries[0].cornerLabel, "and its corner reads that place, not its own (#3862)")
        XCTAssertNotEqual(entries[1].cornerLabel, "34%", "the reply was made at 34%, but the card stands at its parent's 30%")
        XCTAssertEqual(entries[1].spokenPosition, entries[0].spokenPosition)
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

    func testFilesTileAcceptsPacketsByTheExtensionThePacketArchiveWrites() {
        XCTAssertEqual(AddFromFilesPlan.packetExtension, SpokenMarginsPackageArchive.fileExtension)
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
        XCTAssertEqual(unavailableContext.attentionDescription, "Couldn't find the source words near this Margin")
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
