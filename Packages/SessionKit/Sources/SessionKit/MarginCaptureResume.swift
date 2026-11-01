import Foundation

/// The one owner of "does the source resume after a Margin capture, a call that cut one short or a relaunch, and from
/// where" (#3144, #3032 slice 3). `SystemInterruptionResume` owns the same question for a system interruption of
/// playback; together the two files are the family `scripts/resume_owners.py` treats as owners.
///
/// The question used to be answered in `SessionEngine` by four separate variables (`priorPhase`,
/// `pendingInterjectionPause`, `recordingOnFinishedSource`, `rejoinAttempted`) and a protected position, and in
/// `MarginRecordingInterruptionPolicy` by a fifth (`pendingResume`). Each fix for a "playback did or didn't resume"
/// bug touched one copy (#1705 took five audit rounds). Now `SessionEngine` and the policy only report what happened
/// (the tap paused the podcast, the recorder started, the listener saved or cancelled, the call ended) and obey the
/// answer. The app and the hands-free coordinator reach it through the engine's commands and the policy's actions.
///
/// The rules, in one place:
/// - A source that was playing resumes after a Save, Cancel or written Margin, unless the caller says another voice
///   plays on instead (`resumesSource: false`).
/// - A source that had finished returns to finished: there is nothing left to play, and playing again would
///   restart it. This holds for Save, Cancel and a switch to writing, and it overrides `resumesSource`.
/// - A recorder that would not start puts back a source that was playing, never a finished one.
/// - A Cancel or a switch to writing returns to the phase the source was in when the recording began; a Save returns
///   to the plain phase of the target's kind.
/// - The step back over a saved Margin runs once per Margin, however many times Save is retried.
/// - A tap that paused a playing podcast is taken over by the next recording or written Margin, once.
/// - A position the engine protects (after a seek, a relaunch, a jump to a Margin) is kept until playback confirms
///   it, and only the target it was taken for sees it.
/// - A call that cut a Margin short resumes the source only if iOS says it should, the Margin is not recording again,
///   and the source is still exactly where the Margin left it. Lost headphones cancel it.
struct MarginCaptureResume {
    /// What the engine does with the source once a capture is over.
    enum Outcome: Equatable {
        /// Play on from where it stopped.
        case resumePlaying
        /// Leave it paused at the Margin's place.
        case stayPaused
        /// It had finished: leave it finished.
        case settleFinished
    }

    /// The timing of a tap that paused a playing podcast before the recorder was asked for (#1696).
    private(set) var tapPause: MarginCaptureTiming?
    /// The phase the source was in when the recording began.
    private var phaseAtStart: SessionPhase?
    /// The Margin being recorded started on a finished source, at its end (#142).
    private(set) var startedOnFinishedSource = false
    /// The Margin whose step back already ran. Margin ids repeat across sessions ("ij-001" is every session's first),
    /// so the session is part of the key.
    private var rejoinedMargin: String?

    // MARK: Reports

    /// The tap on Add a Margin paused a playing podcast.
    mutating func tapPaused(_ timing: MarginCaptureTiming) {
        tapPause = timing
    }

    var isSourcePausedOnTap: Bool { tapPause != nil }

    /// The recording or the written Margin takes over the tap's pause. Returns it, or nil when the tap paused nothing.
    @discardableResult
    mutating func takeOverTapPause() -> MarginCaptureTiming? {
        defer { tapPause = nil }
        return tapPause
    }

    /// A recording is starting. `finishedAtEnd` is whether the source had finished at its end.
    mutating func captureStarting(finishedAtEnd: Bool) {
        startedOnFinishedSource = finishedAtEnd
    }

    /// The source is paused and its position saved: the phase a Cancel returns to.
    mutating func sourcePaused(in phase: SessionPhase) {
        phaseAtStart = phase
    }

    /// The recorder would not start, or the session ended: nothing is recording.
    mutating func captureAbandoned() {
        phaseAtStart = nil
        startedOnFinishedSource = false
    }

    /// The session the capture belonged to ended.
    mutating func sessionEnded() {
        captureAbandoned()
        tapPause = nil
        rejoinedMargin = nil
    }

    /// True once per Margin: the step back over it may run now. A second ask for the same Margin is refused.
    mutating func claimRejoin(forMargin id: String, inSession sessionId: String) -> Bool {
        let key = "\(sessionId)/\(id)"
        guard rejoinedMargin != key else { return false }
        rejoinedMargin = key
        return true
    }

    // MARK: Answers

    /// A Margin recorded on the finished source goes back to finished, however the capture ends.
    func returnsToFinishedSource(targetType: InterjectionTargetType) -> Bool {
        targetType == .item && startedOnFinishedSource
    }

    /// What the source does after Save, Cancel or a switch to writing.
    func outcome(targetType: InterjectionTargetType, resumesSource: Bool) -> Outcome {
        if returnsToFinishedSource(targetType: targetType) { return .settleFinished }
        return resumesSource ? .resumePlaying : .stayPaused
    }

    /// Whether a recorder that would not start puts the source back playing.
    func resumesAfterFailedStart(sourceWasPlaying: Bool) -> Bool {
        sourceWasPlaying && !startedOnFinishedSource
    }

    /// The phase a Save returns to: the plain phase of the target's kind.
    static func phase(afterSavingOn targetType: InterjectionTargetType) -> SessionPhase {
        switch targetType {
        case .assistantTurn: return .aiResponsePlayback
        case .summaryTurn: return .summaryPlayback
        case .item: return .itemPlayback
        }
    }

    /// The phase a Cancel or a switch to writing returns to: the one the recording began in, else the plain phase.
    func phase(afterCancellingOn targetType: InterjectionTargetType) -> SessionPhase {
        phaseAtStart ?? Self.phase(afterSavingOn: targetType)
    }
}

