import Foundation
@testable import SessionKit
import SessionKitSharing
import XCTest
#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox
#endif

/// A voice Margin in a packet plays its own recording (PKT-06 of the #1039 audit). The three-Margin test in
/// SharingTests counts the packet's assets and sorts their roles, which a packet that gives a Margin another
/// Margin's recording still satisfies.
final class PacketVoicePairingTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private let quote = "The durable idea that prompted this note."
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PacketVoicePairingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var item: SharedItemIdentity {
        SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")
    }

    private func revision(
        _ id: String, transcript: String, cleanedAudioPath: String? = nil, cleanedAudioDurationMs: Int? = nil,
        before: String = "Before this passage.", after: String = "After this passage."
    ) -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: "revision-\(id)", interjectionId: "private-\(id)", itemId: "private-item", sessionId: "private-session",
            createdAt: created, approvedTranscript: transcript, cleanedAudioPath: cleanedAudioPath,
            cleanedAudioDurationMs: cleanedAudioDurationMs, anchorBefore: before, anchorAfter: after,
            status: .senderApproved
        )
    }

    private func packet(from prepared: PreparedSpokenMarginsPackage, name: String) throws -> VerifiedSpokenMarginsPackage {
        let url = root.appendingPathComponent("\(name).spokenmargins")
        try exportPacket(prepared, to: url)
        return try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("\(name)-assets"))
    }

    // MARK: PKT-06: this Margin plays this recording

    /// A short voice clip. On a Mac it is real AAC (the reader decodes it); elsewhere the reader only checks the
    /// `ftyp` header, so a header plus filler is enough. The two clips differ in length, so their bytes differ.
    private func writeClip(to url: URL, tenthsOfASecond: Int) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate / 10) * AVAudioFrameCount(tenthsOfASecond)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try audioFile.write(from: buffer)
        #else
        let header: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, 0, 0, 0, 0]
        try (Data(header) + Data(repeating: UInt8(tenthsOfASecond), count: 100 * tenthsOfASecond)).write(to: url)
        #endif
    }

    func testEachVoiceMarginPlaysItsOwnRecordingAndNotAnotherMarginsOrderOfTheFiles() throws {
        let originalURL = root.appendingPathComponent("original.m4a")
        let cleanedURL = root.appendingPathComponent("cleaned.m4a")
        try writeClip(to: originalURL, tenthsOfASecond: 6)
        try writeClip(to: cleanedURL, tenthsOfASecond: 2)
        let originalBytes = try Data(contentsOf: originalURL)
        let cleanedBytes = try Data(contentsOf: cleanedURL)
        XCTAssertNotEqual(originalBytes, cleanedBytes, "the two clips must be told apart by their bytes")

        // The original-voice Margin comes first so that a builder reusing the previous Margin's file is caught.
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-voices", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [
                .init(packageScopedId: "margin-original", revision: revision("original", transcript: "Heard as recorded."),
                      anchor: .init(anchorType: .text, exactText: quote),
                      representation: .originalAudio(sourceURL: originalURL, durationMs: 600)),
                .init(packageScopedId: "margin-cleaned",
                      revision: revision("cleaned", transcript: "Heard cleaned up.", cleanedAudioPath: cleanedURL.path, cleanedAudioDurationMs: 200),
                      anchor: .init(anchorType: .text, exactText: quote),
                      representation: .cleanedAudio(sourceURL: cleanedURL)),
                .init(packageScopedId: "margin-text", revision: revision("text", transcript: "Only words."),
                      anchor: .init(anchorType: .text, exactText: quote), representation: .textOnly),
            ]
        )
        let verified = try packet(from: prepared, name: "voices")
        let records = verified.commentaryLayers.flatMap(\.interjections)
        XCTAssertEqual(records.count, 3)

        func recording(of scopedId: String) throws -> (descriptor: SpokenMarginsAssetDescriptor, bytes: Data)? {
            let record = try XCTUnwrap(records.first { $0.packageScopedId == scopedId })
            guard let assetId = record.defaultRepresentation?.assetId else { return nil }
            let descriptor = try XCTUnwrap(verified.manifest.assets.first { $0.id == assetId })
            let url = try XCTUnwrap(verified.extractedAssetURLs[assetId])
            return (descriptor, try Data(contentsOf: url))
        }

        let original = try XCTUnwrap(try recording(of: "margin-original"))
        XCTAssertEqual(original.descriptor.role, SpokenMarginsAssetRole.originalVoice)
        XCTAssertEqual(original.descriptor.durationMs, 600)
        XCTAssertEqual(original.bytes, originalBytes, "the original-voice Margin carries the original recording")

        let cleaned = try XCTUnwrap(try recording(of: "margin-cleaned"))
        XCTAssertEqual(cleaned.descriptor.role, SpokenMarginsAssetRole.cleanedVoice)
        XCTAssertEqual(cleaned.descriptor.durationMs, 200)
        XCTAssertEqual(cleaned.bytes, cleanedBytes, "the cleaned-voice Margin carries the cleaned recording")

        XCTAssertNil(try recording(of: "margin-text"), "a text-only Margin carries no voice")
        XCTAssertEqual(verified.manifest.assets.count, 2)
    }

    func testTheRecipientsImportedMarginsPointAtTheirOwnExtractedRecordings() throws {
        let originalURL = root.appendingPathComponent("original.m4a")
        let cleanedURL = root.appendingPathComponent("cleaned.m4a")
        try writeClip(to: originalURL, tenthsOfASecond: 6)
        try writeClip(to: cleanedURL, tenthsOfASecond: 2)
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-voices", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [
                .init(packageScopedId: "margin-original", revision: revision("original", transcript: "Heard as recorded."),
                      anchor: .init(anchorType: .text, exactText: quote),
                      representation: .originalAudio(sourceURL: originalURL, durationMs: 600)),
                .init(packageScopedId: "margin-cleaned",
                      revision: revision("cleaned", transcript: "Heard cleaned up.", cleanedAudioPath: cleanedURL.path, cleanedAudioDurationMs: 200),
                      anchor: .init(anchorType: .text, exactText: quote),
                      representation: .cleanedAudio(sourceURL: cleanedURL)),
            ]
        )
        let verified = try packet(from: prepared, name: "import-voices")
        let repository = InMemorySessionRepository()
        guard case .imported(let layerId, _) = try SpokenMarginsPackageImporter.importPackage(
            verified, itemId: "recipient-item", importedAt: created, repository: repository,
            makeLocalID: { kind, packageID in "recipient-\(kind)-\(packageID)" }
        ) else { return XCTFail("the packet should import") }
        let imported = try repository.loadImportedCommentaryInterjections(layerId: layerId)
        func bytes(_ scopedId: String) throws -> Data {
            let margin = try XCTUnwrap(imported.first { $0.packageScopedId == scopedId })
            return try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(margin.audioPath)))
        }
        XCTAssertEqual(try bytes("margin-original"), try Data(contentsOf: originalURL))
        XCTAssertEqual(try bytes("margin-cleaned"), try Data(contentsOf: cleanedURL))
        XCTAssertEqual(imported.first { $0.packageScopedId == "margin-original" }?.audioDurationMs, 600)
        XCTAssertEqual(imported.first { $0.packageScopedId == "margin-cleaned" }?.audioDurationMs, 200)
    }
}
