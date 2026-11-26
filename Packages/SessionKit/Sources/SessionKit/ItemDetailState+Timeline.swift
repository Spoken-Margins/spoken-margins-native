import Foundation

extension ItemDetailState {
    /// Prepared with item detail so rendering and playback ticks never read the store.
    public func includingTimelineSource(_ document: StructuredDocument?, elements: SourceElementsRecord? = nil) -> Self {
        guard !isNativeAudio else { return self }
        var result = self
        result.timelineSource = TimelineSourceContent(
            text: text, document: document, elements: elements?.elements(for: text) ?? [])
        result.pdfClipSource = document.flatMap { PDFClipSource(document: $0, text: text) }
        // One more pass, only for a PDF with a picture-only figure: the entries its Timeline rows are made from (#4587).
        if let document, let source = result.pdfClipSource, source.floats.contains(where: { $0.textSegmentId == nil }) {
            result.timelineSource.figures = TimelineSourceContent.figureEntries(text: text, document: document, source: source)
        }
        return result
    }
}
