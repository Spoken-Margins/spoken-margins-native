import Foundation
import SessionKit

enum PlaybackQualityPresentation {
    /// Shared with the Lock Screen's Skim buttons (#115).
    static func skimTitle(destinationMs: Int?, backward: Bool) -> String {
        SkimDestinationLabel.title(destinationMs: destinationMs, backward: backward)
    }
}
