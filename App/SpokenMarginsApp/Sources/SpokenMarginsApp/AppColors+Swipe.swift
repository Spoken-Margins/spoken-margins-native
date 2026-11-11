import SwiftUI
import SessionKit

/// The fixed tints of the swipe buttons (#4045). iOS draws a swipe button's words in white in both appearances, so the
/// tint must not turn light in dark mode. They live here, not in `AppColors` itself, so the hot file `Gate1RootView.swift`
/// does not grow; every value still comes from `AppSemanticColorRGB`, where the audit measures white on each one.
extension AppColors {
    static let swipeEvergreen = dynamicColor(AppSemanticColorRGB.swipeEvergreen)
    static let swipeOchre = dynamicColor(AppSemanticColorRGB.swipeOchre)
    static let swipePlum = dynamicColor(AppSemanticColorRGB.swipePlum)
    static let swipeSlate = dynamicColor(AppSemanticColorRGB.swipeSlate)
}
