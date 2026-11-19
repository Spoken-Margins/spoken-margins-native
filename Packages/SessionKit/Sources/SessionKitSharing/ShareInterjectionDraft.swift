import Foundation
import SessionKit

public enum ShareMarginRepresentationChoice: String, CaseIterable, Identifiable {
    case original
    case cleaned
    case textOnly

    public var id: String { rawValue }
}

public struct ShareMarginEditState: Equatable, Sendable {
    public var automaticCleanupEnabled = false
    public var restoredAutomaticDecisionIds: Set<String> = []
    public var manuallyDeletedSegmentIds: Set<String> = []

    public init(
        automaticCleanupEnabled: Bool = false,
        restoredAutomaticDecisionIds: Set<String> = [],
        manuallyDeletedSegmentIds: Set<String> = []
    ) {
        self.automaticCleanupEnabled = automaticCleanupEnabled
        self.restoredAutomaticDecisionIds = restoredAutomaticDecisionIds
        self.manuallyDeletedSegmentIds = manuallyDeletedSegmentIds
    }

    public mutating func disableAutomaticCleanup() {
        automaticCleanupEnabled = false
        restoredAutomaticDecisionIds.removeAll()
    }

    public static let original = ShareMarginEditState()
}

public struct ShareInterjectionDraft: Identifiable {
    public var id: String { interjection.id }
    public var interjection: Interjection
    public var isIncluded = true
    public var approvedTranscript: String
    public var cleanup: InterjectionCleanupResult?
    public var cleanedAudioURL: URL?
    public var cleanedAudioDurationMs: Int?
    public var representationChoice: ShareMarginRepresentationChoice
    public var warning: String?
    public var anchorBefore: String
    public var anchorAfter: String
    public var acousticPauseDecisions: [InterjectionCleanupDecision] = []
    public var editHistory: [ShareMarginEditState] = [.original]
    public var editHistoryIndex = 0
    public var isAnalyzingPauses = false
    public var isPreparingCleanup = false
    public var preparationMessage: String?
    public var renderGeneration = 0
    /// The stand-in words this Margin starts with when it has none of its own (#3027), or `nil`. The listener can
    /// replace them; clearing their words brings these back, so the Margin never goes word-less.
    public var placeholderText: String?
    /// Whether the listener's phone reads this Margin aloud when it goes as text (#3427). On unless the sender turns it
    /// off; it means nothing for a Margin that goes as a recording.
    public var readAloud = true
    /// The choice the sender's last text share of this Margin carried (#3472), or `nil` if it was never shared as text.
    /// When it was "no" and the switch is now on, the packet says "yes" so the listener's held copy follows.
    public var previousReadAloud: Bool?
    /// How much of the episode the sender asks their friend to hear before this Margin, in milliseconds (#4171). It
    /// starts at the length this Margin was last shared with, else the 20 s default. Nothing on screen sets it yet.
    public var leadInMs = SenderLeadIn.defaultMs
    /// The length the sender's last share of this Margin wrote, or `nil` if none ever did. With `leadInMs` it decides
    /// what the packet writes (`SenderLeadIn.valueToWrite`).
    public var previousLeadInMs: Int?

    public init(
        interjection: Interjection,
        isIncluded: Bool = true,
        approvedTranscript: String,
        cleanup: InterjectionCleanupResult? = nil,
        cleanedAudioURL: URL? = nil,
        cleanedAudioDurationMs: Int? = nil,
        representationChoice: ShareMarginRepresentationChoice,
        warning: String? = nil,
        anchorBefore: String,
        anchorAfter: String,
        acousticPauseDecisions: [InterjectionCleanupDecision] = [],
        editHistory: [ShareMarginEditState] = [.original],
        editHistoryIndex: Int = 0,
        isAnalyzingPauses: Bool = false,
        isPreparingCleanup: Bool = false,
        preparationMessage: String? = nil,
        renderGeneration: Int = 0,
        placeholderText: String? = nil
    ) {
        self.interjection = interjection
        self.isIncluded = isIncluded
        self.approvedTranscript = approvedTranscript
        self.cleanup = cleanup
        self.cleanedAudioURL = cleanedAudioURL
        self.cleanedAudioDurationMs = cleanedAudioDurationMs
        self.representationChoice = representationChoice
        self.warning = warning
        self.anchorBefore = anchorBefore
        self.anchorAfter = anchorAfter
        self.acousticPauseDecisions = acousticPauseDecisions
        self.editHistory = editHistory
        self.editHistoryIndex = editHistoryIndex
        self.isAnalyzingPauses = isAnalyzingPauses
        self.isPreparingCleanup = isPreparingCleanup
        self.preparationMessage = preparationMessage
        self.renderGeneration = renderGeneration
        self.placeholderText = placeholderText
    }

