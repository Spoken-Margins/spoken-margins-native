import Foundation
import SessionKitEPUB
import XCTest
import ZIPFoundation

final class EPUBSafetyTests: XCTestCase {
    func testNestedNavigationAndUTF8LocatorsArePreserved() throws {
        let url = try makeEPUB(entries: validEntries())
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try EPUBParser().parse(url: url, itemId: "book", sourceDocumentId: "source")

        XCTAssertEqual(result.package.title, "Test Book")
        XCTAssertEqual(result.package.navigation.count, 1)
        XCTAssertEqual(result.package.navigation[0].children.map(\.title), ["Part One"])
        XCTAssertEqual(result.package.navigation[0].children[0].children.map(\.title), ["Chapter One"])
        XCTAssertEqual(result.package.navigation[0].children[0].children[0].locator?.spineItemId, "chapter")
        XCTAssertEqual(result.package.segments.first?.text, "Café opening")
        XCTAssertEqual(result.package.segments.first?.locator.utf8End, "Café opening".utf8.count)
    }

    func testEncryptedPackageIsRejectedBeforePublication() throws {
        var entries = validEntries()
        entries["META-INF/encryption.xml"] = "<encryption><EncryptedData/></encryption>"
        let url = try makeEPUB(entries: entries)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try EPUBParser().parse(url: url, itemId: "book", sourceDocumentId: "source")) {
            XCTAssertEqual($0 as? EPUBImportError, .unsupportedEncryption)
        }
    }

    func testOversizedExpansionIsRejected() throws {
        let url = try makeEPUB(entries: validEntries())
        defer { try? FileManager.default.removeItem(at: url) }
        let parser = EPUBParser(limits: EPUBParserLimits(maximumEntries: 20, maximumEntryBytes: 32, maximumExpandedBytes: 64, maximumXMLDepth: 32))
        XCTAssertThrowsError(try parser.parse(url: url, itemId: "book", sourceDocumentId: "source")) {
            guard case EPUBImportError.archiveLimitExceeded = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testMissingContainerDoesNotPublishPartialPackage() throws {
        let url = try makeEPUB(entries: ["mimetype": "application/epub+zip"])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try EPUBParser().parse(url: url, itemId: "book", sourceDocumentId: "source")) {
            XCTAssertEqual($0 as? EPUBImportError, .malformedPackage("missing_container"))
        }
    }

    private func validEntries() -> [String: String] {
        [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0"?><container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>
            """,
            "OPS/package.opf": """
            <?xml version="1.0"?><package><metadata><title>Test Book</title><creator>Author</creator><language>en</language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="chapter"/></spine></package>
            """,
            "OPS/chapter.xhtml": """
            <?xml version="1.0"?><html><body><h1>Café opening</h1><p>Hello &amp; welcome.</p><script>ignored()</script></body></html>
            """,
            "OPS/nav.xhtml": """
            <?xml version="1.0"?><html><body><nav><ol><li><a href="chapter.xhtml">Book</a><ol><li><a href="chapter.xhtml">Part One</a><ol><li><a href="chapter.xhtml">Chapter One</a></li></ol></li></ol></li></ol></nav></body></html>
            """
        ]
    }

    private func makeEPUB(entries: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "epub-safety-\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)
        for path in entries.keys.sorted() {
            let data = Data(entries[path]!.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: path == "mimetype" ? .none : .deflate
            ) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        return url
    }
}
