import XCTest
@testable import SpokenMarginsApp

@MainActor
final class OpenSourceLicensesTests: XCTestCase {
    func testEveryListedLicenseIsBundledWithTheApp() {
        for document in OpenSourceLicensesView.documents {
            let text = OpenSourceLicensesView.bundledText(for: document)
            XCTAssertNotEqual(text, "Bundled notice unavailable.", document.resourceName)
            XCTAssertTrue(text.contains("Permission is hereby granted"), document.resourceName)
        }
    }

    func testBundledJavaScriptNoticesNameEveryInlinedPackage() throws {
        let notices = try XCTUnwrap(OpenSourceLicensesView.documents.first { $0.resourceName == "BundledJavaScript-NOTICES" })
        let text = OpenSourceLicensesView.bundledText(for: notices)
        for package in ["defuddle", "turndown", "temml", "mathml-to-latex", "@xmldom/xmldom"] {
            XCTAssertTrue(text.contains("\n\(package) "), package)
        }
    }
}
