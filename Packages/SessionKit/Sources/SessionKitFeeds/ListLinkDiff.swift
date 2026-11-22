import Foundation
import SessionKit

/// What a list's web address now offers, against what the listener already took from it (#4046 PR 6). Pure, so every
/// case is a table row.
public enum ListLinkDiff {
    /// - Parameters:
    ///   - resolved: every show the address offers now, each once.
    ///   - accepted: the shows the listener accepted from this address.
    ///   - rejected: the shows the listener turned down. They are never offered again, even when the list drops a show and
    ///     later adds it back.
    ///   - suppressRemovals: true when part of the list could not be read (an include failed or went past the limits), so
    ///     a show missing from `resolved` may only be unread, not removed.
    /// - Returns: the change to offer, or nil when there is none. The proposal is made from scratch each time, against the
    ///   last accepted copy, so a show that was added and then removed again before the listener looked is not in it.
    public static func proposal(
        resolved: [ProposedShow],
        accepted: [ListMember],
        rejected: [ListMember],
        suppressRemovals: Bool = false,
        checkedAt: Date
    ) -> ListProposal? {
        func isIn(_ members: [ListMember], _ member: ListMember) -> Bool {
            members.contains { $0.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }
        }
        var added: [ProposedShow] = []
        for show in resolved where !isIn(accepted, show.member) && !isIn(rejected, show.member) {
            // A repeat in `resolved` is one show.
            if added.contains(where: { $0.member.matches(feedKey: show.member.feedKey, podcastGUID: show.member.podcastGUID) }) { continue }
            added.append(show)
        }
        var removed: [ListMember] = []
        if !suppressRemovals {
            // A rejected show the listener had accepted earlier is already out of their list: it is not a removal to offer.
            removed = accepted.filter { member in
                !isIn(rejected, member) && !resolved.contains { $0.member.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }
            }
        }
        let proposal = ListProposal(added: added, removed: removed, checkedAt: checkedAt)
        return proposal.isEmpty ? nil : proposal
    }
}
