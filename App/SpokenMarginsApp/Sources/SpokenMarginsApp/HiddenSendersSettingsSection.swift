import SwiftUI
import SessionKit

/// The senders this listener has hidden, each with a way to show them again (#2846). It appears only once someone is
/// hidden, so a listener who never hides anyone never sees it. Showing a sender again brings every Margin back.
struct HiddenSendersSettingsSection: View {
    @ObservedObject var hidden: HiddenSendersController
    let showAgain: (String) -> Void

    var body: some View {
        if !hidden.isEmpty {
            Section {
                ForEach(hidden.current.listed) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FriendArrivalWords.hiddenSenderName(entry.displayLabel))
                                .foregroundStyle(AppColors.text)
                            Text("Hidden \(entry.hiddenAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        Spacer(minLength: 12)
                        Button("Show again") { showAgain(entry.senderId) }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Show \(FriendArrivalWords.hiddenSenderName(entry.displayLabel)) again")
                            .accessibilityIdentifier("settings.hiddenSenders.\(entry.senderId).show")
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text("Hidden senders")
            } footer: {
                Text("Their Margins are kept on this phone but not shown or played. Show again brings them all back.")
            }
        }
    }
}
