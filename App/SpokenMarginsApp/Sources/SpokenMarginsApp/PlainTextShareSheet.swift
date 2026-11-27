import SwiftUI

/// One plain line handed to the iOS share sheet, for "Let Cole know" on the caught-up card (#4785). No link, no file
/// and no app name: the listener picks Messages or any app, and the app sends nothing itself. The other share sheets
/// take files (`ShareFilePresenter`) or a link (`ShareLinkActivityView`), so this is its own small wrapper.
struct PlainTextShare: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

#if canImport(UIKit)
struct PlainTextShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
struct PlainTextShareSheet: View {
    let text: String
    var body: some View { Text(text).textSelection(.enabled).padding() }
}
#endif
