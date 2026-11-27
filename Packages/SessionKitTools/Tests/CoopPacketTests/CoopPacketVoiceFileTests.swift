import AVFoundation
import Foundation
import SessionKit
import SessionKitSharing
@testable import CoopPacket
import XCTest

/// A plan can hand `coop-packet build` a recording for a Margin (`margins[].voiceFile`) instead of having `say` speak
/// it, so synthetic packets can carry a better voice. The packet must carry that recording, encoded the way the app
/// encodes a shared Margin (HE-AAC mono, 24 kbps, `.m4a`), and keep its length.
final class CoopPacketVoiceFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CoopPacketVoiceFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A 3.2 s mono tone at 44.1 kHz in a WAV file, standing in for a rendered voice.
    private func writeTone(seconds: Double) throws -> URL {
        let url = root.appending(path: "voice.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) { samples[i] = 0.3 * sin(Float(i) * 2 * .pi * 220 / 44_100) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testAVoiceFileIsSentEncodedAsTheAppSendsAMarginAndKeepsItsLength() async throws {
        _ = try writeTone(seconds: 3.2)
        let body: [String: Any] = [
            "sender": "synthetic test",
            "packageId": "package-voice-file-test",
            "createdAt": "2026-11-17T12:00:00Z",
            "item": ["itemType": "podcast", "canonicalURL": "https://example.invalid/episode", "title": "Episode", "durationMs": 600_000],
            "margins": [["id": "m-1", "atMs": 60_000, "text": "A note.", "voiceFile": "voice.wav"]]
        ]
        let planURL = root.appending(path: "plan.json")
        try JSONSerialization.data(withJSONObject: body).write(to: planURL)

        let built = try await PacketBuilder.build(planURL: planURL, outDirectory: root)
        let packet = try SpokenMarginsPackageArchive.read(from: built.url, extractingAssetsTo: root.appending(path: "assets"))
        let voice = try XCTUnwrap(packet.manifest.assets.first { $0.role == SpokenMarginsAssetRole.originalVoice })
        XCTAssertEqual(voice.mimeType, "audio/mp4")
        let file = try AVAudioFile(forReading: try XCTUnwrap(packet.extractedAssetURLs[voice.id]))
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 3.2, accuracy: 0.15)
        let description = file.fileFormat.streamDescription.pointee
        XCTAssertEqual(description.mFormatID, kAudioFormatMPEG4AAC_HE, "the recording, not a `say` voice (AAC-LC), is sent")
        XCTAssertEqual(description.mChannelsPerFrame, 1)
    }

    func testAMissingVoiceFileFailsTheBuildAndNamesTheFile() async throws {
        let body: [String: Any] = [
            "sender": "synthetic test",
            "item": ["itemType": "podcast", "canonicalURL": "https://example.invalid/episode", "title": "Episode"],
            "margins": [["id": "m-1", "atMs": 1_000, "text": "A note.", "voiceFile": "missing.wav"]]
        ]
        let planURL = root.appending(path: "plan.json")
        try JSONSerialization.data(withJSONObject: body).write(to: planURL)
        do {
            _ = try await PacketBuilder.build(planURL: planURL, outDirectory: root)
            XCTFail("a plan naming a missing voice file must not build")
        } catch {
            XCTAssertTrue("\(error)".contains("missing.wav"), "\(error)")
        }
    }
}
