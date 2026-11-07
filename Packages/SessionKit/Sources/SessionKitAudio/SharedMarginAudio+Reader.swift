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

    /// The file to hand a player now, after making sure the iPhone voice is making it when no better reading is ready (the
    /// same call starts and finds a render already running). Nil when nothing can play.
    ///
    /// A caller that cannot wait gets a file that exists or is being written for exactly that path: the on-device
    /// voice's reading when it is ready, otherwise the iPhone voice's, never a path no render is writing. It starts no
    /// on-device render: only a caller that waits for one asks (`WrittenMarginReader.rendered`), so nothing is rendered in
    /// a voice nobody hears (#3391).
    public func startingRender(on reader: WrittenMarginReader, onDevice stage: WrittenMarginOnDeviceStage? = nil) -> URL? {
        guard case .readingRendering(let reading, _) = self else { return file }
        return reader.start(["margin": reading], onDevice: stage)["margin"]
    }
}
#endif
