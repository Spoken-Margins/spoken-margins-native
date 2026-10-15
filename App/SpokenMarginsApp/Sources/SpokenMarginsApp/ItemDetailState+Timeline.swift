import SessionKit

extension ItemDetailState {
    /// Prepared with item detail so rendering and playback ticks never read the store.
    func includingTimelineSource(_ document: StructuredDocument?) -> Self {
        guard !isNativeAudio else { return self }
        var result = self
        result.timelineSource = TimelineSourceContent(text: text, document: document)
        return result
    }
}
