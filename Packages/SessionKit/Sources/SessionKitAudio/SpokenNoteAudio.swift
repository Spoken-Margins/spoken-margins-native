import Foundation
import SessionKit

/// The speech recognizer behind a spoken note's transcripts (#3108). It is the one every Margin uses: on-device,
/// word by word with times, so `SpokenNoteSentenceGrouping` can cut sentences at pauses and end punctuation.
public struct SystemSpokenNoteTranscriber: SpokenNoteTranscribing {
    private let client: SystemSpeechTranscriptionClient

    public init(client: SystemSpeechTranscriptionClient = SystemSpeechTranscriptionClient()) {
        self.client = client
    }

    public func transcribe(fileAt url: URL) async throws -> [AlignedTranscriptSegment] {
        try await client.transcribeAligned(audioPath: url.path).segments
    }
}

#if canImport(AVFoundation)
import AVFoundation

/// How long a take's audio file is, in milliseconds. 0 for a file that won't open yet (a recording cut off before its
/// closing index): it is kept either way.
public enum SpokenNoteAudioFile {
    public static func durationMs(of url: URL) -> Int {
        if case .milliseconds(let ms) = RecordedFileDuration.measure(url) { return ms }
        return 0
    }
}
#endif

#if canImport(AVFoundation) && os(iOS)
import AVFoundation

/// Records one take of a spoken note to an AAC file with `AVAudioRecorder` (#3108).
///
/// The app's `audio` background mode keeps a `playAndRecord` session recording with the screen off, so a take
/// goes on when the phone locks. A call, Siri or another app taking the microphone ends the recording on its own;
/// the handler then lets the coordinator close the take with what was taken in so far.
public final class SystemSpokenNoteTakeRecorder: NSObject, SpokenNoteTakeRecording, AVAudioRecorderDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var handler: (@Sendable () -> Void)?
    private var stoppedByUs = false
    private var capturedHighWaterMs = 0
    private var interruptionObserver: NSObjectProtocol?

    public override init() {
        super.init()
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    public func setStoppedBySystemHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    public func begin(writingTo url: URL) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.prepareToRecord(), recorder.record() else {
            recorder.stop() // a prepared recorder's audio queue is running; freed unstopped, it crashes (#3633)
            // The empty file this call just made holds nothing; the session goes back to other apps.
            try? FileManager.default.removeItem(at: url)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw SessionKitError.persistenceFailed("spoken_note_recording_failed")
        }
        lock.withLock {
            self.recorder = recorder
            self.url = url
            stoppedByUs = false
            capturedHighWaterMs = 0
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: nil
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
            self?.systemEndedRecording()
        }
    }

    public func end() async throws -> Int {
        let taken = lock.withLock { () -> (AVAudioRecorder, URL, Int)? in
            guard let recorder, let url else { return nil }
            stoppedByUs = true
            let highWater = max(capturedHighWaterMs, Int((recorder.currentTime * 1_000).rounded()))
            return (recorder, url, highWater)
        }
        guard let (recorder, url, highWater) = taken else {
            throw SessionKitError.persistenceFailed("spoken_note_not_recording")
        }
        recorder.stop()
        lock.withLock {
            self.recorder = nil
            self.url = nil
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        // Handed back to other apps; fails harmlessly while the app's own playback is running.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // The stopped recorder reports 0 for its time, so the length comes from the closed file. A file that won't open
        // keeps the longest time the recorder showed: the audio is kept either way.
        switch RecordedFileDuration.measure(url) {
        case .milliseconds(let ms) where ms > 0: return ms
        default: return highWater
        }
    }

    /// The recorder ended without the coordinator asking: note how long it ran, then tell the coordinator once.
    private func systemEndedRecording(from caller: AVAudioRecorder? = nil) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            // A late callback from an earlier take's recorder must not end the one running now.
            if let caller, caller !== recorder { return nil }
            guard let recorder, !stoppedByUs else { return nil }
            capturedHighWaterMs = max(capturedHighWaterMs, Int((recorder.currentTime * 1_000).rounded()))
            let current = handler
            handler = nil
            return current
        }
        notify?()
    }

    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // After our own stop() this is the echo; the coordinator already knows.
        systemEndedRecording(from: recorder)
    }

    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        systemEndedRecording(from: recorder)
    }
}
#endif

#if canImport(AVFoundation)
import AVFoundation

/// Joins a spoken note's takes into one `.m4a` (#3660) for Export. The takes are read, never changed: they are laid end
/// to end in a composition and exported as AAC to the new file. A take whose audio can't be opened fails the join, so a
/// share never carries a note with a silent gap where a take should be.
public struct SpokenNoteAudioJoiner: SpokenNoteAudioJoining {
    public enum JoinError: Error, Equatable {
        case noAudio
        case exportFailed
    }

    public init() {}

    public func join(_ sources: [URL], to destination: URL) async throws -> Int {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw JoinError.exportFailed
        }
        var cursor = CMTime.zero
        var skipped = 0
        for source in sources {
            // A take that can't be opened (cut short by a system stop, say) is left out and counted; the rest still join.
            let asset = AVURLAsset(url: source)
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration),
                  (try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: cursor)) != nil
            else {
                skipped += 1
                continue
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard skipped < sources.count else { throw JoinError.noAudio }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw JoinError.exportFailed
        }
        try await exporter.export(to: destination, as: .m4a)
        return skipped
    }
}
#endif
