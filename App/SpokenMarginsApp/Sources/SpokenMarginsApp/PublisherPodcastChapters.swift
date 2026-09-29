import Foundation
import SessionKit

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

enum EmbeddedPublisherChapterLoader {
    static func load(from url: URL) async -> PublisherChapterCollection? {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        guard let groups = try? await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: Locale.preferredLanguages
        ), !groups.isEmpty else { return nil }
        var chapters: [PublisherChapter] = []
        for (index, group) in groups.enumerated() {
            let seconds = CMTimeGetSeconds(group.timeRange.start)
            guard seconds.isFinite, seconds >= 0, seconds <= Double(Int.max) / 1_000 else { continue }
            let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle })
            let descriptionItem = group.items.first(where: { $0.commonKey == .commonKeyDescription })
            let title = try? await titleItem?.load(.stringValue)
            let description = try? await descriptionItem?.load(.stringValue)
            let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(PublisherChapter(
                title: trimmedTitle?.isEmpty == false ? String(trimmedTitle!.prefix(240)) : "Chapter \(index + 1)",
                description: trimmedDescription?.isEmpty == false ? String(trimmedDescription!.prefix(500)) : nil,
                startMs: Int((seconds * 1_000).rounded())
            ))
        }
        guard !chapters.isEmpty else { return nil }
        return PublisherChapterCollection(source: .embeddedMedia, chapters: chapters)
        #else
        return nil
        #endif
    }
}
