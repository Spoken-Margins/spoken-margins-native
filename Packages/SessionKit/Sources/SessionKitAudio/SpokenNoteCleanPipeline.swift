import Foundation
import SessionKit

/// Makes the version file. The system one is `SpokenNoteCleanRenderer`.
public protocol SpokenNoteCleanRendering: Sendable {
    func render(
        takes: [SpokenNoteRenderTake], noteFolder: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpokenNoteCleanLayout
}

extension SpokenNoteCleanRenderer: SpokenNoteCleanRendering {}

/// The one type that turns a note into its version with long pauses shortened (#4779). For each take, in order: its
/// cut (the saved one while the take and the rule are unchanged, otherwise made from the take's quiet stretches), then
/// one render for the note.
///
/// PR 0 found that the phone's transcriber doesn't write ums down reliably (branch C), so no words are timed: a cut
/// only ever removes the middle of a quiet stretch.
public struct SpokenNoteCleanPipeline: Sendable {
    private let renderer: any SpokenNoteCleanRendering
    private let silentFlags: @Sendable (URL) throws -> SpokenNoteSilentFlags.Result

    public init(
        renderer: any SpokenNoteCleanRendering = SpokenNoteCleanRenderer(),
        silentFlags: @escaping @Sendable (URL) throws -> SpokenNoteSilentFlags.Result = { try SpokenNoteSilentFlags.read(url: $0) }
    ) {
        self.renderer = renderer
        self.silentFlags = silentFlags
    }

    /// Progress (Design, "How the percent is counted"): reading a take's quiet stretches counts as a tenth of its
    /// length when its cut isn't saved; the render counts as a quarter of the note's length.
    public func run(
        requested: [SpokenNoteWholeAudioLayout.Requested], noteFolder: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> SpokenNoteCleanLayout {
        let report: @Sendable (Double) -> Void = { progress(min(1, max(0, $0))) }
        let noteMs = Double(max(1, requested.reduce(0) { $0 + $1.durationMs }))
        let readUnits = requested.reduce(0.0) { $0 + Double($1.durationMs) / 10 }
        let renderUnits = noteMs / 4
        let totalUnits = readUnits + renderUnits
        var doneUnits = 0.0

        var takes: [SpokenNoteRenderTake] = []
        for take in requested {
            try Task.checkCancellation()
            let url = noteFolder.appendingPathComponent(take.audioFileName)
            let takeFingerprint = "\(take.audioFileName)-\(take.durationMs)-rule\(SpokenNoteCleanPolicy.ruleVersion)"
            let cutURL = SpokenNoteCleanFiles.cutURL(takeId: take.id, inNoteFolder: noteFolder)
            let cut: SpokenNoteTakeCut
            if let saved = SpokenNoteCleanFiles.read(SpokenNoteCutFile.self, from: cutURL), saved.takeFingerprint == takeFingerprint,
               saved.cut.ruleVersion == SpokenNoteCleanPolicy.ruleVersion {
                cut = saved.cut
            } else {
                let flags = try silentFlags(url)
                cut = SpokenNoteTakeCut.make(words: [], silentFlags: flags.flags, durationMs: flags.durationMs)
                try SpokenNoteCleanFiles.write(SpokenNoteCutFile(takeFingerprint: takeFingerprint, cut: cut), to: cutURL)
            }
            doneUnits += Double(take.durationMs) / 10
            report(doneUnits / totalUnits)
            takes.append(SpokenNoteRenderTake(requested: take, url: url, cut: cut, cutFingerprint: SpokenNoteCleanFiles.fingerprint(of: cut)))
        }
        try Task.checkCancellation()
        let renderBase = doneUnits
        return try await renderer.render(takes: takes, noteFolder: noteFolder) { fraction in
            report((renderBase + fraction * renderUnits) / totalUnits)
        }
    }
}
