import Foundation

// Consent before the phone first sends anything of the listener's to Spoken Margins' server (#2842, Apple agreement
// 3.3.3). Plain requests that every listener makes the same way (the tour, the starter list, the kill-switch config)
// are not covered: they carry no library data and no identifier. A send that carries the listener's own words or
// audio is, and so is anything that creates the per-install App Attest key: that key is made only after the listener
// has agreed here, never before (research/B4/DESIGN.md section 7).
//
// The record is a version number per feature. When what a feature sends changes, `disclosureVersion` goes up, the old
// record no longer counts, and the listener is asked again with the new words. The record lives in the app's
// UserDefaults, so deleting the app deletes it, and a reinstall asks again.

public enum ServerSendFeature: String, CaseIterable, Sendable {
    /// "Share as link" (#487): the sealed packet and preview go to our server.
    case shareLinks = "share-links"
    /// Starting or joining a club (#1799): the sealed club name, and each post's sealed packet, go to our server.
    /// No club screen asks for this yet; the words are `ClubConsentCopy`.
    case clubs = "clubs"
}

public enum ServerSendConsent {
    /// Bump when the words below, or what the feature sends, change in a way a listener who already agreed would
    /// want to read again. Every feature shares the number, so a bump asks everyone once more.
    public static let disclosureVersion = 3

    /// Version 3 added the opened-marks paragraph (#5275). Version 4 (#4675) adds the answers paragraph too, in a build
    /// whose links carry a reply box (`SM_LINK_REPLIES`, which the app reads and passes as `repliesOffered`). A build
    /// without reply boxes keeps version 3 and its words. The two must differ, or agreeing to the words without answers
    /// would count as agreeing to answers.
    public static let repliesDisclosureVersion = 4

    /// The version the words shown in this build carry.
    public static func disclosureVersion(repliesOffered: Bool) -> Int {
        repliesOffered ? repliesDisclosureVersion : disclosureVersion
    }

    private static func key(for feature: ServerSendFeature) -> String {
        "serverSendConsent.\(feature.rawValue).version"
    }

    public static func hasConsented(
        to feature: ServerSendFeature, repliesOffered: Bool = false, in defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: key(for: feature)) as? Int == disclosureVersion(repliesOffered: repliesOffered)
    }

    public static func record(_ feature: ServerSendFeature, repliesOffered: Bool = false, in defaults: UserDefaults = .standard) {
        defaults.set(disclosureVersion(repliesOffered: repliesOffered), forKey: key(for: feature))
    }

    public static func withdraw(_ feature: ServerSendFeature, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: feature))
    }
}

/// What the listener reads before the first share link. Drafted from `docs/legal/privacy-policy-draft.md` (row 14)
/// and D15, D16 and D20 in `docs/legal/attorney-questions.md`; the owner's wording replaces it (#2842). It says only
/// what the code does today. Version 2 (#2239) adds the App Attest code and the tie from a link to its install;
/// version 3 (#5275) adds the opened mark a friend's browser or app sends when they open the Margins.
/// When the code starts to send more, the words change in the same PR and `ServerSendConsent.disclosureVersion`
/// goes up. "30 days" is the server's
/// retention (D4, `research/B4/DESIGN.md`); the app only passes the server's `expiresAt` through, so a change there
/// needs the same edit and bump here.
/// The 90-day sentence follows `research/B4/server/internal/senders/senders.go` `Sweep`: install records go after 90
/// idle days, but a sender with a strike keeps a file and a blocked install's tag stays on the block list.
public enum ShareLinkConsentCopy {
    public static let title = "Share as a link?"
    public static let message = """
        A link puts your Margins on our server so your friend can open them in a browser. Before anything leaves \
        your phone, the Margins, their audio and text, a short excerpt of the source around each one, the source's \
        title and address, and the sender name if you typed one are locked with a key that is only in the link. We can't read them. Anyone who has the link \
        can. The link stops working after 30 days.

        When your friend opens the Margins, their browser or app tells our server the link was opened, and your \
        app shows "Opened". Nothing else is kept, and it is deleted with the link. Either of you can turn this \
        off in Settings.

        To make a link, your phone also makes a random code for this app. Our server uses it to check that the \
        request comes from Spoken Margins, and to tie each link to this install so a report of a link can be \
        counted. The code holds no name. Deleting the app deletes your phone's copy. Our server deletes the code \
        after 90 days without use, unless links made with it were reported: then it keeps a note of that, which \
        also holds no name.

        You can send the file instead. It goes straight to your friend and never touches our server.
        """
    public static let accept = "Share as Link"
    public static let decline = "Not Now"

    /// The paragraph a build with reply boxes adds after the first one (#4675, screen A).
    public static let answersParagraph = """
        Your friend can answer through the link. Their answers are locked the same way, wait on our server until your \
        phone collects them or the link ends, and only your phone can open them.
        """

    /// The words for this build: `message`, with the answers paragraph after its first paragraph when links carry a
    /// reply box. Shown with `ServerSendConsent.disclosureVersion(repliesOffered:)`.
    public static func message(repliesOffered: Bool) -> String {
        guard repliesOffered else { return message }
        var paragraphs = message.components(separatedBy: "\n\n")
        paragraphs.insert(answersParagraph, at: min(1, paragraphs.count))
        return paragraphs.joined(separator: "\n\n")
    }
}

/// What the listener reads before they first start or join a club (#1799, `docs/design/club-mailbox.md` sections 2, 3, 6
/// and 8). Drafted from the design note, so it says what the server stores and what a club cannot do; the owner's
/// wording replaces it, and it is not shown until the club screens ship (slice 5). When the code starts to send
/// more, the words change in the same PR and `ServerSendConsent.disclosureVersion` goes up. "90 days" is the
/// server's idle expiry for a club (section 3); "when you open the app" is design section 6, which has no background
/// polling and no push. Unlike a share link, a club makes no App Attest code for the phone: club requests carry no
/// install identity (section 5), so this alert does not mention one.
public enum ClubConsentCopy {
    public static let title = "Start or join a club?"
    public static let message = """
        A club is a box on our server that you and your friends share. Whoever starts a club sends its name and \
        the name they chose for themselves. Everyone who posts sends each Margin with its audio and text, a short \
        excerpt of the source, the source's title and address, and a random code made on your phone for that \
        club, in the same kind of packet as a file. All of it is locked on your phone with a key that is only in \
        the invite link. We can't read it, except in one case: if someone reports the club as abuse material, \
        the report carries the whole link and we keep it for a year.

        Anyone who has the link can read the club, from its first post, and post to it. A post can't be taken \
        back, and there is no way to take someone out: you start a new club.

        Our server keeps no list of members and no names, and your phone makes no code of its own for a club. \
        Each time your phone looks at a club, the server sees the club's number and a proof that you have the \
        link. It also sees how big each post is, their order and the day the club was last used. Like any \
        website, it sees your network address, scrambled and kept only in memory, for up to an hour. It deletes \
        a club after 90 days with no post and no visit, or after 7 days if nobody has posted.

        Your phone looks for new posts when you open the app or pull to refresh, not in the background.

        You can send a friend the file instead. It goes straight to them and never touches our server.
        """
    public static let accept = "Continue"
    public static let decline = "Not Now"
}
