import Foundation

enum EmojiArticleRegressionFixture {
    static let title = "Designing emoji for the way we communicate today"
    static let sourceURL = "https://blog.google/products-and-platforms/platforms/android/world-emoji-day-noto-3d/"
    static let sectionHeadings = [
        "Expression keeps evolving",
        "Art informs innovation",
        "Color meets contrast",
        "Language is for the people"
    ]

    static func text() throws -> String {
        guard let url = Bundle(for: FixtureBundleToken.self).url(
            forResource: "emoji-article-crash-regression",
            withExtension: "txt"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func browserMarkdown() throws -> String {
        var markdown = try text()
        for heading in sectionHeadings {
            markdown = markdown.replacingOccurrences(
                of: "\n\(heading)\n",
                with: "\n## \(heading)\n"
            )
        }
        return "# \(title)\n\n\(markdown)"
    }
}

private final class FixtureBundleToken {}
