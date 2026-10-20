import Foundation

enum EmojiArticleRegressionFixture {
    static let title = "Drawing pictograms for the way people talk now"
    static let sourceURL = "https://example.com/studio/pictogram-day-tidepool-3d/"
    static let sectionHeadings = [
        "Meaning keeps shifting",
        "Craft guides the tools",
        "Tone meets range",
        "Symbols belong to everyone"
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
