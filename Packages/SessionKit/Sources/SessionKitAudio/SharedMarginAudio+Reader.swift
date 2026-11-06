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
        reader: WrittenMarginReader,
        onDevice stage: WrittenMarginOnDeviceStage? = nil
    ) -> SharedMarginAudio {
        resolve(margin, in: layer, voiceFile: voiceFile, reading: { reader.playbackState(for: $0, onDevice: stage) })
    }

    /// The file to play, after making sure a reading that is not ready is being rendered (the same call starts and finds a
    /// render already running). Nil when nothing can play.
    ///
    /// With an on-device voice a reading it has not made is rendered by it, because this is the Margin being played. A
    /// caller that cannot wait (it hands the player a file now) gets the iPhone voice's reading when that is already on
    /// disk, so nothing fails or goes silent; the on-device reading is then ready for the next play (#3391).
    public func startingRender(on reader: WrittenMarginReader, onDevice stage: WrittenMarginOnDeviceStage? = nil) -> URL? {
        guard case .readingRendering(let reading, _) = self else { return file }
        if stage != nil, stage?.reads(reading.text) == true, reader.isReady(reading) {
            _ = reader.start(["margin": reading], onDevice: stage)
            return reader.fileURL(for: reading)
        }
        return reader.start(["margin": reading], onDevice: stage)["margin"]
    }
}
#endif