    public var currentEditState: ShareMarginEditState {
        editHistory[min(max(0, editHistoryIndex), editHistory.count - 1)]
    }

    public var canUndoEdit: Bool { editHistoryIndex > 0 }
    public var canRedoEdit: Bool { editHistoryIndex + 1 < editHistory.count }

    /// Whether the words that will be sent are still the placeholder, not the listener's own.
    public var isShowingPlaceholder: Bool {
        guard let placeholderText else { return false }
        return approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines) == placeholderText
    }
}

extension ShareInterjectionDraft {
    /// The draft the review sheet starts with (#3027). The Margin's own words win: its cleaned transcript, then its
    /// transcript, then its display text. A voice Margin with none starts with `SharedMarginPlaceholder` words, so it
    /// is shared rather than left out. Only a Margin with neither words nor voice keeps the "can't be shared" warning.
    public static func initial(
        for interjection: Interjection,
        isIncluded: Bool,
        hasVoice: Bool,
        itemTitle: String?,
        lastSentReadAloud: Bool? = nil,
        lastSentLeadInMs: Int? = nil,
        timeZone: TimeZone = .current
    ) -> ShareInterjectionDraft {
        let words = SharedMarginTextRequirement.initialReviewedText(for: interjection)
        let placeholder = SharedMarginPlaceholder.words(for: interjection, itemTitle: itemTitle, hasVoice: hasVoice, timeZone: timeZone)
        let transcript = placeholder ?? words
        // The excerpt cap scales with the listener's own words; placeholder words are not commentary.
        let context = ExcerptCapRule.select(
            before: interjection.anchor.anchorBefore,
            after: interjection.anchor.anchorAfter,
            commentLength: ExcerptCapRule.commentLength(transcript: words)
        )
        var draft = ShareInterjectionDraft(
            interjection: interjection,
            isIncluded: isIncluded,
            approvedTranscript: transcript,
            representationChoice: hasVoice ? .original : .textOnly,
            warning: SharedMarginTextRequirement.reviewWarning(for: transcript),
            anchorBefore: context.before,
            anchorAfter: context.after,
            placeholderText: placeholder
        )
        // A re-share keeps the switch where the sender last put it for this Margin (#3472).
        draft.readAloud = lastSentReadAloud ?? true
        draft.previousReadAloud = lastSentReadAloud
        // So does the run-up length (#4171): a re-share starts from the length the friend was last given.
        draft.leadInMs = SenderLeadIn.startingMs(lastSent: lastSentLeadInMs)
        draft.previousLeadInMs = lastSentLeadInMs
        return draft
    }

    /// What this share writes for the Margin's run-up length, or `nil` to write none. The packet and the saved share
    /// both use this one value, so the next share's "previous" is exactly what the friend was told.
    public var leadInToWrite: Int? {
        SenderLeadIn.valueToWrite(chosen: leadInMs, previous: previousLeadInMs)
    }

    /// The listener's words for a Margin that started with placeholder words. Clearing them brings the placeholder
    /// back, so the Margin is never left word-less.
    public mutating func setReviewedWords(_ words: String) {
        guard let placeholderText else { return }
        approvedTranscript = SharedMarginTextRequirement.hasReviewedText(words) ? words : placeholderText
    }
}

extension ShareInterjectionDraft {
    public mutating func setIncluded(_ included: Bool) {
        isIncluded = included
    }

    public mutating func setRepresentation(_ choice: ShareMarginRepresentationChoice, hasOriginalAudio: Bool) {
        if choice == .cleaned, cleanedAudioURL == nil { return }
        if choice == .original, !hasOriginalAudio { return }
        representationChoice = choice
    }

    public mutating func setAnchorBefore(_ value: String) {
        anchorBefore = ExcerptCapRule.hardLimit(
            value, cap: ExcerptCapRule.beforeCap(commentLength: ExcerptCapRule.commentLength(transcript: approvedTranscript)), keepingEnd: true
        )
    }

    public mutating func setAnchorAfter(_ value: String) {
        anchorAfter = ExcerptCapRule.hardLimit(value, cap: ExcerptCapRule.afterMaximum, keepingEnd: false)
    }

