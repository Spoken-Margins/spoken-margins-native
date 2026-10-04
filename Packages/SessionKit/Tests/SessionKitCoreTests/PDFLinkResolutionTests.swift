import Foundation
import XCTest
import SessionKit
import SessionKitFeeds

/// #758: `https://arxiv.org/pdf/2608.09666` typed into Link or Podcast came back "I found the page or feed, but
/// not a playable podcast/audio file." The resolver didn't notice the page was a PDF, so the app sent 2.2 MB of
/// PDF to the HTML article reader, which gave up on size. The same link shared from Safari imports as a PDF.
final class PDFLinkResolutionTests: XCTestCase {
    private static let pdfURL = "https://arxiv.org/pdf/2608.09666"
    private static let pdf = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8)

    func testALinkServingAPDFIsReportedAsAPDFNotAPageWithNoAudio() throws {
        let resolver = PublicPodcastLinkResolver(fetch: Self.serving(Self.pdf))

        let result = try resolver.resolve(Self.request())

        XCTAssertTrue(result.isPDFDocument, "\(result.status) \(result.failureReason ?? "no reason")")
        XCTAssertFalse(result.foundNoAudio, "a PDF must not go to the HTML article reader")
        XCTAssertNotEqual(result.status, .playable)
    }

    func testTheAsyncResolverReportsTheSamePDF() async throws {
        let pdf = Self.pdf
        let resolver = PublicPodcastLinkResolver(
            fetch: Self.serving(pdf),
            asynchronousFetch: { url in
                guard url.absoluteString == Self.pdfURL else { throw URLError(.notConnectedToInternet) }
                return pdf
            }
        )

        let result = try await resolver.resolveAsync(Self.request())

        XCTAssertTrue(result.isPDFDocument, "\(result.status) \(result.failureReason ?? "no reason")")
        XCTAssertFalse(result.foundNoAudio)
    }

    func testAnHTMLPageWithNoAudioIsStillAPageToRead() throws {
        let page = Data("<html><head><title>An essay</title></head><body><p>Text about PDFs: %PDF-</p></body></html>".utf8)

        let result = try PublicPodcastLinkResolver(fetch: Self.serving(page)).resolve(Self.request())

        XCTAssertFalse(result.isPDFDocument)
        XCTAssertTrue(result.foundNoAudio, "\(result.status) \(result.failureReason ?? "no reason")")
    }

    private static func request() -> LinkResolutionRequest {
        LinkResolutionRequest(id: "pdf-link", inputURL: pdfURL, sourceSurface: "source_link_form", createdAt: Date())
    }

    /// The link answers with `body`; any other request fails, as offline.
    private static func serving(_ body: Data) -> PublicPodcastLinkResolver.Fetch {
        { url in
            guard url.absoluteString == pdfURL else { throw URLError(.notConnectedToInternet) }
            return body
        }
    }
}
