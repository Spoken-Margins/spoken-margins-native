import AVFoundation
import Foundation
import SessionKit
import SessionKitPersistence

extension UITestingLaunchSeed {
    /// This process's seed. `.none` unless the app was launched with `--ui-testing`.
    static let current = UITestingLaunchSeed(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    )
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
}
