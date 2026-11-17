import Foundation
import SessionKit

/// The Margins tab's Autoplay menu (Unheard Margins, All Margins, Off) on the existing auto-play path: the layers'
/// reveal mode says on or off, as the Now tab's switch always has, and one preference says whether a Margin the
/// listener already heard plays again. `MarginsAutoplaySetting` holds the rules; nothing here plays or pauses anything.
extension Gate1AppModel {
    /// UserDefaults key for "All Margins": heard Margins autoplay too. Off by default, so autoplay means unheard.
    static let marginsAutoplayIncludesHeardKey = "marginsAutoplayIncludesHeard"

    var marginsAutoplayIncludesHeard: Bool { UserDefaults.standard.bool(forKey: Self.marginsAutoplayIncludesHeardKey) }

    var marginsAutoplay: MarginsControlCenter.Autoplay {
        MarginsAutoplaySetting.current(autoPlayOn: importedCommentaryAutoPlayEnabled, includesHeard: marginsAutoplayIncludesHeard)
    }

    func setMarginsAutoplay(_ autoplay: MarginsControlCenter.Autoplay) {
        let written = MarginsAutoplaySetting.writes(autoplay)
        UserDefaults.standard.set(written.includesHeard, forKey: Self.marginsAutoplayIncludesHeardKey)
        if written.autoPlayOn != importedCommentaryAutoPlayEnabled { setImportedCommentaryAutoPlayEnabled(written.autoPlayOn) }
    }

    /// The reveal mode a prompt acts on: its layer's, except that under "Unheard" a Margin already heard gets the tone.
    func effectiveRevealMode(_ prompt: ImportedCommentaryPrompt) -> ImportedCommentaryRevealMode? {
        MarginsAutoplaySetting.revealMode(
            prompt.layer.revealMode, heard: !prompt.interjection.isNewToListener, includesHeard: marginsAutoplayIncludesHeard)
    }
}
