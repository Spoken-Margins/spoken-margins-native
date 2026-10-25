import Foundation
import SessionKit

/// #1491: the recording screen reminds the listener what they just heard.
/// The words are the ones the engine already captured when recording began, so this reads nothing new from the source.
extension Gate1AppModel {
    var justHeardCue: String? {
        JustHeardCue.excerpt(from: engine?.recordingContextBefore)
    }
}
