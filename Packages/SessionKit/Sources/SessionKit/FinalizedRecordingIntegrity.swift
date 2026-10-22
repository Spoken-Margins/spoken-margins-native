import Foundation

/// Compares the recorder's clock with audio in its closed file. A running clock alone does not
/// prove the file received those samples (#937). This is a warning, never permission to delete audio.
public struct FinalizedRecordingIntegrity: Equatable, Sendable {
    public let reportedMs: Int
    /// Nil means the file could not be measured, not that it contains no speech.
    public let fileMs: Int?
    /// What saving did about the ready cue (#1594): "trimmed:<ms>" or "skipped:<why>". Nil when no cue played.
    public var readyCueTrim: String?

    public init(reportedMs: Int, fileMs: Int?, readyCueTrim: String? = nil) {
        self.reportedMs = max(0, reportedMs)
        self.fileMs = fileMs.map { max(0, $0) }
        self.readyCueTrim = readyCueTrim
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
        var fields = ["reportedMs": String(reportedMs), "fileMs": fileMs.map(String.init) ?? "unknown",
                      "integrity": fileMs == nil ? "unverified" : needsWarning ? "cut_short" : "consistent"]
        if let readyCueTrim { fields["readyCueTrim"] = readyCueTrim }
        return fields
    }
}
