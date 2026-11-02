import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence
#if canImport(UIKit)
import UIKit
#endif

/// #3205: the Follow sheet's two ways to follow a link. Paste reads the clipboard and follows a link there at once;
/// the typed field follows what was typed. Both show one line with an Undo that takes the show back out, and
/// the Undo is offered only when this tap added the show (a show the listener already follows is left alone).
/// The link is never shown or logged here: a private feed link carries a token.
extension Gate1AppModel {
    enum FollowLinkOutcome: Equatable {
        /// The show is followed; the sheet can close.
        case followed
        /// The link found several feeds; the choice is on the sheet.
        case needsChoice
        /// Nothing was followed. The line says why; the sheet shows it, because the app's banner sits behind a sheet.
        case stopped(String?)
    }

    /// Paste on the Follow sheet: a copied link is followed with no further tap.
    func followFromClipboard() async -> FollowLinkOutcome {
        #if canImport(UIKit)
        let clipboard = UIPasteboard.general.string
        #else
        let clipboard: String? = nil
        #endif
        switch FollowPasteDecision.decide(clipboard: clipboard) {
        case .notALink:
            reportFailure(FollowPasteDecision.notALinkMessage)
            return .stopped(FollowPasteDecision.notALinkMessage)
        case .follow(let link):
            return await followLinkWithUndo(link)
        }
    }

    /// The typed field's Follow button.
    func followTypedLink() async -> FollowLinkOutcome {
        await followLinkWithUndo(followedSourceURL)
    }

    /// A feed picked from the choices a link found: the same close, line and Undo as a link that found one feed.
    func followCandidateWithUndo(_ candidate: SourceCandidateEvidence) async -> FollowLinkOutcome {
        await perform { _ in candidate }
    }

    private func followLinkWithUndo(_ link: String) async -> FollowLinkOutcome {
        guard !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .stopped(nil) }
        return await perform { [weak self] coordinator in
            let candidates = try await coordinator.discover(urlString: link)
            self?.diagnostics["followedSourceNetworkHosts"] = await coordinator.contactedHosts.sorted().joined(separator: ",")
            guard candidates.count == 1, let candidate = candidates.first, !candidate.needsConfirmation else {
                self?.followedSourceCandidates = candidates
                return nil
            }
            return candidate
        }
    }

    /// `choose` returns the feed to follow, or nil when the listener has to choose first.
    private func perform(
        choose: (FollowedSourceCoordinator) async throws -> SourceCandidateEvidence?
    ) async -> FollowLinkOutcome {
        let alreadyFollowed = Set(feedSubscriptions.map(\.id))
        do {
            let store = try requireStore()
            let coordinator = requireFollowedSourceCoordinator(store: store)
            guard let candidate = try await choose(coordinator) else {
                reportConfirmation(Self.chooseFeedMessage)
                return .needsChoice
            }
            let subscription = try await coordinator.follow(candidate: candidate)
            await publishFeedSubscriptionsAfterChange()
            followedSourceCandidates = []
            followedSourceURL = ""
            diagnostics["followSourceFailure"] = nil
            let wasAlreadyFollowed = alreadyFollowed.contains(subscription.id)
            let title = subscription.source.title
            let undo: UserFeedbackEvent.Action? = wasAlreadyFollowed ? nil : UserFeedbackEvent.Action(
                title: FollowPasteDecision.undoTitle,
                accessibilityLabel: FollowPasteDecision.undoAccessibilityLabel(showTitle: title),
                identifier: "following.follow.undo.button",
                perform: { [weak self] in self?.unfollowSource(id: subscription.id) }
            )
            reportConfirmation(
                FollowPasteDecision.followedMessage(showTitle: title, wasAlreadyFollowed: wasAlreadyFollowed),
                action: undo)
            // The first look at the new show's episodes can wait on the network; the sheet does not.
            refreshFollowedSources(force: true)
            return .followed
        } catch {
            if let coordinator = followedSourceCoordinator {
                diagnostics["followSourceFailure"] = FollowedSourceMatching.stampedDiagnostic(await coordinator.failureDiagnostic(for: error))
            }
            reportFailure(error)
            let line = (error as? URLError).map { Self.userFacingMessage(for: $0) } ?? ListenerErrorText.message(for: error)
            return .stopped(line)
        }
    }

    static let chooseFeedMessage = "Choose which feed to follow."
}

extension Gate1AppModel {
    /// What Paste would do with the clipboard right now, for a control that follows at once when it can.
    var clipboardFollowDecision: FollowPasteDecision {
        #if canImport(UIKit)
        FollowPasteDecision.decide(clipboard: UIPasteboard.general.string)
        #else
        FollowPasteDecision.decide(clipboard: nil)
        #endif
    }
}
