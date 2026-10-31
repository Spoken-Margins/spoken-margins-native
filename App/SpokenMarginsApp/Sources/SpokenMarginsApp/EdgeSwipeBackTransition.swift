import SwiftUI
import UIKit
import SessionKit

/// The edge swipe back to Library (#106): the screen slides with the finger and Library is drawn
/// underneath, dimmed. Nothing is navigated until a release commits (`EdgeSwipeBackRule`); a cancelled
/// drag springs back and leaves the screen, the selected item and playback untouched.
///
/// The gesture only takes touches that start in a 32 pt strip below the navigation bar, so it never competes
/// with the scrubber (Build 26, #84). It is a UIKit pan recognizer on the whole screen that leaves touches
/// alone (`EdgePanGesture`), not a view over the strip: a view over the strip took every tap there and left
/// the leading 6 pt of the Now button dead (#2917). The recognizer is not part of what moves, so the finger
/// keeps it.
private struct EdgeSwipeBackModifier<Underlay: View>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let enabled: Bool
    /// Asked again when the screen has finished moving, in case a Margin started recording meanwhile.
    let canCommit: () -> Bool
    let action: () -> Void
    let underlay: () -> Underlay

    @State private var tracker = EdgeSwipeBackTracker()
    /// The whole screen's width. The commit rule measures against this, not against the 32 pt strip.
    @State private var width: CGFloat = 0
    /// The moving screen's opacity: only Reduce Motion changes it, to cross-fade instead of slide.
    @State private var fade = 1.0
    /// Bumped by every reset, so a finished animation from an earlier swipe can't reset a newer one.
    @State private var generation = 0

    /// 0 to 1: how much of Library shows through, from the drag, or from the fade under Reduce Motion.
    private var revealed: Double {
        reduceMotion ? 1 - fade : EdgeSwipeBackRule.progress(horizontal: tracker.offset, containerWidth: Double(width))
    }

    private var showsUnderlay: Bool { reduceMotion ? fade < 1 : tracker.showsUnderlay }

    func body(content: Content) -> some View {
        content
            .opacity(fade)
            .offset(x: tracker.offset)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background {
                if showsUnderlay {
                    ZStack {
                        // The status-bar and home-indicator bands the moving screen uncovers.
                        AppColors.background.ignoresSafeArea()
                        underlay()
                            .environment(\.isEdgeSwipePreview, true)
                            .offset(x: reduceMotion ? 0 : -width * 0.25 * CGFloat(1 - revealed))
                    }
                    .overlay { Color.black.opacity(0.22 * (1 - revealed)).ignoresSafeArea() }
                    .transition(.identity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .gesture(EdgePanGesture(enabled: enabled, stripWidth: Self.stripWidth, topClearance: Self.topClearance) { handle($0) })
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled { resetImmediately() }
            }
            .onDisappear { resetImmediately() }
    }

    /// The strip's width, and how far below the top safe area it starts. Native back buttons can overlap the
    /// leading edge on iOS 18, so the strip stays below the navigation bar and those buttons get ordinary taps.
    private static var stripWidth: CGFloat { 32 }
    private static var topClearance: CGFloat { 64 }

    private func handle(_ event: EdgePanGesture.Event) {
        switch event {
        case let .moved(translation):
            tracker.changed(
                horizontal: translation.width,
                vertical: translation.height,
                containerWidth: Double(width),
                followsFinger: !reduceMotion
            )
        case let .ended(translation, velocity):
            guard let outcome = tracker.ended(
                horizontal: translation.width,
                vertical: translation.height,
                velocity: velocity,
                containerWidth: Double(width)
            ) else { return }
            finish(outcome)
        case .cancelled:
            // The system took the touch away without ending it: go back as if the drag was abandoned.
            guard tracker.phase == .dragging else { return }
            _ = tracker.ended(horizontal: tracker.offset, vertical: 0, velocity: 0, containerWidth: Double(width))
            finish(.cancel)
        }
    }

    /// Carries out a release from wherever the screen is now.
    private func finish(_ outcome: EdgeSwipeBackRule.Outcome) {
        let containerWidth = Double(width)
        switch (outcome == .commit && canCommit() ? EdgeSwipeBackRule.Outcome.commit : .cancel, reduceMotion) {
        case (.commit, false):
            let remaining = 1 - revealed
            withAnimation(.easeOut(duration: 0.12 + 0.18 * remaining)) {
                tracker.settle(.commit, containerWidth: containerWidth)
            } completion: { [generation] in
                complete(generation)
            }
        case (.commit, true):
            withAnimation(.easeInOut(duration: 0.18)) { fade = 0 } completion: { [generation] in complete(generation) }
        case (.cancel, false) where tracker.offset > 0:
            withAnimation(.spring(duration: 0.3, bounce: 0)) {
                tracker.settle(.cancel, containerWidth: containerWidth)
            } completion: { [generation] in
                resetImmediately(ifGeneration: generation)
            }
        case (.cancel, _):
            resetImmediately()
        }
    }

    /// The screen has left the display: go to Library, with the moving screen put back first so the next
    /// screen doesn't appear already pushed off to the side.
    private func complete(_ startedIn: Int) {
        guard startedIn == generation, tracker.phase == .settling else { return }
        guard canCommit() else {
            // A Margin started recording while the screen was moving away: stay where we were.
            withAnimation(.spring(duration: 0.3, bounce: 0)) {
                tracker.settle(.cancel, containerWidth: Double(width))
                fade = 1
            } completion: { [generation] in
                resetImmediately(ifGeneration: generation)
            }
            return
        }
        resetImmediately()
        action()
    }

    private func resetImmediately(ifGeneration expected: Int? = nil) {
        if let expected, expected != generation { return }
        generation += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            tracker.reset()
            fade = 1
        }
    }
}

