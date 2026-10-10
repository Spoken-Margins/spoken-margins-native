import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Keeps podcast anchor capture outcomes readable after the fact.
///
/// A Margin's capture can fail in several places (pre window, post window, stream tap, local fallback). The stored
/// `podcastAnchorEvidenceFailureReason` is a history of those reasons, oldest first, so a later fallback never hides
/// the failure that caused it. Diagnostic keys are qualified by a hashed session token because Margin IDs such as
/// `ij-001` repeat in every session.
public enum PodcastAnchorCaptureDiagnostics {
    public static let reasonSeparator = " | "
    static let maximumReasons = 6

    public static func appendingFailureReason(_ reason: String, to existing: String?) -> String {
        var reasons = (existing ?? "")
            .components(separatedBy: reasonSeparator)
            .filter { !$0.isEmpty }
        guard reasons.last != reason else { return reasons.joined(separator: reasonSeparator) }
        reasons.append(reason)
        if reasons.count > maximumReasons {
            // Keep the first failure; it is usually the cause of the rest.
            reasons = [reasons[0]] + reasons.suffix(maximumReasons - 1)
        }
        return reasons.joined(separator: reasonSeparator)
    }

    /// Short, stable, non-reversible session token for privacy-safe diagnostics.
    public static func sessionToken(_ sessionId: String) -> String {
        SHA256.hash(data: Data(sessionId.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public static func marginKey(_ name: String, sessionId: String, interjectionId: String) -> String {
        "\(name):\(sessionToken(sessionId))/\(interjectionId)"
    }

    /// The newest sessions the export looks at. Each one costs a store query and a decode, and the export
    /// used to read all of them (273 on the owner's phone, about 30 s with the Share Diagnostics sheet
    /// blank, #1191); a capture outcome older than this many sessions is not what a bug report is about.
    public static let maximumSessionsScanned = 60

    /// One entry per stored podcast Margin, newest sessions first. Read from the store, so it survives relaunch.
    public static func exportEntries(
        sessions: [Session],
        interjections: (String) throws -> [Interjection],
        limit: Int = 40,
        sessionLimit: Int = maximumSessionsScanned
    ) -> [String: String] {
        let ordered = sessions.sorted {
            ($0.updatedAt ?? $0.createdAt ?? .distantPast) > ($1.updatedAt ?? $1.createdAt ?? .distantPast)
        }.prefix(sessionLimit)
        var entries: [String: String] = [:]
        for session in ordered {
            guard entries.count < limit else { break }
            let records = ((try? interjections(session.id)) ?? [])
                .filter { $0.podcastAnchorEvidenceCaptureStatus != nil }
                .sorted { $0.id > $1.id }
            for interjection in records {
                guard entries.count < limit else { break }
                entries[marginKey("marginCapture", sessionId: session.id, interjectionId: interjection.id)] =
                    exportLine(interjection)
            }
        }
        return entries
    }

    static func exportLine(_ interjection: Interjection) -> String {
        let evidence = interjection.podcastAnchorEvidence ?? []
        let roles = evidence.map { $0.windowRole?.rawValue ?? "unknown" }.sorted().joined(separator: ",")
        return [
            "status=\(interjection.podcastAnchorEvidenceCaptureStatus?.rawValue ?? "none")",
            "evidence=\(evidence.count)",
            "roles=\(roles.isEmpty ? "none" : roles)",
            "context=\(interjection.anchorContextStatus?.rawValue ?? "legacy")",
            "reasons=\(interjection.podcastAnchorEvidenceFailureReason ?? "none")"
        ].joined(separator: ";")
    }
}
