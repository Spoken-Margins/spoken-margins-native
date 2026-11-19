import Foundation
import SessionKit

/// The Tidy version card's actions (#4339). The rules live in SessionKit (`MarginTidyCardState`, `MarginTidyProposer`,
/// `SessionEngine.useTidy`); this file only carries the author's tap to the engine and the proposer's answer to the card.
extension Gate1AppModel {
    /// The tidy version to offer for a Margin that says `transcript`, asked of the app-wide proposer, which runs off the
    /// main actor and remembers a model rewrite for this run.
    func marginTidyProposal(for margin: Interjection, transcript: String) async -> MarginTidyProposal? {
        await marginTidyProposer.proposal(
            marginId: "\(margin.sessionId)::\(margin.id)", transcript: transcript,
            before: margin.anchor.anchorBefore, after: margin.anchor.anchorAfter
        )
    }

    /// "Use tidy version": the tidy text becomes what the Margin shows and exports; the transcript and the recording are
    /// kept. `basedOn` is the transcript the card was made from, so a proposal for words that changed since saves nothing.
    func useTidyVersion(_ margin: Interjection, proposal: MarginTidyProposal, basedOn transcript: String) {
        run { engine in
            snapshot = try engine.useTidy(
                interjectionId: margin.id, sessionId: margin.sessionId, text: proposal.text, basedOn: transcript,
                source: MarginTidyCardState.decisionSource(for: proposal.source)
            )
        }
        refreshMarginRowsInBackground(forItem: margin.itemId)
    }

    /// "Keep mine": the Margin stays as spoken and is not offered a tidy version again.
    func keepMarginAsSpoken(_ margin: Interjection) {
        run { engine in
            snapshot = try engine.keepOriginal(interjectionId: margin.id, sessionId: margin.sessionId)
        }
        refreshMarginRowsInBackground(forItem: margin.itemId)
    }

    /// "Use my original words": drops the approved tidy text and shows the card again as a proposal.
    func useOriginalWords(of margin: Interjection) {
        run { engine in
            snapshot = try engine.useOriginalWords(interjectionId: margin.id, sessionId: margin.sessionId)
        }
        refreshMarginRowsInBackground(forItem: margin.itemId)
    }
}

extension MarginTidyConditions {
    /// What this iPhone reports now: Low Power Mode, and how warm it is. Read when a proposal is asked for.
    static func currentDevice() -> MarginTidyConditions {
        let info = ProcessInfo.processInfo
        let thermal: SpeechThermalLevel
        switch info.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .serious
        }
        return MarginTidyConditions(thermal: thermal, isLowPowerModeEnabled: info.isLowPowerModeEnabled)
    }
}
