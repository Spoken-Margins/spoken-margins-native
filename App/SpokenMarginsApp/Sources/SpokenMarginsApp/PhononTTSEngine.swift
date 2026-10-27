import Foundation
import PhononTTS
import SessionKit
import SessionKitSupertonic

/// Gradium's `Phonon` (#2704) behind the renderer's `PhononSynthesizing`, so `PhononNarrationRenderer` and
/// `PhononVoicePreparation` stay host-tested in SessionKit. Phonon serialises its own calls on one queue and runs
/// the LM on the Neural Engine; nothing here touches the main thread.
final class PhononTTSEngine: PhononSynthesizing, @unchecked Sendable {
    private let phonon: Phonon

    private init(_ phonon: Phonon) { self.phonon = phonon }

    /// The loader `PhononNarrationRenderer(load:)` takes. Loading reads the compiled models the install prepared.
    static let load: PhononEngineLoader = { location in
        PhononTTSEngine(try await Phonon.load(models: location.rootURL, language: .english))
    }

    /// The compile `PhononVoicePreparation(compile:)` runs at install time: `Phonon.load` compiles each package into
    /// a `.mlmodelc` beside it, inside the staged folder, and the loaded model is dropped at once.
    static let compile: PhononVoicePreparation.Compile = { location in
        _ = try await Phonon.load(models: location.rootURL, language: .english)
    }

    /// What Settings › Voices registers for the `phonon-ptts` runtime.
    static let preparation = PhononVoicePreparation(compile: compile)

    var voice: String { phonon.voice }

    func setVoice(_ name: String) async throws {
        try await phonon.setVoice(name)
    }

    func synthesize(_ text: String) async throws -> [Float] {
        try await phonon.synthesize(text)
    }
}
