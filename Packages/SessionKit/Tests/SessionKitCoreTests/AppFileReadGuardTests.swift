import Foundation
import XCTest
import SessionKitTestInputs

/// Guards that read app files as text and need no Apple framework. They live here, in the target that also runs on Linux,
/// rather than beside the Mac-only tests of the same subject, so a diff under `App/` can be checked without a Mac (#3538).
final class AppFileReadGuardTests: XCTestCase {
    func testModelRetainsDiagnosticErrorAndRequestLiterals() throws {
        // These remain app-owned. Pin their bytes at the call site without pretending to run the app.
        let source = try TestInputs.text(.appSources, "Gate1AppModel+PackageImport.swift")
        let start = try XCTUnwrap(source.range(of: "func acquirePodcastForImportedPackage("))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("diagnostics[\"lastSharedPodcastAcquisition\"] = \"package_reference_after_resolution_failure\""))
        XCTAssertTrue(body.contains("diagnostics[\"lastSharedPodcastAcquisition\"] = diagnostic"))
        XCTAssertTrue(body.contains("SessionKitError.persistenceFailed(\"shared_podcast_item_has_no_reference\")"))
        XCTAssertTrue(body.contains("SessionKitError.persistenceFailed(\"shared_podcast_item_not_created\")"))
        XCTAssertTrue(body.contains("sourceSurface: \"spoken_margins_package\""))
        XCTAssertTrue(body.contains(#"id: "shared-package-\(UUID().uuidString)""#))
    }

    func testTheAppTestsThatWritePacketsDirectlyAreTheOnesWeKnowAbout() throws {
        // App tests cannot call exportPacket (the frozen reader is not linked into the app test target), so these
        // writes there are not read by Build 29. EpisodeMapStoredNamesTests writes one only to drive an import and
        // check the names the app saves; it asserts nothing about what Build 29 can read. SpokenMarginsPackageImportCoordinatorTests
        // writes embedded-text packets only to drive the import coordinator's stage and confirm paths; the same
        // packet shape is exported through exportPacket in SharingTests. Its map packet (#1471) is the same shape
        // TextListeningMapPacketTests exports through exportMapOnlyPacket, which asserts the shipped build refuses it. SourceLinkImportTests
        // writes a private-feed packet only to drive the #454 recovery; PrivateFeedRecoveryTests exports the same
        // kind of linkless packet through exportPacket. This pins that list: a new
        // direct write fails here until someone either routes it through a packet the Mac package tests also read
        // with Build 29, or adds it below on purpose.
        let appTests = try TestInputs.directory(.appTests)
        guard FileManager.default.fileExists(atPath: appTests.path) else {
            throw XCTSkip("the app tests are not in this checkout")
        }
        let call = try NSRegularExpression(pattern: #"SpokenMarginsPackageArchive\s*\.write\("#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appTests, includingPropertiesForKeys: nil))
        var counts: [String: Int] = [:]
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let matches = call.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if matches > 0 { counts[file.lastPathComponent] = matches }
        }
        XCTAssertEqual(counts, ["EpisodeMapStoredNamesTests.swift": 1, "LocalAudioListeningPackageTests.swift": 3,
                                "SourceLinkImportTests.swift": 1, "SpokenMarginsPackageHandoffTests.swift": 1,
                                "SpokenMarginsPackageImportCoordinatorTests.swift": 2])
    }
}
