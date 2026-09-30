#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The one way an article is split into narration chunks (#312).
///
/// Three paths must agree on an article's chunks, or "ready offline" silently breaks: the live
/// player (which may speak an "Overview. …" preface first), background preparation, and the
/// assembly of prepared audio. They broke apart across Builds 29 and 30 (#258). All three now take
/// their chunks from here, and prepared audio is matched by `ArticlePlan.identity` rather than by
/// comparing texts.
public enum NarrationChunkPlanner {
    /// Bumping this invalidates every prepared manifest: change it only with the chunking itself.
    public static let version = "rendered-speech-chunker.v2"

    public struct Chunk: Equatable, Sendable {
        public var index: Int
        /// In the article's normalized spoken text.
        public var startOffset: Int
        public var sourceLength: Int
        public var text: String
        public var boundary: RenderedSpeechChunkBoundary
    }

    public struct ArticlePlan: Equatable, Sendable {
        public var identity: String
        public var normalizedText: String
        public var chunks: [Chunk]
    }

    /// Identifies an article's plan: its text and the chunker version. Cheap, so lookups can check it.
    public static func identity(ofArticle articleText: String) -> String {
        var hash = SHA256()
        hash.update(data: Data(version.utf8))
        hash.update(data: Data([0x1f]))
        hash.update(data: Data(articleText.utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The article's own chunks: what background preparation renders and saves.
    public static func articlePlan(
        _ articleText: String, budget: Int = RenderedSpeechChunker.spokenCostBudget
    ) -> ArticlePlan {
        let normalized = SpeechTextNormalizer.normalize(articleText)
        let chunks = RenderedSpeechChunker.sourceSlices(from: normalized, maxCharacters: budget)
            .enumerated()
            .map { index, planned in
                Chunk(index: index, startOffset: planned.startOffset, sourceLength: planned.slice.sourceLength,
                      text: planned.slice.text, boundary: planned.slice.boundary)
            }
        return ArticlePlan(identity: identity(ofArticle: articleText), normalizedText: normalized, chunks: chunks)
    }

    /// A chunk the player renders. `articleIndex` is its index in the article plan, or nil for a
    /// preface chunk (prepared audio never includes the preface).
    public struct SpokenChunk: Equatable, Sendable {
        public var startOffset: Int
        public var sourceLength: Int
        public var text: String
        public var boundary: RenderedSpeechChunkBoundary
        public var articleIndex: Int?
    }

    public struct SpokenPlan: Equatable, Sendable {
        public var chunks: [SpokenChunk]
        /// The article plan's identity when the article's chunks are exactly the prepared ones. Nil
        /// with no article text (the caller identifies the spoken text itself), or when the spoken
        /// text doesn't end in the article's normalized text (then no chunk has an article index).
        public var articleIdentity: String?
        public var articleSpokenStart: Int
    }

    /// What the player renders for `spokenText`, which is `articleText` normalized, optionally
    /// after a preface that ends at `articleSpokenStart`.
    public static func spokenPlan(
        spokenText: String,
        articleText: String?,
        articleSpokenStart: Int,
        budget: Int = RenderedSpeechChunker.spokenCostBudget
    ) -> SpokenPlan {
        let start = max(0, min(articleSpokenStart, spokenText.count))
        if let articleText, !articleText.isEmpty {
            let article = articlePlan(articleText, budget: budget)
            let split = spokenText.index(spokenText.startIndex, offsetBy: start)
            if String(spokenText[split...]) == article.normalizedText {
                var preface = start > 0
                    ? RenderedSpeechChunker.sourceSlices(from: String(spokenText[..<split]), maxCharacters: budget).map {
                        SpokenChunk(startOffset: $0.startOffset, sourceLength: $0.slice.sourceLength,
                                    text: $0.slice.text, boundary: $0.slice.boundary, articleIndex: nil)
                    }
                    : []
                // The chunker leaves trailing whitespace uncovered. Between preface and article that
                // gap made the chunk after the preface start one character early, off the plan.
                if let last = preface.indices.last, preface[last].startOffset + preface[last].sourceLength < start {
                    preface[last].sourceLength = start - preface[last].startOffset
                }
                let body = article.chunks.map {
                    SpokenChunk(startOffset: start + $0.startOffset, sourceLength: $0.sourceLength,
                                text: $0.text, boundary: $0.boundary, articleIndex: $0.index)
                }
                return SpokenPlan(chunks: preface + body, articleIdentity: article.identity, articleSpokenStart: start)
            }
        }
        // No article text given: the spoken text is the article, as before #292 (identity nil; the
        // caller identifies it by its own source text). Given but not matching: plan the whole
        // spoken text and match no prepared audio.
        let isArticle = articleText == nil
        let chunks = RenderedSpeechChunker.sourceSlices(from: spokenText, maxCharacters: budget).enumerated().map { index, planned in
            SpokenChunk(startOffset: planned.startOffset, sourceLength: planned.slice.sourceLength,
                        text: planned.slice.text, boundary: planned.slice.boundary, articleIndex: isArticle ? index : nil)
        }
        return SpokenPlan(chunks: chunks, articleIdentity: nil, articleSpokenStart: 0)
    }
}
