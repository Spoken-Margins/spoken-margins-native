import Foundation

extension RuntimeCapabilityProfile {
    /// This profile with remote AI switched off: the AI capabilities shrink to the ones that run on the
    /// phone, and the provider-only features are forbidden.
    ///
    /// `generate_listening_map` always stays: the engine command behind it is the deterministic local
    /// generator and never calls a model, so a phone without Apple Intelligence still makes a map (#2620).
    /// Summarizing Margins queues a model job, so it stays only when the on-device model is available.
    public func limitedToOnDeviceAI(foundationModelAvailable: Bool) -> RuntimeCapabilityProfile {
        var capabilities = capabilities
        var allowedLocalAI: Set<String> = ["generate_listening_map", "cleanup_transcript", "defer_ai_jobs"]
        if foundationModelAvailable {
            allowedLocalAI.insert("summarize_interjections")
        }
        capabilities["ai"] = capabilities["ai", default: []].filter(allowedLocalAI.contains)
        return RuntimeCapabilityProfile(
            id: "\(id)-local-foundation",
            displayName: "\(displayName) · On-device AI",
            capabilities: capabilities,
            forbiddenCapabilities: Array(Set(forbiddenCapabilities).union([
                "provider_diagnostics",
                "continue_discussion"
            ])).sorted()
        )
    }
}
