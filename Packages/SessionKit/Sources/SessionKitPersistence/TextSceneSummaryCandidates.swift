import Foundation
import SessionKit

/// Which article or PDF the background pass writes scene summaries for next, while charging (#3461). It reads ids,
/// item summaries and saved proposals only; the text itself is read when a run starts, and nothing is fetched.
public enum TextSceneSummaryCandidates {
    /// The first of `itemIds`, in the order given, that
    /// - is text (no media) and already has its rule-based chapters, because a background pass never makes a map the
    ///   listener didn't ask for,
    /// - has no friend's map beside it, and has scenes still waiting for a summary (`TextSceneSummaryProgress`),
    /// - was not `settled`: a background run already ended on it for good (finished, or nothing the model could
    ///   summarise), so the pass doesn't spend the charge on it again. The listener's own tap still works.
    public static func next(itemIds: [String], settled: Set<String>, store: SQLiteSessionStore) -> String? {
        itemIds.first { id in
            guard !settled.contains(id),
                  let item = try? store.loadItemSummary(id: id), item.media == nil,
                  (try? store.listeningMapId(itemId: id)) != nil,
                  let proposals = try? store.loadPortableListeningMapProposals(itemId: id) else { return false }
            return TextSceneSummaryProgress.state(proposals: proposals).offersRun
        }
    }
}