    public mutating func setCleanupDecision(decisionID: String, accepted: Bool, hasOriginalAudio: Bool) -> Bool {
        recordEdit(hasOriginalAudio: hasOriginalAudio) { state in
            if accepted {
                state.restoredAutomaticDecisionIds.remove(decisionID)
            } else {
                state.restoredAutomaticDecisionIds.insert(decisionID)
            }
        }
    }

    public mutating func toggleWord(segmentID: String, hasOriginalAudio: Bool) -> Bool {
        guard let aligned = interjection.alignedTranscript,
              let segment = aligned.segments.first(where: { $0.id == segmentID }) else { return false }
        let overlappingAccepted = cleanup?.decisions.filter {
            $0.accepted && $0.kind != .longPause && $0.startMs < segment.endMs && $0.endMs > segment.startMs
        } ?? []
        return recordEdit(hasOriginalAudio: hasOriginalAudio) { state in
            if state.manuallyDeletedSegmentIds.contains(segmentID) || !overlappingAccepted.isEmpty {
                state.manuallyDeletedSegmentIds.remove(segmentID)
                overlappingAccepted.forEach { state.restoredAutomaticDecisionIds.insert($0.id) }
            } else {
                state.manuallyDeletedSegmentIds.insert(segmentID)
            }
        }
    }

    public func isWordDeleted(segmentID: String) -> Bool {
        guard let segment = interjection.alignedTranscript?.segments.first(where: { $0.id == segmentID }) else {
            return false
        }
        return cleanup?.decisions.contains {
            $0.accepted && $0.kind != .longPause && $0.startMs < segment.endMs && $0.endMs > segment.startMs
        } ?? false
    }

    public mutating func undoEdit(hasOriginalAudio: Bool, renderCleanedAudio: Bool = true) -> Bool {
        guard canUndoEdit else { return false }
        editHistoryIndex -= 1
        return applyEditState(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: renderCleanedAudio)
    }

    public mutating func redoEdit(hasOriginalAudio: Bool, renderCleanedAudio: Bool = true) -> Bool {
        guard canRedoEdit else { return false }
        editHistoryIndex += 1
        return applyEditState(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: renderCleanedAudio)
    }

    /// Takes the anchor evidence the stored Margin has gained since the sheet opened (#3839). The review's step reads the
    /// stored Margin, so a step that says "nothing pending" must not go with a packet built from the copy taken at open.
    /// Returns whether anything changed; the Margin's words and the sender's edits are never touched.
    @discardableResult
    public mutating func refreshAnchorEvidence(from stored: Interjection) -> Bool {
        guard stored.id == interjection.id,
              interjection.podcastAnchorEvidence != stored.podcastAnchorEvidence
                || interjection.podcastAnchorEvidenceCaptureStatus != stored.podcastAnchorEvidenceCaptureStatus
                || interjection.podcastAnchorEvidenceFailureReason != stored.podcastAnchorEvidenceFailureReason
                || interjection.sourceExactEditionSHA256 != stored.sourceExactEditionSHA256 else { return false }
        interjection.podcastAnchorEvidence = stored.podcastAnchorEvidence
        interjection.podcastAnchorEvidenceCaptureStatus = stored.podcastAnchorEvidenceCaptureStatus
        interjection.podcastAnchorEvidenceFailureReason = stored.podcastAnchorEvidenceFailureReason
        interjection.sourceExactEditionSHA256 = stored.sourceExactEditionSHA256
        return true
    }

    /// Whether the sender has changed nothing that a rebuild from the arrived words would overwrite: the words, the
    /// version, the read-aloud switch, the run-up, the placement words, and any cleanup. Whether the Margin is included
    /// is not an edit (it follows the Choose step), so a rebuild keeps it.
    public func isUnedited(hasVoice: Bool, itemTitle: String?, timeZone: TimeZone = .current) -> Bool {
        let baseline = Self.initial(
            for: interjection, isIncluded: isIncluded, hasVoice: hasVoice, itemTitle: itemTitle,
            lastSentReadAloud: previousReadAloud, lastSentLeadInMs: previousLeadInMs, timeZone: timeZone)
        return approvedTranscript == baseline.approvedTranscript
            && representationChoice == baseline.representationChoice
            && readAloud == baseline.readAloud
            && leadInMs == baseline.leadInMs
            && anchorBefore == baseline.anchorBefore
            && anchorAfter == baseline.anchorAfter
            && editHistory == [.original] && editHistoryIndex == 0
            && cleanup == nil && cleanedAudioURL == nil
            && !isAnalyzingPauses && !isPreparingCleanup
    }

