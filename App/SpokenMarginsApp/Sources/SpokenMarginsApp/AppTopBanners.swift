import SwiftUI

/// The banners above the app's content.
///
/// Anything the listener can't miss keeps its place and moves the content below it: an error that
/// stays until they act on it (#310), the Library reset notice, an import in progress, and the Undo
/// for a deleted item. A confirmation or warning dismisses itself, so it floats over the content
/// instead. Rows under a thumb must not move when it appears, goes away or is undone (#1149).
struct StickyTopBanners: View {
    @EnvironmentObject private var model: Gate1AppModel

    private var errorFeedback: UserFeedbackEvent? {
        guard let event = model.feedbackEvent, event.kind == .error else { return nil }
        return event
    }

    var body: some View {
        if !model.recordingNavigationIsLocked,
           errorFeedback != nil || model.trashUndo != nil || model.sourceImportProgressMessage != nil || model.legacyLibraryResetNotice != nil {
            VStack(spacing: 8) {
                if let resetNotice = model.legacyLibraryResetNotice {
                    LegacyLibraryResetBanner(message: resetNotice)
                }
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
struct FloatingFeedbackBanner: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        if !model.recordingNavigationIsLocked,
           let feedback = model.feedbackEvent, feedback.kind != .error {
            UserFeedbackBanner(feedback: feedback)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }
    }
}

struct LegacyLibraryResetBanner: View {
    @EnvironmentObject private var model: Gate1AppModel
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .foregroundStyle(AppColors.secondaryText)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: model.dismissLegacyLibraryResetNotice) {
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss library notice")
        }
        .padding(12)
        .foregroundStyle(AppColors.text)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
        .accessibilityIdentifier("libraryReset.notice.banner")
        .task {
            do {
                try await Task.sleep(for: .seconds(8))
                guard model.legacyLibraryResetNotice == message else { return }
                model.dismissLegacyLibraryResetNotice()
            } catch {
                // The banner disappeared or changed before its auto-dismiss timer fired.
            }
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
