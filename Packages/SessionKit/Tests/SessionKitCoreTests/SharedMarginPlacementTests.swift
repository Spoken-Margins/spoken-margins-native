import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #872: shared Margins said "unresolved" while the app was still placing them, after Download Again
/// reset them for the new edition. These tests cover the state mapping and the reset on a real store.
final class SharedMarginPlacementTests: XCTestCase {
    private let placed = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 45_000)
    private let reset = ImportedAnchorResolution(evidenceClass: .unresolved)

    private func running(previous: [String: ImportedAnchorResolution] = [:]) -> SharedMarginPlacementPasses.Pass? {
        var passes = SharedMarginPlacementPasses()
        passes.begin(.matching, itemId: "item", previous: previous)
        return passes.pass(itemId: "item")
    }

    func testPendingOrRunningPassReadsAsPlacingAndOnlyAFinishedPassAsNotMatched() {
        // Pending layer with a pass running: placing, never unresolved.
        let first = SharedMarginPlacementStatus(resolution: reset, marginId: "a", layerStatus: .pending, pass: running())
        XCTAssertEqual(first, .placing(previousMediaTimeMs: nil))
        XCTAssertEqual(first.positionDescription, "Placing in your copy…")
        XCTAssertEqual(first.label, "Placing")
        // Pending layer, nothing running yet (the episode isn't downloaded): not placed yet, not failed.
        let waiting = SharedMarginPlacementStatus(resolution: reset, marginId: "a", layerStatus: .pending, pass: nil)
        XCTAssertEqual(waiting, .notPlacedYet)
        XCTAssertEqual(waiting.positionDescription, "Not placed yet")
        // A finished pass that couldn't place it: the resolution's own wording ("unresolved", "not matched").
        for status in [ImportedSourceResolutionStatus.contextOnly, .ambiguous, .unavailable, .resolved] {
            let finished = SharedMarginPlacementStatus(resolution: reset, marginId: "a", layerStatus: status, pass: nil)
            XCTAssertEqual(finished, .settled, "\(status)")
            XCTAssertNil(finished.positionDescription)
            XCTAssertNil(finished.label)
        }
        // A rerun on the same edition leaves placed Margins placed and keeps working on the rest.
        XCTAssertEqual(SharedMarginPlacementStatus(resolution: placed, marginId: "a", layerStatus: .contextOnly,
                                                   pass: running()), .settled)
        XCTAssertEqual(SharedMarginPlacementStatus(resolution: reset, marginId: "b", layerStatus: .contextOnly,
                                                   pass: running()), .placing(previousMediaTimeMs: nil))
        let ambiguous = ImportedAnchorResolution(evidenceClass: .ambiguous, localMediaTimeMs: 9_000, isAmbiguous: true)
        XCTAssertEqual(SharedMarginPlacementStatus(resolution: ambiguous, marginId: "c", layerStatus: .ambiguous,
                                                   pass: running()), .placing(previousMediaTimeMs: nil))
    }

    func testPassKeepsThePositionsMarginsHadBeforeTheReset() {
        var passes = SharedMarginPlacementPasses()
        passes.begin(.transcript, itemId: "item")
        passes.begin(.matching, itemId: "item", previous: ["a": placed, "b": reset])
        // A second pass scheduled after the reset sees reset values; it must not forget the old position.
        passes.begin(.matching, itemId: "item", previous: ["a": reset])
        XCTAssertEqual(passes.pass(itemId: "item")?.previousMediaTimeMs, ["a": 45_000])
        XCTAssertNil(passes.pass(itemId: "other"))
        XCTAssertNil(passes.pass(itemId: nil))
        passes.end(.matching, itemId: "item")
        XCTAssertNotNil(passes.pass(itemId: "item"), "the transcript pass is still placing Margins")
        passes.end(.transcript, itemId: "item")
        XCTAssertNil(passes.pass(itemId: "item"))
        passes.end(.matching, itemId: "item")
        XCTAssertEqual(passes, SharedMarginPlacementPasses())
    }

    func testDownloadAgainShowsOldPlacementsAsPlacingAgainUntilThePassWritesResults() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        var layer = ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "package-digest",
            packageId: "package", itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
            importedAt: Date(), sourceResolutionStatus: .resolved, isEnabled: true,
            resolvedRecipientEditionSHA256: "old")
        try store.saveImportedCommentaryLayer(layer)
        var note = ImportedCommentaryInterjection(id: "note", layerId: layer.id, packageScopedId: "note",
            createdAt: Date(), anchorEvidence: PortableAnchorEvidence(anchorType: .media),
            approvedTranscript: "Preserve my words", resolution: placed)
        try store.saveImportedCommentaryInterjection(note)

        // The app records the pass with what the Margins showed, then resets them for the new edition.
        var passes = SharedMarginPlacementPasses()
        passes.begin(.matching, itemId: "item", previous: [note.id: note.resolution])
        try store.invalidateImportedPodcastPlacements(itemId: "item", editionSHA256: "new")

        layer = try XCTUnwrap(store.loadImportedCommentaryLayers(itemId: "item").first)
        note = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: layer.id).first)
        XCTAssertEqual(layer.sourceResolutionStatus, .pending)
        XCTAssertFalse(SharedMarginPlacementStatus.isPlaced(note.resolution), "an old edition's time must not play")
        let during = SharedMarginPlacementStatus(resolution: note.resolution, marginId: note.id,
                                                 layerStatus: layer.sourceResolutionStatus, pass: passes.pass(itemId: "item"))
        XCTAssertEqual(during, .placing(previousMediaTimeMs: 45_000))
        XCTAssertEqual(during.positionDescription, "Placing again · was 0:45")
        XCTAssertEqual(during.previousMediaTimeMs, 45_000)

        // The pass writes its results and ends: the new placement shows.
        layer.sourceResolutionStatus = .resolved
        layer.resolvedRecipientEditionSHA256 = "new"
        try store.saveImportedCommentaryLayer(layer)
        note.resolution = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 52_000)
        try store.saveImportedCommentaryInterjection(note)
        passes.end(.matching, itemId: "item")
        let after = SharedMarginPlacementStatus(resolution: note.resolution, marginId: note.id,
                                                layerStatus: layer.sourceResolutionStatus, pass: passes.pass(itemId: "item"))
        XCTAssertEqual(after, .settled)
        XCTAssertNil(after.previousMediaTimeMs)

        // Same edition again: nothing is reset.
        try store.invalidateImportedPodcastPlacements(itemId: "item", editionSHA256: "new")
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: layer.id).first?.resolution, note.resolution)
    }

    /// The owner's phone check on Build 30 (2026-10-07) imported the Hollywood packet, exported on Build 29 with
    /// no fingerprints and no text context: each Margin carries only the sender's clock time. The pass finished
    /// at once (`complete:0/1`) and the screen said "unresolved", which reads as a failure. These Margins can't be
    /// placed on any copy, so the screen should say so, and not "Placing" or "Position not matched".
    func testAMarginSentWithoutAPositionSaysSoWhateverThePassIsDoing() {
        let layerStates: [ImportedSourceResolutionStatus] = [.pending, .contextOnly, .ambiguous, .unavailable, .resolved]
        for layerStatus in layerStates {
            for pass in [nil, running()] {
                let status = SharedMarginPlacementStatus(resolution: reset, marginId: "a", layerStatus: layerStatus,
                                                         pass: pass, hasPositionEvidence: false)
                XCTAssertEqual(status, .noPositionSent, "\(layerStatus) pass:\(pass != nil)")
                XCTAssertEqual(status.positionDescription, "Sent without a position")
                XCTAssertEqual(status.label, "No position sent")
                XCTAssertNil(status.previousMediaTimeMs)
            }
        }
        // The same Margin with something to match on keeps the pass-based wording.
        XCTAssertEqual(SharedMarginPlacementStatus(resolution: reset, marginId: "a", layerStatus: .contextOnly,
                                                   pass: nil, hasPositionEvidence: true), .settled)
        XCTAssertEqual(SharedMarginPlacementStatus(resolution: reset, marginId: "a", layerStatus: .pending,
                                                   pass: running(), hasPositionEvidence: true), .placing(previousMediaTimeMs: nil))
        // A placed Margin is placed, whatever the packet carried (an exact-edition match needs no fingerprints).
        XCTAssertEqual(SharedMarginPlacementStatus(resolution: placed, marginId: "a", layerStatus: .resolved,
                                                   pass: nil, hasPositionEvidence: false), .settled)
        // One that held a position before Download Again reset it is being placed again.
        XCTAssertEqual(SharedMarginPlacementStatus(resolution: reset, marginId: "a", layerStatus: .pending,
                                                   pass: running(previous: ["a": placed]), hasPositionEvidence: false),
                       .placing(previousMediaTimeMs: 45_000))
        // An ambiguous result is a position to review, not an absent one.
        let ambiguous = ImportedAnchorResolution(evidenceClass: .ambiguous, localMediaTimeMs: 9_000, isAmbiguous: true)
        XCTAssertEqual(SharedMarginPlacementStatus(resolution: ambiguous, marginId: "c", layerStatus: .ambiguous,
                                                   pass: nil, hasPositionEvidence: false), .settled)
    }

    func testOnlyAPodcastMarginWithNothingToMatchOnCountsAsSentWithoutAPosition() throws {
        func layer(_ type: SharedItemType, digest: String? = nil) -> ImportedCommentaryLayer {
            ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "d", packageId: "p",
                itemIdentity: SharedItemIdentity(itemType: type, title: "Episode", exactEditionSHA256: digest),
                importedAt: Date(), sourceResolutionStatus: .pending, isEnabled: true)
        }
        func note(_ anchor: PortableAnchorEvidence, fingerprints: [ImportedPodcastAnchorEvidence]? = nil,
                  resolution: ImportedAnchorResolution? = nil) -> ImportedCommentaryInterjection {
            ImportedCommentaryInterjection(id: "n", layerId: "layer", packageScopedId: "n", createdAt: Date(),
                anchorEvidence: anchor, approvedTranscript: "Words", podcastAnchorEvidence: fingerprints,
                resolution: resolution ?? reset)
        }
        let bare = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 134_000, roughPercent: 4)
        // The Hollywood packet's Margins: a media time and a rough percent, nothing else.
        XCTAssertFalse(note(bare).carriesPositionEvidence(in: layer(.podcast)))
        // Each thing a packet can give a Margin to find its spot by.
        let declared = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 134_000, machineEvidenceAssetIds: ["pre"])
        XCTAssertTrue(note(declared).carriesPositionEvidence(in: layer(.podcast)))
        let words = PortableAnchorEvidence(anchorType: .media, prefix: "and then the studio head said we should",
                                           mediaTimeMs: 134_000)
        XCTAssertTrue(note(words).carriesPositionEvidence(in: layer(.podcast)))
        XCTAssertTrue(note(bare).carriesPositionEvidence(in: layer(.podcast, digest: String(repeating: "a", count: 64))),
                      "the sender's exact file can place a bare time")
        XCTAssertTrue(note(bare, resolution: placed).carriesPositionEvidence(in: layer(.podcast)))
        // Five words are too few to find a place by; punctuation and spaces aren't words.
        let short = PortableAnchorEvidence(anchorType: .media, prefix: "one two three four, five —", suffix: " ", mediaTimeMs: 1)
        XCTAssertFalse(short.hasUsableTextContext)
        XCTAssertTrue(PortableAnchorEvidence(anchorType: .media, prefix: "one two three four five six").hasUsableTextContext)
        XCTAssertTrue(PortableAnchorEvidence(anchorType: .media, suffix: "it's 3 o'clock, said José, again").hasUsableTextContext)
        // Articles are placed by their text, not by fingerprints; nothing here applies to them.
        XCTAssertTrue(note(PortableAnchorEvidence(anchorType: .text, startChar: 3, endChar: 9))
            .carriesPositionEvidence(in: layer(.text)))
    }

    func testSummaryCountsWhatAPassDidWithEachMargin() {
        var summary = SharedMarginPlacementSummary()
        XCTAssertEqual(summary.diagnosticValue, "margins:0 placed:0 ambiguous:0 notFound:0 noPositionSent:0")
        summary.add(placed, hasPositionEvidence: true)
        summary.add(placed, hasPositionEvidence: false)
        summary.add(.init(evidenceClass: .ambiguous, localMediaTimeMs: 9_000, isAmbiguous: true), hasPositionEvidence: true)
        summary.add(.init(evidenceClass: .absentFromRecipientEdition), hasPositionEvidence: true)
        summary.add(reset, hasPositionEvidence: false)
        summary.add(reset, hasPositionEvidence: false)
        XCTAssertEqual(summary.diagnosticValue, "margins:6 placed:2 ambiguous:1 notFound:1 noPositionSent:2")
    }

    func testPlacedMatchesThePlaybackRuleItReplaces() {
        let inline: Set<AnchorResolutionEvidenceClass> = [.exactEdition, .transcriptVerified, .acousticVerified,
            .fused, .mapInterpolated, .timestampFallback, .recipientConfirmed]
        let text: Set<AnchorResolutionEvidenceClass> = [.articleTextVerified, .exactEdition, .recipientConfirmed]
        let all: [AnchorResolutionEvidenceClass] = [.exactEdition, .articleTextVerified, .transcriptVerified,
            .acousticVerified, .fused, .mapInterpolated, .timestampFallback, .recipientConfirmed, .ambiguous,
            .absentFromRecipientEdition, .unresolved]
        for evidence in all {
            XCTAssertEqual(SharedMarginPlacementStatus.isPlaced(.init(evidenceClass: evidence, localMediaTimeMs: 1_000)),
                           inline.contains(evidence), "media \(evidence)")
            XCTAssertEqual(SharedMarginPlacementStatus.isPlaced(.init(evidenceClass: evidence, localStartChar: 10)),
                           text.contains(evidence), "text \(evidence)")
            XCTAssertFalse(SharedMarginPlacementStatus.isPlaced(.init(evidenceClass: evidence)), "none \(evidence)")
            XCTAssertFalse(SharedMarginPlacementStatus.isPlaced(.init(evidenceClass: evidence, localMediaTimeMs: 1_000,
                                                                      isAmbiguous: true)), "ambiguous \(evidence)")
        }
    }

    func testClockReadsLikeTheEpisodeTimes() {
        XCTAssertEqual(SharedMarginPlacementStatus.clock(0), "0:00")
        XCTAssertEqual(SharedMarginPlacementStatus.clock(-5), "0:00")
        XCTAssertEqual(SharedMarginPlacementStatus.clock(754_999), "12:34")
        XCTAssertEqual(SharedMarginPlacementStatus.clock(3_723_000), "1:02:03")
    }
}