    /// Rebuilds this draft from the stored Margin once its words have arrived (#3839): the text, the timing, whether it
    /// can be cleaned. It happens only when the draft was made while the words were pending and the sender has changed
    /// nothing since (`isUnedited`), so it never takes their edits away. The Margin stays included or not as it was.
    /// Returns whether the draft changed.
    @discardableResult
    public mutating func adoptArrivedWords(
        from stored: Interjection, hasVoice: Bool, itemTitle: String?, timeZone: TimeZone = .current
    ) -> Bool {
        guard stored.id == interjection.id,
              interjection.transcriptionStatus == "pending", stored.transcriptionStatus != "pending",
              isUnedited(hasVoice: hasVoice, itemTitle: itemTitle, timeZone: timeZone) else { return false }
        self = Self.initial(
            for: stored, isIncluded: isIncluded, hasVoice: hasVoice, itemTitle: itemTitle,
            lastSentReadAloud: previousReadAloud, lastSentLeadInMs: previousLeadInMs, timeZone: timeZone)
        return true
    }

    public mutating func restoreOriginal(hasOriginalAudio: Bool) {
        editHistory = [.original]
        editHistoryIndex = 0
        cleanup = nil
        cleanedAudioURL = nil
        cleanedAudioDurationMs = nil
        isAnalyzingPauses = false
        isPreparingCleanup = false
        preparationMessage = nil
        let words = interjection.transcript ?? interjection.displayText ?? ""
        approvedTranscript = SharedMarginTextRequirement.hasReviewedText(words) ? words : (placeholderText ?? words)
        representationChoice = hasOriginalAudio ? .original : .textOnly
        warning = SharedMarginTextRequirement.reviewWarning(for: approvedTranscript)
    }

    /// Returns whether the app must render cleaned audio after this in-place edit.
    public mutating func recordEdit(
        hasOriginalAudio: Bool,
        renderCleanedAudio: Bool = true,
        mutate: (inout ShareMarginEditState) -> Void
    ) -> Bool {
        guard interjection.alignedTranscript != nil else { return false }
        var state = currentEditState
        mutate(&state)
        guard state != currentEditState else { return false }
        editHistory = Array(
            editHistory.prefix(editHistoryIndex + 1)
        ) + [state]
        editHistoryIndex += 1
        return applyEditState(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: renderCleanedAudio)
    }

    /// File availability is supplied by the app; audio rendering remains an app side effect.
    public mutating func applyEditState(hasOriginalAudio: Bool, renderCleanedAudio: Bool = true) -> Bool {
        guard let aligned = interjection.alignedTranscript else { return false }
        let state = currentEditState
        let allAutomatic = DeterministicInterjectionCleanup.propose(aligned).decisions.map(\.id)
        var restored = state.restoredAutomaticDecisionIds
        if !state.automaticCleanupEnabled {
            restored.formUnion(allAutomatic)
            restored.formUnion(acousticPauseDecisions.map(\.id))
        }
        let core = DeterministicInterjectionCleanup.propose(
            aligned,
            restoredDecisionIds: restored,
            manuallyDeletedSegmentIds: state.manuallyDeletedSegmentIds
        )
        let acoustic = acousticPauseDecisions.map { decision in
            InterjectionCleanupDecision(
                id: decision.id,
                kind: decision.kind,
                startMs: decision.startMs,
                endMs: decision.endMs,
                originalText: decision.originalText,
                accepted: !restored.contains(decision.id)
            )
        }
        let visibleCoreDecisions = acoustic.isEmpty
            ? core.decisions
            : core.decisions.filter { $0.kind != .longPause }
        let hasEdits = visibleCoreDecisions.contains { $0.accepted } || acoustic.contains { $0.accepted }
        cleanup = hasEdits
            ? InterjectionCleanupResult(
                policyVersion: core.policyVersion,
                cleanedTranscript: core.cleanedTranscript,
                decisions: (visibleCoreDecisions + acoustic).sorted { $0.startMs == $1.startMs ? $0.id < $1.id : $0.startMs < $1.startMs }
            )
            : nil
        approvedTranscript = hasEdits
            ? core.cleanedTranscript
            : (interjection.transcript ?? interjection.displayText ?? "")
        if hasEdits, renderCleanedAudio {
            return true
        } else {
            isPreparingCleanup = false
            cleanedAudioURL = nil
            cleanedAudioDurationMs = nil
            representationChoice = hasOriginalAudio ? .original : .textOnly
        }
        return false
    }
}
