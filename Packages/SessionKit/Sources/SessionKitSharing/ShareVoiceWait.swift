import Foundation
import SessionKit

/// What the Share Margins list shows and waits on while voices without ums are made (#4647). The cleaned words show at
/// once; only the controls that need a voice, and a share that needs one, wait for it.
public enum ShareVoiceWait {
    /// One Margin, as the rules read it.
    public struct Margin: Equatable, Sendable {
        public var isIncluded: Bool
        public var hasWords: Bool
        public var hasRecording: Bool
        public var hasCleanupEdits: Bool
        public var hasCleanedFile: Bool
        /// A voice for it is being made, or it waits its turn in the run (the app's queue mirror and the draft's flags).
        public var voiceInProgress: Bool
        /// What goes now.
        public var representation: ShareMarginRepresentationChoice
        /// What the sender last picked, or `nil`.
        public var senderPick: ShareMarginRepresentationChoice?

        public init(
            isIncluded: Bool, hasWords: Bool, hasRecording: Bool, hasCleanupEdits: Bool, hasCleanedFile: Bool,
            voiceInProgress: Bool, representation: ShareMarginRepresentationChoice,
            senderPick: ShareMarginRepresentationChoice?
        ) {
            self.isIncluded = isIncluded
            self.hasWords = hasWords
            self.hasRecording = hasRecording
            self.hasCleanupEdits = hasCleanupEdits
            self.hasCleanedFile = hasCleanedFile
            self.voiceInProgress = voiceInProgress
            self.representation = representation
            self.senderPick = senderPick
        }

        /// A draft, with what only the app knows: whether its recording can be read, and whether its voice is queued.
        public init(_ draft: ShareInterjectionDraft, hasRecording: Bool, isQueued: Bool) {
            self.init(
                isIncluded: draft.isIncluded,
                hasWords: SharedMarginTextRequirement.hasReviewedText(draft.approvedTranscript),
                hasRecording: hasRecording,
                hasCleanupEdits: draft.cleanup != nil,
                hasCleanedFile: draft.cleanedAudioURL != nil,
                voiceInProgress: isQueued || draft.isAnalyzingPauses || draft.isPreparingCleanup,
                representation: draft.representationChoice,
                senderPick: draft.senderPickedVersion
            )
        }

        private var optedOut: Bool { senderPick == .original || senderPick == .textOnly }

        /// A share must wait for this Margin's voice. It doesn't need edits: the pause analysis can find pauses after the
        /// words found none, so a Margin with nothing to remove may be waited on briefly.
        public var waits: Bool {
            isIncluded && voiceInProgress && hasRecording && !optedOut
        }

        /// The version its header and menu show: "Without ums" while that voice is being made for a Margin with cleanup
        /// edits that the sender hasn't set to As recorded or Words only; otherwise what goes now.
        public var displayedVersion: ShareMarginRepresentationChoice {
            waits && hasCleanupEdits ? .cleaned : representation
        }

        /// The versions the menu offers, in order: As recorded (with a recording), Without ums (with a recording and a
        /// cleaned file or cleanup edits, including while its voice is made), Words only.
        public var menuOptions: [ShareMarginRepresentationChoice] {
            var options: [ShareMarginRepresentationChoice] = []
            if hasRecording { options.append(.original) }
            if hasRecording, hasCleanedFile || hasCleanupEdits { options.append(.cleaned) }
            options.append(.textOnly)
            return options
        }

        /// Its voice was waited on and didn't come: it still has cleanup edits, the sender didn't opt out, nothing is
        /// being made, and it doesn't go Without ums. A Margin whose analysis found nothing has no edits, so never fails.
        public var failedAfterWait: Bool {
            isIncluded && hasCleanupEdits && !optedOut && representation != .cleaned && !voiceInProgress
        }
    }
}

/// Whether Share can go now (#4647).
public enum ShareSendReadiness: Equatable, Sendable {
    /// No included Margin has words.
    case nothingToSend
    /// Some included Margin's voice is still being made; `count` of them.
    case waiting(count: Int)
    /// Everything that goes is ready; `count` Margins go.
    case ready(count: Int)

    public init(_ margins: [ShareVoiceWait.Margin]) {
        let going = margins.filter { $0.isIncluded && $0.hasWords }
        if going.isEmpty {
            self = .nothingToSend
            return
        }
        let waiting = margins.filter(\.waits).count
        self = waiting > 0 ? .waiting(count: waiting) : .ready(count: going.count)
    }

    public var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}

/// A share tapped while voices were being made (#4647): which Margins it waits on, and what to do once they're done.
public struct ShareSendWait: Equatable, Sendable {
    public let waitingIDs: Set<String>

    public init(waitingIDs: Set<String>) {
        self.waitingIDs = waitingIDs
    }

    public enum Verdict: Equatable, Sendable {
        /// `count` of the waited Margins still wait.
        case waiting(count: Int)
        /// Every waited voice is made: the share goes on.
        case ready
        /// Every wait ended and `count` voices didn't come: ask once before sharing without that change.
        case failed(count: Int)
    }

    /// Reads the waited Margins as they are now. A Margin that is gone from the sheet neither waits nor failed.
    public func verdict(_ margins: [String: ShareVoiceWait.Margin]) -> Verdict {
        let current = waitingIDs.compactMap { margins[$0] }
        let still = current.filter(\.waits).count
        if still > 0 { return .waiting(count: still) }
        let failed = current.filter(\.failedAfterWait).count
        return failed > 0 ? .failed(count: failed) : .ready
    }
}

/// What a built packet depends on, so a change the sender can't see doesn't make it stale (#4647). Only included
/// Margins count, and a cleaned file, its length, its render and the cleanup decisions count only for a Margin that goes
/// Without ums: the words that go already carry every word removed.
public enum ShareDraftFingerprint {
    public static func fields(for drafts: [ShareInterjectionDraft]) -> [String] {
        var fields: [String] = []
        for draft in drafts.filter(\.isIncluded).sorted(by: { $0.id < $1.id }) {
            let goesCleaned = draft.representationChoice == .cleaned
            fields.append(draft.id)
            fields.append(draft.approvedTranscript)
            fields.append(draft.representationChoice.rawValue)
            fields.append(String(draft.readAloud))
            fields.append(draft.anchorBefore)
            fields.append(draft.anchorAfter)
            fields.append(String(draft.leadInToWrite ?? -1))
            if goesCleaned {
                fields.append(draft.cleanedAudioURL?.path ?? "")
                fields.append(String(draft.cleanedAudioDurationMs ?? -1))
                fields.append(String(draft.renderGeneration))
                let decisions: [String] = (draft.cleanup?.decisions ?? []).map { decision in
                    "\(decision.id):\(decision.accepted):\(decision.startMs):\(decision.endMs)"
                }
                fields.append(decisions.joined(separator: ","))
            } else {
                fields.append(contentsOf: ["", "", "", ""])
            }
            let evidence: [String] = (draft.interjection.podcastAnchorEvidence ?? []).map { item in
                let provenance: String = item.provenance?.rawValue ?? ""
                return "\(item.id):\(item.localPath):\(provenance)"
            }
            fields.append(evidence.joined(separator: ","))
        }
        return fields
    }
}
