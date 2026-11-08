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
        assistiveTechnologyRunning: { AssistiveTechnology.isRunning }
    )
}

/// Whether VoiceOver or Switch Control is running. Timed cards and banners ask this one place, so none of them
/// forgets Switch Control (#1927, #3720).
@MainActor
enum AssistiveTechnology {
    static var isRunning: Bool {
        #if canImport(UIKit)
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #else
        false
        #endif
    }
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

    /// Whether the listener is on the Margin card, by touch or by focus: the tone-only card's timer waits (#3720).
    /// One card is on screen at a time, so one hold serves the app.
    static let marginCard = FeedbackBannerHold()

    /// Waits while the listener is on the card, a second at a time. At most `maxSeconds` more, so a touch that
    /// SwiftUI never reports as ended can't keep the card forever (#1927, #3720).
    func waitWhileHeld(
        maxSeconds: Int = 30,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        var heldSeconds = 0
        while isHeld, heldSeconds < maxSeconds {
            try await sleep(.seconds(1))
            heldSeconds += 1
        }
    }
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
