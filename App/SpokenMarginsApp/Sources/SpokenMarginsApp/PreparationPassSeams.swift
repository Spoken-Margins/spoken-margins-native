import Foundation
import SessionKit

/// What the background preparation pass reads from the device and renders with. The app uses the
/// defaults; app-hosted tests swap in a heat reading and a renderer that needs no model (#64).
struct PreparationPassSeams {
    var deviceConditions: @MainActor () -> SpeechEngineConditions = { SupertonicResourcePolicy.currentConditions() }
    /// Nil renders with the shared Supertonic renderer, paced per render (#377).
    var renderer: (@MainActor () throws -> any SupertonicRendering)?
}
