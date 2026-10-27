import XCTest
@testable import SpokenMarginsApp

@MainActor
final class OpenSourceLicensesTests: XCTestCase {
    func testEveryListedLicenseIsBundledWithTheApp() {
        for document in OpenSourceLicensesView.documents {
            let text = OpenSourceLicensesView.bundledText(for: document)
            XCTAssertNotEqual(text, "Bundled notice unavailable.", document.resourceName)
            // The bundled backup voice (#849) carries Apache-2.0 notices and CMU's BSD-style license, not MIT text.
            // The Kokoro runtime (#2705) is Apache-2.0 too.
            let required = ["NOTICES": "Apache-2.0", "Kokoro-NOTICES": "Apache-2.0", "CMUdict-LICENSE": "Carnegie Mellon University"][document.resourceName]
                ?? "Permission is hereby granted"
            XCTAssertTrue(text.contains(required), document.resourceName)
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