/// The place the engine keeps a playback position safe until playback confirms it (#3144): after a seek, a relaunch,
/// a jump to a Margin, a step back. While one is held, a position read from the player (which may still report the
/// old place) must not overwrite it. Only the target it was taken for sees it.
struct ProtectedResumePosition {
    private struct Mark {
        var targetId: String
        var targetType: TargetType
        var position: Position
        var mediaSeekRequest: MediaSeekRequest?
    }

    private var mark: Mark?

    /// Keep the session's position, with the media seek whose outcome will confirm or refuse it.
    mutating func protect(_ session: Session, mediaSeekRequest: MediaSeekRequest? = nil) {
        mark = Mark(
            targetId: session.currentTargetId,
            targetType: session.currentTargetType,
            position: session.position,
            mediaSeekRequest: mediaSeekRequest
        )
    }

    /// The protected position, for the target the session is on; nil for any other.
    func position(for session: Session) -> Position? {
        guard let mark, mark.targetId == session.currentTargetId, mark.targetType == session.currentTargetType else {
            return nil
        }
        return mark.position
    }

    func holdsPosition(for session: Session) -> Bool { position(for: session) != nil }

    /// The media seek waiting on the player, for the target the session is on.
    func mediaSeekRequest(for session: Session) -> MediaSeekRequest? {
        guard mark?.targetId == session.currentTargetId, mark?.targetType == session.currentTargetType else { return nil }
        return mark?.mediaSeekRequest
    }

    /// Playback of the target started: the player's clock is trustworthy again.
    mutating func playbackConfirmed(targetId: String) {
        if mark?.targetId == targetId { mark = nil }
    }

    /// The position no longer applies: the seek was settled, the source ended, or the session did.
    mutating func release() {
        mark = nil
    }
}

/// What a call that cut a spoken Margin short does to the source afterwards (#771). It was `pendingResume` inside
/// `MarginRecordingInterruptionPolicy`; the policy now asks here.
struct InterruptedCaptureResume: Equatable {
    private enum State: Equatable {
        case none
        /// A call stopped a Margin; the save or discard hasn't settled where the source is yet.
        case awaitingMark
        case at(InterruptedSourceMark)
    }

    private var state = State.none

    /// A call cut the Margin short and its save or discard is under way.
    mutating func marginCutShort() {
        state = .awaitingMark
    }

    /// Nothing is waiting any more: a later interruption with no Margin recording replaces one whose end never came,
    /// and lost headphones cancel a resume still waiting on a call.
    mutating func cancel() {
        state = .none
    }

    /// The save or discard left the source here (nil: not paused part-way, so nothing resumes).
    mutating func sourceSettled(at mark: InterruptedSourceMark?) {
        guard state == .awaitingMark else { return }
        state = mark.map { .at($0) } ?? .none
    }

    /// The call ended. True when the source resumes: iOS says it should, no Margin is recording, and the source is
    /// still where the Margin left it. Spends the wait either way.
    mutating func ended(shouldResume: Bool, recordedSeconds: TimeInterval?, pausedSource: InterruptedSourceMark?) -> Bool {
        defer { state = .none }
        guard case .at(let mark) = state, shouldResume, recordedSeconds == nil,
              let pausedSource, pausedSource == mark else { return false }
        return true
    }
}

/// What a hands-free Margin does to the source afterwards (#3170, #3032 slice 4). It was `resumesAfter` and
/// `awaitingInterruptionEnd` inside `HandsFreeMarginCoordinator`, each assigned at a different edge: a press after a call
/// that iOS never ended, headphones removed during the closing tone, a call during the rejoin (#1705 fixed these one
/// copy at a time). The coordinator now reports what happened and obeys `resumesSource`.
///
/// The rules, in one place:
/// - A hands-free Margin resumes the source when it ends, unless the headphones were removed (nothing should play from
///   the phone speaker) or the listener pressed again after a call iOS never reported ending.
/// - A call that cut the Margin short holds the answer until it ends; the source then resumes only if iOS says it should,
///   and only if nothing earlier ruled it out.
/// - Headphones removed at any later point rule the resume out, even in the closing tone or while a call is pending.
struct HandsFreeCaptureResume: Equatable {
    /// Whether the source resumes once the closing tone, or the wait for a call, is over.
    private(set) var resumesSource = true
    /// A call took the audio session and has not been reported ended; the answer waits for it.
    private(set) var isWaitingForCallToEnd = false

    /// A new hands-free Margin begins: resume by default, no call pending.
    mutating func reset() {
        resumesSource = true
        isWaitingForCallToEnd = false
    }

    /// The Margin closes and the source should (or should not) resume: a flag or a saved Margin (`resume: true`), or a save
    /// after removed headphones (`resume: false`).
    mutating func closing(resume: Bool) {
        resumesSource = resume
    }

    /// A call or Siri took the audio session.
    mutating func callBegan() {
        isWaitingForCallToEnd = true
    }

    /// The call ended. Returns false when no call was being waited for (nothing changes). Otherwise the wait is spent and
    /// the source resumes only if it still would have and iOS says it should.
    mutating func callEnded(shouldResume: Bool) -> Bool {
        guard isWaitingForCallToEnd else { return false }
        isWaitingForCallToEnd = false
        resumesSource = resumesSource && shouldResume
        return true
    }

    /// The listener pressed again while the call's end was still awaited: iOS does not always report it, and the press
    /// means they are back. The wait is spent and the source stays paused.
    mutating func pressedAfterCallThatNeverEnded() {
        isWaitingForCallToEnd = false
        resumesSource = false
    }

    /// The headphones came out: nothing resumes from the phone speaker.
    mutating func headphonesRemoved() {
        resumesSource = false
    }
}
