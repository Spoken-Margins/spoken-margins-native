import Foundation
import SessionKit
#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox
#endif

/// What the system's audio reader says about a file handed to Add Voice Margin (#4924): how long it runs and whether it
/// is an MPEG-4 audio file (M4A), the container a Margin's own voice is shared in. Read from the file's header; nothing
/// is decoded.
public enum AudioFileLength {
    /// The length in milliseconds, or nil when the file can't be opened as audio or reports no length.
    public static func milliseconds(of url: URL) -> Int? {
        #if canImport(AVFoundation)
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Int((Double(file.length) / rate * 1_000).rounded())
        #else
        return nil
        #endif
    }

    /// True when the file's container is MPEG-4 audio (an M4A, or MP4 with audio), whatever its name says.
    public static func isMPEG4Audio(_ url: URL) -> Bool {
        #if canImport(AVFoundation)
        var opened: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &opened) == noErr, let file = opened else { return false }
        defer { AudioFileClose(file) }
        var container: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &container) == noErr else { return false }
        return container == kAudioFileM4AType || container == kAudioFileMPEG4Type
        #else
        return false
        #endif
    }

    /// The reading `VoiceMarginImport.prepare` takes, or nil when the file can't be read as audio.
    public static func inspect(_ url: URL) -> VoiceMarginImport.Inspection? {
        guard let length = milliseconds(of: url) else { return nil }
        return VoiceMarginImport.Inspection(durationMs: length, isMPEG4Audio: isMPEG4Audio(url))
    }
}
