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
        let map = try XCTUnwrap(result.package.derivedListeningMap())
        XCTAssertEqual(map.itemId, "book")
        XCTAssertTrue(map.chapters.contains(where: { $0.title == "Chapter One" }))
        XCTAssertTrue(map.chapters.allSatisfy { $0.endChar >= $0.startChar })
        XCTAssertEqual(result.package.navigation[0].children[0].children[0].locator?.spineItemId, "chapter")
        XCTAssertEqual(result.package.segments.first?.text, "Café opening")
        XCTAssertEqual(result.package.segments.first?.locator.utf8End, "Café opening".utf8.count)
    }

    func testTextOutsideBlockElementsIsKeptAtTheEndOfTheChapter() throws {
        // Only the end-of-document flush saves text that no block element closes. That callback
        // must run on every platform, including Linux where there is no Objective-C dispatch.
        var entries = validEntries()
        entries["OPS/chapter.xhtml"] = """
        <?xml version="1.0"?><html><body><p>First paragraph.</p><div>Closing words in a div.</div></body></html>
        """
        let url = try makeEPUB(entries: entries)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try EPUBParser().parse(url: url, itemId: "book", sourceDocumentId: "source")
        XCTAssertEqual(result.package.segments.map(\.text), ["First paragraph.", "Closing words in a div."])
    }

    func testChapterWithOnlyDivTextIsNotEmpty() throws {
        var entries = validEntries()
        entries["OPS/chapter.xhtml"] = """
        <?xml version="1.0"?><html><body><div>Chapter text</div></body></html>
        """
        let url = try makeEPUB(entries: entries)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try EPUBParser().parse(url: url, itemId: "book", sourceDocumentId: "source")
        XCTAssertEqual(result.package.segments.map(\.text), ["Chapter text"])
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

    /// Entries are checked one at a time against the entry limit, then added up against the expanded limit.
    /// The limits are exact: the total itself is allowed, one byte less is not.
    func testOversizedExpansionIsRejected() throws {
        let entries = validEntries()
        let sizes = entries.values.map { Int64($0.utf8.count) }
        let largest = try XCTUnwrap(sizes.max()), total = sizes.reduce(0, +)
        let url = try makeEPUB(entries: entries)
        defer { try? FileManager.default.removeItem(at: url) }

        // Every entry is under the entry limit; only their sum is over the expanded limit.
        let tooSmallToHoldThem = EPUBParser(limits: EPUBParserLimits(maximumEntries: 20, maximumEntryBytes: 10_000, maximumExpandedBytes: total - 1, maximumXMLDepth: 32))
        XCTAssertThrowsError(try tooSmallToHoldThem.parse(url: url, itemId: "book", sourceDocumentId: "source")) {
            XCTAssertEqual($0 as? EPUBImportError, .archiveLimitExceeded("expanded_size"))
        }
        let justEnough = EPUBParser(limits: EPUBParserLimits(maximumEntries: 20, maximumEntryBytes: largest, maximumExpandedBytes: total, maximumXMLDepth: 32))
        XCTAssertNoThrow(try justEnough.parse(url: url, itemId: "book", sourceDocumentId: "source"))
    }

    func testAnEntryOverTheEntryLimitIsRejectedWithItsReason() throws {
        let entries = validEntries()
        let largest = try XCTUnwrap(entries.values.map { Int64($0.utf8.count) }.max())
        let url = try makeEPUB(entries: entries)
        defer { try? FileManager.default.removeItem(at: url) }
        let parser = EPUBParser(limits: EPUBParserLimits(maximumEntries: 20, maximumEntryBytes: largest - 1, maximumExpandedBytes: 1_000_000, maximumXMLDepth: 32))
        XCTAssertThrowsError(try parser.parse(url: url, itemId: "book", sourceDocumentId: "source")) {
            XCTAssertEqual($0 as? EPUBImportError, .archiveLimitExceeded("entry_size"))
        }
    }

    func testMoreEntriesThanTheEntryCountLimitAreRejected() throws {
        let entries = validEntries()
        let url = try makeEPUB(entries: entries)
        defer { try? FileManager.default.removeItem(at: url) }
        let exactly = EPUBParser(limits: EPUBParserLimits(maximumEntries: entries.count, maximumEntryBytes: 1_000_000, maximumExpandedBytes: 1_000_000, maximumXMLDepth: 32))
        XCTAssertNoThrow(try exactly.parse(url: url, itemId: "book", sourceDocumentId: "source"))
        let oneFewer = EPUBParser(limits: EPUBParserLimits(maximumEntries: entries.count - 1, maximumEntryBytes: 1_000_000, maximumExpandedBytes: 1_000_000, maximumXMLDepth: 32))
        XCTAssertThrowsError(try oneFewer.parse(url: url, itemId: "book", sourceDocumentId: "source")) {
            XCTAssertEqual($0 as? EPUBImportError, .archiveLimitExceeded("entry_count"))
        }
    }

    // MARK: Paths

    func testAnArchiveEntryOutsideThePackageIsRejectedWhateverTheSlashes() throws {
        for path in ["../evil.xhtml", "OPS/../../evil.xhtml", "/absolute.xhtml", "..\\evil.xhtml"] {
            var entries = validEntries()
            entries[path] = "<html/>"
            let url = try makeEPUB(entries: entries)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertThrowsError(try EPUBParser().parse(url: url, itemId: "book", sourceDocumentId: "source"), path) {
                XCTAssertEqual($0 as? EPUBImportError, .unsafeArchivePath(path), path)
            }
        }
    }

    func testARootfileOrSpineItemThatClimbsOutOfThePackageIsRejected() throws {
        var rootfile = validEntries()
        rootfile["META-INF/container.xml"] = """
        <?xml version="1.0"?><container><rootfiles><rootfile full-path="../package.opf"/></rootfiles></container>
        """
        var spine = validEntries()
        spine["OPS/package.opf"] = spine["OPS/package.opf"]!.replacingOccurrences(of: "href=\"chapter.xhtml\" media-type", with: "href=\"../../outside.xhtml\" media-type")
        for (entries, unsafe) in [(rootfile, "../package.opf"), (spine, "OPS/../../outside.xhtml")] {
            let url = try makeEPUB(entries: entries)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertThrowsError(try EPUBParser().parse(url: url, itemId: "book", sourceDocumentId: "source"), unsafe) {
                XCTAssertEqual($0 as? EPUBImportError, .unsafeArchivePath(unsafe), unsafe)
            }
        }
    }

    // MARK: XML

    func testAChapterNestedDeeperThanTheXMLDepthLimitIsRejected() throws {
        // html, body and the divs, then a paragraph: the deepest element is `divs + 3` levels down.
        func chapter(divs: Int) -> String {
            "<?xml version=\"1.0\"?><html><body>" + String(repeating: "<div>", count: divs) + "<p>Deep.</p>" + String(repeating: "</div>", count: divs) + "</body></html>"
        }
        let limits = EPUBParserLimits(maximumEntries: 20, maximumEntryBytes: 1_000_000, maximumExpandedBytes: 1_000_000, maximumXMLDepth: 12)
        var atTheLimit = validEntries()
        atTheLimit["OPS/chapter.xhtml"] = chapter(divs: 9)
        var overTheLimit = validEntries()
        overTheLimit["OPS/chapter.xhtml"] = chapter(divs: 10)

        let fits = try makeEPUB(entries: atTheLimit)
        defer { try? FileManager.default.removeItem(at: fits) }
        XCTAssertEqual(try EPUBParser(limits: limits).parse(url: fits, itemId: "book", sourceDocumentId: "source").package.segments.map(\.text), ["Deep."])

        let tooDeep = try makeEPUB(entries: overTheLimit)
        defer { try? FileManager.default.removeItem(at: tooDeep) }
        XCTAssertThrowsError(try EPUBParser(limits: limits).parse(url: tooDeep, itemId: "book", sourceDocumentId: "source")) {
            XCTAssertEqual($0 as? EPUBImportError, .archiveLimitExceeded("xml_depth"))
        }
    }

    // MARK: Encryption

    /// Content encryption (an Adobe or Apple DRM scheme) leaves the chapters unreadable, so the book is
    /// refused rather than imported as gibberish.
    func testAnEPUBWhoseChaptersAreEncryptedIsRejected() throws {
        var entries = validEntries()
        entries["META-INF/encryption.xml"] = """
        <?xml version="1.0"?><encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/><enc:CipherData><enc:CipherReference URI="OPS/chapter.xhtml"/></enc:CipherData></enc:EncryptedData></encryption>
        """
        let url = try makeEPUB(entries: entries)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try EPUBParser().parse(url: url, itemId: "book", sourceDocumentId: "source")) {
            XCTAssertEqual($0 as? EPUBImportError, .unsupportedEncryption)
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
