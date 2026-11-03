import Foundation
@testable import SessionKit
@testable import SessionKitSharing
import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Shared Margin audio goes out smaller: HE-AAC mono at 24 kbps, re-encoded when the packet is written and never
/// at recording time (#3218). The packet must still import through the shipped build's reader (`exportPacket`).
final class SharedMarginAudioCompressionTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private let quote = "The durable idea that prompted this note."
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedMarginAudioCompressionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private var item: SharedItemIdentity {
        SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")
    }

    private func revision(_ id: String, cleanedAudioPath: String? = nil, cleanedAudioDurationMs: Int? = nil) -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: "revision-\(id)", interjectionId: "private-\(id)", itemId: "private-item", sessionId: "private-session",
            createdAt: created, approvedTranscript: "Thought \(id).", cleanedAudioPath: cleanedAudioPath,
            cleanedAudioDurationMs: cleanedAudioDurationMs, anchorBefore: "Before.", anchorAfter: "After.", status: .senderApproved
        )
    }

    private func prepared(original: URL?, cleaned: URL?) throws -> PreparedSpokenMarginsPackage {
        var selections: [ReviewedInterjectionSelection] = []
        if let original {
            selections.append(.init(
                packageScopedId: "margin-original", revision: revision("original"),
                anchor: .init(anchorType: .text, exactText: quote),
                representation: .originalAudio(sourceURL: original, durationMs: 20_000)))
        }
        if let cleaned {
            selections.append(.init(
                packageScopedId: "margin-cleaned",
                revision: revision("cleaned", cleanedAudioPath: cleaned.path, cleanedAudioDurationMs: 20_000),
                anchor: .init(anchorType: .text, exactText: quote),
                representation: .cleanedAudio(sourceURL: cleaned)))
        }
        if selections.isEmpty {
            selections.append(.init(
                packageScopedId: "margin-text", revision: revision("text"),
                anchor: .init(anchorType: .text, exactText: quote), representation: .textOnly))
        }
        return try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-compress", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: selections)
    }

    /// A voice file the reader accepts: a real tone on a Mac, an `ftyp` header plus filler elsewhere.
    private func writeVoice(to url: URL, short: Bool = false) throws {
        #if canImport(AVFoundation)
        try Self.writeSpeechLikeAAC(to: url, seconds: short ? 4 : 20)
        #else
        let header: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, 0, 0, 0, 0]
        try (Data(header) + Data(repeating: 7, count: short ? 4_000 : 40_000)).write(to: url)
        #endif
    }

    /// Stands in for the encoder: hands back a valid, shorter voice file (a truncated m4a would not open on a Mac).
    private func smallerTranscoder() throws -> CopyTranscoder {
        let small = root.appendingPathComponent("small-fixture.m4a")
        try writeVoice(to: small, short: true)
        return CopyTranscoder(smaller: small)
    }

    private func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private struct CopyTranscoder: SharedMarginAudioTranscoding {
        let smaller: URL
        func transcode(_ source: URL, to destination: URL) async throws {
            try FileManager.default.copyItem(at: smaller, to: destination)
        }
    }

    private struct BiggerTranscoder: SharedMarginAudioTranscoding {
        func transcode(_ source: URL, to destination: URL) async throws {
            try (try Data(contentsOf: source) + Data(repeating: 1, count: 500)).write(to: destination)
        }
    }

    private struct FailingTranscoder: SharedMarginAudioTranscoding {
        struct Failed: Error {}
        func transcode(_ source: URL, to destination: URL) async throws { throw Failed() }
    }

    // MARK: Host tests (a fake encoder)

    func testVoiceAssetsGoOutAsSmallerCopiesAndNothingElseInThePacketChanges() async throws {
        let original = root.appendingPathComponent("original.m4a")
        let cleaned = root.appendingPathComponent("cleaned.m4a")
        try writeVoice(to: original)
        try writeVoice(to: cleaned)
        let before = try prepared(original: original, cleaned: cleaned)

        let (after, report) = await SharedMarginAudioCompression.compressed(
            before, workingIn: root.appendingPathComponent("staging"), using: try smallerTranscoder())

        XCTAssertEqual(report.compressedCount, 2)
        XCTAssertEqual(report.keptOriginalCount, 0)
        XCTAssertLessThan(report.sentBytes, report.originalBytes)
        XCTAssertEqual(after.manifest, before.manifest, "descriptors, paths and durations are what the shipped builds already read")
        XCTAssertEqual(after.artifactData, before.artifactData)
        XCTAssertEqual(Set(after.assetFiles.keys), Set(before.assetFiles.keys))
        for (path, url) in after.assetFiles {
            XCTAssertNotEqual(url, before.assetFiles[path], "\(path) still points at the recording")
            XCTAssertLessThan(size(url), size(before.assetFiles[path]!))
        }
        // The sender's own recordings are left where they were.
        XCTAssertGreaterThan(size(original), size(after.assetFiles.values.first!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))

        let fullURL = root.appendingPathComponent("full.spokenmargins")
        let smallURL = root.appendingPathComponent("small.spokenmargins")
        try exportPacket(before, to: fullURL)
        try exportPacket(after, to: smallURL)
        XCTAssertLessThan(size(smallURL), size(fullURL))
        let verified = try SpokenMarginsPackageArchive.read(from: smallURL, extractingAssetsTo: root.appendingPathComponent("assets"))
        XCTAssertEqual(verified.manifest.assets.filter { $0.role == SpokenMarginsAssetRole.originalVoice }.count, 1)
        XCTAssertEqual(verified.manifest.assets.filter { $0.role == SpokenMarginsAssetRole.cleanedVoice }.count, 1)
    }

    func testACopyThatIsNotSmallerIsNotSent() async throws {
        let original = root.appendingPathComponent("original.m4a")
        try writeVoice(to: original)
        let before = try prepared(original: original, cleaned: nil)

        let (after, report) = await SharedMarginAudioCompression.compressed(
            before, workingIn: root.appendingPathComponent("staging"), using: BiggerTranscoder())

        XCTAssertEqual(report.compressedCount, 0)
        XCTAssertEqual(report.keptOriginalCount, 1)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertEqual(after.assetFiles, before.assetFiles)
        XCTAssertEqual(report.sentBytes, report.originalBytes)
    }

    func testAFailedReEncodeSendsTheRecordingAsItIsAndTheShareStillWorks() async throws {
        let original = root.appendingPathComponent("original.m4a")
        let cleaned = root.appendingPathComponent("cleaned.m4a")
        try writeVoice(to: original)
        try writeVoice(to: cleaned)
        let before = try prepared(original: original, cleaned: cleaned)

        let (after, report) = await SharedMarginAudioCompression.compressed(
            before, workingIn: root.appendingPathComponent("staging"), using: FailingTranscoder())

        XCTAssertEqual(report.failedCount, 2)
        XCTAssertEqual(report.keptOriginalCount, 2)
        XCTAssertEqual(after.assetFiles, before.assetFiles)
        XCTAssertNoThrow(try exportPacket(after, to: root.appendingPathComponent("kept.spokenmargins")))
    }

    func testATextOnlyPacketIsReturnedUntouchedWithoutMakingAFolder() async throws {
        let before = try prepared(original: nil, cleaned: nil)
        let staging = root.appendingPathComponent("staging")

        let (after, report) = await SharedMarginAudioCompression.compressed(before, workingIn: staging, using: FailingTranscoder())

        XCTAssertEqual(report, SharedMarginAudioCompressionReport())
        XCTAssertEqual(after.assetFiles, before.assetFiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testEvidenceAssetsAreNeverRunThroughTheEncoder() async throws {
        let original = root.appendingPathComponent("original.m4a")
        try writeVoice(to: original)
        let signature = root.appendingPathComponent("signature.shazamsignature")
        try Data(repeating: 9, count: 2_000).write(to: signature)
        let withEvidence = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-evidence", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-original", revision: revision("original"),
                anchor: .init(anchorType: .text, exactText: quote, machineEvidenceAssetIds: ["evidence-1"]),
                representation: .originalAudio(sourceURL: original, durationMs: 20_000))],
            machineEvidence: [ReviewedMachineEvidenceAsset(
                id: "evidence-1", path: "assets/evidence/evidence-1.shazamsignature", sourceURL: signature,
                durationMs: 12_000, anchorOffsetMs: 0)])

        let (after, report) = await SharedMarginAudioCompression.compressed(
            withEvidence, workingIn: root.appendingPathComponent("staging"), using: try smallerTranscoder())

        XCTAssertEqual(report.compressedCount, 1, "only the voice file")
        XCTAssertEqual(after.assetFiles["assets/evidence/evidence-1.shazamsignature"], signature)
    }

    // MARK: The real encoder (a Mac)

    #if canImport(AVFoundation)
    /// Twenty seconds of a voice-like signal (a drifting tone with syllable-rate swells and a little noise) as AAC at
    /// 44.1 kHz mono, the way a Margin is recorded.
    private static func writeSpeechLikeAAC(to url: URL, seconds: Double) throws {
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        var noise: UInt32 = 12_345
        for frame in 0..<Int(frames) {
            let t = Double(frame) / sampleRate
            let swell = 0.5 + 0.5 * sin(2 * .pi * 3.5 * t)
            let pitch = 140 + 40 * sin(2 * .pi * 0.4 * t)
            noise = noise &* 1_664_525 &+ 1_013_904_223
            let hiss = (Double(noise >> 8) / Double(1 << 24) - 0.5) * 0.02
            samples[frame] = Float(swell * (0.25 * sin(2 * .pi * pitch * t) + 0.12 * sin(2 * .pi * pitch * 3 * t)) + hiss)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
        try file.write(from: buffer)
    }

    private func seconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func testTheRealEncoderShrinksARecordingToAboutTwentyFourKilobitsAndItStillPlaysAndImports() async throws {
        let original = root.appendingPathComponent("original.m4a")
        try Self.writeSpeechLikeAAC(to: original, seconds: 20)
        let before = try prepared(original: original, cleaned: nil)

        let (after, report) = await SharedMarginAudioCompression.compressed(
            before, workingIn: root.appendingPathComponent("staging"), using: AVFoundationMarginAudioTranscoder())

        XCTAssertEqual(report.compressedCount, 1, "the encoder produced a file: \(report)")
        XCTAssertEqual(report.failedCount, 0)
        let sent = try XCTUnwrap(after.assetFiles.values.first)
        XCTAssertLessThan(Double(size(sent)), Double(size(original)) * 0.6, "the copy is well under today's recording")
        let kilobitsPerSecond = Double(size(sent)) * 8 / 20 / 1_000
        XCTAssertLessThan(kilobitsPerSecond, 32, "about 24 kbps plus the container")

        // It decodes with AVFoundation, as long as the recording, and stays mono.
        let decoded = try AVAudioFile(forReading: sent)
        XCTAssertEqual(decoded.processingFormat.channelCount, 1)
        XCTAssertEqual(try seconds(of: sent), 20, accuracy: 0.25)

        // The shipped build's reader (`exportPacket`) and this build's both accept the packet, and the listener's
        // copy decodes from the extracted file.
        let packetURL = root.appendingPathComponent("hq.spokenmargins")
        try exportPacket(after, to: packetURL)
        let verified = try SpokenMarginsPackageArchive.read(from: packetURL, extractingAssetsTo: root.appendingPathComponent("assets"))
        let extracted = try XCTUnwrap(verified.extractedAssetURLs.values.first)
        XCTAssertEqual(try seconds(of: extracted), 20, accuracy: 0.25)
        XCTAssertEqual(verified.manifest.assets.first?.durationMs, 20_000)

        // The sender's recording is untouched.
        XCTAssertEqual(try seconds(of: original), 20, accuracy: 0.25)
    }

    /// The padded file is the last resort when the remux fails. It is measured against the recording like the remux
    /// is, so a saved file that came out short is refused and the recording goes out (#3218 audit note).
    func testWhenTheRemuxFailsTheEncodedFileIsUsedOnlyIfItIsTheRecordingsLength() async throws {
        let source = root.appendingPathComponent("source.m4a")
        let shortCopy = root.appendingPathComponent("short.encoded.m4a")
        let fullCopy = root.appendingPathComponent("full.encoded.m4a")
        try Self.writeSpeechLikeAAC(to: source, seconds: 20)
        try Self.writeSpeechLikeAAC(to: shortCopy, seconds: 5)
        try Self.writeSpeechLikeAAC(to: fullCopy, seconds: 20)
        let refused = root.appendingPathComponent("refused.m4a")
        let accepted = root.appendingPathComponent("accepted.m4a")

        do {
            try await AVFoundationMarginAudioTranscoder.place(shortCopy, at: refused, matchingSecondsOf: source) { _, _ in false }
            XCTFail("a 5 s file must not stand in for a 20 s recording")
        } catch let error as SharedMarginAudioTranscodingError {
            guard case .conversionFailed = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))

        try await AVFoundationMarginAudioTranscoder.place(fullCopy, at: accepted, matchingSecondsOf: source) { _, _ in false }
        XCTAssertEqual(try seconds(of: accepted), 20, accuracy: 0.25)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fullCopy.path), "the encoded file moved into place")
    }

    func testAFileThatIsNotAudioIsKeptAsItIs() async throws {
        let notAudio = root.appendingPathComponent("broken.m4a")
        try Data(repeating: 3, count: 4_000).write(to: notAudio)
        let before = try prepared(original: notAudio, cleaned: nil)

        let (after, report) = await SharedMarginAudioCompression.compressed(
            before, workingIn: root.appendingPathComponent("staging"), using: AVFoundationMarginAudioTranscoder())

        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(after.assetFiles, before.assetFiles)
    }
    #endif
}
