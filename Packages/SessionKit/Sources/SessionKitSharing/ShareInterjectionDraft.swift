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
        renderGeneration: Int = 0
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
    }

    public var currentEditState: ShareMarginEditState {
        editHistory[min(max(0, editHistoryIndex), editHistory.count - 1)]
    }

    public var canUndoEdit: Bool { editHistoryIndex > 0 }
    public var canRedoEdit: Bool { editHistoryIndex + 1 < editHistory.count }
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

    public mutating func restoreOriginal(hasOriginalAudio: Bool, anchorWarning: String?) {
        editHistory = [.original]
        editHistoryIndex = 0
        cleanup = nil
        cleanedAudioURL = nil
        cleanedAudioDurationMs = nil
        isAnalyzingPauses = false
        isPreparingCleanup = false
        preparationMessage = nil
        approvedTranscript = interjection.transcript ?? interjection.displayText ?? ""
        representationChoice = hasOriginalAudio ? .original : .textOnly
        warning = SharedMarginTextRequirement.reviewWarning(for: approvedTranscript) ?? anchorWarning
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
