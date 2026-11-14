import Foundation
import SessionKit

/// What VoiceOver reads for the chapter row's arrows (#3986): the label is the action and the value is where it goes.
/// The words are `SkimDestinationSpeech` in SessionKit and the lookup is `SkimDestinationDescriber`; this only hands the
/// describer the playing item's chapters and Margins and picks the row for each control. It keeps no state, and it sits
/// in its own file so `Gate1AppModel` does not grow.
extension Gate1AppModel {
    /// The playing item's chapters, own Margins and friends' Margins, in the item's own unit.
    var skimDescriber: SkimDestinationDescriber {
        let itemId = skimSource?.itemId ?? selectedItem.id
        let chapters: [(id: String, title: String, position: Int)] = isTextReadingSnapshot
            ? selectedItem.chapters.map { ($0.id, $0.title, $0.startChar) }
            : (selectedItem.mediaChapters.isEmpty ? selectedItem.listeningMapScenes : selectedItem.mediaChapters)
                .map { ($0.id, $0.title, $0.startMs) }
        var friendLabels: [String: String?] = [:]
        for row in sharedMarginRows where row.layer.itemId == itemId {
            friendLabels[row.interjection.id] = row.layer.displayLabel
        }
        return SkimDestinationDescriber(
            isText: isTextReadingSnapshot, textLength: isTextReadingSnapshot ? selectedItem.text.count : 0, chapters: chapters,
            ownMarginIds: Set(marginRows.map(\.interjection).filter { $0.itemId == itemId }.map(\.id)),
            friendLabels: friendLabels, playhead: skimCurrentMediaTimeMs)
    }

    /// The next chapter's id and start, in the item's own unit; nil when there is none ahead.
    private var nextChapterStop: (id: String, start: Int)? {
        if let chapter = nextPlaybackChapter { return (chapter.id, chapter.startChar) }
        if let chapter = nextPlaybackMediaChapter { return (chapter.id, chapter.startMs) }
        return nil
    }

    /// The title Next chapter will land at, said when it is pressed ("Next chapter, Alignment").
    var nextChapterAnnouncementTitle: String? {
        nextChapterStop.flatMap { skimDescriber.chapterTitle(id: $0.id) }
    }

    /// The words for the arrow left of the chapter title, or nil where the row draws none.
    var chapterRowBackwardSpeech: SkimDestinationSpeech.Speech? {
        switch chapterRowBackwardControl {
        case .hidden: return nil
        case .skimDisabled: return skimDisabledSpeech(.backward)
        default: return skimSpeech(.backward)
        }
    }

    /// The words for the arrow right of the chapter title, or nil where the row draws none.
    var chapterRowForwardSpeech: SkimDestinationSpeech.Speech? {
        let control = chapterRowForwardControl
        switch control {
        case .hidden: return nil
        case .skim: return skimSpeech(.forward)
        case .skimDisabled, .playNextItem: return skimDisabledSpeech(.forward)
        case .nextChapter, .nextChapterInSkimSlot:
            let next = nextChapterStop
            return skimDescriber.nextChapterSpeech(
                standingInFor: control == .nextChapterInSkimSlot ? skimBridge.forwardUnavailableReason : nil,
                chapterId: next?.id, start: next?.start, inSkimSlot: control == .nextChapterInSkimSlot)
        }
    }

    /// A Skim arrow that can be pressed: where its press lands, or the place a playing summary ends.
    private func skimSpeech(_ direction: SkimDestinationSpeech.Direction) -> SkimDestinationSpeech.Speech {
        if snapshot.isRecording { return SkimDestinationSpeech.skim(direction, to: .locked, position: nil) }
        let forward = direction == .forward
        let describer = skimDescriber
        let skim: SkimDirection = forward ? .forward : .backward
        if let landing = snapshot.skimBridgeState?.destinationMediaTimeMs {
            return describer.landingSpeech(direction: skim, at: landing)
        }
        return describer.speech(
            direction: skim, choice: forward ? skimBridge.forwardChoice : skimBridge.backwardChoice,
            summaryDestination: forward ? skimBridge.forwardDestinationMs : skimBridge.backwardDestinationMs)
    }

    /// A dimmed Skim arrow: nothing that way, or the stops are still being read from the store.
    private func skimDisabledSpeech(_ direction: SkimDestinationSpeech.Direction) -> SkimDestinationSpeech.Speech {
        let destination: SkimDestinationSpeech.Destination = snapshot.isRecording ? .locked
            : (direction == .forward && skimBridge.forwardUnavailableReason == .loading ? .loading : .none)
        return SkimDestinationSpeech.skim(direction, to: destination, position: nil)
    }
}
