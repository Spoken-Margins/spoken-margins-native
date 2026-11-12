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
}

public enum ServerSendConsent {
    /// Bump when the words below, or what the feature sends, change in a way a listener who already agreed would
    /// want to read again. Every feature shares the number, so a bump asks everyone once more.
    public static let disclosureVersion = 2

    private static func key(for feature: ServerSendFeature) -> String {
        "serverSendConsent.\(feature.rawValue).version"
    }

    public static func hasConsented(to feature: ServerSendFeature, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(for: feature)) as? Int == disclosureVersion
    }

    public static func record(_ feature: ServerSendFeature, in defaults: UserDefaults = .standard) {
        defaults.set(disclosureVersion, forKey: key(for: feature))
    }

    public static func withdraw(_ feature: ServerSendFeature, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: feature))
    }
}

/// What the listener reads before the first share link. Drafted from `docs/legal/privacy-policy-draft.md` (row 14)
/// and D15, D16 and D20 in `docs/legal/attorney-questions.md`; the owner's wording replaces it (#2842). It says only
/// what the code does today. Version 2 (#2239) adds the App Attest code and the tie from a link to its install.
/// When the code starts to send more, the words change in the same PR and `ServerSendConsent.disclosureVersion`
/// goes up. "30 days" is the server's
/// retention (D4, `research/B4/DESIGN.md`); the app only passes the server's `expiresAt` through, so a change there
/// needs the same edit and bump here.
public enum ShareLinkConsentCopy {
    public static let title = "Share as a link?"
    public static let message = """
        A link puts your Margins on our server so your friend can open them in a browser. Before anything leaves \
        your phone, the Margins, their audio and text, a short excerpt of the source around each one, the source's \
        title and address, and the sender name if you typed one are locked with a key that is only in the link. We can't read them. Anyone who has the link \
        can. The link stops working after 30 days.

        To make a link, your phone also makes a random code for this app. Our server uses it to check that the \
        request comes from Spoken Margins, and to tie each link to this install so a report of a link can be \
        counted. The code holds no name. It is deleted with the app.

        You can send the file instead. It goes straight to your friend and never touches our server.
        """
    public static let accept = "Share as Link"
    public static let decline = "Not Now"
}
