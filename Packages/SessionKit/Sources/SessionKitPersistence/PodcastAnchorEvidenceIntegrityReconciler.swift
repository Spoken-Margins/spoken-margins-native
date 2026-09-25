import CryptoKit
import Foundation
import SessionKit

public enum PodcastAnchorEvidenceIntegrityReconciler {
    public struct Result {
        public let interjection: Interjection
        public let indeterminateReadCount: Int
    }

    /// A transient access error is not evidence that committed bytes are lost.
    /// The caller supplies signature validation so this store-side policy can
    /// be tested without depending on ShazamKit's runtime.
    public static func reconcile(
        _ original: Interjection,
        interruptedJobs: Bool,
        readFile: (URL) throws -> Data = { try Data(contentsOf: $0) },
        signatureIsValid: (Data) -> Bool
    ) -> Result {
        var margin = original
        var retainedEvidence: [CapturedPodcastAnchorEvidence] = []
        var indeterminateReads = 0
        for evidence in original.podcastAnchorEvidence ?? [] {
            let bytes: Data
            do {
                bytes = try readFile(URL(fileURLWithPath: evidence.localPath))
            } catch {
                if isConfirmedMissing(error) {
                    invalidate(evidence, in: &margin)
                } else {
                    retainedEvidence.append(evidence)
                    indeterminateReads += 1
                }
                continue
            }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let valid = !bytes.isEmpty
                && (evidence.byteCount == nil || evidence.byteCount == bytes.count)
                && (evidence.checksumSHA256 == nil || evidence.checksumSHA256 == digest)
                && signatureIsValid(bytes)
            if valid {
                retainedEvidence.append(evidence)
            } else {
                invalidate(evidence, in: &margin)
            }
        }
        margin.podcastAnchorEvidence = retainedEvidence
        for role in [PodcastAnchorEvidenceWindowRole.preInterjection, .postResume] {
            guard let captureRole = PodcastAnchorCaptureWindow.Role(rawValue: role.rawValue),
                  let window = margin.podcastAnchorCaptureWindows?.first(where: { $0.role == captureRole }) else {
                continue
            }
            if window.state == .committed && !retainedEvidence.contains(where: { $0.windowRole == role }) {
                margin.updatePodcastAnchorWindow(role) { $0.invalidateCommitted("committed_signature_missing") }
            } else if interruptedJobs && [.waiting, .collecting, .deriving].contains(window.state) {
                margin.updatePodcastAnchorWindow(role) { $0.failed("capture_interrupted", retryable: true) }
            }
        }
        return Result(interjection: margin, indeterminateReadCount: indeterminateReads)
    }

    private static func invalidate(_ evidence: CapturedPodcastAnchorEvidence, in margin: inout Interjection) {
        guard let role = evidence.windowRole,
              let captureRole = PodcastAnchorCaptureWindow.Role(rawValue: role.rawValue) else { return }
        margin.updatePodcastAnchorWindow(role) { window in
            if window.role == captureRole {
                window.invalidateCommitted("signature_asset_missing_or_corrupt")
            }
        }
    }

    private static func isConfirmedMissing(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError)
            || (value.domain == NSPOSIXErrorDomain && value.code == 2) // ENOENT
    }
}
