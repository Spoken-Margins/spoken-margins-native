import SessionKit
import SessionKitSharing
import XCTest

/// #1968: what a listener reads when a `.spokenmargins` file can't be opened. Every error case maps to one of
/// three plain outcomes, and none of them uses the code's words.
final class PackageArchiveListenerMessageTests: XCTestCase {
    private typealias ArchiveError = SpokenMarginsPackageArchiveError

    func testEveryCaseSaysWhatToDoNextInPlainWords() {
        let table: [(error: ArchiveError, expected: ArchiveError.ListenerOutcome)] = [
            (.unsupportedSchema("9.9"), .needsNewerApp),
            (.unsupportedRequiredCapability("future_thing"), .needsNewerApp),
            (.packageTooLarge, .tooLarge),
            (.audioTooLarge("audio/a.m4a"), .tooLarge),
            (.audioTooLong("audio/a.m4a"), .tooLarge),
            (.malformedArchive, .damaged),
            (.invalidEntry("../evil"), .damaged),
            (.duplicateEntry("manifest.json"), .damaged),
            (.manifestMissing, .damaged),
            (.manifestTooLarge, .damaged),
            (.invalidManifest("default representation is absent"), .damaged),
            (.invalidDigest, .damaged),
            (.invalidAsset("assets/x"), .damaged),
            (.excessiveCompression("audio/a.m4a"), .damaged)
        ]
        for (error, expected) in table {
            XCTAssertEqual(error.listenerOutcome, expected, "\(error)")
            let message = error.listenerMessage
            for word in ["package", "manifest", "capability", "digest", "schema", "entry", "asset", "/"] {
                XCTAssertFalse(message.lowercased().contains(word), "\(error) says \"\(word)\": \(message)")
            }
        }
    }

    func testTheThreeMessages() {
        XCTAssertEqual(ArchiveError.unsupportedRequiredCapability("x").listenerMessage,
                       "These Margins need a newer Spoken Margins. Update the app, then open them again.")
        XCTAssertEqual(ArchiveError.invalidDigest.listenerMessage, "This file looks damaged. Ask your friend to send it again.")
        XCTAssertEqual(ArchiveError.packageTooLarge.listenerMessage,
                       "This file is bigger than Spoken Margins can open. Ask your friend to send fewer Margins at a time.")
    }

    func testTheTechnicalDescriptionStaysForDiagnostics() {
        XCTAssertEqual(ArchiveError.manifestMissing.errorDescription, "The package has no manifest.")
    }
}
