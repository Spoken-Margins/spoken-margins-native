import Foundation
import XCTest
@testable import SessionKit

final class SafeErrorTextTests: XCTestCase {
    private enum PayloadError: Error {
        case titled(String)
        case plain
        case two(path: String, count: Int)
    }

    private enum CustomWordsError: Error, CustomStringConvertible, LocalizedError {
        case secret
        var description: String { "Could not open /Users/someone/Family Taxes 2025.pdf" }
        var errorDescription: String? { description }
    }

    private struct StructError: Error, CustomStringConvertible {
        let path: String
        var description: String { "bad file \(path)" }
    }

    /// Fragments that must never come out, whatever the input.
    private let secrets = ["secret", "family", "taxes", "someone", "/users", "/var", ".pdf", "example.com", "ünïcode", "日本語"]

    private func assertSafe(_ error: Error, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = SafeErrorText.describe(error).lowercased()
        for fragment in secrets {
            XCTAssertFalse(text.contains(fragment), "\(label): \(fragment) reached \(text)", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(text.count, 200, label, file: file, line: line)
    }

    func testTableOfNeighbouringErrorsNeverCarriesTheirText() {
        let long = String(repeating: "secret ", count: 5000)
        let cases: [(String, Error)] = [
            ("NSError with a path in userInfo", NSError(domain: "NSCocoaErrorDomain", code: 260, userInfo: [
                NSFilePathErrorKey: "/Users/someone/Secret Plans/Family Taxes 2025.pdf",
                NSLocalizedDescriptionKey: "The file \u{201C}Family Taxes 2025.pdf\u{201D} couldn\u{2019}t be opened.",
                NSURLErrorKey: URL(fileURLWithPath: "/Users/someone/Family Taxes 2025.pdf"),
            ])),
            ("URLError", URLError(.notConnectedToInternet, userInfo: [
                NSURLErrorFailingURLStringErrorKey: "https://example.com/secret",
                NSLocalizedDescriptionKey: "https://example.com/secret failed",
            ])),
            ("CocoaError file with spaces", CocoaError(.fileReadNoSuchFile, userInfo: [
                NSFilePathErrorKey: "/Users/someone/Family Taxes 2025.pdf",
            ])),
            ("CocoaError file with Unicode", CocoaError(.fileReadNoPermission, userInfo: [
                NSFilePathErrorKey: "/Users/someone/ünïcode 日本語 secret.pdf",
            ])),
            ("our enum with an associated title", PayloadError.titled("Secret Plans")),
            ("our enum with a long payload", PayloadError.titled(long)),
            ("our enum with an empty payload", PayloadError.titled("")),
            ("our enum with a path payload", PayloadError.two(path: "/var/mobile/Family Taxes.pdf", count: 3)),
            ("an enum whose own description is text", CustomWordsError.secret),
            ("a struct whose description is text", StructError(path: "/Users/someone/Family Taxes 2025.pdf")),
            ("a domain that is a sentence", NSError(domain: "Secret Family Taxes: /Users/someone", code: 1)),
            ("an empty domain", NSError(domain: "", code: 0)),
            ("an underlying path", NSError(domain: "A", code: 1, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: "/Users/someone/secret", code: 2, userInfo: [NSLocalizedDescriptionKey: "Family Taxes.pdf"]),
            ])),
        ]
        for (label, error) in cases { assertSafe(error, label) }
    }

    func testDomainAndCodeStillTellFailuresApart() {
        let notFound = SafeErrorText.describe(CocoaError(.fileReadNoSuchFile))
        let noPermission = SafeErrorText.describe(CocoaError(.fileReadNoPermission))
        XCTAssertEqual(notFound, "NSCocoaErrorDomain#260")
        XCTAssertNotEqual(notFound, noPermission)
        XCTAssertEqual(SafeErrorText.describe(URLError(.timedOut)), "NSURLErrorDomain#-1001")
    }

    func testAnUnderlyingErrorIsKeptAsDomainAndCode() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "NSOSStatusErrorDomain", code: -12842),
        ])
        XCTAssertEqual(SafeErrorText.describe(error), "AVFoundationErrorDomain#-11800 < NSOSStatusErrorDomain#-12842")
    }

    func testOurEnumKeepsItsCaseNameAndNeverItsPayload() {
        XCTAssertTrue(SafeErrorText.describe(PayloadError.titled("Secret Plans")).hasSuffix(":titled"))
        XCTAssertTrue(SafeErrorText.describe(PayloadError.plain).hasSuffix(":plain"))
        XCTAssertTrue(SafeErrorText.describe(PayloadError.two(path: "/x y/z.pdf", count: 1)).hasSuffix(":two"))
        XCTAssertFalse(SafeErrorText.describe(CustomWordsError.secret).contains(":"), "text that isn't a bare name is dropped")
        XCTAssertFalse(SafeErrorText.describe(StructError(path: "p")).contains(":"), "only enums give a case name")
    }
}
