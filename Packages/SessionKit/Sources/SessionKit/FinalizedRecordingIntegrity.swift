import Foundation

/// Compares the recorder's clock with audio in its closed file. A running clock alone does not
/// prove the file received those samples (#937). This is a warning, never permission to delete audio.
public struct FinalizedRecordingIntegrity: Equatable, Sendable {
    public let reportedMs: Int
    /// Nil means the file could not be measured, not that it contains no speech.
    public let fileMs: Int?

    public init(reportedMs: Int, fileMs: Int?) {
        self.reportedMs = max(0, reportedMs)
        self.fileMs = fileMs.map { max(0, $0) }
    }

    public var needsWarning: Bool {
        guard let fileMs else { return true }
        // Reuse the capture supervisor's conservative threshold. Codec priming, brief Margins and
        // silent but complete recordings must not be reported as lost speech.
        return reportedMs >= MarginCaptureTimings.cutShortAfterMs && fileMs < reportedMs / 2
    }

    public func qualifying(_ verdict: MarginCaptureSupervisor.SaveVerdict) -> MarginCaptureSupervisor.SaveVerdict {
        needsWarning ? .saveCutShort : verdict
    }

    public var diagnosticFields: [String: String] {
        ["reportedMs": String(reportedMs), "fileMs": fileMs.map(String.init) ?? "unknown",
         "integrity": fileMs == nil ? "unverified" : needsWarning ? "cut_short" : "consistent"]
    }
}
