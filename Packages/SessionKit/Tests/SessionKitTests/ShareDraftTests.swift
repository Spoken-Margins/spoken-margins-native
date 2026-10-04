import Foundation
@testable import SessionKit
import SessionKitSharing
import XCTest
#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox
#endif

/// The Send sheet's defaults and its Includes line (#785), and that a packet built from them
/// still imports in the last shipped build.
final class ShareDraftTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Moments

    func testFromAMarginOnlyThatOneGoes() {
        let draft = ShareDraft(scope: .margin(id: "b"), candidates: [margin("a"), margin("b", starred: true), margin("c")])
        XCTAssertEqual(draft.selection, .thisOne)
        XCTAssertEqual(draft.moments.map(\.marginID), ["b"])
    }

    func testFromAnItemTheStarredOnesGoWhenAnyAreStarred() {
        let draft = ShareDraft(scope: .item, candidates: [margin("a"), margin("b", starred: true), margin("c", starred: true)])
        XCTAssertEqual(draft.selection, .starred)
        XCTAssertEqual(draft.moments.map(\.marginID), ["b", "c"])
    }

    func testFromAnItemAllGoWhenNoneAreStarred() {
        let candidates = [margin("a"), margin("b"), margin("deleted", status: "deleted"), margin("reply", target: .assistantTurn)]
        let draft = ShareDraft(scope: .item, candidates: candidates)
        XCTAssertEqual(draft.selection, .all)
        XCTAssertEqual(draft.moments.map(\.marginID), ["a", "b"], "only active Margins on the item itself, as today")
    }

    // MARK: Voice

    func testVoiceIsCleanedWhenThereIsOneThenOriginalThenText() {
        let draft = ShareDraft(
            scope: .item, candidates: [margin("cleaned"), margin("original"), margin("text")],
            audio: ["cleaned": .originalAndCleaned, "original": .original]
        )
        XCTAssertEqual(draft.moments.map(\.voice), [.cleaned, .original, .textOnly])
        XCTAssertEqual(ShareDraft.defaultVoice(for: .none), .textOnly)
    }

    func testAMissingFileFallsBackRatherThanFailing() {
        let moment = ShareDraft(scope: .item, candidates: [margin("a")], audio: ["a": .originalAndCleaned]).moments[0]
        let original = URL(fileURLWithPath: "/tmp/original.m4a")
        guard case .originalAudio(let url, 4_000) = moment.representation(originalURL: original, originalDurationMs: 4_000, cleanedURL: nil) else {
            return XCTFail("expected the original when the cleaned file is gone")
        }
        XCTAssertEqual(url, original)
        guard case .textOnly = moment.representation(originalURL: nil, originalDurationMs: nil, cleanedURL: nil) else {
            return XCTFail("expected text with no files")
        }
    }

    func testSettledVoicesKeepTheIncludesLineTrueToWhatGoes() {
        var draft = ShareDraft(scope: .item, candidates: [margin("a")], audio: ["a": .originalAndCleaned])
        XCTAssertEqual(draft.includesLine, "Your voice, 1 short quote")
        draft.settleVoices([:])
        XCTAssertEqual(draft.moments.map(\.voice), [.textOnly])
        XCTAssertEqual(draft.includesLine, "Your words, 1 short quote", "with no files left the packet holds only text")

        var withOriginal = ShareDraft(scope: .item, candidates: [margin("a")], audio: ["a": .originalAndCleaned])
        withOriginal.settleVoices(["a": .init(originalURL: URL(fileURLWithPath: "/tmp/o.m4a"), originalDurationMs: 4_000)])
        XCTAssertEqual(withOriginal.moments.map(\.voice), [.original])
        XCTAssertEqual(withOriginal.includesLine, "Your voice, 1 short quote")
    }

    // MARK: Name and link

    func testARememberedNameIsUsedAndAMissingOneIsAskedForOnce() {
        let named = ShareDraft(scope: .item, candidates: [margin("a")], savedSenderName: "  Cole ")
        XCTAssertEqual(named.senderName, "Cole")
        XCTAssertFalse(named.needsSenderName)
        for saved in [nil, "", "   "] {
            let unnamed = ShareDraft(scope: .item, candidates: [margin("a")], savedSenderName: saved)
            XCTAssertNil(unnamed.senderName)
            XCTAssertTrue(unnamed.needsSenderName)
        }
    }

    func testAPrivateFeedLinkIsNeverIncluded() {
        let patreon = "https://c10.patreonusercontent.com/4/patreon-media/p/post/98765/a1/episode.mp3?token-hash=abc123"
        XCTAssertNil(ShareDraft(scope: .item, candidates: [margin("a")], itemLink: patreon).itemLink)
        let substack = "https://api.substack.com/feed/podcast/424242/private/5b2d8e0c9a7f4e1d8c3b6a5f2e9d0c7b.rss"
        XCTAssertNil(ShareDraft(scope: .item, candidates: [margin("a")], itemLink: substack).itemLink)
        let open = "https://example.com/podcast/episode-12"
        XCTAssertEqual(ShareDraft(scope: .item, candidates: [margin("a")], itemLink: open).itemLink, open)
    }

    // MARK: Includes

    func testIncludesLineForOneMarginWithVoice() {
        let draft = ShareDraft(scope: .margin(id: "a"), candidates: [margin("a")], audio: ["a": .original])
        XCTAssertEqual(draft.includesLine, "Your voice, 1 short quote")
    }

    func testIncludesLineForThreeTextOnlyMargins() {
        let draft = ShareDraft(scope: .item, candidates: [margin("a"), margin("b"), margin("c")])
        XCTAssertEqual(draft.includesLine, "Your words, 3 short quotes")
    }

    func testIncludesLineNamesMatchingDataOnlyWhileItGoes() {
        var draft = ShareDraft(scope: .item, candidates: [margin("a"), margin("b", before: "", after: "")],
                               audio: ["a": .originalAndCleaned], hasMatchingData: true)
        XCTAssertTrue(draft.includesMatchingData, "on by default")
        XCTAssertEqual(draft.includesLine, "Your voice, 1 short quote, matching data")
        draft.includesMatchingData = false
        XCTAssertEqual(draft.includesLine, "Your voice, 1 short quote")
        XCTAssertFalse(ShareDraft(scope: .item, candidates: [margin("a")]).includesMatchingData, "nothing to include")
        XCTAssertFalse(ShareDraft(scope: .item, candidates: [margin("a")]).includesLine.contains("matching"))
    }

    // MARK: Build 29

    func testAPacketFromTheDefaultsImportsInTheShippedBuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareDraftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("original.m4a")
        let cleanedURL = root.appendingPathComponent("cleaned.m4a")
        try writeSilentM4A(to: originalURL)
        try writeSilentM4A(to: cleanedURL)

        let margins = [margin("cleaned", ms: 60_000), margin("original", ms: 120_000), margin("text", ms: 180_000)]
        let draft = ShareDraft(
            scope: .item, candidates: margins,
            audio: ["cleaned": .originalAndCleaned, "original": .original],
            savedSenderName: "Cole", itemLink: "https://example.com/episodes/one"
        )
        let selections = try draft.moments.enumerated().map { index, moment -> ReviewedInterjectionSelection in
            let margin = try XCTUnwrap(margins.first { $0.id == moment.marginID })
            let cleaned = moment.voice == .cleaned ? cleanedURL : nil
            let revision = InterjectionShareRevision(
                id: "revision-\(margin.id)", interjectionId: margin.id, itemId: "item", sessionId: "session",
                createdAt: fixedDate, approvedTranscript: "A thought about \(margin.id).",
                cleanedAudioPath: cleaned?.path, cleanedAudioDurationMs: cleaned == nil ? nil : 100,
                anchorBefore: moment.quote.before, anchorAfter: moment.quote.after, status: .senderApproved
            )
            return ReviewedInterjectionSelection(
                packageScopedId: String(format: "margin-%03d", index + 1),
                revision: revision,
                anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: margin.anchor.mediaTimeMs),
                representation: moment.representation(
                    originalURL: moment.voice == .textOnly ? nil : originalURL, originalDurationMs: 100, cleanedURL: cleaned
                )
            )
        }
        let item = SharedItemIdentity(
            itemType: .podcast, canonicalURL: draft.itemLink, originalURL: draft.itemLink, title: "Episode One",
            showTitle: "Example Show", episodeGUID: "episode-one", durationMs: 3_600_000
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "share-draft-defaults", createdAt: fixedDate, item: item, itemTransportSelection: .reference,
            selections: selections, senderDisplayLabel: draft.senderName
        )
        XCTAssertEqual(
            prepared.manifest.assets.map(\.role).sorted(),
            [SpokenMarginsAssetRole.cleanedVoice, SpokenMarginsAssetRole.originalVoice].sorted()
        )
        let packetURL = root.appendingPathComponent("defaults.spokenmargins")
        let manifest = try exportPacket(prepared, to: packetURL)
        XCTAssertEqual(manifest.senderDisplayLabel, "Cole")
        let verified = try SpokenMarginsPackageArchive.read(from: packetURL, extractingAssetsTo: root.appendingPathComponent("assets"))
        XCTAssertEqual(verified.commentaryLayers.flatMap(\.interjections).count, 3)
    }

    // MARK: Fixtures

    private func margin(
        _ id: String, starred: Bool = false, status: String = "active", target: InterjectionTargetType = .item,
        ms: Int? = nil, before: String = "Before the moment.", after: String = "After the moment."
    ) -> Interjection {
        var margin = Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: target, targetId: "item",
            createdAt: fixedDate, roughPercent: 10,
            anchor: Anchor(anchorType: ms == nil ? .text : .media, startChar: 0, endChar: 0,
                           anchorBefore: before, anchorAfter: after, mediaTimeMs: ms),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil,
            cleanedTranscript: nil, displayText: "A Margin", status: status
        )
        margin.isStarredForSharing = starred ? true : nil
        return margin
    }

    private func writeSilentM4A(to url: URL) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 10)))
        buffer.frameLength = buffer.frameCapacity
        try audioFile.write(from: buffer)
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }
}
