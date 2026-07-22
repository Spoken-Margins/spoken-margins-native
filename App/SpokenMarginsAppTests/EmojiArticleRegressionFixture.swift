import Foundation

enum EmojiArticleRegressionFixture {
    static let title = "Designing emoji for the way we communicate today"
    static let sourceURL = "https://blog.google/products-and-platforms/platforms/android/world-emoji-day-noto-3d/"

    static func text() throws -> String {
        guard let url = Bundle(for: FixtureBundleToken.self).url(
            forResource: "emoji-article-crash-regression",
            withExtension: "txt"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private final class FixtureBundleToken {}
