import SwiftUI
import SessionKit

/// The senders and the single Margins this listener has hidden, each with a way to show them again (#2846). Each list
/// appears only once something is hidden, so a listener who never hides anything never sees it. Showing a sender again
/// brings every Margin back; showing a Margin again brings back only that one.
struct HiddenSendersSettingsSection: View {
    @ObservedObject var hidden: HiddenSendersController
    let showAgain: (String) -> Void
    let showMarginAgain: (String) -> Void

    var body: some View {
        if !hidden.current.entries.isEmpty {
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
        if !hidden.current.margins.isEmpty {
            Section {
                ForEach(hidden.current.listedMargins) { margin in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FriendArrivalWords.hiddenMarginName(margin))
                                .foregroundStyle(AppColors.text)
                                .lineLimit(3)
                            Text("\(FriendArrivalWords.hiddenMarginSender(margin)) · hidden \(margin.hiddenAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        Spacer(minLength: 12)
                        Button("Show again") { showMarginAgain(margin.marginId) }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Show the Margin \(FriendArrivalWords.hiddenMarginName(margin)) again")
                            .accessibilityIdentifier("settings.hiddenMargins.\(margin.marginId).show")
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text("Hidden Margins")
            } footer: {
                Text("These Margins are kept on this phone but not shown or played. Show again brings one back.")
            }
        }
    }
}
