#if canImport(AVFoundation) && canImport(ShazamKit)
import AVFoundation
import Foundation
import ShazamKit

/// ShazamKit's callback API can block its caller while reading the asset. Both the call and the
/// queue's state run on this dedicated serial queue; at most one signature is in flight.
final class PodcastAssetSignatureGenerator: @unchecked Sendable {
    private static let shared = PodcastAssetSignatureGenerator()
    private let queue = DispatchQueue(label: "SpokenMargins.podcast-asset-signatures", qos: .utility)
    private var pending: [Request] = []
    private var isGenerating = false

    static func signature(from asset: AVAsset) async throws -> SHSignature {
        let cancellation = Cancellation()
        let signature: SHSignature = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = Request(asset: asset, continuation: continuation, cancellation: cancellation)
                shared.queue.async {
                    shared.pending.append(request)
                    shared.startNext()
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return signature
    }

    private func startNext() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isGenerating else { return }
        while !pending.isEmpty {
            let request = pending.removeFirst()
            if request.cancellation.isCancelled {
                request.continuation.resume(throwing: CancellationError())
                continue
            }
            isGenerating = true
            autoreleasepool {
                SHSignatureGenerator.generateSignature(from: request.asset) { signature, error in
                    if let error {
                        request.continuation.resume(throwing: error)
                    } else if let signature {
                        request.continuation.resume(returning: signature)
                    } else {
                        request.continuation.resume(throwing: PodcastAnchorEvidenceError.signatureGenerationFailed)
                    }
                    self.queue.async {
                        self.isGenerating = false
                        self.startNext()
                    }
                }
            }
            return
        }
    }

    // The asset is retained and read by ShazamKit until completion. Callers finish building it before
    // handing it over. The continuation is resumed once; queue state never crosses the serial queue.
    private struct Request: @unchecked Sendable {
        let asset: AVAsset
        let continuation: CheckedContinuation<SHSignature, Error>
        let cancellation: Cancellation
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
#endif
