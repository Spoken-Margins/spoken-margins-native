import XCTest
@testable import SessionKit

/// #5417: a long paper imported by link lost about half its sections. Its Markdown said "p \< 0.001" and,
/// pages later, "r<sub>L</sub>"; the import cleaner's catch-all `<[^>]+>` took everything between.
final class BrowserTextHandoffSanitizerTests: XCTestCase {
    private func readablePage(_ text: String, format: BrowserTextContentFormat = .markdown) -> BrowserTextHandoff {
        BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://example.com/paper", title: "Paper"),
            text: text,
            contentFormat: format
        )
    }

    private let laterSections = """
    ## Case study 2

    **Finding backdoor triggers from the weights.** A backdoor only shows up when its trigger is in the prompt.

    ## Conclusion

    The readouts help.

    ## Appendix A

    Table A1 lists the 16 test sets.
    """

    /// The structure of the real page (alignment.anthropic.com, neuron-basis applications), not its text.
    func testAComparisonBeforeLaterMarkupKeepsEverySectionBetween() {
        let text = """
        # Paper

        The auditor with readouts scores better on 31 finetunes (sign test, p \\< 0.001), and worse on 1.

        \(laterSections)

        We add s · c · ‖r<sub>L</sub>‖ · p · w, where ‖r<sub>L</sub>‖ is the mean residual norm.

        The last 21 adapters were chosen before any audit (p \\< 0.001). In w<sub>gate</sub> · e the change shows.
        """
        let sanitized = BrowserTextHandoffSanitizer.sanitized(readablePage(text)).text
        for passage in [
            "sign test, p \\< 0.001), and worse on 1.",
            "**Finding backdoor triggers from the weights.**",
            "## Conclusion",
            "Table A1 lists the 16 test sets.",
            "The last 21 adapters were chosen before any audit (p \\< 0.001).",
            "the mean residual norm."
        ] {
            XCTAssertTrue(sanitized.contains(passage), passage)
        }
        XCTAssertFalse(sanitized.contains("<sub>"))
        XCTAssertFalse(sanitized.contains("</sub>"))
    }

    /// Neighbouring inputs: each kind of "<" a page's prose holds, followed by each kind of markup the cleaner
    /// removes (#5417 Done when 3: after a table, a figure, a details or footnote block).
    func testEveryProseLessThanSurvivesEveryLaterMarkupKind() {
        let comparisons = [
            "p < 0.05", "p<0.05", "x <y", "a \\< b", "a <= b", "x <- y", "I <3 this", "1<2", "a < b < c",
            "<", "＜ full width", "n < 10 items"
        ]
        let markup: [(html: String, mustGo: String)] = [
            ("<sub>L</sub>", "<sub>"),
            ("<figure><img src=\"chart.png\" alt=\"a > b\"></figure>", "<figure"),
            ("<table><tr><td colspan=\"2\">cell</td></tr></table>", "<table"),
            ("<details><summary>More</summary>Hidden words</details>", "<details"),
            ("<sup>1</sup>", "<sup>"),
            ("<h2 id=\"x\">Heading</h2>", "<h2"),
            ("<br/>", "<br"),
            ("<!-- note -->", "<!--"),
            ("<span style='font-weight: 700;'>Bold</span>", "<span"),
            ("<details open><summary>Open</summary>Shown</details>", "<details"),
            ("<td nowrap class=\"a\">cell</td>", "<td"),
            ("<a href=x?y=z>link</a>", "<a"),
            ("<![CDATA[raw]]>", "CDATA")
        ]
        for comparison in comparisons {
            for (html, mustGo) in markup {
                for format in [BrowserTextContentFormat.markdown, .plainText] {
                    let text = "Before \(comparison) after.\n\nMiddle section words.\n\n\(html)\n\nEnd words."
                    let sanitized = BrowserTextHandoffSanitizer.sanitized(readablePage(text, format: format)).text
                    let label = "\(format) \(comparison) / \(html)"
                    XCTAssertTrue(sanitized.contains("Before \(comparison) after."), label)
                    XCTAssertTrue(sanitized.contains("Middle section words."), label)
                    XCTAssertTrue(sanitized.contains("End words."), label)
                    XCTAssertFalse(sanitized.contains(mustGo), label)
                }
            }
        }
    }

    func testMarkupIsStillCleanedAsBefore() {
        let text = """
        <h2 class="t">Section</h2><p>One <b>bold</b> word.</p>
        <video controls><source src="a.mp4">Your browser doesn't support video.</video>
        <figure><svg></svg><figcaption>Gone</figcaption></figure>
        <SCRIPT type="x">var a = 1 > 0;</SCRIPT>After.
        """
        let sanitized = BrowserTextHandoffSanitizer.sanitized(readablePage(text)).text
        XCTAssertTrue(sanitized.contains("## Section"))
        XCTAssertTrue(sanitized.contains("One bold word."))
        XCTAssertTrue(sanitized.contains("After."))
        for gone in ["<", "browser doesn't support", "figcaption", "Gone", "var a"] {
            XCTAssertFalse(sanitized.contains(gone), gone)
        }
    }

    func testTextWithOnlyComparisonsIsReturnedUnchanged() {
        let handoff = readablePage("p < 0.05 and q > 0.1, so x<y   stays  spaced.")
        XCTAssertEqual(BrowserTextHandoffSanitizer.sanitized(handoff), handoff)
    }

    func testOtherCaptureModesAreNotCleaned() {
        for mode in [BrowserTextCaptureMode.selectedText, .markdownFile, .plainTextFile] {
            let handoff = BrowserTextHandoff(
                captureMode: mode,
                source: BrowserTextSource(url: "file:///fixture.md", title: "Deliberate Markup"),
                text: "Keep <video> as deliberate text.",
                contentFormat: .plainText
            )
            XCTAssertEqual(BrowserTextHandoffSanitizer.sanitized(handoff), handoff)
        }
    }
}
