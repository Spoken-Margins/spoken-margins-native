import Foundation
@testable import SessionKit
import SessionKitSharing
import XCTest
#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox
#endif

/// A voice Margin with no words shares with placeholder words in the web app's format (#3027, #3025), instead of
/// being left out of the packet.
final class SharedMarginPlaceholderTests: XCTestCase {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    /// 30 Oct 2026, 14:05 in Chicago.
    private var recorded: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 5))!
    }

    private func margin(
        transcript: String? = nil,
        cleaned: String? = nil,
        display: String? = nil,
        status: String = "failed",
        mediaTimeMs: Int? = 754_900,
        captureKind: InterjectionCaptureKind? = .audio,
        createdAt: Date? = nil
    ) -> Interjection {
        Interjection(
            id: "margin-\(UUID().uuidString)", itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: createdAt ?? recorded, roughPercent: 40,
            anchor: Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: 0, endChar: 0,
                           anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: mediaTimeMs),
            audioPath: captureKind == .written ? nil : "margins/voice.m4a", audioStatus: "saved",
            transcriptionStatus: status, transcript: transcript, cleanedTranscript: cleaned, displayText: display,
            status: "active", captureKind: captureKind
        )
    }

    private func placeholder(_ margin: Interjection, title: String? = "Episode 1 (example episode)", hasVoice: Bool = true) -> String? {
        SharedMarginPlaceholder.words(for: margin, itemTitle: title, hasVoice: hasVoice, timeZone: chicago)
    }

    // MARK: The format, matching Web/src/shared/placeholder.test.ts

    func testNamesTheMomentTheItemAndTheDayLikeTheWebApp() {
        XCTAssertEqual(placeholder(margin()), "Voice Margin at 12:34 in “Episode 1 (example episode)”, recorded 30 Oct 2026")
    }

    func testNeighbouringInputs() {
        let long = String(repeating: "A ", count: 200)
        let family = "👨‍👩‍👧‍👦"
        let rows: [(name: String, mediaTimeMs: Int?, title: String?, expected: String)] = [
            ("no title", 5_000, nil, "Voice Margin at 0:05, recorded 30 Oct 2026"),
            ("empty title", 5_000, "", "Voice Margin at 0:05, recorded 30 Oct 2026"),
            ("whitespace title", 5_000, "   \n\t ", "Voice Margin at 0:05, recorded 30 Oct 2026"),
            ("past an hour", 3_725_000, "Long one", "Voice Margin at 1:02:05 in “Long one”, recorded 30 Oct 2026"),
            ("exactly an hour", 3_600_000, "T", "Voice Margin at 1:00:00 in “T”, recorded 30 Oct 2026"),
            ("start", 0, "T", "Voice Margin at 0:00 in “T”, recorded 30 Oct 2026"),
            ("negative time", -4_000, "T", "Voice Margin at 0:00 in “T”, recorded 30 Oct 2026"),
            ("article: no media time", nil, "An essay", "Voice Margin in “An essay”, recorded 30 Oct 2026"),
            ("line breaks fold", 61_000, "Café\nau  lait", "Voice Margin at 1:01 in “Café au lait”, recorded 30 Oct 2026"),
            ("decomposed accent composes", 61_000, "Cafe\u{301}", "Voice Margin at 1:01 in “Café”, recorded 30 Oct 2026"),
            ("Japanese", 61_000, "日本語のポッドキャスト", "Voice Margin at 1:01 in “日本語のポッドキャスト”, recorded 30 Oct 2026"),
            ("title with commas and quotes", 61_000, "Yes, “No”, Maybe", "Voice Margin at 1:01 in “Yes, “No”, Maybe”, recorded 30 Oct 2026"),
            ("long title", 1_000, long, "Voice Margin at 0:01 in “\(String(repeating: "A ", count: 40).trimmingCharacters(in: .whitespaces))…”, recorded 30 Oct 2026"),
            ("emoji title cut whole", 1_000, String(repeating: family, count: 100), "Voice Margin at 0:01 in “\(String(repeating: family, count: 79))…”, recorded 30 Oct 2026"),
        ]
        for row in rows {
            XCTAssertEqual(
                SharedMarginPlaceholder.words(mediaTimeMs: row.mediaTimeMs, itemTitle: row.title, recordedAt: recorded, timeZone: chicago),
                row.expected, row.name
            )
        }
    }

    func testALongTitleIsCutToTheLimitAtAWholeCharacter() {
        let cut = SharedMarginPlaceholder.title(String(repeating: "A ", count: 200))
        XCTAssertEqual(cut.count, SharedMarginPlaceholder.titleCharacterLimit)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertFalse(cut.hasSuffix(" …"), "no space before the ellipsis")
        let exact = String(repeating: "x", count: SharedMarginPlaceholder.titleCharacterLimit)
        XCTAssertEqual(SharedMarginPlaceholder.title(exact), exact, "a title at the limit is kept whole")
        XCTAssertEqual(SharedMarginPlaceholder.title(String(repeating: "👨‍👩‍👧‍👦", count: 100), limit: 10), String(repeating: "👨‍👩‍👧‍👦", count: 9) + "…")
    }

    func testTheDateIsDayMonthWordAndYearOnTheListenersDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        let newYearsEve = calendar.date(from: DateComponents(year: 2027, month: 12, day: 31, hour: 23, minute: 59))!
        XCTAssertEqual(SharedMarginPlaceholder.date(newYearsEve, timeZone: chicago), "31 Dec 2027")
        XCTAssertEqual(SharedMarginPlaceholder.date(newYearsEve, timeZone: TimeZone(identifier: "UTC")!), "1 Jan 2028",
                       "the day is the listener's own calendar day")
        let second = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2))!
        XCTAssertEqual(SharedMarginPlaceholder.date(second, timeZone: chicago), "2 Jan 2026")
    }

    // MARK: Which Margins get it

    func testOwnWordsAndTranscriptsAlwaysWinOverThePlaceholder() {
        XCTAssertNil(placeholder(margin(transcript: "Remember this.", status: "completed")))
        XCTAssertNil(placeholder(margin(cleaned: "Cleaned words.")))
        XCTAssertNil(placeholder(margin(display: "Typed words.")))
        // A blank cleaned transcript no longer hides the raw one.
        let blankCleaned = margin(transcript: "Raw words.", cleaned: "  ", status: "completed")
        XCTAssertNil(placeholder(blankCleaned))
        XCTAssertEqual(SharedMarginTextRequirement.initialReviewedText(for: blankCleaned), "Raw words.")
    }

    func testPendingAndFailedTranscriptsBothGetThePlaceholder() {
        for status in ["pending", "failed", "skipped", "not_started"] {
            XCTAssertEqual(placeholder(margin(status: status)),
                           "Voice Margin at 12:34 in “Episode 1 (example episode)”, recorded 30 Oct 2026", status)
            XCTAssertEqual(placeholder(margin(transcript: "  \n", status: status)),
                           "Voice Margin at 12:34 in “Episode 1 (example episode)”, recorded 30 Oct 2026", "blank, \(status)")
        }
    }

    func testOnlyVoiceMarginsGetThePlaceholder() {
        XCTAssertNil(placeholder(margin(captureKind: .written)), "a written Margin with no words has nothing to stand in for")
        XCTAssertNil(placeholder(margin(), hasVoice: false), "no recording on the phone: nothing travels")
        XCTAssertNotNil(placeholder(margin(captureKind: nil)), "Margins from before written Margins are voice Margins")
    }

    func testAVoiceMarginWithoutWordsCanBeSharedAndAWrittenOneCannot() {
        XCTAssertTrue(SharedMarginTextRequirement.canShare(margin(), hasVoice: true))
        XCTAssertFalse(SharedMarginTextRequirement.canShare(margin(), hasVoice: false))
        XCTAssertFalse(SharedMarginTextRequirement.canShare(margin(captureKind: .written), hasVoice: false))
        XCTAssertTrue(SharedMarginTextRequirement.canShare(margin(transcript: "Words."), hasVoice: false))
    }

    // MARK: The review sheet's draft

    func testTheDraftStartsWithReplaceablePlaceholderWordsAndNoWarning() {
        var draft = ShareInterjectionDraft.initial(
            for: margin(), isIncluded: true, hasVoice: true, itemTitle: "Episode 1 (example episode)",
            anchorWarning: nil, timeZone: chicago
        )
        let words = "Voice Margin at 12:34 in “Episode 1 (example episode)”, recorded 30 Oct 2026"
        XCTAssertEqual(draft.approvedTranscript, words)
        XCTAssertEqual(draft.placeholderText, words)
        XCTAssertTrue(draft.isShowingPlaceholder)
        XCTAssertNil(draft.warning, "it is shared, so it isn't marked can't-be-shared")
        XCTAssertEqual(draft.representationChoice, .original)

        draft.setReviewedWords("My own words.")
        XCTAssertEqual(draft.approvedTranscript, "My own words.")
        XCTAssertFalse(draft.isShowingPlaceholder)

        draft.setReviewedWords("  ")
        XCTAssertEqual(draft.approvedTranscript, words, "clearing the words brings the placeholder back")
        XCTAssertTrue(draft.isShowingPlaceholder)

        draft.setReviewedWords("Mine again.")
        draft.restoreOriginal(hasOriginalAudio: true, anchorWarning: nil)
        XCTAssertEqual(draft.approvedTranscript, words, "undoing all edits goes back to the placeholder, not to nothing")
    }

    func testADraftWithWordsHasNoPlaceholderAndIgnoresPlaceholderEdits() {
        var draft = ShareInterjectionDraft.initial(
            for: margin(transcript: "Remember this.", status: "completed"), isIncluded: true, hasVoice: true,
            itemTitle: "T", anchorWarning: nil, timeZone: chicago
        )
        XCTAssertNil(draft.placeholderText)
        XCTAssertFalse(draft.isShowingPlaceholder)
        draft.setReviewedWords("Other")
        XCTAssertEqual(draft.approvedTranscript, "Remember this.")
    }

    func testAWrittenMarginWithoutWordsIsStillWarnedAndLeftOut() {
        let draft = ShareInterjectionDraft.initial(
            for: margin(captureKind: .written), isIncluded: true, hasVoice: false, itemTitle: "T",
            anchorWarning: nil, timeZone: chicago
        )
        XCTAssertEqual(draft.approvedTranscript, "")
        XCTAssertEqual(draft.warning, SharedMarginTextRequirement.reviewWarningText)
        XCTAssertNil(draft.placeholderText)
    }

    /// #1185: the count on the button is the count in the packet. A word-less voice Margin now counts.
    func testTheCountIncludesAWordlessVoiceMargin() {
        let drafts = [
            ShareInterjectionDraft.initial(for: margin(), isIncluded: true, hasVoice: true, itemTitle: "T", anchorWarning: nil),
            ShareInterjectionDraft.initial(for: margin(captureKind: .written), isIncluded: true, hasVoice: false, itemTitle: "T", anchorWarning: nil),
        ]
        let summary = SharedMarginSelectionSummary(drafts, isIncluded: \.isIncluded, text: \.approvedTranscript)
        XCTAssertEqual(summary.packetCount, 1)
        XCTAssertEqual(summary.leftOutCount, 1)
    }

    // MARK: Builds 29, 32 and 34 read it

    /// The placeholder goes in the existing transcript field, so the shipped readers import the voice Margin.
    /// `exportPacket` opens it with Build 29's frozen reader, and hands it on for Builds 32 and 34 (#1900).
    func testThePacketWithPlaceholderWordsImportsInTheShippedBuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("placeholder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("voice.m4a")
        try writeClip(to: audio)

        let draft = ShareInterjectionDraft.initial(
            for: margin(), isIncluded: true, hasVoice: true, itemTitle: "A Useful Article", anchorWarning: nil, timeZone: chicago
        )
        let words = "Voice Margin at 12:34 in “A Useful Article”, recorded 30 Oct 2026"
        XCTAssertEqual(draft.approvedTranscript, words)
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "voice-placeholder",
            createdAt: recorded,
            item: SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article"),
            itemTransportSelection: .reference,
            selections: [ReviewedInterjectionSelection(
                packageScopedId: "margin-0001",
                revision: InterjectionShareRevision(
                    id: "revision-voice", interjectionId: "note", itemId: "item", sessionId: "session",
                    createdAt: recorded, approvedTranscript: draft.approvedTranscript,
                    anchorBefore: "Before.", anchorAfter: "After.", status: .senderApproved
                ),
                anchor: .init(anchorType: .text, exactText: "The durable idea that prompted this note."),
                representation: .originalAudio(sourceURL: audio, durationMs: 600)
            )]
        )
        let url = root.appendingPathComponent("placeholder.spokenmargins")
        try exportPacket(prepared, to: url)
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets"))
        let record = try XCTUnwrap(verified.commentaryLayers.flatMap(\.interjections).first)
        XCTAssertEqual(record.defaultRepresentation?.approvedTranscript, words)
        XCTAssertNotNil(record.defaultRepresentation?.assetId, "the voice travels with it")
    }

    private func writeClip(to url: URL) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate * 0.6)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try audioFile.write(from: buffer)
        #else
        let header: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, 0, 0, 0, 0]
        try (Data(header) + Data(repeating: 6, count: 600)).write(to: url)
        #endif
    }
}
