import Foundation

// One-time preparation of a downloaded voice (#2700), after every file is verified and before the voice
// counts as installed. Kokoro compiles each `.mlpackage` with `MLModel.compileModel` and keeps the compiled
// copy in the voice's folder (#2705); Phonon's first load compiles for about 10 seconds (#2704). Doing it at
// install time means the listener sees "Preparing voice" once in Settings › Voices, not a stall the first
// time the voice reads.
//
// The preparer works in the staged folder, so whatever it writes moves into place with the downloaded files
// in the installer's one rename, and Remove deletes it with them. A failed or interrupted preparation leaves
// the voice not installed; the downloaded files stay staged and the next Download prepares again without
// downloading. Anything a preparer writes outside the folder it is given would outlive Remove, so it doesn't.

public protocol VoiceModelPreparing: Sendable {
    /// False when there is nothing to do, so Settings never flashes "Preparing voice".
    var needsPreparation: Bool { get }

    /// Prepares the voice in `stagedFolder`, which holds every file of `entry`, each already checked against
    /// the catalog's SHA-256. Writes only inside `stagedFolder`. Throws to leave the voice uninstalled;
    /// honours task cancellation where it can.
    func prepare(stagedFolder: URL, entry: VoiceModelEntry) async throws
}

/// ONNX Runtime voices (Supertonic) load their files as they are.
public struct NoVoiceModelPreparation: VoiceModelPreparing {
    public init() {}
    public var needsPreparation: Bool { false }
    public func prepare(stagedFolder: URL, entry: VoiceModelEntry) async throws {}
}

/// Which preparer each catalog runtime uses. A runtime with none registered needs no preparation.
public struct VoiceModelPreparers: Sendable {
    public var byRuntime: [String: any VoiceModelPreparing]

    public init(byRuntime: [String: any VoiceModelPreparing] = [:]) {
        self.byRuntime = byRuntime
    }

    /// What this build registers before any Neural Engine voice lands: ONNX Runtime needs nothing.
    public static let standard = VoiceModelPreparers(byRuntime: [VoiceModelCatalogVerifier.onnxRuntime: NoVoiceModelPreparation()])

    public func preparer(forRuntime name: String) -> any VoiceModelPreparing {
        byRuntime[name] ?? NoVoiceModelPreparation()
    }

    /// A copy with `preparer` registered for `runtime`, replacing any earlier one.
    public func registering(_ preparer: any VoiceModelPreparing, forRuntime runtime: String) -> VoiceModelPreparers {
        var copy = self
        copy.byRuntime[runtime] = preparer
        return copy
    }
}
