import Foundation

/// Tells a finished podcast download that is really a web page or a message apart from audio (#919).
///
/// A hotel Wi-Fi sign-in page, a CDN error or a login redirect can come back as HTML with a 200 status,
/// so the status alone doesn't say the episode arrived. Every audio container (MP3, M4A, WAV, Ogg,
/// FLAC, AIFF) carries non-text bytes in its first few hundred bytes: length fields, zero padding, frame
/// headers. A file whose opening bytes are all plain text is none of them, whatever the server's
/// Content-Type or the file name claims. The check goes one way only: it refuses what is clearly text and
/// lets every other file through, so an audio format it has never heard of is never turned away.
public enum DownloadedAudioSniffer {
    /// How much of the start of the file is looked at.
    public static let prefixLength = 512

    /// True when `prefix` holds only text: printable characters, tabs and line breaks, no control bytes.
    /// An empty prefix is not text; an empty file is the caller's separate case.
    public static func looksLikeText(_ prefix: Data) -> Bool {
        let head = prefix.prefix(prefixLength)
        guard !head.isEmpty else { return false }
        return !head.contains(where: isControlByte)
    }

    /// True when the start of the file at `url` is text. A file that can't be read is not called text:
    /// unknown is not a reason to refuse it.
    public static func looksLikeText(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: prefixLength) else { return false }
        return looksLikeText(prefix)
    }

    /// Tab, line feed and carriage return are text. Every other byte below space, and DEL, is not.
    private static func isControlByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x09, 0x0A, 0x0D: false
        case 0x00...0x1F, 0x7F: true
        default: false
        }
    }
}
