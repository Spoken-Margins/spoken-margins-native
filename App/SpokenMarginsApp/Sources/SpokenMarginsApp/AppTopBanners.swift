import SwiftUI
import SessionKit

/// One stable delivery owner, outside the root's changing screens and passive banner copies.
@MainActor
struct AppFeedbackPresentation: ViewModifier {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.feedbackDeliveryEffects) private var effects

    func body(content: Content) -> some View {
        let event = model.recordingNavigationIsLocked ? nil : model.feedbackEvent
        content
            .safeAreaInset(edge: .top, spacing: 8) { StickyTopBanners() }
            .overlay(alignment: .top) { FloatingFeedbackBanner() }
            .task(id: event?.id) { @MainActor in
                guard let event else { return }
                await deliver(event)
            }
    }

    private func deliver(_ event: UserFeedbackEvent) async {
        // A VoiceOver listener hears that the banner holds a button, not only its message (#784).
        let announcement = event.action.map { "\(event.message) \($0.title) is available." } ?? event.message
        effects.announce(announcement)
        guard let seconds = FeedbackBannerPolicy.autoDismissSeconds(
            for: event.kind,
            offersAction: event.action != nil
        ) else { return }
        do {
            try await effects.sleep(.seconds(seconds))
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
/// Neither banner shows an event that the Now screen draws as the tag under its title (#430).
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

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer()
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
    let undo: TrashUndoState

    var body: some View {
        HStack(spacing: 12) {
            Text("Moved \(undo.title) to Recently Deleted")
                .font(.subheadline)
                .lineLimit(2)
            Spacer()
            Button("Undo", action: model.undoLastTrash)
                .font(.subheadline.bold())
            Button(action: model.dismissTrashUndo) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("trash.undo.banner")
    }
}
