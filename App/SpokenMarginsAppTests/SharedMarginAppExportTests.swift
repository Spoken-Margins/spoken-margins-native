import XCTest
import AVFoundation
import SessionKitSharing
import SessionKitPersistence
import ShippedPacketReader
@testable import SessionKit
@testable import SpokenMarginsApp

/// The packet the app's real exporter writes, read back field by field (#1039, PKT-02).
///
/// The other sharing tests that run `exportSharedInterjections` use one text anchor with no voice
/// and no acoustic evidence, so they stay green when the exporter pairs a voice with the wrong
/// Margin, drops the media time, swaps the context, or zeroes the evidence offset. This test seeds
/// one podcast-style Margin (media time, transcript segment, real signature file, real recording),
/// a second voice Margin with a recording of a different length, and a text-only Margin, then
/// checks every record against the Margin it came from, and has Build 29's frozen reader import
/// the same file.
@MainActor
final class SharedMarginAppExportTests: XCTestCase {
    func testExportedPacketCarriesEachMarginsOwnAnchorEvidenceAndVoice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "shared-margin-app-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        model.resetAndSeed()
        model.importTitle = "Harbour notes"
        model.importText = "The tide went out at dawn. Nobody on the pier noticed the boat had gone. By noon the harbour master was asking questions."
        model.importTextItem()
        let itemID = model.selectedItem.id
        let itemText = try XCTUnwrap(SQLiteSessionStore(path: db.path).loadItem(id: itemID).text)

        // Two recordings whose lengths differ by most of a second, so a voice paired with
        // the wrong Margin changes both the bytes and the duration.
        let longVoice = root.appending(path: "long-voice.m4a")
        let shortVoice = root.appending(path: "short-voice.m4a")
        try writeTone(to: longVoice, seconds: 1.6, frequency: 440)
        try writeTone(to: shortVoice, seconds: 0.7, frequency: 660)
        let signature = root.appending(path: "evidence-pre.shazamsignature")
        try Self.signatureData().write(to: signature)

        let podcastRange = try characterRange(of: "Nobody on the pier", in: itemText)
        let voiceRange = try characterRange(of: "harbour master", in: itemText)
        let textRange = try characterRange(of: "The tide", in: itemText)
        model.selectedItem.interjections = [
            margin(
                id: "margin-podcast", itemID: itemID, roughPercent: 31,
                anchor: Anchor(
                    anchorType: .media, startChar: podcastRange.lowerBound, endChar: podcastRange.upperBound,
                    anchorBefore: "The tide went out at dawn.", anchorAfter: "noticed the boat had gone.",
                    mediaTimeMs: 754_250, transcriptSegmentId: "segment-12"
                ),
                audioPath: longVoice.path, transcript: "The pier went quiet right here.",
                evidence: [CapturedPodcastAnchorEvidence(
                    id: "evidence-pre", localPath: signature.path, durationMs: 12_000, anchorOffsetMs: 3_250,
                    provenance: .decodedPlaybackStream, windowRole: .preInterjection
                )]
            ),
            margin(
                id: "margin-voice", itemID: itemID, roughPercent: 77,
                anchor: Anchor(
                    anchorType: .text, startChar: voiceRange.lowerBound, endChar: voiceRange.upperBound,
                    anchorBefore: "By noon the", anchorAfter: "was asking questions."
                ),
                audioPath: shortVoice.path, transcript: "He always asks too late."
            ),
            margin(
                id: "margin-text", itemID: itemID, roughPercent: 2,
                anchor: Anchor(
                    anchorType: .text, startChar: textRange.lowerBound, endChar: textRange.upperBound,
                    anchorBefore: "", anchorAfter: "went out at dawn."
                ),
                audioPath: nil, transcript: "A written note only."
            )
        ]

        model.prepareShareInterjections()
        XCTAssertEqual(model.sharingState.drafts.map(\.representationChoice), [.original, .original, .textOnly],
                       "A Margin with a recording defaults to sending its own voice")
        await model.exportSharedInterjections(presentsReadySheet: false)
        XCTAssertNil(model.sharingState.errorMessage)
        let packetURL = try XCTUnwrap(model.sharedSpokenMarginsPackageURL)
        defer { try? FileManager.default.removeItem(at: packetURL) }

        let packet = try SpokenMarginsPackageArchive.read(from: packetURL, extractingAssetsTo: root.appending(path: "read"))
        let records = packet.commentaryLayers.flatMap(\.interjections)
        XCTAssertEqual(records.map(\.packageScopedId), ["margin-0001", "margin-0002", "margin-0003"])
        guard records.count == 3 else { return }

