import Foundation
import XCTest
import SessionKitTestInputs

/// Guards that read app files as text and need no Apple framework. They live here, in the target that also runs on Linux,
/// rather than beside the Mac-only tests of the same subject, so a diff under `App/` can be checked without a Mac (#3538).
final class AppFileReadGuardTests: XCTestCase {
    /// Code with comments removed, cut to the function the literals belong to, so a literal that survives only in a
    /// comment is not found (#4306).
    static func acquireBody(_ text: String) -> String? {
        SwiftSourceScan.body(after: "func acquirePodcastForImportedPackage(", in: SwiftSourceScan.code(text))
    }

    static func missingLiterals(_ text: String) -> [String] {
        guard let body = acquireBody(text) else { return ["func acquirePodcastForImportedPackage is gone"] }
        return [
            "diagnostics[\"lastSharedPodcastAcquisition\"] = \"package_reference_after_resolution_failure\"",
            "diagnostics[\"lastSharedPodcastAcquisition\"] = diagnostic",
            "SessionKitError.persistenceFailed(\"shared_podcast_item_has_no_reference\")",
            "SessionKitError.persistenceFailed(\"shared_podcast_item_not_created\")",
            "sourceSurface: \"spoken_margins_package\"",
            #"id: "shared-package-\(UUID().uuidString)""#
        ].filter { !body.contains($0) }
    }

    func testModelRetainsDiagnosticErrorAndRequestLiteralsInSourceText() throws {
        // These remain app-owned. Pin their bytes at the call site without pretending to run the app.
        let source = try TestInputs.text(.appSources, "Gate1AppModel+PackageImport.swift")
        XCTAssertEqual(Self.missingLiterals(source), [])
    }

    func testALiteralLeftOnlyInACommentIsMissingFromTheAcquireFunction() throws {
        let source = try TestInputs.text(.appSources, "Gate1AppModel+PackageImport.swift")
        let real = "diagnostics[\"lastSharedPodcastAcquisition\"] = diagnostic"
        XCTAssertTrue(source.contains(real), "the mutation below must find the write")
        let commentedOut = source.replacingOccurrences(of: real, with: "// " + real)
        XCTAssertEqual(Self.missingLiterals(commentedOut), [real])
        // The same text in a different function is not the acquire function's write.
        let moved = source.replacingOccurrences(of: real, with: "").appending("\nfunc other() {\n    \(real)\n}\n")
        XCTAssertEqual(Self.missingLiterals(moved), [real])
    }

    func testTheAppTestsThatWritePacketsDirectlyAreTheOnesWeKnowAbout() throws {
        // App tests cannot call exportPacket (the frozen reader is not linked into the app test target), so these
        // writes there are not read by Build 29. EpisodeMapStoredNamesTests writes one only to drive an import and
        // check the names the app saves; it asserts nothing about what Build 29 can read. SpokenMarginsPackageImportCoordinatorTests
        // writes embedded-text packets only to drive the import coordinator's stage and confirm paths; the same
        // packet shape is exported through exportPacket in SharingTests. Its map packet (#1471) is the same shape
        // TextListeningMapPacketTests exports through exportMapOnlyPacket, which asserts the shipped build refuses it. SkimBridgeControllerTests
        // writes the same map-only packet shape to drive the real importer into a store and then Skim (#1471); it asserts nothing
        // about what Build 29 can read. SourceLinkImportTests
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
                                "SkimBridgeControllerTests.swift": 1, "SourceLinkImportTests.swift": 1, "SpokenMarginsPackageHandoffTests.swift": 1,
                                "SpokenMarginsPackageImportCoordinatorTests.swift": 2])
    }
}
