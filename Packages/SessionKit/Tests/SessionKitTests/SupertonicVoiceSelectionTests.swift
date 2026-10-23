#if canImport(AVFoundation)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKitSupertonic
import SessionKit

/// APA-15 (#1042): the only real-render test checked each voice against itself (a sample rate, a length,
/// a peak above 0.000001), so a renderer that always loaded James's style, or wrote near-silence, passed.
/// Here the real model (the `supertonicModel` input, a download since #1820) reads one sentence in each voice. Each must be clearly audible, and Lily's voice
/// must sit clearly higher than James's. The model starts each render from random noise, so two renders
/// never match sample for sample; the pitch of the voice is what a style changes and the noise doesn't.
final class SupertonicVoiceSelectionTests: XCTestCase {
    func testJamesAndLilyReadTheSameSentenceInTheirOwnAudibleVoices() async throws {
        let assets = try SupertonicTestModel.assets()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-voices-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = try SupertonicNarrationRenderer(assets: assets, outputDirectory: root, governor: OnDeviceVoiceGovernor())
        let sentence = "Both voices read this same sentence aloud, one after the other."
        func render(_ voice: SupertonicVoiceID) async throws -> (samples: [Float], sampleRate: Double) {
            let result = try await renderer.render(text: sentence, voice: voice, speed: 1, synthesisSteps: 5)
            let read = try Self.samples(at: result.audioURL)
            await renderer.discardGeneratedAudio(at: result.audioURL)
            return read
        }

        let james = try await render(.m2)
        let jamesAgain = try await render(.m2)
        let lily = try await render(.f2)
        await renderer.unload()

        XCTAssertGreaterThan(Self.peak(james.samples), 0.01, "James is audible, not near-silence")
        XCTAssertGreaterThan(Self.peak(lily.samples), 0.01, "Lily is audible, not near-silence")
        let jamesPitch = try XCTUnwrap(Self.medianPitch(james.samples, sampleRate: james.sampleRate), "James has a voiced pitch")
        let jamesAgainPitch = try XCTUnwrap(Self.medianPitch(jamesAgain.samples, sampleRate: jamesAgain.sampleRate))
        let lilyPitch = try XCTUnwrap(Self.medianPitch(lily.samples, sampleRate: lily.sampleRate), "Lily has a voiced pitch")
        let pitches = "James \(Int(jamesPitch)) Hz and \(Int(jamesAgainPitch)) Hz, Lily \(Int(lilyPitch)) Hz"
        print("APA-15 median pitch: \(pitches)")
        // Two renders of one voice differ by up to about 15% (53 lane runs, #1338), so the control allows 20%:
        // still well inside the 30% gap the voice check below asks for.
        XCTAssertLessThan(abs(jamesPitch - jamesAgainPitch) / jamesPitch, 0.2,
                          "control: one voice keeps its pitch from render to render: \(pitches)")
        XCTAssertGreaterThan(lilyPitch / jamesPitch, 1.3, "Lily's voice is not James's: \(pitches)")
    }

    private static func samples(at url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }

    private static func peak(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }

    /// The median fundamental frequency over the voiced frames, by autocorrelation in the range of
    /// speaking voices (70 to 400 Hz); nil when no frame is clearly voiced. The audio is averaged down to a
    /// quarter of its rate first, which keeps that range and makes the search sixteen times cheaper.
    private static func medianPitch(_ full: [Float], sampleRate fullRate: Double) -> Double? {
        let samples = stride(from: 0, to: full.count - 3, by: 4).map { (full[$0] + full[$0 + 1] + full[$0 + 2] + full[$0 + 3]) / 4 }
        let sampleRate = fullRate / 4
        let frame = Int(sampleRate * 0.04), hop = frame / 2
        let minLag = Int(sampleRate / 400), maxLag = Int(sampleRate / 70)
        let loudness = Double(peak(samples))
        var pitches: [Double] = []
        var start = 0
        while start + frame + maxLag <= samples.count {
            var energy = 0.0
            for index in start..<(start + frame) { energy += Double(samples[index] * samples[index]) }
            let rms = (energy / Double(frame)).squareRoot()
            if rms > loudness * 0.1 {
                var best = (lag: 0, score: 0.0)
                for lag in minLag...maxLag {
                    var product = 0.0, shifted = 0.0
                    for index in start..<(start + frame) {
                        product += Double(samples[index] * samples[index + lag])
                        shifted += Double(samples[index + lag] * samples[index + lag])
                    }
                    let score = product / max(1e-12, (energy * shifted).squareRoot())
                    if score > best.score { best = (lag, score) }
                }
                if best.score > 0.6 { pitches.append(sampleRate / Double(best.lag)) }
            }
            start += hop
        }
        guard pitches.count >= 5 else { return nil }
        return pitches.sorted()[pitches.count / 2]
    }
}
#endif
