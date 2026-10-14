import Foundation

/// What one share-sheet candidate yielded when the share extension loaded it.
public enum ShareSheetCandidateOutcome<Import: Sendable>: Sendable {
    /// Content the share carried (a file, PDF bytes, page text, a package): handed off at once.
    case content(Import)
    /// A web link the app would download again. It waits while a non-link candidate is untried (#271).
    case link(Import)
    /// Plain text another app shared (#662). The first one is kept until every other candidate, links
    /// included, has been tried, and is handed off only when nothing else was found.
    case sharedText(Import)
    /// Nothing usable here; the next candidate is tried.
    case nothing
    /// The share can't be handed off (a package that could not be saved, say).
    case failed(Error)
}

/// Tries a share's candidates in order, one at a time, and decides what the share hands off: the first
/// content any candidate yields, or else the first link, or else the first shared text, once nothing
/// else is left to try (#271, #662).
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
        Walk(
            candidates: candidates,
            identifiers: candidates.map(identifier),
            load: load,
            resume: resume,
            completion: completion
        ).step(0)
    }

    /// The walk and its state. Steps run one at a time, each after the previous load reported; each
    /// pending load's callback holds the walk, so it lives until the walk completes.
    ///
    /// `step` is a method here, not a recursive nested function: with `-O -whole-module-optimization`
    /// (Release, so the phone build and TestFlight archives), Swift 6.4's AllocBoxToStack pass crashed
    /// on the self-capturing nested function once it was inlined into the share extension's
    /// `viewDidAppear` ("invalid operand index", ApplySite.swift:106; #1453).
    private final class Walk<Candidate: Sendable, Import: Sendable>: @unchecked Sendable {
        typealias Load = @Sendable (Candidate, @escaping @Sendable (ShareSheetCandidateOutcome<Import>) -> Void) -> Void

        private let candidates: [Candidate]
        private let identifiers: [String]
        private let load: Load
        private let resume: @Sendable (@escaping @Sendable () -> Void) -> Void
        private let completion: @Sendable (Result<Import, Error>?) -> Void
        private var linkFallback = ShareSheetLinkFallback<Import>()
        private var textFallback: Import?

        init(
            candidates: [Candidate],
            identifiers: [String],
            load: @escaping Load,
            resume: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
            completion: @escaping @Sendable (Result<Import, Error>?) -> Void
        ) {
            self.candidates = candidates
            self.identifiers = identifiers
            self.load = load
            self.resume = resume
            self.completion = completion
        }

        func step(_ index: Int) {
            guard index < candidates.count else {
                completion((linkFallback.deferredLink ?? textFallback).map { .success($0) })
                return
            }
            load(candidates[index]) { outcome in
                self.resume { self.handle(outcome, at: index) }
            }
        }

        private func handle(_ outcome: ShareSheetCandidateOutcome<Import>, at index: Int) {
            switch outcome {
            case .content(let found):
                completion(.success(found))
            case .failed(let error):
                completion(.failure(error))
            case .nothing:
                step(index + 1)
            case .sharedText(let text):
                if textFallback == nil { textFallback = text }
                step(index + 1)
            case .link(let link):
                if let accepted = linkFallback.accept(link, isLink: true, at: index, in: identifiers) {
                    completion(.success(accepted))
                } else {
                    step(index + 1)
                }
            }
        }
    }
}
