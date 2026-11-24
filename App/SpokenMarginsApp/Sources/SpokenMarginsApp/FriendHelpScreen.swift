import SessionKit
import SwiftUI

/// The questions someone a friend sent Margins to asks, each with its short answer (#5268). The words are
/// `FriendHelpTopic`'s; the site's `friends/` page asks the same questions. It reads no model and loads nothing, so
/// it opens offline and over anything, including a recording or an import waiting underneath.
struct FriendHelpSection: View {
    /// The question to move VoiceOver to once its row is on screen; `nil` leaves focus where the screen puts it.
    let focus: FriendHelpTopic?

    @AccessibilityFocusState private var focused: FriendHelpTopic?
    @State private var hasFocused = false

    var body: some View {
        Section("A Friend Sent You Margins") {
            ForEach(FriendHelpTopic.allCases) { topic in
                VStack(alignment: .leading, spacing: 6) {
                    Text(topic.question)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($focused, equals: topic)
                        .accessibilityIdentifier("help.friend.\(topic.rawValue)")
                    Text(topic.appAnswer)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .id(topic)
                .onAppear {
                    guard topic == focus, !hasFocused else { return }
                    hasFocused = true
                    // The row comes on screen as the list scrolls to it; focus is set a turn later, once it is laid out,
                    // as the failure sheet's headline does.
                    Task { @MainActor in
                        await Task.yield()
                        focused = topic
                    }
                }
            }
        }
    }
}

/// The friend help on its own, as a sheet over the screen where a friend's link, file or episode got stuck. It opens
/// at the question that screen raises, and Done returns to that screen as it was.
struct FriendHelpScreen: View {
    let focus: FriendHelpTopic?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    FriendHelpSection(focus: focus)
                }
                .onAppear {
                    guard let focus else { return }
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(focus, anchor: .top)
                    }
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("friendHelp.done")
                }
            }
            .accessibilityIdentifier("friendHelp.screen")
        }
    }
}

/// "Get Help" under a stuck screen's own buttons: plain, in the accent colour, the shape of the failure sheet's
/// "Report this link".
struct FriendHelpButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Get Help").frame(maxWidth: .infinity).minimumTapTarget()
        }
    }
}
