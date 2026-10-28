import Foundation
import XCTest
@testable import SessionKit

/// The rules for how a podcast Margin's anchor evidence is written onto the stored Margin, and the names that
/// evidence is saved under. The names are in SQLite rows and file names: a change orphans evidence already stored.
final class PodcastAnchorEvidenceRecordTests: XCTestCase {
    // MARK: - Fixtures

    private func evidence(
        _ id: String,
        role: PodcastAnchorEvidenceWindowRole? = nil,
        provenance: PodcastAnchorEvidenceProvenance? = nil,
        durationMs: Int = 4_000
    ) -> CapturedPodcastAnchorEvidence {
        CapturedPodcastAnchorEvidence(
            id: id,
            localPath: "/var/mobile/Containers/Data/Application/ABC/Library/Application Support/\(id).sig",
            durationMs: durationMs,
            anchorOffsetMs: 2_000,
            provenance: provenance,
            windowRole: role
        )
    }

    private func margin(
        evidence stored: [CapturedPodcastAnchorEvidence]? = nil,
        sha: String? = nil,
        captureStatus: PodcastAnchorEvidenceCaptureStatus? = nil,
        failureReason: String? = nil,
        context: AnchorContextStatus? = nil
    ) -> Interjection {
        Interjection(
            id: "ij-001",
            itemId: "episode",
            sessionId: "session-a",
            targetType: .item,
            targetId: "episode",
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 60_000),
            audioPath: "interjections/ij-001.m4a",
            audioStatus: "saved",
            transcriptionStatus: "complete",
            transcript: "a spoken note",
            cleanedTranscript: "A spoken note.",
            displayText: "A spoken note.",
            status: "active",
            anchorContextStatus: context,
            podcastAnchorEvidence: stored,
            sourceExactEditionSHA256: sha,
            podcastAnchorEvidenceCaptureStatus: captureStatus,
            podcastAnchorEvidenceFailureReason: failureReason
        )
    }

    // MARK: - Merging evidence

    func testMergingReplacesAnEntryWithTheSameIdAndKeepsTheOthers() {
        let old = evidence("anchor-a-1-stream-pre", role: .preInterjection, provenance: .decodedPlaybackStream, durationMs: 1)
        let other = evidence("anchor-a-1-stream-post", role: .postResume, provenance: .decodedPlaybackStream)
        // Same id as `old` but a different role and provenance, so only the id can match it.
        let new = evidence("anchor-a-1-stream-pre", role: .sourceWindowBefore, provenance: .sourceWindowReference, durationMs: 9)

        let merged = PodcastAnchorEvidenceRecord.merging(
            [new], sourceExactEditionSHA256: nil, into: margin(evidence: [old, other]))

        XCTAssertEqual(merged.podcastAnchorEvidence, [other, new], "sorted by id, and the old entry is gone")
    }

    func testMergingReplacesAnEntryWithTheSameWindowRoleAndProvenanceUnderAnotherId() {
        let old = evidence("anchor-a-1-local-pre", role: .preInterjection, provenance: .exactLocalPlaybackEdition, durationMs: 1)
        let other = evidence("anchor-a-1-local-post", role: .postResume, provenance: .exactLocalPlaybackEdition)
        let new = evidence("anchor-a-1-retry-pre", role: .preInterjection, provenance: .exactLocalPlaybackEdition, durationMs: 9)

        let merged = PodcastAnchorEvidenceRecord.merging(
            [new], sourceExactEditionSHA256: nil, into: margin(evidence: [old, other]))

        XCTAssertEqual(merged.podcastAnchorEvidence, [other, new], "sorted by id, and the old entry is gone")
    }

    func testMergingKeepsEntriesThatShareOnlyTheRoleOrOnlyTheProvenance() {
        let sameRole = evidence("b", role: .preInterjection, provenance: .observedDecodedPlayback)
        let sameProvenance = evidence("c", role: .postResume, provenance: .decodedPlaybackStream)
        let new = evidence("a", role: .preInterjection, provenance: .decodedPlaybackStream)

        let merged = PodcastAnchorEvidenceRecord.merging(
            [new], sourceExactEditionSHA256: nil, into: margin(evidence: [sameRole, sameProvenance]))

        XCTAssertEqual(merged.podcastAnchorEvidence, [new, sameRole, sameProvenance])
    }

    func testMergingTreatsTwoEntriesWithNoRoleAndNoProvenanceAsTheSamePair() {
        // Entries stored before roles and provenance existed carry neither. Pinned as it is today.
        let legacy = evidence("legacy", durationMs: 1)
        let tagged = evidence("tagged", role: .postResume, provenance: .decodedPlaybackStream)
        let new = evidence("fresh", durationMs: 9)

        let merged = PodcastAnchorEvidenceRecord.merging(
            [new], sourceExactEditionSHA256: nil, into: margin(evidence: [legacy, tagged]))

        XCTAssertEqual(merged.podcastAnchorEvidence, [new, tagged])
    }

    func testMergingASecondEntryForTheSamePairInOneBatchKeepsTheLaterOne() {
        let first = evidence("first", role: .postResume, provenance: .decodedPlaybackStream, durationMs: 1)
        let second = evidence("second", role: .postResume, provenance: .decodedPlaybackStream, durationMs: 2)

        let merged = PodcastAnchorEvidenceRecord.merging(
            [first, second], sourceExactEditionSHA256: nil, into: margin())

        XCTAssertEqual(merged.podcastAnchorEvidence, [second])
    }

    func testMergingIntoAMarginWithNoEvidenceStartsTheList() {
        let new = evidence("a", role: .postResume, provenance: .decodedPlaybackStream)

        let merged = PodcastAnchorEvidenceRecord.merging([new], sourceExactEditionSHA256: nil, into: margin(evidence: nil))

        XCTAssertEqual(merged.podcastAnchorEvidence, [new])
    }

    func testMergingStoresEntriesSortedById() {
        let stored = [
            evidence("m", role: .postResume, provenance: .decodedPlaybackStream),
            evidence("c", role: .sourceWindowAfter, provenance: .sourceWindowReference)
        ]
        let added = [
            evidence("z", role: .preInterjection, provenance: .decodedPlaybackStream),
            evidence("a", role: .sourceWindowBefore, provenance: .sourceWindowReference)
        ]

        let merged = PodcastAnchorEvidenceRecord.merging(added, sourceExactEditionSHA256: nil, into: margin(evidence: stored))

        XCTAssertEqual(merged.podcastAnchorEvidence?.map(\.id), ["a", "c", "m", "z"])
    }

    func testMergingMarksTheCaptureReadyFromEveryEarlierStatus() {
        let statuses: [PodcastAnchorEvidenceCaptureStatus?] = [
            nil, .pendingPostResumeSample, .pendingExactLocalCapture, .unavailable, .ready
        ]
        for status in statuses {
            let merged = PodcastAnchorEvidenceRecord.merging(
                [evidence("a", role: .postResume, provenance: .decodedPlaybackStream)],
                sourceExactEditionSHA256: nil,
                into: margin(captureStatus: status)
            )
            XCTAssertEqual(merged.podcastAnchorEvidenceCaptureStatus, .ready, "from \(String(describing: status))")
        }
    }

    func testMergingSetsTheEditionHashAndANilKeepsTheEarlierOne() {
        let new = [evidence("a", role: .postResume, provenance: .decodedPlaybackStream)]

        let hashed = PodcastAnchorEvidenceRecord.merging(new, sourceExactEditionSHA256: "abc123", into: margin(sha: "old"))
        XCTAssertEqual(hashed.sourceExactEditionSHA256, "abc123")

        // The stream and source-window captures pass nil. They must not erase the hash an exact local capture
        // stored, because the shared item identity of a packet needs every Margin's digest (#972 entry 8).
        let kept = PodcastAnchorEvidenceRecord.merging(new, sourceExactEditionSHA256: nil, into: margin(sha: "old"))
        XCTAssertEqual(kept.sourceExactEditionSHA256, "old")
        let stillNone = PodcastAnchorEvidenceRecord.merging(new, sourceExactEditionSHA256: nil, into: margin())
        XCTAssertNil(stillNone.sourceExactEditionSHA256)
    }

    func testMergingTurnsAPendingContextIntoUnavailableAndLeavesTheOtherStatesAlone() {
        let new = [evidence("a", role: .postResume, provenance: .decodedPlaybackStream)]
        let expected: [(AnchorContextStatus?, AnchorContextStatus?)] = [
            (.pending, .unavailable),
            (.ready, .ready),
            (.unavailable, .unavailable),
            (nil, nil)
        ]
        for (before, after) in expected {
            let merged = PodcastAnchorEvidenceRecord.merging(
                new, sourceExactEditionSHA256: nil, into: margin(context: before))
            XCTAssertEqual(merged.anchorContextStatus, after, "from \(String(describing: before))")
        }
    }

    func testMergingChangesNothingButTheEvidenceFields() {
        let before = margin(
            evidence: [evidence("old", role: .preInterjection, provenance: .decodedPlaybackStream)],
            sha: "old-sha",
            captureStatus: .pendingExactLocalCapture,
            failureReason: "stream_failed:timeout",
            context: .pending
        )
        let new = evidence("new", role: .postResume, provenance: .decodedPlaybackStream)

        let merged = PodcastAnchorEvidenceRecord.merging([new], sourceExactEditionSHA256: "new-sha", into: before)

        var expected = before
        expected.podcastAnchorEvidence = [new, before.podcastAnchorEvidence![0]]
        expected.sourceExactEditionSHA256 = "new-sha"
        expected.podcastAnchorEvidenceCaptureStatus = .ready
        expected.anchorContextStatus = .unavailable
        // The failure history stays, so a later reader still sees why the first attempt failed.
        XCTAssertEqual(merged, expected)
        XCTAssertEqual(merged.podcastAnchorEvidenceFailureReason, "stream_failed:timeout")
    }

    func testMergingNothingStillMarksTheCaptureReadyWithAnEmptyList() {
        // Pinned as it is today: the caller decides whether an empty capture is worth persisting.
        let merged = PodcastAnchorEvidenceRecord.merging([], sourceExactEditionSHA256: nil, into: margin())

        XCTAssertEqual(merged.podcastAnchorEvidence, [])
        XCTAssertEqual(merged.podcastAnchorEvidenceCaptureStatus, .ready)
    }

    // MARK: - Marking unavailable, pending, and recording a failure

    func testMarkingUnavailableSetsTheStatusAndAppendsTheReason() {
        let before = margin(
            evidence: [evidence("a", role: .postResume, provenance: .decodedPlaybackStream)],
            sha: "sha",
            captureStatus: .pendingExactLocalCapture,
            failureReason: "stream_failed:timeout",
            context: .pending
        )

        let after = PodcastAnchorEvidenceRecord.markingUnavailable(before, reason: "no_exact_local_playback_edition")

        var expected = before
        expected.podcastAnchorEvidenceCaptureStatus = .unavailable
        expected.podcastAnchorEvidenceFailureReason = "stream_failed:timeout | no_exact_local_playback_edition"
        XCTAssertEqual(after, expected)
    }

    func testMarkingUnavailableStartsAndDeduplicatesTheFailureHistory() {
        let first = PodcastAnchorEvidenceRecord.markingUnavailable(margin(), reason: "storage_unavailable")
        XCTAssertEqual(first.podcastAnchorEvidenceCaptureStatus, .unavailable)
        XCTAssertEqual(first.podcastAnchorEvidenceFailureReason, "storage_unavailable")

        let repeated = PodcastAnchorEvidenceRecord.markingUnavailable(first, reason: "storage_unavailable")
        XCTAssertEqual(repeated.podcastAnchorEvidenceFailureReason, "storage_unavailable")
    }

    func testMarkingPendingLocalCaptureChangesOnlyTheCaptureStatus() {
        let before = margin(
            evidence: [evidence("a", role: .postResume, provenance: .decodedPlaybackStream)],
            sha: "sha",
            captureStatus: .pendingPostResumeSample,
            failureReason: "stream_failed:timeout",
            context: .pending
        )

        let after = PodcastAnchorEvidenceRecord.markingPendingLocalCapture(before)

        var expected = before
        expected.podcastAnchorEvidenceCaptureStatus = .pendingExactLocalCapture
        XCTAssertEqual(after, expected)
    }

    func testRecordingAFailureReasonAppendsItAndLeavesTheCaptureStatusAlone() {
        let statuses: [PodcastAnchorEvidenceCaptureStatus?] = [
            nil, .pendingPostResumeSample, .pendingExactLocalCapture, .ready, .unavailable
        ]
        for status in statuses {
            let before = margin(captureStatus: status, failureReason: "stream_failed:timeout", context: .pending)

            let after = PodcastAnchorEvidenceRecord.recordingFailureReason("no_exact_local_playback_edition", on: before)

            var expected = before
            expected.podcastAnchorEvidenceFailureReason = "stream_failed:timeout | no_exact_local_playback_edition"
            XCTAssertEqual(after, expected, "from \(String(describing: status))")
        }
    }

    // MARK: - Names

    func testDirectoryIsUnderApplicationSupportByTheSafeSessionAndMarginIds() {
        let base = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/Library/Application Support", isDirectory: true)

        let plain = PodcastAnchorEvidencePaths.directory(
            applicationSupport: base, sessionId: "session-a", interjectionId: "ij-001")
        XCTAssertEqual(plain.path, base.path + "/SpokenMargins/AnchorEvidence/session-a/ij-001")

        let odd = PodcastAnchorEvidencePaths.directory(
            applicationSupport: base, sessionId: "session 1/2", interjectionId: "ij:001")
        XCTAssertEqual(odd.path, base.path + "/SpokenMargins/AnchorEvidence/session-1-2/ij-001")
    }

    func testEvidenceIdsKeepTheNamesSavedInStoredMargins() {
        let suffixes = ["local", "stream-pre", "stream-post", "source-window"]
        for suffix in suffixes {
            XCTAssertEqual(
                PodcastAnchorEvidencePaths.evidenceID(sessionId: "session-a", interjectionId: "ij-001", suffix: suffix),
                "anchor-session-a-ij-001-\(suffix)"
            )
        }
        XCTAssertEqual(
            PodcastAnchorEvidencePaths.evidenceID(sessionId: "session 1/2", interjectionId: "ij:001", suffix: "stream-pre"),
            "anchor-session-1-2-ij-001-stream-pre",
            "the ids are made safe; the suffix is used as given"
        )
        XCTAssertEqual(
            PodcastAnchorEvidencePaths.evidenceID(sessionId: "s", interjectionId: "i", suffix: "a b"),
            "anchor-s-i-a b"
        )
    }

    func testSafeComponentKeepsLettersDigitsDotUnderscoreAndHyphen() {
        for value in ["ij-001", "Session_A.1", "0123456789", "a.b-c_d", "unknown", "..", "---"] {
            XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent(value), value)
        }
    }

    func testSafeComponentMapsEachOtherCharacterToOneHyphenWithoutCollapsing() {
        let table: [(String, String)] = [
            ("a b", "a-b"),
            ("a  b", "a--b"),
            ("a/b\\c:d", "a-b-c-d"),
            ("a//b", "a--b"),
            ("a\tb\nc", "a-b-c"),
            (" ", "-"),
            ("  ", "--"),
            ("a+b=c", "a-b-c"),
            ("100%", "100-"),
            ("a@b.com", "a-b.com"),
            ("-a-", "-a-")
        ]
        for (input, expected) in table {
            XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent(input), expected, "input \(input.debugDescription)")
        }
    }

    func testSafeComponentTreatsAccentedLettersAsOutsideTheAllowedSet() {
        // Escapes, so the source file's Unicode normalization can't change the input.
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent(composed), "caf-")
        XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent(decomposed), "cafe-")
        XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent("\u{C9}t\u{E9} \u{FC}ber"), "-t---ber")
        XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent("\u{E9}\u{E9}"), "--")
    }

    func testSafeComponentReturnsUnknownOnlyForAnEmptyInput() {
        XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent(""), "unknown")
        XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent(" "), "-", "a replaced character is not empty")
    }

    func testSafeComponentCutsToNinetySixCharactersAfterReplacing() {
        let exactly96 = String(repeating: "a", count: 96)
        XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent(exactly96), exactly96)
        XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent(exactly96 + "a"), exactly96)
        XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent(String(repeating: "a", count: 500)), exactly96)

        // The cut counts the safe result, so replaced characters count as one each.
        let accented = String(repeating: "\u{E9}", count: 100)
        XCTAssertEqual(PodcastAnchorEvidencePaths.safeComponent(accented), String(repeating: "-", count: 96))

        // A long id's tail is lost, so two long ids with the same start share a name. Pinned as it is today.
        XCTAssertEqual(
            PodcastAnchorEvidencePaths.safeComponent(exactly96 + "-one"),
            PodcastAnchorEvidencePaths.safeComponent(exactly96 + "-two")
        )
    }
}
