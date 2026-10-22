import Foundation
import XCTest
@testable import SessionKit

/// #2481: live capture's PCM conversion, file-time padding and Margin placement.
final class LiveCaptureTests: XCTestCase {
    // MARK: PCM decoding

    private func int16Data(_ values: [Int16], bigEndian: Bool) -> Data {
        var data = Data()
        for value in values {
            let bits = UInt16(bitPattern: value)
            let ordered = bigEndian ? bits.bigEndian : bits.littleEndian
            withUnsafeBytes(of: ordered) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func float32Data(_ values: [Float]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    func testBigEndianInterleavedStereoInt16DownmixesToMono() {
        let format = LiveCaptureSourceFormat(
            sampleRate: 44_100, channels: 2, bitsPerChannel: 16,
            formatFlags: LiveCaptureSourceFormat.flagIsSignedInteger | LiveCaptureSourceFormat.flagIsBigEndian
        )
        let data = int16Data([16_384, 0, -16_384, -16_384], bigEndian: true)
        let mono = LiveCapturePCM.monoSamples(buffers: [data], format: format)
        XCTAssertEqual(mono.count, 2)
        XCTAssertEqual(mono[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(mono[1], -0.5, accuracy: 0.0001)
    }

    func testLittleEndianInt16ReadsTheSameValuesAsBigEndian() {
        let flags = LiveCaptureSourceFormat.flagIsSignedInteger
        let format = LiveCaptureSourceFormat(sampleRate: 48_000, channels: 1, bitsPerChannel: 16, formatFlags: flags)
        let mono = LiveCapturePCM.monoSamples(buffers: [int16Data([8_192, -32_768], bigEndian: false)], format: format)
        XCTAssertEqual(mono, [0.25, -1])
    }

    func testNonInterleavedFloatAveragesPlanes() {
        let format = LiveCaptureSourceFormat(
            sampleRate: 48_000, channels: 2, bitsPerChannel: 32,
            formatFlags: LiveCaptureSourceFormat.flagIsFloat | LiveCaptureSourceFormat.flagIsNonInterleaved
        )
        let mono = LiveCapturePCM.monoSamples(buffers: [float32Data([1, 0.5]), float32Data([0, 0.5])], format: format)
        XCTAssertEqual(mono, [0.5, 0.5])
    }

    func testUnsupportedWidthGivesNoSamples() {
        let format = LiveCaptureSourceFormat(sampleRate: 48_000, channels: 1, bitsPerChannel: 24, formatFlags: 0)
        XCTAssertEqual(LiveCapturePCM.monoSamples(buffers: [Data(count: 6)], format: format), [])
    }

    func testInt16LittleEndianClipsAndRoundTrips() {
        let data = LiveCapturePCM.int16LittleEndian([0.5, 2, -2, .nan])
        let format = LiveCaptureSourceFormat(sampleRate: 16_000, channels: 1, bitsPerChannel: 16, formatFlags: LiveCaptureSourceFormat.flagIsSignedInteger)
        let back = LiveCapturePCM.monoSamples(buffers: [data], format: format)
        XCTAssertEqual(back[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(back[1], 1, accuracy: 0.001)
        XCTAssertEqual(back[2], -1, accuracy: 0.001)
        XCTAssertEqual(back[3], 0)
    }

    func testPeakAndRMS() {
        let level = LiveCapturePCM.peakAndRMS([0.5, -0.5, 0.5, -0.5])
        XCTAssertEqual(level.peak, 0.5)
        XCTAssertEqual(level.rms, 0.5, accuracy: 0.0001)
        XCTAssertEqual(LiveCapturePCM.peakAndRMS([]).peak, 0)
    }

    // MARK: Resampling

    func testResamplerOutputsTheTargetRateAcrossBuffers() {
        let ramp = (0..<44_100).map { Float($0) / 44_100 }
        var whole = LiveCaptureResampler()
        let once = whole.process(ramp, sourceRate: 44_100)
        var chunked = LiveCaptureResampler()
        var pieces: [Float] = []
        var start = 0
        for size in [1_024, 333, 1, 4_096, 2_000] where start < ramp.count {
            let end = min(ramp.count, start + size)
            pieces += chunked.process(Array(ramp[start..<end]), sourceRate: 44_100)
            start = end
        }
        while start < ramp.count {
            let end = min(ramp.count, start + 1_024)
            pieces += chunked.process(Array(ramp[start..<end]), sourceRate: 44_100)
            start = end
        }
        XCTAssertEqual(once.count, 16_000, accuracy: 1)
        XCTAssertEqual(pieces.count, once.count, accuracy: 1)
        for (a, b) in zip(once, pieces) { XCTAssertEqual(a, b, accuracy: 0.0001) }
        // A ramp stays a ramp: each output sits at its source time.
        XCTAssertEqual(once[8_000], 0.5, accuracy: 0.001)
    }

    func testResamplerPassesThroughAtTheTargetRate() {
        var resampler = LiveCaptureResampler()
        XCTAssertEqual(resampler.process([0.1, 0.2], sourceRate: 16_000), [0.1, 0.2])
        XCTAssertEqual(resampler.process([], sourceRate: 16_000), [])
    }

    func testResamplerUpsamples() {
        var resampler = LiveCaptureResampler()
        let out = resampler.process([Float](repeating: 0.25, count: 8_000), sourceRate: 8_000)
        XCTAssertEqual(out.count, 15_999, accuracy: 2)
        XCTAssertTrue(out.allSatisfy { abs($0 - 0.25) < 0.0001 })
    }

    // MARK: Padding and offsets

    func testSilencePaddingFillsOnlyRealGaps() {
        XCTAssertEqual(LiveCapturePCM.silencePaddingSamples(writtenSamples: 16_000, elapsedSeconds: 1.1), 0)
        XCTAssertEqual(LiveCapturePCM.silencePaddingSamples(writtenSamples: 16_000, elapsedSeconds: 3), 32_000)
        XCTAssertEqual(LiveCapturePCM.silencePaddingSamples(writtenSamples: 48_000, elapsedSeconds: 2), 0)
        XCTAssertEqual(LiveCapturePCM.silencePaddingSamples(writtenSamples: 0, elapsedSeconds: .nan), 0)
    }

    func testMarginOffsetCountsFromTheFirstBuffer() {
        let first = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(LiveCaptureMargin.offsetMs(now: first.addingTimeInterval(12.3456), firstBufferAt: first), 12_346)
        XCTAssertEqual(LiveCaptureMargin.offsetMs(now: first, firstBufferAt: nil), 0)
        XCTAssertEqual(LiveCaptureMargin.offsetMs(now: first.addingTimeInterval(-1), firstBufferAt: first), 0)
    }

    func testStatusAndConfigRoundTripThroughJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "live-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var status = LiveCaptureStatus(sessionId: "s1", state: .running, startedAt: Date(timeIntervalSince1970: 5))
        status.samplesWritten = 32_000
        status.sourceFormat = LiveCaptureSourceFormat(sampleRate: 44_100, channels: 2, bitsPerChannel: 16, formatFlags: 6)
        try LiveCaptureFiles.write(status, to: LiveCaptureFiles.statusURL(id: "s1", in: directory))
        let read = LiveCaptureFiles.read(LiveCaptureStatus.self, from: LiveCaptureFiles.statusURL(id: "s1", in: directory))
        XCTAssertEqual(read, status)
        XCTAssertEqual(read?.durationMs, 2_000)
        XCTAssertEqual(read?.sourceFormat?.summary, "44100 Hz · 2 ch · Int16 BE")
    }

    // MARK: Margin placement

    private func audioItem(durationMs: Int?) -> Item {
        Item(
            id: "audiobook-live", title: "Live capture", mediaType: "audiobook", text: nil,
            externalReference: "file:///tmp/live.m4a", status: "ready", externalReferenceType: "audiobook",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/live.m4a", durationMs: durationMs, nativeMediaId: "audiobook-audio-live")
        )
    }

    private func repository(_ item: Item) -> InMemorySessionRepository {
        InMemorySessionRepository(items: [item.id: item], sessions: [:], interjections: [:])
    }

    func testMarginsLandAtTheirTimesAndThePlaceIsLeftAtTheStart() throws {
        let item = audioItem(durationMs: 120_000)
        let repo = repository(item)
        let margins = [
            LiveCaptureMargin(id: "b", text: "Second", offsetMs: 70_000, createdAt: Date()),
            LiveCaptureMargin(id: "a", text: "First", offsetMs: 12_500, createdAt: Date()),
            LiveCaptureMargin(id: "c", text: "   ", offsetMs: 80_000, createdAt: Date()),
            LiveCaptureMargin(id: "d", text: "Past the end", offsetMs: 500_000, createdAt: Date())
        ]
        let saved = try LiveCaptureMarginPlacer.place(margins, itemId: item.id, repository: repo)
        XCTAssertEqual(saved.map(\.displayText), ["First", "Second", "Past the end"])
        XCTAssertEqual(saved.map(\.anchor.mediaTimeMs), [12_500, 70_000, 119_999])
        let sessions = try repo.loadSessions(itemId: item.id)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.position.mediaTimeMs, 0)
        XCTAssertEqual(try repo.loadInterjections(sessionId: sessions[0].id).count, 3)
    }

    func testNoMarginsStillGivesTheItemASession() throws {
        let item = audioItem(durationMs: nil)
        let repo = repository(item)
        XCTAssertEqual(try LiveCaptureMarginPlacer.place([], itemId: item.id, repository: repo), [])
        XCTAssertEqual(try repo.loadSessions(itemId: item.id).count, 1)
    }

    func testMissingOrNonAudioItemsThrowBeforeWriting() {
        let text = Item(id: "t", title: "Text", mediaType: "text", text: "Hi", externalReference: nil, status: "ready")
        let repo = repository(text)
        XCTAssertThrowsError(try LiveCaptureMarginPlacer.place([], itemId: "missing", repository: repo)) {
            XCTAssertEqual($0 as? LiveCaptureMarginPlacer.Failure, .itemNotFound)
        }
        XCTAssertThrowsError(try LiveCaptureMarginPlacer.place([], itemId: "t", repository: repo)) {
            XCTAssertEqual($0 as? LiveCaptureMarginPlacer.Failure, .notAudio)
        }
    }
}
