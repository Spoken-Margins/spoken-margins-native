import Foundation
import SessionKit

enum AppLinks {
    static var privacy: URL {
        URL(string: "https://spokenmargins.proximitytoprogress.com/privacy/") ?? URL(fileURLWithPath: "/")
    }

    static var support: URL {
        URL(string: "https://spokenmargins.proximitytoprogress.com/support/") ?? URL(fileURLWithPath: "/")
    }

    /// The designated-agent page for copyright notices (17 U.S.C. § 512(c)(2), #2236). Settings links to it.
    static var copyright: URL {
        URL(string: "https://spokenmargins.proximitytoprogress.com/copyright/") ?? URL(fileURLWithPath: "/")
    }

    static var versionDescription: String {
        BuildIdentity.describe(info: Bundle.main.infoDictionary ?? [:])
    }
}
