import AVFoundation
import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import UIKit

extension Gate1AppModel {
    /// The app's model. A UI-test launch that asks for stand-in audio services
    /// records a generated tone and gets a fixed Margin transcript, so it never
    /// meets a microphone or Speech Recognition prompt.
    static func makeApplicationModel() -> Gate1AppModel {
        guard UITestingHooks.usesStandInAudioServices, let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return Gate1AppModel() }
        return Gate1AppModel(
            recordingClient: UITestingToneRecordingClient(supportDirectory: support),
            sourceTranscriptionClient: UITestingSourceTranscriptionClient(),
            interjectionTranscriptionHandler: { _ in UITestingMarginTranscript.text }
        )
    }
}

/// Resets the store and writes a UI-test seed's one item into it, with any
/// files that item needs. Called only for a seed that has an item, which a
/// normal launch never does.
enum UITestingLaunchSeedWriter {
    static func write(_ seed: UITestingLaunchSeed, into store: SQLiteSessionStore) throws -> Item {
        guard let item = seed.item else { throw CocoaError(.featureUnsupported) }
        try store.reset()
        if case let .offlinePodcast(_, durationSeconds) = seed {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let folder = support.appending(path: "PodcastAudio", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: UITestingLaunchSeed.podcastFileName)
            let bytes = try writeEpisodeAudio(to: url, seconds: durationSeconds)
            if let download = seed.podcastDownload(bytesWritten: bytes) {
                try store.savePodcastDownload(download)
            }
        }
        try store.seed(item: item)
        return item
    }

    /// A co-op relaunch (#474): adds one friend's layer, with a voice, to the podcast the first launch seeded, as
    /// importing a packet for an episode the listener already has would. Does nothing without the co-op switch, and
    /// a second relaunch that finds the layer already there adds nothing.
    static func importCoopLayerIfRequested(into store: SQLiteSessionStore) throws {
        guard UITestingHooks.importsCoopLayer else { return }
        let layer = UITestingLaunchSeed.coopLayer(importedAt: Date())
        guard try store.loadImportedCommentaryLayer(packageDigest: layer.packageDigest) == nil else { return }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        // The stand-in recorder writes a tone as long as its clock says the recording lasted.
        let began = Date()
        var reads = 0
        let recorder = UITestingToneRecordingClient(supportDirectory: support, now: {
            reads += 1
            return began.addingTimeInterval(reads == 1 ? 0 : Double(UITestingLaunchSeed.coopMarginDurationMs) / 1_000)
        })
        try recorder.beginRecording()
        let audioPath = try recorder.finishRecording(audioRef: nil)
        let margin = UITestingLaunchSeed.coopInterjection(audioPath: audioPath, createdAt: layer.importedAt)
        _ = try store.importCommentaryLayer(layer, interjections: [margin])
    }

    /// A quiet tone as small 8 kHz PCM, so writing a 25-minute episode takes well under a second.
    private static func writeEpisodeAudio(to url: URL, seconds: Int) throws -> Int64 {
        try? FileManager.default.removeItem(at: url)
        let sampleRate = 8_000.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let chunkFrames = AVAudioFrameCount(sampleRate * 10)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
                  let samples = buffer.int16ChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
            for frame in 0..<Int(chunkFrames) {
                samples[frame] = Int16(1_200 * sin(2 * Double.pi * 220 * Double(frame) / sampleRate))
            }
            buffer.frameLength = chunkFrames
            for _ in 0..<Int((Double(seconds) / 10).rounded(.up)) {
                try file.write(from: buffer)
            }
            // The download record must match the finished size on disk.
            file.close()
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return Int64(size)
    }

    /// A four-page text PDF with the page furniture J7 checks is not read: a
    /// running header, a "Downloaded on" stamp and page numbers on every page.
    static func writePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "J7 Walking Notes.pdf")
        let body = UIFont.systemFont(ofSize: 10)
        let small = UIFont.systemFont(ofSize: 9)
        let paragraphs = [
            "The first walk began at the river, where the path bends under the old willows and the water runs slow and brown.",
            "By the second mile the light had changed, and the hedges on either side held small birds that called and went quiet.",
            "At the top of the hill the town spread out below, roofs and chimneys, and a bell somewhere marking the hour.",
            "The way home followed the railway cutting, past allotments where someone was burning leaves in a small blue fire.",
        ]
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).writePDF(to: url) { context in
            for (page, paragraph) in paragraphs.enumerated() {
                context.beginPage()
                ("Quiet Walks Review · Volume 3" as NSString).draw(at: CGPoint(x: 40, y: 24), withAttributes: [.font: small])
                if page == 0 {
                    ("Walking Notes" as NSString).draw(at: CGPoint(x: 40, y: 70), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24)])
                }
                // Long pages keep one sentence under 1.5% of the text, so a percent check can be tight.
                let text = Array(repeating: paragraph, count: 18).joined(separator: " ")
                (text as NSString).draw(in: CGRect(x: 40, y: 120, width: 532, height: 560), withAttributes: [.font: body])
                ("Downloaded on 25 September 2026" as NSString).draw(at: CGPoint(x: 40, y: 760), withAttributes: [.font: small])
                ("\(page + 1)" as NSString).draw(at: CGPoint(x: 560, y: 760), withAttributes: [.font: small])
            }
        }
        return url
    }
}
