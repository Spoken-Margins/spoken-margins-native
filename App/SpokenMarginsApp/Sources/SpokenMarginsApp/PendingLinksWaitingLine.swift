import SwiftUI
import SessionKit

/// One plain line while shared links wait for a connection, e.g. "1 link waiting for a connection" (#1546).
/// The icon backs up the words; nothing rests on colour.
struct PendingLinksWaitingLine: View {
    let count: Int

    var body: some View {
        if let line = PendingHandoffRetryPolicy.waitingLine(count: count) {
            Label(line, systemImage: "wifi.slash")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityIdentifier("library.linksWaitingForConnection")
        }
    }
}
