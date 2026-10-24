import SwiftUI
import SessionKit

/// The edge swipe back to Library (#106): the screen slides with the finger and Library is drawn
/// underneath, dimmed. Nothing is navigated until a release commits (`EdgeSwipeBackRule`); a cancelled
/// drag springs back and leaves the screen, the selected item and playback untouched.
///
/// The gesture stays confined to a 32 pt strip below the navigation bar so it never competes with the
/// scrubber (Build 26, #84). The strip is not part of what moves, so the finger keeps its recognizer.
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
    @GestureState private var isTouching = false

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
                    underlay()
                        .offset(x: reduceMotion ? 0 : -width * 0.25 * CGFloat(1 - revealed))
                        .overlay { Color.black.opacity(0.22 * (1 - revealed)) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .leading) {
                if enabled { edgeStrip }
            }
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled { resetImmediately() }
            }
            .onChange(of: isTouching) { _, touching in
                // The system took the touch away without ending it: go back as if the drag was abandoned.
                guard !touching, tracker.phase == .dragging else { return }
                _ = tracker.ended(horizontal: tracker.offset, vertical: 0, velocity: 0, containerWidth: Double(width))
                finish(.cancel)
            }
            .onDisappear { resetImmediately() }
    }

    private var edgeStrip: some View {
        // Attach recognition only to the edge. A gesture on the entire screen competes with slider
        // tracking even when its action later rejects a drag that started away from the edge.
        GeometryReader { geometry in
            // Native back buttons can overlap the leading edge on iOS 18. Keep the gesture below the
            // navigation bar so those buttons receive ordinary center taps.
            let topClearance = geometry.safeAreaInsets.top + 64
            Color.clear
                .frame(width: 32, height: max(0, geometry.size.height - topClearance))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 18, coordinateSpace: .global)
                        .updating($isTouching) { _, state, _ in state = true }
                        .onChanged { value in
                            tracker.changed(
                                horizontal: value.translation.width,
                                vertical: value.translation.height,
                                containerWidth: Double(width),
                                followsFinger: !reduceMotion
                            )
                        }
                        .onEnded { value in
                            guard let outcome = tracker.ended(
                                horizontal: value.translation.width,
                                vertical: value.translation.height,
                                velocity: value.velocity.width,
                                containerWidth: Double(width)
                            ) else { return }
                            finish(outcome)
                        }
                )
                .offset(y: topClearance)
                .accessibilityHidden(true)
        }
        .frame(width: 32)
    }

    /// Carries out a release from wherever the screen is now.
    private func finish(_ outcome: EdgeSwipeBackRule.Outcome) {
        let containerWidth = Double(width)
        switch (outcome == .commit && canCommit() ? EdgeSwipeBackRule.Outcome.commit : .cancel, reduceMotion) {
        case (.commit, false):
            let remaining = 1 - revealed
            withAnimation(.easeOut(duration: 0.12 + 0.18 * remaining)) {
                tracker.settle(.commit, containerWidth: containerWidth)
            } completion: {
                complete()
            }
        case (.commit, true):
            withAnimation(.easeInOut(duration: 0.18)) { fade = 0 } completion: { complete() }
        case (.cancel, false) where tracker.offset > 0:
            withAnimation(.spring(duration: 0.3, bounce: 0)) {
                tracker.settle(.cancel, containerWidth: containerWidth)
            } completion: {
                resetImmediately()
            }
        case (.cancel, _):
            resetImmediately()
        }
    }

    /// The screen has left the display: go to Library, with the moving screen put back first so the next
    /// screen doesn't appear already pushed off to the side.
    private func complete() {
        guard tracker.phase == .settling else { return }
        guard canCommit() else {
            // A Margin started recording while the screen was moving away: stay where we were.
            withAnimation(.spring(duration: 0.3, bounce: 0)) {
                tracker.settle(.cancel, containerWidth: Double(width))
                fade = 1
            } completion: {
                resetImmediately()
            }
            return
        }
        resetImmediately()
        action()
    }

    private func resetImmediately() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            tracker.reset()
            fade = 1
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
