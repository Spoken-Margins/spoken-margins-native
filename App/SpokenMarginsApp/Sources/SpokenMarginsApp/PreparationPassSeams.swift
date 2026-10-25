import Foundation
import SessionKit
import SessionKitPersistence

/// What the background preparation pass reads from the device and renders with. The app uses the
/// defaults; app-hosted tests swap in a heat reading and a renderer that needs no model (#64).
struct PreparationPassSeams {
    var deviceConditions: @MainActor () -> SpeechEngineConditions = { SupertonicResourcePolicy.currentConditions() }
    /// Nil renders with the shared Supertonic renderer, paced per render (#377).
    var renderer: (@MainActor () throws -> any SupertonicRendering)?
    /// Whether a memory warning is still holding back new rendering (#1107). Tests pass one that ends on cue.
    var memoryBackoffActive: @MainActor () -> Bool = { SupertonicResourcePolicy.memoryBackoff.isActive() }
    /// How a run waits out a heat pause or a memory backoff (#905). Tests pass one that returns at once and counts the seconds.
    var pause: @Sendable (Int) async throws -> Void = { seconds in try await Task.sleep(for: .seconds(seconds)) }
}

extension Gate1AppModel {
    /// Heat or Low Power Mode can arrive while the pass reserves space and sets up the renderer, so
    /// the chunk start is checked once more right before rendering (Codex audit on e5088b9). Returns
    /// nil to render. Otherwise the reservation is released and the manifest paused like at the
    /// first check, and the pass stops.
    func preparationHeldAtRenderStart(
        policy: PreparationJobPolicy,
        manifestId: String,
        reservationId: String,
        ledger: OfflineStorageLedger,
        coordinator: PreparedAudioCoordinator,
        store: SQLiteSessionStore
    ) async throws -> PreparationChunkDecision? {
        let device = preparationSeams.deviceConditions()
        let gate = PreparationChunkGate.decide(
            policy: policy, thermal: device.thermal, isLowPowerModeEnabled: device.isLowPowerModeEnabled, itemAlreadyListened: false
        )
        guard gate != .render else { return nil }
        try? await ledger.release(reservationId: reservationId)
        if try await coordinator.applyGate(gate, manifestId: manifestId).changed { refreshLibraryRowsInBackground() }
        diagnostics["backgroundAudioPreparation"] = gate.rawValue
        return gate
    }
}
