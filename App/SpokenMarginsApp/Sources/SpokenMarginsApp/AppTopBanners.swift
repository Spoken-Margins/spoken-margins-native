import SwiftUI
import SessionKit

/// One stable delivery owner, outside the root's changing screens and passive banner copies.
@MainActor
struct AppFeedbackPresentation: ViewModifier {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.feedbackDeliveryEffects) private var effects
    @State private var hold = FeedbackBannerHold()

    func body(content: Content) -> some View {
        let event = model.recordingNavigationIsLocked ? nil : model.feedbackEvent
        content
            .safeAreaInset(edge: .top, spacing: 8) { StickyTopBanners().environment(\.feedbackBannerHold, hold) }
            .overlay(alignment: .top) { FloatingFeedbackBanner().environment(\.feedbackBannerHold, hold) }
            .task(id: event?.id) { @MainActor in
                guard let event else { return }
                await deliver(event)
            }
    }

    private func deliver(_ event: UserFeedbackEvent) async {
        // A VoiceOver listener hears that the banner holds a button, not only its message (#784).
        let announcement = event.action.map { "\(event.message) \($0.title) is available." } ?? event.message
        effects.announce(announcement)
        // A touch from the previous banner can't carry over; VoiceOver focus stays where it is.
        hold.setTouched(false)
        guard let seconds = FeedbackBannerPolicy.autoDismissSeconds(
            for: event.kind,
            offersAction: event.action != nil,
            assistiveTechnologyRunning: effects.assistiveTechnologyRunning()
        ) else { return }
        do {
            try await effects.sleep(.seconds(seconds))
            // A listener still touching the banner, or with VoiceOver on it, keeps it (#1927).
            // At most 30 more seconds, so a touch that SwiftUI never reports as ended can't keep it forever.
            var heldSeconds = 0
            while hold.isHeld, heldSeconds < 30 {
                try await effects.sleep(.seconds(1))
                heldSeconds += 1
            }
            try Task.checkCancellation()
            model.dismissFeedback(id: event.id)
        } catch {}
    }
}

/// The banners above the app's content.
///
/// Anything the listener can't miss keeps its place and moves the content below it: an error that
/// stays until they act on it (#310), an import in progress, and the Undo
/// for a deleted item. A confirmation or warning dismisses itself, so it floats over the content
/// instead. Rows under a thumb must not move when it appears, goes away or is undone (#1149).
struct StickyTopBanners: View {
    @EnvironmentObject private var model: Gate1AppModel

    private var errorFeedback: UserFeedbackEvent? {
        guard let event = model.feedbackEvent, event.kind == .error, model.playbackFeedbackTag == nil else { return nil }
        return event
    }

    var body: some View {
        if !model.recordingNavigationIsLocked,
           errorFeedback != nil || model.trashUndo != nil || model.sourceImportProgressMessage != nil {
            VStack(spacing: 8) {
                if let progressMessage = model.sourceImportProgressMessage {
                    SourceOperationBanner(message: progressMessage)
                }
                if let feedback = errorFeedback {
                    UserFeedbackBanner(feedback: feedback)
                }
                if let undo = model.trashUndo {
                    TrashUndoBanner(undo: undo)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
    }
}

/// A confirmation or warning, drawn over the content below the navigation bar where an error would sit.
/// Neither banner shows an event that the playback screen draws as its one-line tag (#430).
struct FloatingFeedbackBanner: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        if !model.recordingNavigationIsLocked,
           let feedback = model.feedbackEvent, feedback.kind != .error, model.playbackFeedbackTag == nil {
            UserFeedbackBanner(feedback: feedback)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }
    }
}

struct SourceOperationBanner: View {
    let message: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the hint drops under the message instead of squeezing it (#1935).
        let large = dynamicTypeSize.isAccessibilitySize
        (large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 10))) {
            HStack(spacing: 10) {
                ProgressView()
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(large ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if !large { Spacer() }
            }
            Text("You can keep listening")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
        }
        .padding(12)
        .foregroundStyle(AppColors.text)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sourceImport.progress.banner")
    }
}

struct TrashUndoBanner: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let undo: TrashUndoState

    var body: some View {
        // At accessibility sizes the buttons take their own row under the title (#1935).
        let large = dynamicTypeSize.isAccessibilitySize
        (large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))) {
            Text("Moved \(undo.title) to Recently Deleted")
                .font(.subheadline)
                .lineLimit(large ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if !large { Spacer() }
            HStack(spacing: 12) {
                // Undo and Dismiss each get a 44 pt hit area, with room between them (#1926).
                Button(action: model.undoLastTrash) {
                    Text("Undo")
                        .font(.subheadline.bold())
                        .minimumTapTarget()
                }
                .accessibilityIdentifier("trash.undo.button")
                Button(action: model.dismissTrashUndo) {
                    TapTargetIcon(systemName: "xmark")
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("trash.undo.banner")
    }
}
