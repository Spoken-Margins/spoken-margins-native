import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// `withAnimation` that does nothing but run the body while Reduce Motion is on (#1928). The Timeline
/// follows playback with a scroll on every entry change, so an animated scroll there repeats all session.
func withMotion<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    #if canImport(UIKit)
    if UIAccessibility.isReduceMotionEnabled { return try body() }
    #endif
    return try withAnimation(animation, body)
}

private struct MotionAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct ReduceMotionTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let transition: AnyTransition

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}

private struct NumericTextTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText())
    }
}

extension View {
    /// `.animation(_:value:)` that is off under Reduce Motion.
    func motionAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }

    /// A transition that becomes a plain fade under Reduce Motion, so a screen doesn't slide in.
    func motionTransition(_ transition: AnyTransition) -> some View {
        modifier(ReduceMotionTransition(transition: transition))
    }

    /// `.contentTransition(.numericText())` that is off under Reduce Motion.
    func numericTextTransition() -> some View {
        modifier(NumericTextTransition())
    }
}
