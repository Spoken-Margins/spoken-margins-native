import Foundation
import SessionKit

enum AppLinks {
    static var privacy: URL {
        URL(string: "https://spokenmargins.proximitytoprogress.com/privacy/") ?? URL(fileURLWithPath: "/")
    }

    static var support: URL {
        URL(string: "https://spokenmargins.proximitytoprogress.com/support/") ?? URL(fileURLWithPath: "/")
    }

    static var versionDescription: String {
        BuildIdentity.describe(info: Bundle.main.infoDictionary ?? [:])
    }
}
