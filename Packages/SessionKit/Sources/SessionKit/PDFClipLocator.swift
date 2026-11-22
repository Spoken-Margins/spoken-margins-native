import Foundation

/// Turns the page rectangles of a PDF's table and figure-text lines into the regions a Timeline row can show
/// as a picture (#3895). It is a pure function of the rectangles, so what counts as a reliable region is
/// tested on the host, and the app only has to render what it returns.
///
/// Rectangles are fractions of the page's crop box with the origin at the bottom left, as
/// `PDFNormalizedRect` is everywhere else. A region is a cluster of lines that sit close together on one page
/// and belong to one segment, grown by a small margin. A cluster that is too small, too much like the whole
/// page, or made of a single line gets no region: the Timeline then shows the row as text, as it always has,
/// rather than a box that may cut the wrong thing.
public enum PDFClipLocator {
    /// One table or figure-text line, in the segment the document builder put it in.
    public struct Line: Equatable, Sendable {
        public var segmentId: String
        public var kind: StructuredDocument.Float.Kind
        public var pageIndex: Int
        public var bounds: PDFNormalizedRect

        public init(segmentId: String, kind: StructuredDocument.Float.Kind, pageIndex: Int, bounds: PDFNormalizedRect) {
            self.segmentId = segmentId
            self.kind = kind
            self.pageIndex = pageIndex
            self.bounds = bounds
        }
    }

    /// Lines closer than this (a fraction of the page) join one region.
    static let joinDistance = 0.03
    /// What is added around a region so its edges are not cut through a line.
    static let padding = 0.012
    /// About 40 pt on a Letter or A4 page.
    static let minimumWidth = 0.065
    static let minimumHeight = 0.05
    /// A region this much of the page is the page, not a table or a figure on it.
    static let maximumArea = 0.85
    static let minimumLines = 2
    public static let maximumFloatsPerDocument = 40

    /// The float kind a line's role stands for, or nil for a role that never gets a clip.
    public static func kind(of role: StructuredDocument.Role) -> StructuredDocument.Float.Kind? {
        switch role {
        case .table: .table
        case .figureText: .figure
        default: nil
        }
    }

    /// The floats for these lines, in document order, at most `maximumFloatsPerDocument`.
    public static func floats(from lines: [Line]) -> [StructuredDocument.Float] {
        var result: [StructuredDocument.Float] = []
        var perPage: [Int: Int] = [:]
        // Lines of one segment on one page, in the order they were read, are one group.
        var groups: [(key: String, lines: [Line])] = []
        for line in lines where isUsable(line.bounds) {
            let key = "\(line.segmentId)|\(line.kind.rawValue)|\(line.pageIndex)"
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].lines.append(line)
            } else {
                groups.append((key, [line]))
            }
        }
        for group in groups {
            for cluster in clusters(of: group.lines.map(\.bounds)) where cluster.count >= minimumLines {
                guard let region = region(for: cluster) else { continue }
                guard result.count < maximumFloatsPerDocument, let first = group.lines.first else { return result }
                let number = (perPage[first.pageIndex] ?? 0) + 1
                perPage[first.pageIndex] = number
                result.append(StructuredDocument.Float(
                    id: "float-p\(first.pageIndex + 1)-\(number)",
                    kind: first.kind,
                    label: nil,
                    pageIndex: first.pageIndex,
                    bounds: region,
                    captionSegmentId: nil,
                    textSegmentId: first.segmentId
                ))
            }
        }
        return result
    }

    /// A rectangle that is finite, has an area and lies at least partly on the page.
    static func isUsable(_ rect: PDFNormalizedRect) -> Bool {
        [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
            && rect.x < 1 && rect.y < 1 && rect.x + rect.width > 0 && rect.y + rect.height > 0
    }

    /// Groups rectangles that are within `joinDistance` of each other, directly or through another one.
    static func clusters(of rects: [PDFNormalizedRect]) -> [[PDFNormalizedRect]] {
        var clusters: [[PDFNormalizedRect]] = rects.map { [$0] }
        var merged = true
        while merged {
            merged = false
            outer: for i in clusters.indices {
                for j in clusters.indices where j > i {
                    if clusters[i].contains(where: { a in clusters[j].contains { near(a, $0) } }) {
                        clusters[i] += clusters[j]
                        clusters.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return clusters
    }

    private static func near(_ a: PDFNormalizedRect, _ b: PDFNormalizedRect) -> Bool {
        let horizontal = max(a.x, b.x) - min(a.x + a.width, b.x + b.width)
        let vertical = max(a.y, b.y) - min(a.y + a.height, b.y + b.height)
        return horizontal <= joinDistance && vertical <= joinDistance
    }

    /// The padded union of a cluster, kept on the page, or nil when it isn't a reliable clip.
    static func region(for cluster: [PDFNormalizedRect]) -> PDFNormalizedRect? {
        guard let minX = cluster.map(\.x).min(), let minY = cluster.map(\.y).min(),
              let maxX = cluster.map({ $0.x + $0.width }).max(), let maxY = cluster.map({ $0.y + $0.height }).max() else { return nil }
        let left = max(0, minX - padding), bottom = max(0, minY - padding)
        let right = min(1, maxX + padding), top = min(1, maxY + padding)
        let width = right - left, height = top - bottom
        guard width >= minimumWidth, height >= minimumHeight, width * height <= maximumArea else { return nil }
        return PDFNormalizedRect(x: left, y: bottom, width: width, height: height)
    }
}
