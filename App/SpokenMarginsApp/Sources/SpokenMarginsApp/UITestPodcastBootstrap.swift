import Foundation
import SessionKitPersistence

/// Bundle lookup stays in the app; launch gating, file installation and persistence
/// live in SessionKit so normal launches can be checked without a simulator.
enum UITestPodcastBootstrap {
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
