import Foundation
import SessionKit

/// The skip unit the transport buttons ask the engine for. Moved out of `Gate1AppModel.swift` unchanged,
/// to keep that file under its size ceiling (scripts/hot_file_ratchet.py) while #937 adds its call sites.
extension Gate1AppModel {
    func skipUnitForCurrentTarget() -> String {
        switch snapshot.targetType {
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            return mediaSkipUnit(seconds: mediaSkipForwardSeconds)
        default:
            return skipUnit
        }
    }

    func mediaSkipUnit(seconds: Int) -> String {
        MediaSkipRule.unit(seconds: seconds)
    }
}
