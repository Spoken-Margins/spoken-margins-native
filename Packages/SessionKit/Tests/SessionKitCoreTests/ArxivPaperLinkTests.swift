import Foundation
import XCTest
import SessionKit
import SessionKitFeeds

/// #5049: pasting `https://arxiv.org/abs/1706.03762` into Link or Podcast spun for about 41 s and then said no
/// playable file was found; its PDF link added at once.
final class ArxivPaperLinkTests: XCTestCase {
    private static let pdf = "https://arxiv.org/pdf/1706.03762"

    func testAbstractLinksMapToThePDFLink() {
        let rows: [(input: String, expected: String?)] = [
            ("https://arxiv.org/abs/1706.03762", Self.pdf),
            ("https://arxiv.org/abs/1706.03762v7", Self.pdf + "v7"),
            ("https://arxiv.org/abs/1706.03762v2/", Self.pdf + "v2"),
            ("http://arxiv.org/abs/1706.03762", Self.pdf),
            ("https://www.arxiv.org/abs/1706.03762", Self.pdf),
            ("https://export.arxiv.org/abs/1706.03762", Self.pdf),
            ("HTTPS://ARXIV.ORG/abs/1706.03762", Self.pdf),
            ("https://arxiv.org/abs/1706.03762/", Self.pdf),
            ("https://arxiv.org/abs/1706.03762?context=cs.CL", Self.pdf),
            ("https://arxiv.org/abs/1706.03762v7?context=cs#section", Self.pdf + "v7"),
            ("  https://arxiv.org/abs/1706.03762\n", Self.pdf),
            ("https://arxiv.org/abs/2301.01234", "https://arxiv.org/pdf/2301.01234"),
            ("https://arxiv.org/abs/0704.0001", "https://arxiv.org/pdf/0704.0001"),
            ("https://arxiv.org/abs/hep-th/9901001", "https://arxiv.org/pdf/hep-th/9901001"),
            ("https://arxiv.org/abs/hep-th/9901001v2", "https://arxiv.org/pdf/hep-th/9901001v2"),
            ("https://arxiv.org/abs/math.GT/0309136", "https://arxiv.org/pdf/math.GT/0309136"),
            ("https://arxiv.org/abs/cond-mat/0001001/", "https://arxiv.org/pdf/cond-mat/0001001"),
            // Not abstract links: left alone.
            ("https://arxiv.org/pdf/1706.03762", nil),
            ("https://arxiv.org/pdf/1706.03762v7.pdf", nil),
            ("https://arxiv.org/list/cs.CL/recent", nil),
            ("https://arxiv.org/html/1706.03762v7", nil),
            ("https://arxiv.org/abs/", nil),
            ("https://arxiv.org/abs", nil),
            ("https://arxiv.org/abs/not-an-id", nil),
            ("https://arxiv.org/abs/1706.03762/extra", nil),
            ("https://arxiv.org/abs/1706.037", nil),
            ("https://arxiv.org/abs/1706.03762x", nil),
            ("https://arxiv.org/abs/17060.03762", nil),
            ("https://arxiv.org/abs/hep-th/99010", nil),
            ("https://arxiv.org/ABS/1706.03762", nil),
            ("https://example.com/abs/1706.03762", nil),
            ("https://notarxiv.org/abs/1706.03762", nil),
            ("https://arxiv.org.example.com/abs/1706.03762", nil),
            ("https://arxiv.org@example.com/abs/1706.03762", nil),
            ("https://example.com/?u=https://arxiv.org/abs/1706.03762", nil),
            ("https://arxiv.org:8443/abs/1706.03762", nil),
            ("ftp://arxiv.org/abs/1706.03762", nil),
            ("arxiv.org/abs/1706.03762", nil),
            ("", nil),
            ("   ", nil),
            ("https://arxiv.org/abs/" + String(repeating: "1", count: 5_000), nil),
            ("https://arxiv.org/abs/1706.03762" + String(repeating: "/", count: 5_000), nil),
        ]
        for row in rows {
            XCTAssertEqual(ArxivPaperLink.pdfURL(forAbstract: row.input)?.absoluteString, row.expected, "input: \(row.input.prefix(80))")
        }
    }

    func testTheResolverReportsAnAbstractLinkAsThePDF() throws {
        let resolver = PublicPodcastLinkResolver(fetch: Self.servingPDFOnly)

        let result = try resolver.resolve(Self.request("https://arxiv.org/abs/1706.03762v7?context=cs"))

        XCTAssertTrue(result.isPDFDocument, "\(result.status) \(result.failureReason ?? "no reason")")
        XCTAssertFalse(result.foundNoAudio)
    }

    func testTheResolverReadsAnHTTPAbstractLinkToo() throws {
        let result = try PublicPodcastLinkResolver(fetch: Self.servingPDFOnly).resolve(Self.request("http://www.arxiv.org/abs/1706.03762/"))

        XCTAssertTrue(result.isPDFDocument, "\(result.status) \(result.failureReason ?? "no reason")")
    }

    func testTheAsyncResolverReportsTheSameAbstractLink() async throws {
        let resolver = PublicPodcastLinkResolver(
            fetch: Self.servingPDFOnly,
            asynchronousFetch: { url in
                guard url.absoluteString == ArxivPaperLinkTests.pdf else { throw URLError(.notConnectedToInternet) }
                return ArxivPaperLinkTests.pdfBody
            }
        )

        let result = try await resolver.resolveAsync(Self.request("https://arxiv.org/abs/1706.03762"))

        XCTAssertTrue(result.isPDFDocument, "\(result.status) \(result.failureReason ?? "no reason")")
    }

    func testALookalikeIsStillReadAsAPage() throws {
        let page = Data("<html><head><title>List</title></head><body><p>papers</p></body></html>".utf8)
        let resolver = PublicPodcastLinkResolver(fetch: { _ in page })

        let result = try resolver.resolve(Self.request("https://arxiv.org/list/cs.CL/recent"))

        XCTAssertFalse(result.isPDFDocument)
    }

    private static let pdfBody = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8)

    private static func request(_ url: String) -> LinkResolutionRequest {
        LinkResolutionRequest(id: "arxiv-abs", inputURL: url, sourceSurface: "source_link_form", createdAt: Date())
    }

    /// Only the PDF address answers; the abstract page is not served, as if it had no audio and no PDF.
    private static let servingPDFOnly: PublicPodcastLinkResolver.Fetch = { url in
        guard url.absoluteString.hasPrefix(pdf) else { throw URLError(.fileDoesNotExist) }
        return pdfBody
    }
}
