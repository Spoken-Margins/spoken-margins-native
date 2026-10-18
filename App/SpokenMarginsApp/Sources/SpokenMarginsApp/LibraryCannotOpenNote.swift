import SwiftUI
import SessionKit

/// The Library tab's body when this build can't open the listener's existing Library (#1969): the Library is safe,
/// don't delete the app, update. Try again reopens it; the technical reason sits under Details.
struct LibraryCannotOpenNote: View {
    let note: LibraryAccessNote
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(LibraryAccessNote.title, systemImage: "lock.shield")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.text)
                .accessibilityAddTraits(.isHeader)
            Text(LibraryAccessNote.message)
                .font(.body)
                .foregroundStyle(AppColors.text)
            Button("Try again", action: retry)
                .filledActionButton()
                .accessibilityIdentifier("library.cannotOpen.retry")
            DisclosureGroup("Details") {
                Text(note.detail)
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("library.cannotOpen.details")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.cannotOpen")
    }
}
