import SessionKit

extension Gate1AppModel {
    /// The Margins tab's Play button on a friend's Margin (#4447). A Margin with a time in the item starts its moment
    /// as before. One the app matched at a passage of the listener's article or PDF has no time to seek to, so it goes
    /// the way a Skim stop on text does (`startSkimMargin`): to the passage, then the Margin. The button is enabled by
    /// `SharedMarginRow.canPlayFromMarginsList`, which asks `SharedMarginListPlay` for the same two places.
    /// Either way the tap leaves one `margin.tap` line; `playSharedMarginMoment` writes its own.
    func playSharedMarginFromMarginsList(_ row: SharedMarginRow) {
        noteCatchUp(.play) // playing a Margin puts the caught-up card away (#4785)
        guard SharedMarginListPlay(row.interjection) == .textPassage else { return playSharedMarginMoment(row) }
        recordMarginTap(.shared, startSharedMarginAtPassage(row))
    }

    private func startSharedMarginAtPassage(_ row: SharedMarginRow) -> MarginTapOutcome {
        guard !rejectNavigationOrSessionMutationWhileRecording("play_shared_margin_from_list") else { return .refused(.recordingInProgress) }
        guard SharedMarginPrompts.isLayerPlaybackEligible(row.layer, records: [row.interjection]) else {
            reportFailure("This friend's Margins are turned off. Turn them on to hear this one.")
            return .refused(.marginsOff)
        }
        guard row.layer.itemId == selectedItem.id else {
            reportFailure("This shared Margin isn't ready to play here yet.")
            return .refused(.itemDidNotOpen)
        }
        guard let prompt = importedCommentaryPrompts(includeAnnounced: true).first(where: { $0.interjection.id == row.interjection.id }) else {
            reportFailure("This shared Margin isn't ready to play here yet.")
            return .refused(.marginUnavailable)
        }
        // Asked before the jump, from the prompt the listen step will resolve (not the row, which may be older): what the
        // Margin sounds like decides what the tap came to.
        let audio = WrittenMarginReadings.audio(for: prompt.interjection, in: prompt.layer, voiceFile: resolvedApplicationSupportAssetURL(for:))
        guard playSharedMarginNow(prompt) else { return .refused(.noPosition) } // the jump reported why
        // The jump only moved the text and showed the card. Whether the voice started is a separate answer (audit on b149832).
        return MarginTapPassageStart.outcome(audio: audio, sharedVoiceIsPlayingThisMargin: playingImportedCommentary?.id == prompt.id)
    }
}
