import Foundation
import SessionKit

/// Makes the version file. The system one is `SpokenNoteCleanRenderer`.
public protocol SpokenNoteCleanRendering: Sendable {
    func render(
        takes: [SpokenNoteRenderTake], noteFolder: URL, version: SpokenNoteAudioVersion,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpokenNoteCleanLayout
}

extension SpokenNoteCleanRenderer: SpokenNoteCleanRendering {}

/// The one type that turns a note into one of its made versions. For each take, in order: its cut (the saved one while
/// the take and the rule are unchanged, otherwise made again), then one render for the note, in the version's folder.
///
/// - Shorter pauses (#4779): PR 0 found that the phone's transcriber doesn't write ums down reliably (branch C), so no
///   words are timed: a cut only ever removes the middle of a quiet stretch.
/// - Without ums (#5342): the owner's call is the Margins cleanup, as it is. Each take is transcribed by the
///   transcriber every Margin uses, and `SpokenNoteTakeCut.make(withoutUms:)` removes what the Margins cleanup removes,
///   with long pauses shortened as Shorter pauses does. Where the transcriber wrote no um down, none is removed.
public struct SpokenNoteCleanPipeline: Sendable {
    private let renderer: any SpokenNoteCleanRendering
    private let silentFlags: @Sendable (URL) throws -> SpokenNoteSilentFlags.Result
    private let transcriber: any SpokenNoteTranscribing

    public init(
        renderer: any SpokenNoteCleanRendering = SpokenNoteCleanRenderer(),
        silentFlags: @escaping @Sendable (URL) throws -> SpokenNoteSilentFlags.Result = { try SpokenNoteSilentFlags.read(url: $0) },
        transcriber: any SpokenNoteTranscribing = SystemSpokenNoteTranscriber()
    ) {
        self.renderer = renderer
        self.silentFlags = silentFlags
        self.transcriber = transcriber
    }

    /// Progress (Design, "How the percent is counted"): reading a take's quiet stretches counts as a tenth of its
    /// length when its cut isn't saved, and for Without ums its transcript as half its length more; the render counts as
    /// a quarter of the note's length.
    public func run(
        requested: [SpokenNoteWholeAudioLayout.Requested], noteFolder: URL, version: SpokenNoteAudioVersion = .shorterPauses,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> SpokenNoteCleanLayout {
        let report: @Sendable (Double) -> Void = { progress(min(1, max(0, $0))) }
        let readShare = version == .withoutUms ? 0.6 : 0.1
        let noteMs = Double(max(1, requested.reduce(0) { $0 + $1.durationMs }))
        let readUnits = requested.reduce(0.0) { $0 + Double($1.durationMs) * readShare }
        let renderUnits = noteMs / 4
        let totalUnits = readUnits + renderUnits
        var doneUnits = 0.0

        var takes: [SpokenNoteRenderTake] = []
        var transcriptFailures = 0
        var lastTranscriptError: Error?
        for take in requested {
            try Task.checkCancellation()
            let url = noteFolder.appendingPathComponent(take.audioFileName)
            // Without ums also names the Margins cleanup's policy, so a change there makes its cuts again.
            let takeFingerprint = "\(take.audioFileName)-\(take.durationMs)-rule\(SpokenNoteCleanPolicy.ruleVersion)"
                + (version == .withoutUms ? "-\(DeterministicInterjectionCleanup.policyVersion)" : "")
            let cutURL = SpokenNoteCleanFiles.cutURL(takeId: take.id, inNoteFolder: noteFolder, version: version)
            let cut: SpokenNoteTakeCut
            if let saved = SpokenNoteCleanFiles.read(SpokenNoteCutFile.self, from: cutURL), saved.takeFingerprint == takeFingerprint,
               saved.cut.ruleVersion == SpokenNoteCleanPolicy.ruleVersion {
                cut = saved.cut
            } else {
                let flags = try silentFlags(url)
                if version == .withoutUms {
                    do {
                        let segments = try await transcriber.transcribe(fileAt: url)
                        cut = SpokenNoteTakeCut.make(withoutUms: segments, silentFlags: flags.flags, durationMs: flags.durationMs)
                        try SpokenNoteCleanFiles.write(SpokenNoteCutFile(takeFingerprint: takeFingerprint, cut: cut), to: cutURL)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        // A take the transcriber can't read (often one with no speech) still has its pauses shortened.
                        // Its cut isn't saved, so the next run asks the transcriber again.
                        transcriptFailures += 1
                        lastTranscriptError = error
                        cut = SpokenNoteTakeCut.make(words: [], silentFlags: flags.flags, durationMs: flags.durationMs)
                    }
                } else {
                    cut = SpokenNoteTakeCut.make(words: [], silentFlags: flags.flags, durationMs: flags.durationMs)
                    try SpokenNoteCleanFiles.write(SpokenNoteCutFile(takeFingerprint: takeFingerprint, cut: cut), to: cutURL)
                }
            }
            doneUnits += Double(take.durationMs) * readShare
            report(doneUnits / totalUnits)
            takes.append(SpokenNoteRenderTake(requested: take, url: url, cut: cut, cutFingerprint: SpokenNoteCleanFiles.fingerprint(of: cut)))
        }
        // No take could be transcribed (Speech Recognition not allowed, or the recognizer is unavailable): there is no
        // Without ums to make, and the listener is told it plays as recorded, as for any failure.
        if let lastTranscriptError, transcriptFailures == requested.count { throw lastTranscriptError }
        try Task.checkCancellation()
        let renderBase = doneUnits
        return try await renderer.render(takes: takes, noteFolder: noteFolder, version: version) { fraction in
            report((renderBase + fraction * renderUnits) / totalUnits)
        }
    }
}
