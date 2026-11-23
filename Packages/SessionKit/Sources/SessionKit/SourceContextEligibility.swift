import Foundation

extension Interjection {
    /// Whether a Margin can have the source's words around it at all: a spoken Margin on the item, at a time in the media.
    ///
    /// A moved Margin with no saved place (`hasPlace`, #4233) has no moment to cut a window around, so no context job and
    /// no retry sweep is started for it. The app's scheduler, its retry sweep and `HeardSourceWindowFiles.isStillNeeded`
    /// all ask this, so none of them can start work for a Margin another would refuse.
    public var canHaveSourceContext: Bool {
        captureKind != .written
            && targetType == .item
            && hasPlace
            && anchor.mediaTimeMs != nil
    }
}
