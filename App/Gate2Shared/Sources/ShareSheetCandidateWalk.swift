import Foundation

/// What one share-sheet candidate yielded when the share extension loaded it.
public enum ShareSheetCandidateOutcome<Import: Sendable>: Sendable {
    /// Content the share carried (a file, PDF bytes, page text, a package): handed off at once.
    case content(Import)
    /// A web link the app would download again. It waits while a non-link candidate is untried (#271).
    case link(Import)
    /// Nothing usable here; the next candidate is tried.
    case nothing
    /// The share can't be handed off (a package that could not be saved, say).
    case failed(Error)
}

/// Tries a share's candidates in order, one at a time, and decides what the share hands off: the first
/// content any candidate yields, or else the first link, once nothing else is left to try (#271).
///
/// The share extension runs this with loaders that read its `NSItemProvider`s, and the app's tests run the
/// same walk with real providers, so the tests prove the extension's own decision rather than a copy of it.
public enum ShareSheetCandidateWalk {
    /// - `identifier` names a candidate's representation, for `ShareSheetLinkFallback`.
    /// - `load` loads one candidate and reports what it yielded, once, on any queue.
    /// - `resume` runs each step after a load reports; the share extension passes the main queue.
    /// - `completion` gets what to hand off, or nil when no candidate yielded anything.
    public static func run<Candidate: Sendable, Import: Sendable>(
        _ candidates: [Candidate],
        identifier: (Candidate) -> String,
        load: @escaping @Sendable (Candidate, @escaping @Sendable (ShareSheetCandidateOutcome<Import>) -> Void) -> Void,
        resume: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { $0() },
        completion: @escaping @Sendable (Result<Import, Error>?) -> Void
    ) {
        let identifiers = candidates.map(identifier)
        let walk = Walk<Import>()

        @Sendable func step(_ index: Int) {
            guard index < candidates.count else {
                completion(walk.linkFallback.deferredLink.map { .success($0) })
                return
            }
            load(candidates[index]) { outcome in
                resume {
                    switch outcome {
                    case .content(let found):
                        completion(.success(found))
                    case .failed(let error):
                        completion(.failure(error))
                    case .nothing:
                        step(index + 1)
                    case .link(let link):
                        if let accepted = Optional(link) {
                            completion(.success(accepted))
                        } else {
                            step(index + 1)
                        }
                    }
                }
            }
        }
        step(0)
    }

    /// The walk's state. Steps run one at a time, each after the previous load reported.
    private final class Walk<Import: Sendable>: @unchecked Sendable {
        var linkFallback = ShareSheetLinkFallback<Import>()
    }
}
