import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// UIApplication background time for on-device narration starts (#854). The policy (which starts are protected
/// and when the time is given back) lives in SessionKit's `NarrationStartupProtection`.
enum NarrationStartupBackgroundTime {
    @MainActor
    static func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)? {
        #if canImport(UIKit) && os(iOS)
        let hold = Hold(expired: expired)
        hold.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { hold.expire() }
        }
        guard hold.identifier != .invalid else { return nil }
        return { hold.end() }
        #else
        return nil
        #endif
    }

    #if canImport(UIKit) && os(iOS)
    @MainActor
    private final class Hold {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        private let expired: @MainActor () -> Void

        init(expired: @escaping @MainActor () -> Void) { self.expired = expired }

        /// iOS took the time back: tell the protection, and end the task even if the protection had moved on.
        func expire() {
            expired()
            end()
        }

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
    #endif
}
