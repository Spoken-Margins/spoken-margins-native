#if canImport(AVFoundation)
import Foundation
import SessionKit

/// Closes the writer before reading the finalized container. No outcome deletes or changes the file,
/// and a read failure must not throw after the recorder has stopped and strand the session in capture.
enum RecordingFileFinalizer {
    static func finish(url: URL, reportedMs: Int, stop: () -> Void) -> FinalizedRecordingIntegrity {
        stop()
        let fileMs: Int?
        switch MainThreadOperationLabels.shared.scoped("recorder.measureFile", { RecordedFileDuration.measure(url) }) {
        case .milliseconds(let ms): fileMs = ms
        case .unreadable: fileMs = nil
        }
        return FinalizedRecordingIntegrity(reportedMs: reportedMs, fileMs: fileMs)
    }
}
#endif
