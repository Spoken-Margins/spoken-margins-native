import Foundation

/// Recipient scene starts in proposal order. Unplaced starts stay nil for Skim;
/// the item page omits them and presents the placed chapters in time order.
public struct SceneStarts: Equatable, Sendable {
    public let scenes: [PortableListeningMapScene]
    public let sceneStarts: [Int?]

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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