/// A pan recognizer for the edge swipe. It receives a touch only if it starts inside the strip, never cancels
/// the touch for the views under it, and only runs alongside a scroll view's pan, so a tap or a drag that the
/// control under the finger wants still reaches it (#2917) and the scrubber keeps its own drags (#84).
private struct EdgePanGesture: UIGestureRecognizerRepresentable {
    enum Event {
        case moved(translation: CGSize)
        case ended(translation: CGSize, velocity: Double)
        case cancelled
    }

    /// DragGesture's old minimum distance: smaller movements are taps and wobble, not the start of a swipe.
    private static let minimumDistance: CGFloat = 18

    let enabled: Bool
    let stripWidth: CGFloat
    let topClearance: CGFloat
    let send: (Event) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(enabled: enabled, stripWidth: stripWidth, topClearance: topClearance)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
        context.coordinator.enabled = enabled
        context.coordinator.stripWidth = stripWidth
        context.coordinator.topClearance = topClearance
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Window coordinates (`nil`): the view the recognizer sits on moves with the screen while it follows the finger.
        let point = recognizer.translation(in: nil)
        let translation = CGSize(width: point.x, height: point.y)
        switch recognizer.state {
        case .began, .changed:
            guard hypot(point.x, point.y) >= Self.minimumDistance else { return }
            send(.moved(translation: translation))
        case .ended:
            send(.ended(translation: translation, velocity: Double(recognizer.velocity(in: nil).x)))
        case .cancelled, .failed:
            send(.cancelled)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled: Bool
        var stripWidth: CGFloat
        var topClearance: CGFloat

        init(enabled: Bool, stripWidth: CGFloat, topClearance: CGFloat) {
            self.enabled = enabled
            self.stripWidth = stripWidth
            self.topClearance = topClearance
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard enabled, let window = gestureRecognizer.view?.window else { return false }
            let point = touch.location(in: nil)
            return point.x >= 0 && point.x < stripWidth && point.y >= window.safeAreaInsets.top + topClearance
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other.view is UIScrollView
        }
    }
}

extension View {
    /// Swipe in from the leading edge to go back to Library. `underlay` draws what the moving screen
    /// reveals; it is built only while a swipe is under way and is never interactive or read by VoiceOver.
    func edgeSwipeBack<Underlay: View>(
        enabled: Bool,
        canCommit: @escaping () -> Bool,
        action: @escaping () -> Void,
        @ViewBuilder underlay: @escaping () -> Underlay
    ) -> some View {
        modifier(EdgeSwipeBackModifier(enabled: enabled, canCommit: canCommit, action: action, underlay: underlay))
    }
}

extension AppNavigationState {
    /// Library as the swipe will land on it: the same tab and scroll position, with no sheet or task over it.
    var edgeSwipePreview: AppNavigationState {
        var preview = self
        preview.addSourceRoute = nil
        preview.taskRoute = nil
        return preview
    }
}

extension EnvironmentValues {
    /// True inside the Library drawn under a swipe (#106), so the preview starts no fetch, refresh or
    /// pasteboard check: a swipe that may not navigate does not act for the listener.
    @Entry var isEdgeSwipePreview = false
}
