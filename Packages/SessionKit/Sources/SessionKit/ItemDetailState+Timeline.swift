import Foundation

extension ItemDetailState {
    /// Prepared with item detail so rendering and playback ticks never read the store.
    public func includingTimelineSource(_ document: StructuredDocument?, elements: SourceElementsRecord? = nil) -> Self {
        guard !isNativeAudio else { return self }
        var result = self
        result.timelineSource = TimelineSourceContent(
            text: text, document: document, elements: elements?.elements(for: text) ?? [])
        return result
    }
}
