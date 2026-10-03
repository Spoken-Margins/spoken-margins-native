import Foundation
import SessionKitPersistence

/// Bundle lookup stays in the app; launch gating, file installation and persistence
/// live in SessionKit so normal launches can be checked without a simulator.
enum UITestPodcastBootstrap {
    /// The default UI-test launch adds a generated AI reply to its seeded session. Launches that seed
    /// their own library (a source text, or the offline podcast) don't. Kept here so Gate1AppModel doesn't grow.
    static var seedsGeneratedTimeline: Bool {
        let environment = ProcessInfo.processInfo.environment
        return CommandLine.arguments.contains("--ui-testing")
            && environment[UITestPodcastSeed.environmentKey] != "1"
            && environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] == nil
    }

    static func seedIfRequested(
        store: SQLiteSessionStore,
        applicationSupportDirectory: () throws -> URL
    ) throws -> Bool {
        try UITestPodcastSeed.installIfRequested(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment,
            store: store,
            fixtureURL: {
                guard let url = Bundle.main.url(
                    forResource: UITestPodcastSeed.fixtureName, withExtension: "mp3",
                    subdirectory: "fixtures/audio"
                ) else { throw CocoaError(.fileReadNoSuchFile) }
                return url
            },
            applicationSupportDirectory: applicationSupportDirectory
        )
    }
}
