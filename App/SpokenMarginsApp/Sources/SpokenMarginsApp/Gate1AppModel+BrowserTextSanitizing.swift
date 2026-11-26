import Foundation
import SessionKit

/// Cleaning HTML out of captured page text before import. Moved out of Gate1AppModel unchanged,
/// so the model's hot file has room for #810's call sites.
extension Gate1AppModel {
    /// The cleaning itself lives in SessionKit, where it is host-tested (#5417).
    static func sanitizedBrowserTextHandoff(_ handoff: BrowserTextHandoff) -> BrowserTextHandoff {
        BrowserTextHandoffSanitizer.sanitized(handoff)
    }
}
