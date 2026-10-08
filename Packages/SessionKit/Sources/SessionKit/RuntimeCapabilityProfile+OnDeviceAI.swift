import Foundation

extension RuntimeCapabilityProfile {
    /// This profile with remote AI switched off: the AI capabilities shrink to the ones that run on the
    /// phone, and the provider-only features are forbidden.
    ///
    /// With the on-device model available the phone can also draft Listening Maps and summarize
    /// Margins; without it only transcript cleanup and deferring a job stay.
    public func limitedToOnDeviceAI(foundationModelAvailable: Bool) -> RuntimeCapabilityProfile {
        var capabilities = capabilities
        let allowedLocalAI = foundationModelAvailable
            ? Set(["generate_listening_map", "summarize_interjections", "cleanup_transcript", "defer_ai_jobs"])
            : Set(["cleanup_transcript", "defer_ai_jobs"])
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
