import Foundation

/// Recipient scene starts in proposal order. Unplaced starts stay nil for Skim;
/// the item page omits them and presents the placed chapters in time order.
public struct SceneStarts: Equatable, Sendable {
    public let scenes: [PortableListeningMapScene]
    public let sceneStarts: [Int?]
    /// Where each scene ends on the recipient's clock, in proposal order; nil when the end can't be placed.
    public let sceneEnds: [Int?]

    public init(scenes: [PortableListeningMapScene], projection: ResolvedListeningMapProjection?) {
        self.scenes = scenes.sorted { $0.order < $1.order }
        let exactIdentityProjection = projection?.algorithmVersion == "episode-projection.exact-edition.v1"
            || (projection?.points.isEmpty == false && projection?.points.allSatisfy {
                ($0.confidence == .exactEdition || $0.confidence == .verified)
                    && $0.recipientMediaTimeMs == $0.sourceMediaTimeMs
            } == true)
        func projectedTime(_ sourceTimeMs: Int?) -> Int? {
            guard let sourceTimeMs else { return nil }
            return projection?.projectedRecipientTime(for: sourceTimeMs)
                ?? (exactIdentityProjection ? sourceTimeMs : nil)
        }
        self.sceneStarts = self.scenes.map { projectedTime($0.startAnchor.mediaTimeMs) }
        self.sceneEnds = self.scenes.map { projectedTime($0.endAnchor.mediaTimeMs) }
    }

    /// Scene starts on a text item (an article, PDF or Listening Edition), read from the character positions the
    /// import stored on each scene (`startAnchor.startChar`, `endAnchor.endChar`) (#1471). Every position is in
    /// characters, not milliseconds, and `skimPlan` takes the reading position and the text length the same way, so
    /// the one ordering rule serves audio and text. A scene without a character start stays unplaced, and an end
    /// at or before its start is treated as unknown.
    public init(textScenes scenes: [PortableListeningMapScene]) {
        self.scenes = scenes.sorted { $0.order < $1.order }
        let starts = self.scenes.map { $0.startAnchor.startChar.flatMap { $0 >= 0 ? $0 : nil } }
        self.sceneStarts = starts
        self.sceneEnds = zip(self.scenes, starts).map { scene, start in
            guard let start, let end = scene.endAnchor.endChar, end > start else { return nil }
            return end
        }
    }

    /// The map Skim reads on a text item: the first proposal whose scenes are placed by character (#1471). A proposal
    /// placed only by media time (a podcast's) says nothing about where to read, so it never counts.
    public static func textProposal(in proposals: [PortableListeningMapProposalArtifact]) -> PortableListeningMapProposalArtifact? {
        proposals.first { proposal in
            proposal.scenes.contains { $0.startAnchor.startChar.map { $0 >= 0 } == true }
        }
    }

    /// `skimPlan` for a text item, where there is no duration: the last scene's forward destination is the end of its
    /// own span, or just past its start when the span is unknown. A last-scene summary then plays and the reader
    /// pauses where it was, rather than moving (#1471).
    public func textSkimPlan(direction: SkimDirection, at charOffset: Int) -> SkimPlan? {
        let lastStart = sceneStarts.compactMap { $0 }.max() ?? 0
        let end = max(sceneEnds.compactMap { $0 }.max() ?? 0, lastStart + 1)
        return skimPlan(direction: direction, at: charOffset, durationMs: end)
    }

    public struct SkimPlan: Equatable, Sendable {
        public let currentScene: PortableListeningMapScene
        public let summaryScene: PortableListeningMapScene
        public let destinationSceneId: String?
        public let destinationMediaTimeMs: Int
    }

    public func skimPlan(direction: SkimDirection, at recipientMediaTimeMs: Int, durationMs: Int?) -> SkimPlan? {
        guard !scenes.isEmpty else { return nil }
        guard let currentIndex = scenes.indices.last(where: {
            guard let start = sceneStarts[$0] else { return false }
            return start <= recipientMediaTimeMs
        }) else { return nil }

        let summaryIndex: Int
        let destinationSceneId: String?
        let destinationMediaTimeMs: Int
        switch direction {
        case .forward:
            summaryIndex = currentIndex
            if scenes.indices.contains(currentIndex + 1) {
                guard let destination = sceneStarts[currentIndex + 1] else { return nil }
                destinationSceneId = scenes[currentIndex + 1].id
                destinationMediaTimeMs = destination
            } else {
                guard let duration = durationMs else { return nil }
                destinationSceneId = nil
                destinationMediaTimeMs = duration
            }
        case .backward:
            guard currentIndex > 0, let destination = sceneStarts[currentIndex] else { return nil }
            summaryIndex = currentIndex - 1
            destinationSceneId = scenes[currentIndex].id
            destinationMediaTimeMs = destination
        }

        let summaryScene = scenes[summaryIndex]
        guard summaryScene.eligibility == .eligible,
              summaryScene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return SkimPlan(
            currentScene: scenes[currentIndex], summaryScene: summaryScene,
            destinationSceneId: destinationSceneId, destinationMediaTimeMs: destinationMediaTimeMs
        )
    }

    public var chapters: [MediaTimelineChapter] {
        scenes.indices.compactMap { index -> MediaTimelineChapter? in
            let scene = scenes[index]
            guard let startMs = sceneStarts[index] else { return nil }
            let title = scene.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Scene \(scene.order + 1)"
            return MediaTimelineChapter(
                id: scene.id,
                title: displayTitle,
                description: scene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                startMs: startMs,
                transcriptSegmentId: scene.startAnchor.transcriptSegmentId ?? scene.id
            )
        }.sorted { $0.startMs < $1.startMs }
    }
}

extension SceneStarts {
    /// Every placed scene as a span on the recipient's clock, in time order, carrying the summary Now may show (#1629).
    /// A scene without a usable summary still gets a span, so its time never shows the scene before it.
    public var summarySpans: [SceneSummarySpan] {
        scenes.indices.compactMap { index -> SceneSummarySpan? in
            guard let startMs = sceneStarts[index] else { return nil }
            let scene = scenes[index]
            let summary = scene.eligibility == .eligible
                ? scene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil
            // An end at or before the start can't be right; treat it as unknown rather than hiding the scene.
            let endMs = sceneEnds[index].flatMap { $0 > startMs ? $0 : nil }
            return SceneSummarySpan(sceneId: scene.id, startMs: startMs, endMs: endMs, summary: summary)
        }.sorted { $0.startMs < $1.startMs }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
