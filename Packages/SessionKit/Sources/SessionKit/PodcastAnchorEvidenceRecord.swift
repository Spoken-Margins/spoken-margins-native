import Foundation

/// How a Margin's podcast anchor evidence is written onto its stored `Interjection`.
///
/// Each function takes the Margin as it was read from the store and returns the changed value. The caller
/// reads and saves it; nothing here touches the store, the files or the screen.
public enum PodcastAnchorEvidenceRecord {
    /// Adds captured evidence and marks the capture `ready`.
    ///
    /// A new entry replaces a stored one with the same id, or with the same (windowRole, provenance) pair, and keeps
    /// every other entry. Entries are stored sorted by id. A non-nil `sourceExactEditionSHA256` replaces the stored one;
    /// nil keeps it, because the stream and source-window captures have no edition to report and must not blank the
    /// digest an exact local capture stored (#972 entry 8; the packet's shared item identity reads it). A context status still `pending` becomes
    /// `unavailable`, because the evidence is now final; `ready` and nil stay as they are.
    public static func merging(
        _ evidence: [CapturedPodcastAnchorEvidence],
        sourceExactEditionSHA256: String?,
        into interjection: Interjection
    ) -> Interjection {
        var interjection = interjection
        var merged = interjection.podcastAnchorEvidence ?? []
        for newEvidence in evidence {
            merged.removeAll {
                $0.id == newEvidence.id
                    || ($0.windowRole == newEvidence.windowRole && $0.provenance == newEvidence.provenance)
            }
            merged.append(newEvidence)
        }
        interjection.podcastAnchorEvidence = merged.sorted { $0.id < $1.id }
        if let sourceExactEditionSHA256 { interjection.sourceExactEditionSHA256 = sourceExactEditionSHA256 }
        interjection.podcastAnchorEvidenceCaptureStatus = .ready
        if interjection.anchorContextStatus == .pending {
            interjection.anchorContextStatus = .unavailable
        }
        return interjection
    }

    /// Marks the capture `unavailable` and appends the reason to the failure history.
    public static func markingUnavailable(_ interjection: Interjection, reason: String) -> Interjection {
        var interjection = interjection
        interjection.podcastAnchorEvidenceCaptureStatus = .unavailable
        interjection.podcastAnchorEvidenceFailureReason = PodcastAnchorCaptureDiagnostics.appendingFailureReason(
            reason,
            to: interjection.podcastAnchorEvidenceFailureReason
        )
        return interjection
    }

    /// Marks the capture as waiting for the exact local edition. Changes only the capture status.
    public static func markingPendingLocalCapture(_ interjection: Interjection) -> Interjection {
        var interjection = interjection
        interjection.podcastAnchorEvidenceCaptureStatus = .pendingExactLocalCapture
        return interjection
    }

    /// Appends a failure to the history without changing the capture status, so a fallback that runs next can't
    /// hide it.
    public static func recordingFailureReason(_ reason: String, on interjection: Interjection) -> Interjection {
        var interjection = interjection
        interjection.podcastAnchorEvidenceFailureReason = PodcastAnchorCaptureDiagnostics.appendingFailureReason(
            reason,
            to: interjection.podcastAnchorEvidenceFailureReason
        )
        return interjection
    }
}

/// Where a Margin's podcast anchor evidence lives on disk and what its entries are called.
///
/// These names are saved in SQLite rows (`CapturedPodcastAnchorEvidence.id`) and used as file names, so changing the
/// rule orphans the evidence already stored. Other sanitizers in the code base look similar but follow different
/// rules, and their outputs are saved too; don't merge this one with them.
public enum PodcastAnchorEvidencePaths {
    /// `<applicationSupport>/SpokenMargins/AnchorEvidence/<safe session id>/<safe Margin id>`
    public static func directory(
        applicationSupport: URL,
        sessionId: String,
        interjectionId: String
    ) -> URL {
        applicationSupport
            .appending(path: "SpokenMargins/AnchorEvidence", directoryHint: .isDirectory)
            .appending(path: safeComponent(sessionId), directoryHint: .isDirectory)
            .appending(path: safeComponent(interjectionId), directoryHint: .isDirectory)
    }

    /// `anchor-<safe session id>-<safe Margin id>-<suffix>`. The suffix is the caller's (`local`, `stream-pre`,
    /// `stream-post`, `source-window`) and is used as given.
    public static func evidenceID(sessionId: String, interjectionId: String, suffix: String) -> String {
        "anchor-\(safeComponent(sessionId))-\(safeComponent(interjectionId))-\(suffix)"
    }

    /// Maps each character outside `A-Za-z0-9._-` to `-`, one for one (runs are not collapsed), keeps the first 96
    /// characters, and returns `unknown` when nothing is left. Also names the episode-map files and assets.
    public static func safeComponent(_ value: String) -> String {
        let safe = value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        return safe.isEmpty ? "unknown" : String(safe.prefix(96))
    }
}
