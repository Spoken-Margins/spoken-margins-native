import Foundation

/// Whether the Now tab's scene follows the playing sentence, and which scene it shows (#4453).
///
/// The Now tab shows a whole scene the listener can scroll. While it follows, the lit sentence stays in view. A scroll
/// by the listener stops that; it starts again on the Back to playing button, when a scroll comes to rest with the lit
/// sentence on screen, and on any jump the listener chose in playback (a seek, Skim, a chapter jump, "Play this
/// moment"). There is no timer. This is a view-follow state, not a playback state machine: it never moves audio and
/// owns nothing playback needs.
public struct PlaybackSceneFollow: Equatable, Sendable {
    /// Where the playhead is: the scene (named by where it starts in the text), its title, and the lit sentence.
    public struct Playhead: Equatable, Sendable {
        public let chapterStart: Int
        public let chapterTitle: String?
        public let sentence: Int

        public init(chapterStart: Int, chapterTitle: String?, sentence: Int) {
            self.chapterStart = chapterStart
            self.chapterTitle = chapterTitle
            self.sentence = sentence
        }
    }

    /// The lit sentence is kept in view without the listener touching the list.
    public private(set) var isFollowing = true
    /// The scene on screen: the playing one while following, the one the listener was reading otherwise.
    public private(set) var shownChapterStart: Int?
    public private(set) var playhead: Playhead?

    public init() {}

    /// The title for the button's second line, "Now in: <title>": only when the playing scene is not the one on screen
    /// and has a title.
    public var nowInTitle: String? {
        guard let playhead, let shownChapterStart, playhead.chapterStart != shownChapterStart else { return nil }
        return playhead.chapterTitle
    }

    /// Back to playing is offered whenever the listener has left the lit sentence, or is reading an older scene.
    public var offersBackToPlaying: Bool { !isFollowing }

    /// The list moves to the lit sentence by itself: following, and no VoiceOver (focus must not be pulled away).
    public func scrollsOnItsOwn(assistiveTechnologyRunning: Bool) -> Bool {
        isFollowing && !assistiveTechnologyRunning
    }

    /// The listener dragged, flung or tapped the status bar.
    public mutating func listenerScrolled() {
        isFollowing = false
    }

    /// The listener's scroll came to rest. Following starts again when the lit sentence is on screen.
    public mutating func scrollCameToRest(litSentenceIsVisible: Bool) {
        guard !isFollowing, litSentenceIsVisible, playhead?.chapterStart == shownChapterStart else { return }
        isFollowing = true
    }

    /// The Back to playing button: the playing scene, following again.
    public mutating func backToPlayingTapped() {
        isFollowing = true
        shownChapterStart = playhead?.chapterStart
    }

    /// The playhead moved. `byListenerControl` is true for a seek, Skim, a chapter jump, Rewind, "Play this moment" or a
    /// Margin moment, which the listener asked for; a playback tick passes false.
    ///
    /// The same sentence and the next one, or the first sentence of a later scene, are playback going on. Any other
    /// move is a jump: following starts again at the new place, even if the listener had scrolled away.
    public mutating func playheadMoved(to next: Playhead, byListenerControl: Bool) {
        defer { playhead = next }
        guard let previous = playhead else {
            shownChapterStart = next.chapterStart
            return
        }
        let advanced = !byListenerControl && Self.isPlaybackGoingOn(from: previous, to: next)
        if advanced {
            // Reading elsewhere keeps the scene on screen. Following takes the next scene along with the playhead.
            if isFollowing { shownChapterStart = next.chapterStart }
        } else {
            isFollowing = true
            shownChapterStart = next.chapterStart
        }
    }

    static func isPlaybackGoingOn(from previous: Playhead, to next: Playhead) -> Bool {
        if next.chapterStart == previous.chapterStart {
            return next.sentence == previous.sentence || next.sentence == previous.sentence + 1
        }
        return next.chapterStart > previous.chapterStart && next.sentence == 0
    }
}
