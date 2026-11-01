import Foundation
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

extension Gate1AppModel {
    /// A Margin started from a headphone or compact control did not record (#3085). iOS only lets an app begin
    /// recording while it is in the foreground, so a locked phone fails here, and the banner would be seen only after
    /// unlocking. Say so with a short sound, and keep why in the export. The cue never configures the audio session.
    func noteCompactBeginFailure(_ error: Error, origin: String) {
        let cue = MarginOutcomeCuePlayer.shared.play(.couldNotStart)
        let protectedData: CompactBeginFailureRecord.Tristate
        #if canImport(UIKit)
        protectedData = UIApplication.shared.isProtectedDataAvailable ? .yes : .no
        #else
        protectedData = .unknown
        #endif
        let record = CompactBeginFailureRecord(
            appState: Gate2AppState.isInBackground() ? "background" : "foreground",
            protectedDataAvailable: protectedData, origin: origin, error: String(describing: error), cue: cue)
        diagnostics["lastCompactBeginFailure"] = record.diagnosticsLine
        recordDeveloperDiagnostic("margin.compact_begin_failed", record.eventFields)
    }
}
