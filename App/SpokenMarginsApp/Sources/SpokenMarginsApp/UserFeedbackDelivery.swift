import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The two effects of delivering feedback, shared by every presentation of the same event.
/// Immutable environment injection lets mounted views use a controlled clock without global hooks.
struct UserFeedbackDeliveryEffects: Sendable {
    let announce: @MainActor @Sendable (String) -> Void
    let sleep: @Sendable (Duration) async throws -> Void

    static let live = Self(
        announce: { message in
            #if canImport(UIKit)
            UIAccessibility.post(notification: .announcement, argument: message)
            #endif
        },
        sleep: { duration in try await Task.sleep(for: duration) }
    )
}

private struct UserFeedbackDeliveryEffectsKey: EnvironmentKey {
    static let defaultValue = UserFeedbackDeliveryEffects.live
}

extension EnvironmentValues {
    var feedbackDeliveryEffects: UserFeedbackDeliveryEffects {
        get { self[UserFeedbackDeliveryEffectsKey.self] }
        set { self[UserFeedbackDeliveryEffectsKey.self] = newValue }
    }
}
