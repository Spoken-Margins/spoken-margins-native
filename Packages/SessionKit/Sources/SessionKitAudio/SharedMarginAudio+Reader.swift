import Foundation
import SessionKit

#if canImport(AVFoundation)
extension SharedMarginAudio {
    /// `resolve` with `reader` answering whether a reading is ready. Asking is an in-memory look-up (no disk on the
    /// calling thread), so this is safe on the main thread. It starts no render; use `startingRender(on:)` to play.
    public static func resolve(
        _ margin: ImportedCommentaryInterjection,
        in layer: ImportedCommentaryLayer,
        voiceFile: (_ audioPath: String) -> URL?,
        reader: WrittenMarginReader
    ) -> SharedMarginAudio {
        resolve(margin, in: layer, voiceFile: voiceFile, reading: { (reader.fileURL(for: $0), reader.isReady($0)) })
    }

    /// The file to play, after making sure a reading that is not ready is being rendered (the same call starts and finds a
    /// render already running). Nil when nothing can play.
    public func startingRender(on reader: WrittenMarginReader) -> URL? {
        if case .readingRendering(let reading, _) = self { return reader.start(["margin": reading])["margin"] }
        return file
    }
}
#endif
