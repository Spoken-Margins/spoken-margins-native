import Foundation
import SessionKit

/// A shared Listening Map placed on the listener's own copy of an article or PDF (#1471).
///
/// Each scene start is found by its short quotation on the recipient's text, so the map lands on an
/// edition whose whitespace, quote marks or a paragraph differ from the sender's. Scenes that can't be
/// found, or that would run backwards, are left out and counted, never guessed for.
public struct TextListeningMapPlacement: Equatable, Sendable {
    public struct Scene: Equatable, Sendable, Identifiable {
        public let id: String
        public let order: Int
        public let title: String
        /// The sender's summary of the chapter. Nil when the scene is not eligible for one.
        public let summary: String?
        public let startChar: Int
        /// Where the chapter ends: the next placed chapter's start, or the end of the text.
        public let endChar: Int
    }

    public let proposalId: String
    /// In reading order.
    public let scenes: [Scene]
    /// Scene ids the text did not place, in the map's order.
    public let unplacedSceneIds: [String]

    public var totalSceneCount: Int { scenes.count + unplacedSceneIds.count }
    public var isComplete: Bool { unplacedSceneIds.isEmpty && !scenes.isEmpty }

    /// At least half the chapters landed. With fewer, the rest of the map would mislead Skim more than help it.
    public var isUsable: Bool { !scenes.isEmpty && scenes.count * 2 >= totalSceneCount }

    /// The chapters a text item shows and jumps by.
    public var chapters: [Chapter] {
        let length = scenes.last?.endChar ?? 0
        return scenes.map {
            Chapter(id: $0.id, title: $0.title, startChar: $0.startChar, endChar: $0.endChar,
                    percent: $0.startChar * 100 / max(1, length))
        }
    }

    /// Chapter summaries by chapter id, for the chapters that have one.
    public var summariesByChapterId: [String: String] {
        Dictionary(uniqueKeysWithValues: scenes.compactMap { scene in scene.summary.map { (scene.id, $0) } })
    }

    /// The listener-facing line for a map that only partly landed. Nil when every chapter did.
    public var shortfallDescription: String? {
        guard !unplacedSceneIds.isEmpty else { return nil }
        let placed = scenes.count
        return "Placed \(placed) of \(totalSceneCount) chapters. The rest weren't found in your copy."
    }

    init(proposalId: String, scenes: [Scene], unplacedSceneIds: [String]) {
        self.proposalId = proposalId
        self.scenes = scenes
        self.unplacedSceneIds = unplacedSceneIds
    }
}

public enum TextListeningMapPlacer {
    /// Places `proposal` on `text`. `expectedExactEditionSHA256` is the sender's exact-text hash: when it equals
    /// the hash of `text`, the sender's offsets are trusted without searching.
    public static func place(
        _ proposal: PortableListeningMapProposalArtifact,
        in text: String,
        expectedExactEditionSHA256: String? = nil
    ) -> TextListeningMapPlacement {
        let scenes = proposal.scenes.sorted { $0.order < $1.order }
        var found: [(sceneIndex: Int, start: Int)] = []
        for (index, scene) in scenes.enumerated() {
            let resolution = PortableArticleAnchorResolver.resolve(
                anchor: scene.startAnchor, in: text, expectedExactEditionSHA256: expectedExactEditionSHA256
            )
            guard resolution.evidenceClass == .articleTextVerified, !resolution.isAmbiguous,
                  let start = resolution.localStartChar else { continue }
            found.append((index, start))
        }
        // A start that jumped ahead of its neighbours is a wrong match; keep the longest run in reading order.
        let kept = longestStrictlyIncreasing(found.map(\.start)).map { found[$0] }
        let keptIndexes = Set(kept.map(\.sceneIndex))
        let characters = text.count
        let placed = kept.enumerated().map { position, entry -> TextListeningMapPlacement.Scene in
            let scene = scenes[entry.sceneIndex]
            let end = position + 1 < kept.count ? kept[position + 1].start : characters
            let title = scene.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = scene.eligibility == .eligible
                ? scene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return TextListeningMapPlacement.Scene(
                id: scene.id, order: scene.order,
                title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Scene \(scene.order + 1)",
                summary: summary.flatMap { $0.isEmpty ? nil : $0 },
                startChar: entry.start, endChar: end
            )
        }
        return TextListeningMapPlacement(
            proposalId: proposal.id, scenes: placed,
            unplacedSceneIds: scenes.indices.filter { !keptIndexes.contains($0) }.map { scenes[$0].id }
        )
    }

    /// Indexes of a longest strictly increasing subsequence; the earliest wins a tie.
    static func longestStrictlyIncreasing(_ values: [Int]) -> [Int] {
        guard !values.isEmpty else { return [] }
        var length = Array(repeating: 1, count: values.count)
        var previous = Array(repeating: -1, count: values.count)
        for i in values.indices {
            for j in 0..<i where values[j] < values[i] && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                previous[i] = j
            }
        }
        var tail = 0
        for i in values.indices where length[i] > length[tail] { tail = i }
        var result: [Int] = []
        var cursor = tail
        while cursor >= 0 {
            result.append(cursor)
            cursor = previous[cursor]
        }
        return result.reversed()
    }
}
