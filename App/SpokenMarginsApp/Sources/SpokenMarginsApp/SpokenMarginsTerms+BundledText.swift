import Foundation
import SessionKit

/// The Terms text ships in the app bundle (`Legal/SPOKEN_MARGINS_TERMS_OF_USE.txt`), so reading it stays in the
/// app. The version and acceptance rules are in SessionKit.
extension SpokenMarginsTerms {
    static func hasBundledText(in bundle: Bundle = .main) -> Bool {
        bundle.url(
            forResource: "SPOKEN_MARGINS_TERMS_OF_USE",
            withExtension: "txt",
            subdirectory: "Legal"
        ) != nil
    }

    static func bundledText(in bundle: Bundle = .main) -> String {
        guard let url = bundle.url(
            forResource: "SPOKEN_MARGINS_TERMS_OF_USE",
            withExtension: "txt",
            subdirectory: "Legal"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled Spoken Margins Terms of Use are unavailable. On-device voice remains disabled."
        }
        return text
    }
}
