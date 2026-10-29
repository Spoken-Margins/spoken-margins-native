import Foundation
import SessionKit

/// Every launch argument and environment value that lets a UI test steer the app.
///
/// Debug builds read them. Release builds (TestFlight, App Store) compile none of
/// them in: the literals below sit inside `#if DEBUG`, every hook answers "no", and
/// nothing a person can pass at launch wipes the Library or fakes the microphone
/// (#517). `scripts/tests/test_ui_test_hooks_debug_only.py` keeps the literals here.
enum UITestingHooks {
    #if DEBUG
    private static func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    /// The app was launched by a UI test.
    static var isActive: Bool { CommandLine.arguments.contains("--ui-testing") }

    /// A fresh-install launch (#2854): the first-run flow runs as shipped, instead of being kept out of the way.
    static var keepsFirstRun: Bool { isActive && seed == .firstRun }

    /// A UI-test launch that keeps the first-run elements (Welcome sample, guided item, drawer, Terms, prompts, the
    /// voice download notice) away from the screens it drives. False for a fresh-install launch.
    static var suppressesFirstRun: Bool { isActive && !keepsFirstRun }

    /// Wipes the app's defaults before the model reads them, so a fresh-install launch starts as a new install does.
    /// Launch arguments live in another domain and survive.
    static func prepareFirstRunIfRequested() {
        guard keepsFirstRun, let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }

    /// What this launch puts in the Library before it loads.
    static let seed = UITestingLaunchSeed(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    /// The launch swaps the microphone and speech recognition for stand-ins.
    static var usesStandInAudioServices: Bool {
        UITestingLaunchSeed.usesStandInAudioServices(
            arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment
        )
    }

    /// A keep-library relaunch also imports one friend's Margin onto the seeded podcast (#474).
    static var importsCoopLayer: Bool {
        UITestingLaunchSeed.importsCoopLayer(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    }

    /// The first shared-source fetch fails once, to exercise the retry path.
    static var forcesFirstSharedSourceMiss: Bool {
        isActive && environment("SPOKEN_MARGINS_UI_TEST_FORCE_FIRST_SHARED_SOURCE_MISS") == "1"
    }

    /// A link resolver that always asks the listener to choose between two episodes.
    static var ambiguousSourceLinkResolver: LinkResolutionClient? {
        guard isActive, environment("SPOKEN_MARGINS_UI_TEST_AMBIGUOUS_SOURCE_LINK") == "1" else { return nil }
        return UITestingAmbiguousSourceLinkResolver()
    }

    /// A deterministic stand-in for the on-device summary model.
    static var localFoundationModelClient: (any LocalFoundationModelClient)? {
        guard isActive,
              let rawMode = environment("SPOKEN_MARGINS_UI_TEST_LOCAL_SUMMARY"),
              let mode = UITestingLocalFoundationModelClient.Mode(rawValue: rawMode) else { return nil }
        return UITestingLocalFoundationModelClient(mode: mode)
    }

    /// A fixed speech rate, so timing-sensitive scripts don't depend on the simulator's setting.
    static var speechRate: Double? {
        guard isActive else { return nil }
        return environment("SPOKEN_MARGINS_UI_TEST_SPEECH_RATE").flatMap(Double.init)
    }

    /// The script exercises Supertonic narration instead of system speech.
    static var usesSupertonic: Bool {
        isActive && environment("SPOKEN_MARGINS_UI_TEST_SUPERTONIC") == "1"
    }

    /// A Margin note to add to the first session of a summary route.
    static var summaryInterjectionNote: String? {
        guard isActive else { return nil }
        return environment("SPOKEN_MARGINS_UI_TEST_INTERJECTION")
    }
    #else
    static var isActive: Bool { false }
    static var keepsFirstRun: Bool { false }
    static var suppressesFirstRun: Bool { false }
    static func prepareFirstRunIfRequested() {}
    static let seed = UITestingLaunchSeed.none
    static var usesStandInAudioServices: Bool { false }
    static var importsCoopLayer: Bool { false }
    static var forcesFirstSharedSourceMiss: Bool { false }
    static var ambiguousSourceLinkResolver: LinkResolutionClient? { nil }
    static var localFoundationModelClient: (any LocalFoundationModelClient)? { nil }
    static var speechRate: Double? { nil }
    static var usesSupertonic: Bool { false }
    static var summaryInterjectionNote: String? { nil }
    #endif
}
