import Foundation

/// The message Settings > Share beta instructions hands to the share sheet (#1770).
///
/// A tester who already has the beta can pass it to a friend. The message is a constant: it carries no Library data,
/// no listener name and no build number, and the only link in it is the join page. The page owns the TestFlight
/// invitation, so the app never carries an invitation URL of its own and the page can change it.
///
/// The words follow the page's own steps ("tap step 2"), so a friend gets one instruction for the moment after
/// TestFlight installs, not two. The row that shows this is only right while the app is distributed through
/// TestFlight; it is removed before the first App Store build (the follow-up issue on #1770 tracks that).
public enum BetaInviteShare {
    /// The one link in the message.
    public static let joinURL = "https://spokenmargins.com/join"

    /// The share message, plain text. No image is attached: the link's preview supplies the card.
    public static let text = """
        Try Spoken Margins with me. It's a listening app where you talk back to what you hear.

        It's in beta, so it comes through Apple's TestFlight app. Open the link and follow the three steps. The trick: after TestFlight installs, go back to that page and tap step 2.

        Already have TestFlight? Skip to step 2. Seeing "Redeem"? You don't need a code. Go back to the page and tap step 2.

        \(joinURL)
        """
}
