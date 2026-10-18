import SwiftUI
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

/// The effects of delivering feedback, shared by every presentation of the same event.
/// Immutable environment injection lets mounted views use a controlled clock without global hooks.
struct UserFeedbackDeliveryEffects: Sendable {
    let announce: @MainActor @Sendable (String) -> Void
    let sleep: @Sendable (Duration) async throws -> Void
    /// Whether VoiceOver or Switch Control is running, so banners stay long enough to use them (#1927).
    var assistiveTechnologyRunning: @MainActor @Sendable () -> Bool = { false }

    static let live = Self(
        announce: { message in
            #if canImport(UIKit)
            UIAccessibility.post(notification: .announcement, argument: message)
            #endif
        },
        sleep: { duration in try await Task.sleep(for: duration) },
        assistiveTechnologyRunning: {
            #if canImport(UIKit)
            UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
            #else
            false
            #endif
        }
    )
}

/// Whether the listener is touching the banner or has VoiceOver or Switch Control focus on it. The
/// dismiss timer waits while it is (#1927). The banner writes it and the delivery task reads it, so
/// it is a plain object: nothing redraws when it changes.
@MainActor
final class FeedbackBannerHold {
    private var touched = false
    private var focused = false

    var isHeld: Bool { FeedbackBannerPolicy.timerIsHeld(touched: touched, focused: focused) }

    func setTouched(_ value: Bool) { touched = value }
    func setFocused(_ value: Bool) { focused = value }
    func reset() { touched = false; focused = false }
}

private struct FeedbackBannerHoldKey: EnvironmentKey {
    static let defaultValue: FeedbackBannerHold? = nil
}

private struct UserFeedbackDeliveryEffectsKey: EnvironmentKey {
    static let defaultValue = UserFeedbackDeliveryEffects.live
}

extension EnvironmentValues {
    var feedbackDeliveryEffects: UserFeedbackDeliveryEffects {
        get { self[UserFeedbackDeliveryEffectsKey.self] }
        set { self[UserFeedbackDeliveryEffectsKey.self] = newValue }
    }

    var feedbackBannerHold: FeedbackBannerHold? {
        get { self[FeedbackBannerHoldKey.self] }
        set { self[FeedbackBannerHoldKey.self] = newValue }
    }
}