        // Anchors: every field the recipient places the Margin with, written out by hand.
        XCTAssertEqual(records[0].anchor, PortableAnchorEvidence(
            anchorType: .media, startChar: podcastRange.lowerBound, endChar: podcastRange.upperBound,
            exactText: "Nobody on the pier", prefix: "The tide went out at dawn.", suffix: "noticed the boat had gone.",
            mediaTimeMs: 754_250, roughPercent: 31, transcriptSegmentId: "segment-12",
            machineEvidenceAssetIds: ["evidence-pre"]
        ))
        XCTAssertEqual(records[1].anchor, PortableAnchorEvidence(
            anchorType: .text, startChar: voiceRange.lowerBound, endChar: voiceRange.upperBound,
            exactText: "harbour master", prefix: "By noon the", suffix: "was asking questions.",
            roughPercent: 77
        ))
        XCTAssertEqual(records[2].anchor, PortableAnchorEvidence(
            anchorType: .text, startChar: textRange.lowerBound, endChar: textRange.upperBound,
            exactText: "The tide", prefix: nil, suffix: "went out at dawn.", roughPercent: 2
        ))

        // Acoustic evidence: the podcast Margin's own signature, with its own offset into the clip.
        let evidence = try XCTUnwrap(packet.manifest.assets.first { $0.id == "evidence-pre" })
        XCTAssertEqual(evidence.role, SpokenMarginsAssetRole.acousticSignature)
        XCTAssertEqual(evidence.anchorOffsetMs, 3_250)
        XCTAssertEqual(evidence.durationMs, 12_000)
        XCTAssertEqual(evidence.provenance, PodcastAnchorEvidenceProvenance.decodedPlaybackStream.rawValue)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(packet.extractedAssetURLs["evidence-pre"])), Self.signatureData())

        // Voices: each Margin carries its own recording, with that recording's length.
        let expectedVoices: [(record: SharedInterjectionPackageRecord, source: URL, seconds: Double, text: String)] = [
            (records[0], longVoice, 1.6, "The pier went quiet right here."),
            (records[1], shortVoice, 0.7, "He always asks too late.")
        ]
        var voiceDurations: [Int] = []
        for expected in expectedVoices {
            let representation = try XCTUnwrap(expected.record.representations.first { $0.id == expected.record.defaultRepresentationId })
            XCTAssertEqual(representation.kind, .originalAudioAndText, expected.record.packageScopedId)
            XCTAssertEqual(representation.approvedTranscript, expected.text, expected.record.packageScopedId)
            let assetID = try XCTUnwrap(representation.assetId, expected.record.packageScopedId)
            let descriptor = try XCTUnwrap(packet.manifest.assets.first { $0.id == assetID })
            XCTAssertEqual(descriptor.role, SpokenMarginsAssetRole.originalVoice, expected.record.packageScopedId)
            let assetURL = try XCTUnwrap(packet.extractedAssetURLs[assetID], expected.record.packageScopedId)
            XCTAssertEqual(try Data(contentsOf: assetURL), try Data(contentsOf: expected.source),
                           "\(expected.record.packageScopedId) must carry its own Margin's recording")
            let durationMs = try XCTUnwrap(descriptor.durationMs, expected.record.packageScopedId)
            XCTAssertEqual(Double(durationMs), expected.seconds * 1_000, accuracy: 150, expected.record.packageScopedId)
            voiceDurations.append(durationMs)
        }
        XCTAssertGreaterThan(voiceDurations.first ?? 0, (voiceDurations.last ?? 0) + 500)

        let textRepresentation = try XCTUnwrap(records[2].representations.first { $0.id == records[2].defaultRepresentationId })
        XCTAssertEqual(textRepresentation.kind, .textOnly)
        XCTAssertNil(textRepresentation.assetId)
        XCTAssertEqual(textRepresentation.approvedTranscript, "A written note only.")
        XCTAssertEqual(Set(packet.manifest.assets.map(\.role)), [
            SpokenMarginsAssetRole.originalVoice, SpokenMarginsAssetRole.acousticSignature
        ])
        XCTAssertEqual(packet.manifest.assets.count, 3)

        // The last shipped build imports this exact file and keeps every Margin's text and anchor.
        let shipped = try ShippedPacketReader.importedMargins(at: packetURL, includingAnchorEvidence: true)
            .sorted { $0.packageScopedId < $1.packageScopedId }
        XCTAssertEqual(shipped.map(\.packageScopedId), records.map(\.packageScopedId), ShippedPacketReader.build)
        XCTAssertEqual(shipped.map(\.approvedTranscript),
                       ["The pier went quiet right here.", "He always asks too late.", "A written note only."])
        for (imported, record) in zip(shipped, records) {
            let json = try XCTUnwrap(imported.anchorEvidenceJSON, imported.packageScopedId)
            XCTAssertEqual(try JSONDecoder().decode(PortableAnchorEvidence.self, from: json), record.anchor,
                           "\(ShippedPacketReader.build) must keep \(imported.packageScopedId)'s anchor")
        }
    }

    /// #473, Done when 3: the app's real exporter writes a reply with its link in the optional conversation
    /// artifact, writes nothing for a Margin that is not a reply, and the last shipped build imports the same file
    /// with both as ordinary Margins. The parent's audio is not part of the packet: only the listener's own
    /// Margins are exported.
    func testExportedPacketCarriesAReplysLinkAndBuild29ReadsItAsAnOrdinaryMargin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "shared-margin-app-reply-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        model.resetAndSeed()
        model.importTitle = "Harbour notes"
        model.importText = "The tide went out at dawn. Nobody on the pier noticed the boat had gone. By noon the harbour master was asking questions."
        model.importTextItem()
        let itemID = model.selectedItem.id
        let itemText = try XCTUnwrap(SQLiteSessionStore(path: db.path).loadItem(id: itemID).text)
        let replyRange = try characterRange(of: "Nobody on the pier", in: itemText)
        let plainRange = try characterRange(of: "harbour master", in: itemText)
        let parent = MarginPacketIdentity(packageDigest: String(repeating: "a", count: 64), packageScopedId: "margin-0007")
        let link = MarginReplyLink.replying(to: parent, parentConversationId: nil)

        var reply = margin(
            id: "margin-reply", itemID: itemID, roughPercent: 31,
            anchor: Anchor(anchorType: .text, startChar: replyRange.lowerBound, endChar: replyRange.upperBound,
                           anchorBefore: "The tide went out at dawn.", anchorAfter: "noticed the boat had gone."),
            audioPath: nil, transcript: "I saw that too."
        )
        reply.replyTo = link
        let plain = margin(
            id: "margin-plain", itemID: itemID, roughPercent: 77,
            anchor: Anchor(anchorType: .text, startChar: plainRange.lowerBound, endChar: plainRange.upperBound,
                           anchorBefore: "By noon the", anchorAfter: "was asking questions."),
            audioPath: nil, transcript: "He always asks too late."
        )
        model.selectedItem.interjections = [reply, plain]

        model.prepareShareInterjections()
        await model.exportSharedInterjections(presentsReadySheet: false)
        XCTAssertNil(model.sharingState.errorMessage)
        let packetURL = try XCTUnwrap(model.sharedSpokenMarginsPackageURL)
        defer { try? FileManager.default.removeItem(at: packetURL) }

        let packet = try SpokenMarginsPackageArchive.read(from: packetURL, extractingAssetsTo: root.appending(path: "read"))
        let records = packet.commentaryLayers.flatMap(\.interjections)
        XCTAssertEqual(records.map(\.packageScopedId), ["margin-0001", "margin-0002"])
        let conversation = try XCTUnwrap(packet.conversations.first, "a packet with a reply carries the conversation artifact")
        XCTAssertEqual(conversation.linksByPackageScopedId, ["margin-0001": [link]], "only the reply is linked, to the Margin it answers")
        XCTAssertEqual(packet.manifest.requiredCapabilities, [SharedCommentaryLayerArtifact.schemaVersion],
                       "a reply requires no new capability")
        XCTAssertFalse(packet.manifest.assets.contains { $0.role == SpokenMarginsAssetRole.originalVoice },
                       "the parent's recording is not re-exported")

        let shipped = try ShippedPacketReader.importedMargins(at: packetURL)
            .sorted { $0.packageScopedId < $1.packageScopedId }
        XCTAssertEqual(shipped.map(\.packageScopedId), ["margin-0001", "margin-0002"], ShippedPacketReader.build)
        XCTAssertEqual(shipped.map(\.approvedTranscript), ["I saw that too.", "He always asks too late."])
    }

    /// The share revisions and the export record are written on a background thread now (#2509). They must still
    /// be there when the export returns: one revision per Margin, and each stored Margin remembers its packet identity.
    func testExportSavesEachMarginsRevisionAndRemembersItsPacketIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "shared-margin-app-record-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        model.resetAndSeed()
        model.importTitle = "Harbour notes"
        model.importText = "The tide went out at dawn. Nobody on the pier noticed the boat had gone. By noon the harbour master was asking questions."
        model.importTextItem()
        let itemID = model.selectedItem.id
        let store = try SQLiteSessionStore(path: db.path)
        let itemText = try XCTUnwrap(store.loadItem(id: itemID).text)
        let first = try characterRange(of: "Nobody on the pier", in: itemText)
        let second = try characterRange(of: "harbour master", in: itemText)
        let margins = [
            margin(id: "margin-record-1", itemID: itemID, roughPercent: 31,
                   anchor: Anchor(anchorType: .text, startChar: first.lowerBound, endChar: first.upperBound,
                                  anchorBefore: "The tide went out at dawn.", anchorAfter: "noticed the boat had gone."),
                   audioPath: nil, transcript: "I saw that too."),
            margin(id: "margin-record-2", itemID: itemID, roughPercent: 77,
                   anchor: Anchor(anchorType: .text, startChar: second.lowerBound, endChar: second.upperBound,
                                  anchorBefore: "By noon the", anchorAfter: "was asking questions."),
                   audioPath: nil, transcript: "He always asks too late.")
        ]
        for margin in margins { try store.saveInterjection(margin) }
        model.selectedItem.interjections = margins

        model.prepareShareInterjections()
        await model.exportSharedInterjections(presentsReadySheet: false)
        XCTAssertNil(model.sharingState.errorMessage)
        let packetURL = try XCTUnwrap(model.sharedSpokenMarginsPackageURL)
        defer { try? FileManager.default.removeItem(at: packetURL) }

        for margin in margins {
            XCTAssertEqual(try store.loadInterjectionShareRevisions(interjectionId: margin.id).count, 1, margin.id)
        }
        let stored = try store.loadInterjections(sessionId: "session-app-export")
        let scoped = margins.compactMap { margin in stored.first(where: { $0.id == margin.id })?.sharedAs?.map(\.packageScopedId) }
        XCTAssertEqual(scoped.count, 2, "both stored Margins remember the packet they were exported in")
        XCTAssertEqual(Set(scoped.flatMap { $0 }), ["margin-0001", "margin-0002"])
    }

    /// The archive is now written while the main thread stays free (#2510), so a second tap can arrive mid-build.
    /// It must do nothing: no second packet, no error banner over the one being built.
    func testASecondExportWhileOneIsRunningDoesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "shared-margin-app-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        model.resetAndSeed()
        model.sharingState.isExporting = true
        let url = await model.exportSharedInterjections(presentsReadySheet: false)
        XCTAssertNil(url, "a call that wrote nothing returns no file, so a preview never reuses an older packet")
        XCTAssertNil(model.sharingState.errorMessage, "a second call returns before it checks anything")
        XCTAssertNil(model.sharedSpokenMarginsPackageURL)
        XCTAssertTrue(model.sharingState.isExporting, "the running build still owns the flag")
    }

    private func margin(
        id: String,
        itemID: String,
        roughPercent: Int,
        anchor: Anchor,
        audioPath: String?,
        transcript: String,
        evidence: [CapturedPodcastAnchorEvidence]? = nil
    ) -> Interjection {
        Interjection(
            id: id, itemId: itemID, sessionId: "session-app-export", targetType: .item, targetId: itemID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), roughPercent: roughPercent, anchor: anchor,
            audioPath: audioPath, audioStatus: audioPath == nil ? "none" : "saved",
            transcriptionStatus: "transcribed", transcript: transcript, cleanedTranscript: nil,
            displayText: nil, status: "active", podcastAnchorEvidence: evidence
        )
    }

    private func characterRange(of phrase: String, in text: String) throws -> Range<Int> {
        let range = try XCTUnwrap(text.range(of: phrase), "\(phrase) is missing from the imported text")
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        return start..<(start + phrase.count)
    }

    /// Writes a real AAC recording of a sine tone.
    private func writeTone(to url: URL, seconds: Double, frequency: Double) throws {
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            samples[frame] = Float(0.3 * sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        file.close()
    }

    /// A fixed ShazamKit signature from 12 seconds of synthetic PCM (the same bytes
    /// SharedMarginExportTests uses), so the reader's signature check passes.
    private static func signatureData() -> Data {
        Data(base64Encoded:
            "gCWAJQIAAAAMAAAAgCX+yhgv5cWEAAAAECDwQgAAAAAAAAAAAAAAAAAAABgAAAAAAAAAAAD9AgAAAHwAAAAAQIQAAABAAANgDwAA" +
            "AP8sAQAAAK+LchBLr4tyEABBAANgSwAAAP+WAQAAAFKKohFgaIqkEQx9i9ES/wIDAAAAfIsvFWl9iy8VDGeKXBZdUopeFiKvi44X" +
            "Y6+Ljhf/YAUAAABBi+sZDMCKGhs0tIobGwBCAANgAAAAAEMAA2AAAAAA"
        )!
    }
}
