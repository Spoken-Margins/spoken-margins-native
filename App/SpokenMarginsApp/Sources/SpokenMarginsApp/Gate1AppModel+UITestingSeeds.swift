import Foundation
import SessionKit
import SessionKitPersistence
#if canImport(AVFoundation)
import AVFoundation
#endif

/// UI-testing content seeds (#986), moved unchanged out of the central model.
/// Startup ordering, launch hooks and every stored property remain in Gate1AppModel.
extension Gate1AppModel {
    func seedUITestingGeneratedTimelineIfNeeded(sessionId: String, engine: SessionEngine, store: SQLiteSessionStore) throws {
        guard UITestingHooks.seed.seedsGeneratedTimeline,
              try store.loadTurns(sessionId: sessionId).isEmpty else {
            return
        }
        _ = try engine.submitFollowup(text: "Can you respond to my interjection?")
        _ = try engine.aiStreamDelta(
            turnId: "turn-response-001",
            content: """
            <sm_summary>Here is a quick response to your interjection.</sm_summary>
            <sm_response>Here is a quick response to your interjection. First, your test is checking whether generated turns stay easy to navigate. Second, the response chapters should remain tappable in the main timeline.</sm_response>
            <sm_chapters_json>{"schemaVersion":"assistant-response-map.v1","chapters":[{"id":"ai-ch-1","title":"Quick Response","anchor":"Here is a quick response"},{"id":"ai-ch-2","title":"Timeline Navigation","anchor":"Second, the response chapters"}]}</sm_chapters_json>
            """
        )
        _ = try engine.aiJobCompleted(turnId: "turn-response-001")
        snapshot = try engine.inspectSession(sessionId: sessionId)
    }

    func seedUITestingSummaryInterjectionIfNeeded(
        sessionId: String,
        engine: SessionEngine,
        store: SQLiteSessionStore
    ) throws {
        guard let note = UITestingHooks.summaryInterjectionNote,
              try store.loadInterjections(sessionId: sessionId).isEmpty else { return }
        let interjection = Interjection(
            id: "ij-ui-summary",
            itemId: activeItemId,
            sessionId: sessionId,
            targetType: .item,
            targetId: activeItemId,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: snapshot.sourceProgressPercent,
            anchor: Anchor(
                anchorType: .text,
                startChar: 0,
                endChar: min(24, selectedItem.text.count),
                anchorBefore: String(selectedItem.text.prefix(120)),
                anchorAfter: ""
            ),
            audioPath: nil,
            audioStatus: "saved",
            transcriptionStatus: "transcribed",
            transcript: note,
            cleanedTranscript: nil,
            displayText: note,
            status: "active",
            anchorContextStatus: .ready
        )
        try store.saveInterjection(interjection)
        snapshot = try engine.inspectSession(sessionId: sessionId)
        diagnostics["uiTestSummaryFixture"] = interjection.id
    }

    /// The Test Desk's Share Margins seed (#4647 PR 0): five of the listener's own spoken Margins on this session, each
    /// with an aligned transcript (`ShareBatchSeed`) and a matching recording, a 220 Hz tone at -20 dBFS over the words
    /// and digital silence in the two gaps, so the pause analysis finds them. Margins 2 and 4 are starred.
    func seedUITestingShareBatchIfNeeded(
        sessionId: String,
        engine: SessionEngine,
        store: SQLiteSessionStore
    ) throws {
        guard UITestingHooks.seedsShareBatch,
              try !store.loadInterjections(sessionId: sessionId).contains(where: { $0.id == ShareBatchSeed.id(margin: 1) })
        else { return }
        let folder = "SpokenMargins/ui-test-share-batch"
        let directory = try applicationSupportDirectory().appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for margin in 1...ShareBatchSeed.marginCount {
            let id = ShareBatchSeed.id(margin: margin)
            let transcript = ShareBatchSeed.transcript(margin: margin)
            let fileName = "\(id).m4a"
            try Self.writeShareBatchRecording(transcript: transcript, to: directory.appending(path: fileName))
            let interjection = Interjection(
                id: id,
                itemId: activeItemId,
                sessionId: sessionId,
                targetType: .item,
                targetId: activeItemId,
                createdAt: Date(timeIntervalSince1970: TimeInterval(10 + margin)),
                roughPercent: min(95, margin * 15),
                anchor: Anchor(
                    anchorType: .text,
                    startChar: 0,
                    endChar: min(24, selectedItem.text.count),
                    anchorBefore: String(selectedItem.text.prefix(120)),
                    anchorAfter: ""
                ),
                audioPath: "\(folder)/\(fileName)",
                audioStatus: "saved",
                transcriptionStatus: "transcribed",
                transcript: transcript.text,
                cleanedTranscript: nil,
                displayText: transcript.text,
                status: "active",
                anchorContextStatus: .ready,
                alignedTranscript: transcript,
                isStarredForSharing: ShareBatchSeed.starredMargins.contains(margin) ? true : nil
            )
            try store.saveInterjection(interjection)
        }
        snapshot = try engine.inspectSession(sessionId: sessionId)
        diagnostics["uiTestShareBatch"] = String(ShareBatchSeed.marginCount)
    }

    nonisolated private static func writeShareBatchRecording(transcript: AlignedInterjectionTranscript, to url: URL) throws {
        #if canImport(AVFoundation)
        try? FileManager.default.removeItem(at: url)
        let sampleRate = 22_050.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let totalFrames = Int(Double(transcript.segments.last?.endMs ?? 0) * sampleRate / 1_000)
        guard totalFrames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        for frame in 0..<totalFrames { samples[frame] = 0 }
        let amplitude: Float = 0.1 // -20 dBFS
        let step = 2 * Float.pi * 220 / Float(sampleRate)
        for segment in transcript.segments {
            let first = Int(Double(segment.startMs) * sampleRate / 1_000)
            let last = min(totalFrames, Int(Double(segment.endMs) * sampleRate / 1_000))
            for frame in first..<max(first, last) {
                samples[frame] = amplitude * sin(step * Float(frame))
            }
        }
        try file.write(from: buffer)
        #endif
    }
}
