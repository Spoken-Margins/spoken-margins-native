import Foundation
import SessionKit

/// #1491: the recording screen reminds the listener what they just heard.
/// The words are the ones the engine already captured when recording began, so this reads nothing new from the source.
/// A podcast with no transcript has none; its words come from the heard audio a moment later (#2966).
extension Gate1AppModel {
    var justHeardCue: String? {
        JustHeardCue.excerpt(from: engine?.recordingContextBefore) ?? (snapshot.isRecording ? justHeardPeek.text : nil)
    }
}
