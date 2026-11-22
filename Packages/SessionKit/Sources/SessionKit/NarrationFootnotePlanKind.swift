import Foundation

/// Which of an article's two plans a caller, a manifest or an identity means (#3777).
///
/// An article has a plain plan (the notes come in their chapter at the end, markers are spoken) and, when a note can be
/// read where it is cited, a second plan with note chunks (`articlePlan(_:asides: true)`). The plans differ in chunk
/// count, chunk text and every offset after the first silenced marker, so audio made for one must never be matched to
/// the other. The kind is decided once, where a preparation is created (`FootnotePlanDecision`); every later step
/// takes it from the manifest or from the identity the plan carries, so two steps cannot disagree.
extension NarrationChunkPlanner {
    private final class AnchorMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        private var anchors: [FootnoteAnchor] = []

        func anchors(for text: String) -> [FootnoteAnchor] {
            // Most articles have no `[^`: no memo, no scan.
            guard text.contains("[^") else { return [] }
            lock.lock()
            if self.text == text {
                let found = anchors
                lock.unlock()
                return found
            }
            lock.unlock()
            let found = FootnoteAnchors.find(in: text)
            lock.lock()
            self.text = text
            anchors = found
            lock.unlock()
            return found
        }
    }

    private static let anchorMemo = AnchorMemo()

    /// The article's matched notes. Per-chunk callers (a commit, a lookup, an identity check) ask many times for one
    /// text, so the last answer is kept.
    static func matchedFootnotes(in articleText: String) -> [FootnoteAnchor] {
        anchorMemo.anchors(for: articleText)
    }

    /// Whether the article has a note that can be read where it is cited. Without one the two plans are the same plan
    /// and share one identity, so no caller has a choice to make.
    public static func hasFootnotesToReadWhereCited(in articleText: String) -> Bool {
        !matchedFootnotes(in: articleText).isEmpty
    }

    /// Whether `candidate` names a plan of this article, the plain one or the one with notes.
    public static func isIdentity(_ candidate: String, ofArticle articleText: String) -> Bool {
        candidate == identity(ofArticle: articleText) || candidate == identity(ofArticle: articleText, asides: true)
    }

    /// Which plan of this article `candidate` names: false for the plain plan, true for the plan with note chunks, nil when it
    /// names neither (another text's identity). One answer for a caller that must check the text and learn the kind,
    /// with the fewest hashes: the plain identity first, and the other only for an article that has a note.
    public static func planUsesAsides(identity candidate: String, ofArticle articleText: String) -> Bool? {
        if candidate == identity(ofArticle: articleText) { return false }
        if hasFootnotesToReadWhereCited(in: articleText), candidate == identity(ofArticle: articleText, asides: true) { return true }
        return nil
    }

    /// Whether `candidate` names the plan with note chunks. False for the plain identity, for nil (a manifest from
    /// before #312), for another text's identity, and for an article with no matched note (one identity, no asides).
    public static func usesAsides(identity candidate: String?, ofArticle articleText: String) -> Bool {
        guard let candidate, hasFootnotesToReadWhereCited(in: articleText),
              candidate != identity(ofArticle: articleText) else { return false }
        return candidate == identity(ofArticle: articleText, asides: true)
    }

    /// The spoken text the player holds for `spokenSource` when it is a preface followed by `articleText`, with every
    /// matched citation of the article silent, so `spokenPlan(spokenText:articleText:articleSpokenStart:asides: true)`
    /// matches it. Nil when the source does not end in the article or the article has no matched note: the plain
    /// projection is then the right one.
    public static func silencedSpeech(source spokenSource: String, endingWith articleText: String) -> NormalizedSpeechText? {
        guard !articleText.isEmpty, spokenSource.hasSuffix(articleText) else { return nil }
        let ranges = silencedCitationRanges(inArticle: articleText)
        guard !ranges.isEmpty else { return nil }
        let shift = spokenSource.count - articleText.count
        return SpeechTextNormalizer.normalizeWithSourceOffsets(
            spokenSource, silencingSourceRanges: ranges.map { ($0.lowerBound + shift)..<($0.upperBound + shift) })
    }
}

/// Decides, where a preparation of an article is created, whether it is planned with note chunks (#3777).
///
/// Every place that creates a preparation (the player's first play, the Library's startup, explicit and automatic
/// preparation) asks this one rule with the same inputs, so they agree. A step that works on a preparation that
/// already exists does not ask: it follows the manifest's own kind (`NarrationChunkPlanner.usesAsides(identity:ofArticle:)`).
public enum FootnotePlanDecision {
    /// - Parameters:
    ///   - mode: the listener's Footnotes setting.
    ///   - isPDF: PDFs keep today's behaviour (the Design: footnote blocks are skipped where they sit).
    ///   - articleText: the text the plan is made from.
    ///   - manifests: every saved preparation of this item, under any voice.
    public static func asides(
        mode: FootnoteMode, isPDF: Bool, articleText: String, manifests: [PreparedAudioManifest]
    ) -> Bool {
        guard mode.plansAsides, !isPDF, NarrationChunkPlanner.hasFootnotesToReadWhereCited(in: articleText) else { return false }
        let plain = NarrationChunkPlanner.identity(ofArticle: articleText)
        let plainAudioExists = manifests.contains { manifest in
            guard manifest.articleIdentity == nil || manifest.articleIdentity == plain else { return false }
            return holdsAudio(manifest)
        }
        return mode.asidesForPlan(preparedAudioExistsUnderPlainIdentity: plainAudioExists)
    }

    /// A preparation with audio saved that a plain `begin` would keep or resume. A manifest that was just begun and has
    /// no chunk yet holds nothing, so a plan can still change for it. One retired for re-preparation (a chunk failed its
    /// checksum, the voice was switched away and back) still holds its intact chunks: `begin` resumes them, so it must
    /// not be replaced by the other plan. A failed or never prepared one holds nothing.
    static func holdsAudio(_ manifest: PreparedAudioManifest) -> Bool {
        switch manifest.state {
        case .preparing, .pausedForThermal, .readyOffline, .stopped:
            return manifest.artifact != nil || !manifest.chunks.isEmpty
        case .needsRepreparation:
            return !manifest.chunks.isEmpty
        case .notPrepared, .failed:
            return false
        }
    }
}
