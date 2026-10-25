import Combine
import Foundation
import SessionKit

/// The Margin capture state (#993): what the recording and written-Margin screens show, the one microphone request
/// that may be waiting, and the shield that stops a double tap on Save from starting a new Margin. Moved out of
/// `Gate1AppModel` without changing a statement of what it does or the order it does it in.
///
/// It is state and the rules that guard it, nothing else. It has no host, no engine, no recorder, no Task, no timer
/// and no audio session, and it never calls out. The model keeps every sequence (engine, snapshot, streaming
/// queue, diagnostics) in the statement order it always ran in, and each write it made to this state is one call
/// here at the same place. That keeps the order visible in the model, and it means no call here can re-enter the
/// model while one of these values is being changed.
///
/// The published values are the canonical copies. The model exposes them under their old names and forwards
/// `objectWillChange` synchronously, so observers are told before a value changes, as they were when the model
/// published them itself. Every write notifies, including one that stores an equal value: nothing here compares
/// first, and the tests pin that. `pendingVoiceRequestID` is deliberately not published, as before.
@MainActor
final class MarginCaptureCoordinator: ObservableObject {
    @Published private(set) var presentationContext: RecordingPresentationContext?
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var primer = MicrophonePrimer()
    @Published private(set) var isFinishing = false
    @Published private(set) var restartShield = MarginRestartShield()
    @Published private(set) var writtenDraft: WrittenMarginDraft?
    /// Holds the object that journals the written Margin being typed (#1970). Only stored here; the model creates and uses it.
    var draftKeeper: WrittenMarginDraftKeeper?
    private(set) var pendingVoiceRequestID: UUID?
    /// The shared Margin the spoken Margin being started answers (#473), and whether the listener switched it to
    /// independent. Published so the switch redraws the recording screen. It goes with the presentation context.
    @Published private(set) var replyChoice = MarginReplyChoice()
    var pendingReply: MarginReplyDraft? { replyChoice.effective }
    /// The last shared Margin heard, so a Margin recorded over it or just after answers it (#473). Not published.
    private(set) var sharedReplyMemory = SharedMarginReplyMemory()
    /// The compact control's microphone request (#2126): Cancel or a newer request makes a late grant stale.
    private var compactRequest = CurrentRequest()

    // MARK: A spoken Margin's microphone request

    /// A tap on Add a Margin: a new request, the earlier denial forgotten, the request showing. In this order.
    func beginVoiceRequest() -> UUID {
        let id = UUID()
        pendingVoiceRequestID = id
        compactRequest.cancel() // the newest request wins; a compact grant still out must not start a second Margin (#2126)
        permissionDenied = false
        isRequestingPermission = true
        return id
    }

    /// True when this request must wait for Continue before iOS's prompt. Always writes the primer, as before.
    func holdForPrimer(captureID: UUID, status: PermissionPromptStatus) -> Bool {
        primer.holds(captureID: captureID, status: status)
    }

    /// Continue on the primer: the request to go on with, once. The primer clears even when the request has moved on.
    func continuePrimer() -> UUID? {
        guard let captureID = primer.continueTapped(), pendingVoiceRequestID == captureID else { return nil }
        return captureID
    }

    enum PermissionOutcome { case stale, denied, granted }

    /// The answer to the microphone request. An answer for a request that is no longer the current one changes
    /// nothing; a denial ends the request and shows the denial, in the order it always did.
    func resolvePermission(for id: UUID, granted: Bool) -> PermissionOutcome {
        guard pendingVoiceRequestID == id else { return .stale }
        guard granted else {
            isRequestingPermission = false
            presentationContext = nil
            replyChoice = MarginReplyChoice()
            pendingVoiceRequestID = nil
            permissionDenied = true
            return .denied
        }
        return .granted
    }

    /// Whether this is still the current request. Writes nothing.
    func claimStart(for id: UUID) -> Bool {
        pendingVoiceRequestID == id
    }

    /// The end of a start, however it went (the `defer` after `claimStart`).
    func releaseStart() {
        isRequestingPermission = false
        pendingVoiceRequestID = nil
    }

    /// Cancel, or the pencil, while a request waits: the primer, the request and the screen's context go. It does
    /// not clear a denial and does not put the source back; the callers decide that.
    func abandonVoiceRequest() {
        compactRequest.cancel() // a compact control's grant that lands after Cancel starts nothing (#2126)
        primer.cancel()
        pendingVoiceRequestID = nil
        isRequestingPermission = false
        presentationContext = nil
        replyChoice = MarginReplyChoice()
    }

    // MARK: A compact control's request (#2126: fenced like the in-app request)

    /// A Live Activity, widget or headphone tap asked for a Margin. The token goes through the permission prompt.
    @discardableResult
    func beginCompactRequest() -> CurrentRequest.Token {
        isRequestingPermission = true
        return compactRequest.begin()
    }

    /// Whether the compact request is still wanted: no Cancel and no newer request since. Writes nothing.
    func isCurrentCompactRequest(_ token: CurrentRequest.Token) -> Bool {
        compactRequest.isCurrent(token)
    }

    func endCompactRequest() {
        compactRequest.cancel()
        isRequestingPermission = false
    }

    // MARK: What the recording screen shows

    func setPresentationContext(_ context: RecordingPresentationContext) {
        presentationContext = context
    }

    /// Always writes, and so always notifies, even when there is no context.
    func clearPresentationContext() {
        presentationContext = nil
        replyChoice = MarginReplyChoice()
    }

    func setPendingReply(_ reply: MarginReplyDraft?) {
        replyChoice = MarginReplyChoice(suggested: reply)
    }

    /// Switches the Margin being started between a reply and an independent Margin (#473).
    func toggleReplyChoice() {
        replyChoice.toggle()
    }

    func sharedMarginBegan(_ draft: MarginReplyDraft, itemId: String) {
        sharedReplyMemory.began(draft, itemId: itemId)
    }

    func sharedMarginEnded(at date: Date = Date()) {
        sharedReplyMemory.ended(at: date)
    }

    // MARK: Finishing, and the shield that follows

    /// Save was tapped. False when a finish is already under way. The flag and then the shield, in this order.
    func requestFinish() -> Bool {
        guard !isFinishing else { return false }
        isFinishing = true
        restartShield.saveRequested()
        return true
    }

    /// The save returned: the shield first, then the flag.
    func finalizeFinish(at date: Date, stillRecording: Bool) {
        restartShield.saveFinished(at: date, stillRecording: stillRecording)
        isFinishing = false
    }

    func screenAppeared(at date: Date) {
        restartShield.screenAppeared(at: date)
    }

    func isCoolingDown(at date: Date) -> Bool {
        !restartShield.acceptsBegin(at: date)
    }

    // MARK: A written Margin

    func clearPermissionDenied() {
        permissionDenied = false
    }

    func openDraft(_ draft: WrittenMarginDraft) {
        writtenDraft = draft
    }

    /// Without a draft nothing is written, so nothing is announced.
    func setDraftText(_ text: String) {
        writtenDraft?.text = text
    }

    func toggleDraftReply() {
        writtenDraft?.replyChoice.toggle()
    }

    func closeDraft() {
        writtenDraft = nil
    }
}
