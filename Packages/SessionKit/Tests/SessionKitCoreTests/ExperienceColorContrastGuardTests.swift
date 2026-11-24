import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #3739: the contrast audit measured only token-on-token pairs. These tests give it alpha compositing and the system
/// colours, audit the Timeline rows and the Watch plates that the 2026-11-08 audit found by hand, and fail when a new
/// tint or a new system colour appears without a decision.
final class AppColorCompositingTests: XCTestCase {
    func testCompositingIsTheStraightAlphaBlend() {
        let white = AppColorRGB(red: 1, green: 1, blue: 1)
        let black = AppColorRGB(red: 0, green: 0, blue: 0)
        XCTAssertEqual(white.composited(over: black, alpha: 0.5), AppColorRGB(red: 0.5, green: 0.5, blue: 0.5))
        XCTAssertEqual(white.composited(over: black, alpha: 0), black, "no alpha leaves the base")
        XCTAssertEqual(white.composited(over: black, alpha: 1), white, "full alpha leaves the colour")
        XCTAssertEqual(white.composited(over: black, alpha: 3), white, "alpha is clamped")
        XCTAssertEqual(white.composited(over: black, alpha: -1), black, "alpha is clamped")
    }

    func testCompositingWorksInEachAppearanceSeparately() {
        let tint = AppSemanticColorRGB.evergreen.composited(over: AppSemanticColorRGB.bone, alpha: 0.12)
        XCTAssertEqual(tint.light, AppSemanticColorRGB.evergreen.light.composited(over: AppSemanticColorRGB.bone.light, alpha: 0.12))
        XCTAssertEqual(tint.dark, AppSemanticColorRGB.evergreen.dark.composited(over: AppSemanticColorRGB.bone.dark, alpha: 0.12))
        XCTAssertNotEqual(tint.light, tint.dark)
    }

    /// The row text on a tint is never read against the plain base, so a pair against plain bone says nothing about it.
    func testATintedFillIsMeasuredWhereThePlainBaseIsNot() {
        let plain = AppColorContrastAudit.contrastRatio(
            foreground: AppSemanticColorRGB.secondaryText.light, background: AppSemanticColorRGB.bone.light)
        let tinted = AppColorContrastAudit.contrastRatio(
            foreground: AppSemanticColorRGB.secondaryText.light,
            background: AppSemanticColorRGB.evergreen.composited(over: AppSemanticColorRGB.bone, alpha: 0.12).light)
        XCTAssertGreaterThanOrEqual(plain, 4.5, "the plain pair passes, which is why the old audit saw nothing")
        XCTAssertLessThan(tinted, 4.5, "the same text on the current row's tint does not")
    }
}

final class AppColorContrastAuditFindingsTests: XCTestCase {
    private func ratio(_ pairName: String, _ appearance: String) throws -> Double {
        let pair = try XCTUnwrap(AppColorContrastAudit.allPairs.first { $0.name == pairName }, "no pair named \(pairName)")
        let measurement = AppColorContrastAudit.measurements(for: [pair]).first { $0.appearance == appearance }
        return try XCTUnwrap(measurement).ratio
    }

    /// #3731: the Watch's plates were white on the system orange (2.06:1) and blue (3.65:1). Now a dark label on the
    /// orange and a deeper blue under white.
    func testTheWatchPlatesAreReadable() throws {
        XCTAssertGreaterThanOrEqual(try ratio("watch session plate label", "dark"), 8.0)
        XCTAssertGreaterThanOrEqual(try ratio("watch episode plate label", "dark"), 5.7)
        XCTAssertGreaterThanOrEqual(try ratio("watch record plate label", "dark"), 5.7)
    }

    /// Each finding is a known failure until its own issue fixes it, so a fix that works has to delete the entry.
    func testEveryNewFindingIsListedAsKnownUntilItsIssueFixesIt() {
        let listed = Set(AppColorContrastAudit.knownFailures.map { "\($0.pair) [\($0.appearance)]" })
        let measured = AppColorContrastAudit.measurements(for: AppColorContrastAudit.allPairs)
        let failing = measured.filter(\.fails).map { "\($0.pair) [\($0.appearance)]" }
        XCTAssertEqual(Set(failing).subtracting(listed), [], "an unlisted failure is a new bug: fix it or list it with its issue")
        XCTAssertEqual(AppColorContrastAudit.staleKnownFailures(), [])
    }
}

final class AppLiveActivityPairsTests: XCTestCase {
    /// The same pairs on a white surface: every pair with a light mark on it has to fail, or the audit measures nothing.
    private func onWhite(_ pairs: [AppColorContrastAudit.Pair]) -> [AppColorContrastAudit.Pair] {
        pairs.map { .init(name: $0.name, foreground: $0.foreground, background: AppSemanticColorRGB.white, minimumRatio: $0.minimumRatio) }
    }

    func testTheLiveActivityPairsAllPassToday() {
        XCTAssertFalse(AppColorContrastAudit.liveActivityPairs.isEmpty)
        let failing = AppColorContrastAudit.failures(for: AppColorContrastAudit.liveActivityPairs)
        XCTAssertEqual(failing, [], "every Live Activity pair passes since the buttons left the system blue (#3739)")
        XCTAssertFalse(AppColorContrastAudit.knownFailures.contains { $0.pair.hasPrefix("live activity") })
    }

    func testTheLiveActivityPairsCanFail() {
        let wrong = AppColorContrastAudit.failures(for: onWhite(AppColorContrastAudit.liveActivityPairs))
        XCTAssertGreaterThan(wrong.count, 20, "white marks on a white plate must fail: \(wrong.count)")
    }

    func testThePressedFillPairsCanFail() {
        let wrong = AppColorContrastAudit.failures(for: onWhite(AppColorContrastAudit.pressedFillPairs))
        XCTAssertGreaterThan(wrong.count, 10, "light marks on a white surface must fail: \(wrong.count)")
    }

    /// The pairs name what the widgets draw, so a widget that changes a colour or an alpha has to change its pair with it.
    func testTheWidgetsStillDrawTheColoursThePairsMeasure() throws {
        let directory = try TestInputs.directory(.appGate2Widget)
        let text = try ["Gate2LiveActivityWidget.swift", "LiveSessionActivityWidget.swift"].map {
            try String(contentsOf: directory.appendingPathComponent("Sources/" + $0), encoding: .utf8)
        }.joined().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        XCTAssertTrue(text.contains("Color(red: 0.08, green: 0.09, blue: 0.12)"), "the plate")
        XCTAssertTrue(text.contains("Color(red: 0.34, green: 0.71, blue: 0.91)"), "the progress blue")
        XCTAssertTrue(text.contains("Color(red: 0.27, green: 0.78, blue: 0.43)"), "the second green")
        for alpha in ["0.74", "0.8", "0.84", "0.86"] {
            XCTAssertTrue(text.contains(".white.opacity(\(alpha))"), "white at \(alpha) is no longer drawn: drop its pair")
        }
        // The chapter line is 0.78 white, drawn through a ternary since the paused prompt shares the line (#3692); the
        // paused prompt itself is plain white, which the title pair covers.
        XCTAssertTrue(text.contains(".white.opacity(offersResume ? 1 : 0.78)"), "white at 0.78 is no longer drawn: drop its pair")
        for alpha in ["0.16", "0.12", "0.14"] {
            XCTAssertTrue(text.contains("Color.white.opacity(\(alpha))"), "the white chip at \(alpha) is no longer drawn: drop its pair")
        }
        XCTAssertTrue(text.contains("Color.green.opacity(0.28)"), "the system green chip")
        XCTAssertTrue(text.contains("? .red : .orange"), "the recording tint")
        XCTAssertFalse(text.contains(".tint(.blue)"), "the system blue tint is back: it measures 4.46:1 on the plate in light (#3739)")
        XCTAssertEqual(text.components(separatedBy: "static let buttonTint = Color(red: 0.34, green: 0.71, blue: 0.91)").count - 1, 1, "the button tint literal")
        XCTAssertEqual(text.components(separatedBy: ".tint(LiveSessionActivityStyle.buttonTint)").count - 1, 3, "Resume, Mark and Finish Margin")
        XCTAssertTrue(text.contains(".foregroundStyle(.secondary)"), "the Dynamic Island's secondary line")
    }
}

/// #3739 slice 4: the share extension (UIKit) and the Safari popup (`popup.css`) draw colours outside the app's tokens.
final class AppExtensionColourPairsTests: XCTestCase {
    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func matches(of pattern: String, in text: String) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    // MARK: Share extension

    func testTheShareExtensionPairsPassAndTheOldBlueDoneLabelFails() {
        XCTAssertEqual(AppColorContrastAudit.failures(for: AppColorContrastAudit.shareExtensionPairs), [])
        // Before this slice the Done button drew the default tint, the system blue: 3.60:1 on the card in light mode.
        let old = AppColorContrastAudit.Pair(
            name: "share extension Done label (default tint)", foreground: AppSystemColorRGB.blue,
            background: AppSystemColorRGB.secondarySystemBackground, minimumRatio: 4.5)
        let failing = AppColorContrastAudit.measurements(for: [old]).filter(\.fails)
        XCTAssertEqual(failing.map(\.appearance), ["light"])
        XCTAssertEqual(failing[0].ratio, 3.60, accuracy: 0.01)
    }

    /// The extension draws only what its pairs measure: no other UIKit colour, no alpha, and the Done label in the icon's green.
    func testTheShareExtensionDrawsOnlyTheColoursThePairsMeasure() throws {
        // Comments are dropped, so a colour named in one is not a use, and a stale line left in one is not a pass.
        let raw = try TestInputs.text(.appShareExtension, "Sources/SourceLinkShareViewController.swift")
        let source = collapsed(raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
        }.joined(separator: "\n"))
        let implicit = try matches(
            of: #"(?<![\w)\]?!])\.(system[A-Z]\w*|secondarySystem\w*|tertiarySystem\w*|\w*[Ll]abel|separator|opaqueSeparator|placeholderText|lightText|darkText|white|black|gray|red|blue|green|orange|yellow|purple|brown|cyan|magenta|clear)\b"#,
            in: source).map { $0[1] }
        XCTAssertGreaterThanOrEqual(implicit.count, 4, "the scan must see the extension's colours: \(implicit)")
        XCTAssertEqual(Set(implicit).subtracting(["systemBackground", "secondarySystemBackground", "label"]), [], "a new colour needs a pair in shareExtensionPairs")
        XCTAssertEqual(try matches(of: #"\bUIColor\.\w+"#, in: source).count, 0, "no UIColor.<name>")
        XCTAssertEqual(try matches(of: #"\bUIColor\("#, in: source).count, 2, "only the two copies of the green token")
        XCTAssertEqual(try matches(of: #"\bUIColor \{"#, in: source).count, 1)
        XCTAssertFalse(source.contains("withAlphaComponent") || source.contains(".alpha ="), "an alpha is a tint: give it a pair")
        XCTAssertTrue(source.contains("statusLabel.textColor = .label") && source.contains("titleLabel.textColor = .label"))
        let doneColour = try XCTUnwrap(source.range(of: "closeButton.setTitleColor(iconView.tintColor, for: .normal)"), "Done is the icon's green, not the default tint")
        let iconColour = try XCTUnwrap(source.range(of: "iconView.tintColor = UIColor {"))
        XCTAssertLessThan(iconColour.lowerBound, doneColour.lowerBound, "the icon's green is set before Done reads it, or Done gets the default blue")
        XCTAssertTrue(source.contains("cardView.backgroundColor = .secondarySystemBackground"), "the card the pairs measure on")
    }

    // MARK: Safari popup

    func testTheSafariPopupPairsPassAndCanFail() {
        XCTAssertEqual(AppColorContrastAudit.failures(for: AppColorContrastAudit.safariPopupPairs), [])
        // The caption on the accent plate is the wrong pairing, and it must fail.
        let wrong = AppColorContrastAudit.Pair(
            name: "caption on the accent", foreground: AppSafariPopupRGB.caption, background: AppSafariPopupRGB.accent, minimumRatio: 4.5)
        XCTAssertFalse(AppColorContrastAudit.failures(for: [wrong]).isEmpty)
    }

    /// Every declaration in `popup.css` that carries a colour, an edge or an alpha, as `selector | property: value`. Each is
    /// the pair in `safariPopupPairs` that measures it, so a colour changed, a new state (`:hover`, `:focus`, `:active`) or a new
    /// property with a colour in it fails here until it has a pair.
    private static let popupColourDeclarations: Set<String> = [
        "body | color: #f6f6f6", "body | background: #101312",                      // safari popup body and title
        ".brand-mark | color: #07110d", ".brand-mark | background: #57d696",        // safari popup brand mark
        ".brand p | color: #aeb8b3",                                                 // safari popup caption
        "button | color: #111", "button | background: #57d696", "button | border: 0",  // safari popup button label
        "button:disabled | opacity: 0.55",                                           // safari popup disabled button label
        "#status | color: #bdbdbd"                                                   // safari popup status line
    ]

    /// The stylesheet as `selector | property: value` for each declaration whose property can carry a colour, with comments
    /// removed so a colour named in one is neither a use nor a pass.
    private func popupDeclarations() throws -> [String] {
        let css = try TestInputs.text(.appBrowserTextExtension, "Resources/Styles/popup.css")
            .replacingOccurrences(of: #"/\*.*?\*/"#, with: " ", options: [.regularExpression])
        let flattened = collapsed(css)
        var found: [String] = []
        for rule in try matches(of: #"([^{}]+)\{([^{}]*)\}"#, in: flattened) {
            let selector = rule[1].trimmingCharacters(in: .whitespaces)
            for declaration in rule[2].split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let carriesColour = parts[0].range(
                    of: #"color|background|border|outline|shadow|filter|opacity|fill|stroke|blend|mask|accent|caret|decoration"#,
                    options: .regularExpression) != nil
                if carriesColour && !parts[0].hasSuffix("radius") { found.append("\(selector) | \(parts[0]): \(parts[1])") }
            }
        }
        XCTAssertFalse(flattened.contains("@media") || flattened.contains("@supports"), "a conditional block hides rules from this scan: give its colours pairs and teach the scan")
        return found
    }

    func testThePopupRulesAreExactlyThePairsThatMeasureThem() throws {
        let found = try popupDeclarations()
        XCTAssertGreaterThanOrEqual(found.count, 9, "the scan must see the stylesheet: \(found)")
        XCTAssertEqual(Set(found), Self.popupColourDeclarations, "a colour, state or edge with no pair: add it to safariPopupPairs and to this table")
        // A hex is a colour in the palette, in 3 or 6 digits: no alpha digits, no other colour syntax.
        for declaration in found {
            for hex in try matches(of: #"#([0-9a-fA-F]+)\b"#, in: declaration).map({ $0[1].lowercased() }) {
                XCTAssertTrue(hex.count == 3 || hex.count == 6, "\(declaration): a hex with alpha is a tint the audit cannot read")
                let sixDigit = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
                XCTAssertNotNil(AppSafariPopupRGB.palette[sixDigit], "\(declaration): \(hex) is not in AppSafariPopupRGB")
            }
        }
        for declaration in found where declaration.contains("color") || declaration.contains("background") {
            XCTAssertNil(declaration.range(of: #"rgb|hsl|color-mix|light-dark|var\("#, options: .regularExpression), declaration)
        }
    }

    func testThePopupPageSetsNoColoursOfItsOwn() throws {
        let html = try TestInputs.text(.appBrowserTextExtension, "Resources/popup.html")
        XCTAssertFalse(html.contains("<style"))
        XCTAssertFalse(html.contains("style="))
    }
}

final class AppTintedFillPairsTests: XCTestCase {
    func testTheTintedFillPairsAllPassToday() {
        XCTAssertFalse(AppColorContrastAudit.tintedFillPairs.isEmpty)
        XCTAssertEqual(AppColorContrastAudit.failures(for: AppColorContrastAudit.tintedFillPairs), [])
    }

    /// The pairs can fail: the fill colour `ochre` used as the icon colour on its own 0.2 tint is the mistake
    /// `ochreText` exists to avoid, and the audit sees it in light mode.
    func testTheAuditSeesTheWrongIconColourOnATile() {
        let wrong = AppColorContrastAudit.Pair(
            name: "artwork icon in the fill colour",
            foreground: AppSemanticColorRGB.ochre,
            background: AppSemanticColorRGB.ochre.composited(over: AppSemanticColorRGB.panel, alpha: 0.2),
            minimumRatio: 3
        )
        XCTAssertFalse(AppColorContrastAudit.failures(for: [wrong]).isEmpty)
    }

    func testTheTintedFillPairsAreInTheAudit() {
        let names = Set(AppColorContrastAudit.allPairs.map(\.name))
        for pair in AppColorContrastAudit.tintedFillPairs { XCTAssertTrue(names.contains(pair.name), pair.name) }
    }
}

/// Where the app draws a tint or a system colour, the audit has to know about it.
final class AppColorUsageGuardTests: XCTestCase {
    private func appSwiftFiles() throws -> [URL] {
        let inputs: [TestInputs.Input] = [
            .appSources, .appSharedSources, .appGate2Shared, .appBrowserTextExtension, .appShareExtension,
            .appGate2Widget, .appWatch, .appWatchApp
        ]
        var files: [URL] = []
        for input in inputs {
            let directory = try TestInputs.directory(input)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            files += enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        return files
    }

    /// Whitespace is collapsed, so a modifier split over lines is still seen.
    private func collapsedText(_ file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func matches(of pattern: String, in text: String) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    // MARK: Tints

    /// What each `AppColors.<token>.opacity(<alpha>)` in the app is, by `token@alpha`. `audited` means the text on it is
    /// measured by `timelineRowPairs`, `tintedFillPairs`, `pressedFillPairs` or `liveActivityPairs`; `noText` means no text sits on it (a hairline, a stripe, a pressed state, a
    /// plain shape); `unaudited` is a fill with text or an icon on it that no pair measures yet, left for #3739's next
    /// slices (none left today). A new tint is not in this list, so it fails until someone says which of the three it is. The key is the token and the
    /// alpha, not the call site: a new text fill that reuses an audited key is not seen, so give it a new alpha or a pair.
    private enum TintKind: Equatable { case audited, noText, unaudited }

    private static let tints: [String: TintKind] = [
        "evergreen@0.12": .noText,
        // #3739 slice 2: `tintedFillPairs`.
        "ochre@0.12": .audited, "evergreen@0.16": .audited,
        "listeningAccent@0.18": .audited, "softGreen@0.85": .audited, "softGreen@0.55": .audited,
        // Card borders: `ExperienceSurface(tint:)` strokes with it, on a panel fill.
        "coral@0.34": .noText, "evergreen@0.18": .noText, "ochre@0.16": .noText, "ochre@0.65": .noText,
        "ochre@0.7": .noText, "ochre@0.5": .noText, "evergreen@0.5": .noText,
        "plum@0.4": .noText, "plum@0.08": .noText,
        // Strokes, stripes and dots.
        "evergreen@0.25": .noText, "bone@0.75": .noText, "border@0.75": .noText, "border@0.8": .noText,
        // Fills with text or an icon on them that no pair measures yet.
        // The empty track of the storage bar: the swatches on it carry the meaning. The artwork tile fills
        // (`SMExperienceTypeCover`) are drawn by a view nothing uses yet, so they are left out until it is.
        "ochre@0.20": .noText, "plum@0.16": .noText,
        "border@0.45": .noText, "watchSecondary@0.24": .noText,
        // The playback card's plates and the pressed states of the buttons: `pressedFillPairs` (#3739 slice 3).
        "watchControl@0.8": .audited, "watchControl@0.72": .audited, "panel@0.75": .audited,
        "listeningAccent@0.75": .audited, "captureBackground@0.78": .audited,
        "primaryAction@0.78": .audited, "softGreen@0.7": .audited
    ]

    func testEveryTintTheAppDrawsIsClassified() throws {
        var found: Set<String> = []
        for file in try appSwiftFiles() {
            let text = try collapsedText(file)
            // `opacity(0.12)`, a pressed state `opacity(isPressed ? 0.75 : 1)` and `opacity(isCurrent ? 0.85 : 0.55)`: each
            // alpha other than a plain 1 is a tint.
            for match in try matches(of: #"AppColors\.(\w+)\s*\.opacity\(\s*(?:!?[\w.]+ \? )?([0-9.]+)(?: : ([0-9.]+))?\s*\)"#, in: text) {
                for alpha in [match[2], match[3]] where !alpha.isEmpty && Double(alpha) != 1 { found.insert("\(match[1])@\(alpha)") }
            }
        }
        XCTAssertGreaterThan(found.count, 20, "the scan must see the app's tints")
        let known = Set(Self.tints.keys)
        XCTAssertEqual(
            found.subtracting(known).sorted(), [],
            "a tint with no decision: if text sits on it, add a pair for it to the audit and list it as audited; if not, list it as noText"
        )
        // A tint that is no longer drawn is not an error: two PRs that each add or remove one must not turn each other red.
    }

    func testEveryAuditedTintHasPairsInTheAudit() {
        let names = AppColorContrastAudit.allPairs.map(\.name)
        for (key, kind) in Self.tints where kind == .audited {
            let parts = key.split(separator: "@")
            // The pair names print the alpha as a number, so `0.20` in source is `0.2` there.
            let alpha = Double(parts[1]).map { "\($0)" } ?? String(parts[1])
            let marker = "on \(parts[0]) at \(alpha) over"
            XCTAssertTrue(names.contains { $0.contains(marker) }, "\(key) is listed as audited but no pair measures text on it")
        }
    }

    // MARK: Tint tokens (#4953)

    /// Every `AppColors` token the app passes to `.tint(`, and why it is safe there. A `.bordered` control draws its words
    /// in its tint, so a token that is only safe as a fill becomes unreadable text: `primaryAction` was 1.9:1 in dark mode
    /// on the Margins Retry (#4953), and `plum` 4.1:1 on Share's Stop. Neither is listed, on purpose. The key is the token,
    /// not the call site, as with `tints` above: a listed token reused on a new surface is not seen.
    private enum TintTokenKind { case borderedLabel, plainText, swipe, alwaysDark, prominentFill, nonText }

    private static let classifiedTintTokens: [String: TintTokenKind] = [
        // The app accent: `accentPairs` audits it as a bordered button label on bone and the panel.
        "evergreen": .borderedLabel,
        // A disclosure tint on bone and the panel: the "reading body on bone" and panel body pairs.
        "text": .plainText,
        // White words on a swipe button, audited; `swipeTintsThatAreNotSwipeTokens` owns them.
        "swipeEvergreen": .swipe, "swipeOchre": .swipe, "swipePlum": .swipe, "swipeSlate": .swipe,
        // Drawn on the always-dark playback, recording or live surfaces, where the plate pairs measure them.
        "accent": .alwaysDark, "listeningAccent": .alwaysDark, "ochre": .alwaysDark, "watchControl": .alwaysDark,
        "watchDanger": .alwaysDark,
        // A `.borderedProminent` fill under `captureText`: the "capture action" pair.
        "captureBackground": .prominentFill,
        // A spinner on an evergreen fill, and a progress bar: no words drawn in them.
        "onEvergreen": .nonText, "ochreText": .nonText
    ]

    private static let tintTokenPattern = try! NSRegularExpression(pattern: #"(?<![\w.])AppColors\.(\w+)"#)

    /// The `AppColors` tokens inside each `.tint(…)` argument of a Swift file, in order, duplicates kept. Strings and
    /// comments are stripped first, as the swipe guard does, so a `//` in a string cannot hide a real use. Block comments
    /// are not handled, the same as the swipe guard.
    static func tintTokens(in text: String) -> [String] {
        let collapsed = text
            .replacingOccurrences(of: #""(?:\\.|[^"\\\n])*""#, with: "\"\"", options: .regularExpression)
            .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var tokens: [String] = []
        var searchRange = collapsed.startIndex..<collapsed.endIndex
        while let tint = collapsed.range(of: #"\.tint\("#, options: .regularExpression, range: searchRange) {
            var depth = 1
            var end = tint.upperBound
            while end < collapsed.endIndex, depth > 0 {
                if collapsed[end] == "(" { depth += 1 } else if collapsed[end] == ")" { depth -= 1 }
                end = collapsed.index(after: end)
            }
            let argument = String(collapsed[tint.upperBound..<end])
            let range = NSRange(argument.startIndex..., in: argument)
            for match in tintTokenPattern.matches(in: argument, range: range) {
                if let token = Range(match.range(at: 1), in: argument) { tokens.append(String(argument[token])) }
            }
            searchRange = tint.upperBound..<collapsed.endIndex
        }
        return tokens
    }

    func testTheTintTokenScanSeesEveryToken() {
        let cases: [(String, [String])] = [
            (".tint(AppColors.primaryAction)", ["primaryAction"]),
            (".tint(\n  AppColors.primaryAction\n)", ["primaryAction"]),
            (".tint(isActive ? AppColors.plum : AppColors.evergreen)", ["plum", "evergreen"]),
            (".tint(AppColors.swipePlum.opacity(0.5))", ["swipePlum"]),
            ("// .tint(AppColors.plum)\n.tint(AppColors.evergreen)", ["evergreen"]),
            ("Text(\"// x\").tint(AppColors.plum)", ["plum"]),
            (".background(AppColors.primaryAction)", []),
            (".tint(.white)", []),
            (".tint(LiveSessionActivityStyle.buttonTint)", []),
            (".tint(AppColors.evergreen).foregroundStyle(AppColors.plum)", ["evergreen"]),
            ("", [])
        ]
        for (input, expected) in cases {
            XCTAssertEqual(Self.tintTokens(in: input), expected, input)
        }
    }

    func testEveryTintTokenIsClassified() throws {
        var unlisted: Set<String> = []
        var seen: Set<String> = []
        for file in try appSwiftFiles() {
            let tokens = Self.tintTokens(in: try String(contentsOf: file, encoding: .utf8))
            seen.formUnion(tokens)
            for token in tokens where Self.classifiedTintTokens[token] == nil {
                unlisted.insert("\(file.lastPathComponent): \(token)")
            }
        }
        XCTAssertTrue(seen.contains("evergreen"), "the scan must see the app accent")
        XCTAssertGreaterThanOrEqual(seen.count, 10, "the scan must see the app's tint tokens")
        XCTAssertEqual(
            unlisted.sorted(), [],
            "a tint token with no decision: a `.bordered` control draws its words in its tint. Use `AppColors.evergreen`, or add the token with the pair that measures it (#4953)"
        )
    }

    func testEveryBorderedLabelTokenHasAnAuditedPair() {
        let colors = Dictionary(AppSemanticColorRGB.all.map { ($0.name, $0.color) }, uniquingKeysWith: { first, _ in first })
        for token in Self.classifiedTintTokens.keys {
            XCTAssertNotNil(colors[token], "\(token) is not a token in AppSemanticColorRGB.all")
        }
        let borderedLabels = AppColorContrastAudit.accentPairs.filter { $0.name.hasPrefix("bordered button label") }
        for (token, kind) in Self.classifiedTintTokens where kind == .borderedLabel {
            let color = colors[token]
            XCTAssertTrue(
                borderedLabels.contains { $0.foreground == color },
                "\(token) is listed as a bordered label but no \"bordered button label\" pair measures it"
            )
        }
    }

    /// The two tints #4953 took out, measured the way the audit measures a bordered label: each fails in dark mode, which
    /// is why neither is in `classifiedTintTokens`.
    func testTheTwoUnlistedTintsFailAsBorderedLabelsInDarkMode() {
        let primaryAction = AppSemanticColorRGB.primaryAction
        let plum = AppSemanticColorRGB.plum
        let cases: [(String, AppDynamicRGB, AppDynamicRGB)] = [
            ("primaryAction over bone", primaryAction, primaryAction.composited(over: AppSemanticColorRGB.bone, alpha: 0.25)),
            ("plum over panel", plum, plum.composited(over: AppSemanticColorRGB.panel, alpha: 0.25))
        ]
        for (name, foreground, background) in cases {
            let ratio = AppColorContrastAudit.contrastRatio(foreground: foreground.dark, background: background.dark)
            XCTAssertLessThan(ratio, 4.5, name)
        }
    }

    // MARK: Destructive buttons on the dark live-session cards (#4443)

    /// A destructive button with no tint draws the system red, which is dim on `watchControl`: the finish card's Discard
    /// Session was nearly invisible on the owner's phone. The audit already holds `watchDanger` on `watchControl` to 4.5:1
    /// ("danger label on watch control"), but only a button that uses the token is measured by it. So every destructive
    /// button in a live-session view carries `.tint(AppColors.watchDanger)`, except the confirmation dialog's, which the
    /// system draws.
    static func untintedDestructiveButtons(in text: String) throws -> [String] {
        var offenders: [String] = []
        for match in try NSRegularExpression(pattern: #"Button\([^{}]{0,80}role: \.destructive"#).matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let start = Range(match.range, in: text)!.lowerBound
            let before = String(text[..<start].suffix(160))
            if before.contains(".confirmationDialog(") || before.contains(".alert(") { continue }
            // The button's own modifiers: up to the next `Button(` or 400 characters.
            var after = String(text[start...].prefix(400))
            if let next = after.range(of: "Button(", range: after.index(after.startIndex, offsetBy: 7)..<after.endIndex) {
                after = String(after[..<next.lowerBound])
            }
            if !after.contains(".tint(AppColors.watchDanger)") { offenders.append(String(after.prefix(60))) }
        }
        return offenders
    }

    func testDestructiveButtonScanSeesAnUntintedOneAndSkipsTheDialogs() throws {
        let bare = #"Button("Discard Session", role: .destructive) { confirmsDiscard = true } } .padding(12)"#
        let tinted = #"Button(role: .destructive) { a() } label: { Label("Discard Session", systemImage: "trash") } .buttonStyle(.bordered) .tint(AppColors.watchDanger) }"#
        let dialog = #".confirmationDialog("Discard?", isPresented: $x) { Button("Discard Session", role: .destructive) { go() } }"#
        XCTAssertEqual(try Self.untintedDestructiveButtons(in: bare).count, 1)
        XCTAssertEqual(try Self.untintedDestructiveButtons(in: tinted), [])
        XCTAssertEqual(try Self.untintedDestructiveButtons(in: dialog), [])
    }

    func testLiveSessionDestructiveButtonsUseTheDangerTokenAndKeepTheirIcon() throws {
        // Only `LiveSessionView.swift`: its cards are filled with `watchControl`. The Margin detail's Delete has its own
        // button style on its own surface.
        let files = try appSwiftFiles()
        let view = try XCTUnwrap(files.first { $0.lastPathComponent == "LiveSessionView.swift" })
        let text = try collapsedText(view)
        XCTAssertGreaterThan(text.components(separatedBy: "role: .destructive").count - 1, 1, "the scan must see Discard Session and its dialog")
        XCTAssertEqual(try Self.untintedDestructiveButtons(in: text), [], "tint it with AppColors.watchDanger")
        XCTAssertTrue(text.contains(#"Label("Discard Session", systemImage: "trash")"#), "the icon keeps the words and the shape, not the colour alone")
        XCTAssertTrue(
            AppColorContrastAudit.allPairs.contains { $0.name == "danger label on watch control" },
            "the pair that measures watchDanger on the card"
        )
    }

    // MARK: System colours

    /// A system colour used directly: `Color.red`, `.foregroundStyle(.secondary)`, or an arm of a ternary. The default
    /// tint, placeholders and `.secondary` text fall under the same dynamic system values the audit cannot see
    /// against the app's surfaces, so every use is counted per file and a file may not use more than its baseline (#3739).
    private static let systemColorUse: [String] = {
        let names = "red|green|blue|orange|yellow|teal|mint|indigo|purple|pink|cyan|brown|gray|secondary|tertiary|quaternary"
        return [
            #"\bColor\.(?:\#(names))\b"#,
            #"(?:foregroundStyle|foregroundColor|tint|fill|stroke|background|overlay|accentColor)\(\s*\.(?:\#(names))\b"#,
            #"\?\s*\.(?:\#(names))\b"#,
            #"\?[^?:;{}]{1,60}:\s*\.(?:\#(names))\b"#,
            // A colour returned from a switch or a function: `case .success: .green`, `return .red`.
            #"(?:\bcase [^:]{1,60}:|\breturn)\s*\.(?:\#(names))\b"#,
            // UIKit's system colours, and the bridge into SwiftUI.
            #"\bUIColor\.system\w+"#,
            #"\bColor\(\s*(?:uiColor: )?\.system\w+"#,
            // White and black are not in the tokens either, and a text label drawn over them at an alpha is a tint.
            #"(?<![\w])(?:Color)?\.(?:white|black)\s*\.opacity\("#
        ]
    }()

    /// The uses that exist today, by file. A file not listed here may not use one; a listed file may not use more.
    /// Lower a number, or delete the line, when a use goes. There is no test for slack, so two PRs that each remove or
    /// add a use never turn each other red.
    /// MarginRecordingScreen: the divider, and the end-phrase hint (#3940), white at 75% under the timer.
    /// FootnoteCardView: the note's words (white at 85%) and the card's fill (white at 10%), as `PinnedMarginCardView` draws
    /// the friend's card above the same passage (#3777).
    /// Gate2LiveActivityWidget: the Margin circle's ring, white at 86% on its 16% fill (#4764), measured by its pair.
    private static let systemColorBaseline: [String: Int] = [
        "AppTopBanners.swift": 1, "EdgeSwipeBackTransition.swift": 1, "MarginRecordingScreen.swift": 2,
        "FirstMarginPromptCard.swift": 2, "FootnoteCardView.swift": 2, "Gate1RootView.swift": 1, "Gate2LiveActivityWidget.swift": 14,
        "LiveActivityTourPreview.swift": 1, "LiveSessionActivityWidget.swift": 8, "MiniPlayer.swift": 1,
        "PinnedMarginCardView.swift": 4, "PlaybackFeedbackTagView.swift": 3, "PlaybackLivePassageView.swift": 1,
        "PlaybackMarginRowView.swift": 1, "PlaybackMarginTranscriptionStatusView.swift": 1, "PlaybackPositionSlider.swift": 1,
        "PlaybackScreen.swift": 6, "WatchUntetheredView.swift": 28
    ]

    private func systemColorUses() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for file in try appSwiftFiles() {
            let text = try collapsedText(file)
            var count = 0
            for pattern in Self.systemColorUse { count += try matches(of: pattern, in: text).count }
            if count > 0 { counts[file.lastPathComponent, default: 0] += count }
        }
        return counts
    }

    func testNoNewSystemColourIsDrawnWithoutADecision() throws {
        let uses = try systemColorUses()
        XCTAssertGreaterThan(uses.values.reduce(0, +), 20, "the scan must see the app's system colours")
        var over: [String] = []
        for (file, count) in uses where count > (Self.systemColorBaseline[file] ?? 0) {
            over.append("\(file): \(count) uses, \(Self.systemColorBaseline[file] ?? 0) allowed")
        }
        XCTAssertEqual(
            over.sorted(), [],
            "use a token from AppSemanticColorRGB (the audit measures those), or add the system colour to AppSystemColorRGB with a pair"
        )
    }

    // MARK: Secondary text and placeholders (#3738)

    /// Where `.foregroundStyle(.secondary)` is allowed: the Watch and the Live Activity draw on their own dark plates, and
    /// the Listening options sheet in `PlaybackScreen.swift` is forced dark, so the system grey reads well there. Anywhere
    /// else it is 3.4:1 on white in light mode, and the token `secondaryText` is 4.84:1 or better.
    private static let darkSecondaryAllowed: Set<String> = [
        "PlaybackScreen.swift", "WatchUntetheredView.swift", "SpokenMarginsWatchApp.swift", "Gate2LiveActivityWidget.swift",
        "LiveSessionActivityWidget.swift"
    ]

    func testSecondaryTextOutsideTheDarkSurfacesUsesTheToken() throws {
        var offenders: [String] = []
        for file in try appSwiftFiles() where !Self.darkSecondaryAllowed.contains(file.lastPathComponent) {
            let text = try collapsedText(file)
            let count = try matches(of: #"foregroundStyle\(\s*\.(?:secondary|tertiary|quaternary)\s*\)"#, in: text).count
            if count > 0 { offenders.append("\(file.lastPathComponent): \(count)") }
        }
        XCTAssertEqual(offenders.sorted(), [], "use AppColors.secondaryText: the system grey is 3.4:1 on white")
    }

    /// The default placeholder is a system grey, 1.73:1 on the input fill in light mode. `AppTextField` and
    /// `AppSecureField` draw it in `secondaryText`. Only the system alerts keep a plain field: the system draws those.
    /// The follow lists' alerts (#4046) are three of them: New list in the "Lists for <show>" sheet, New list on the Lists
    /// screen, and Rename on a list's screen.
    private static let plainFieldAllowed: [String: Int] = [
        "ExperienceDesignSystem.swift": 3, "ExperienceItemDetailScreen.swift": 1, "ItemCollectionSheet.swift": 1,
        "SpokenNoteRenameAlert.swift": 1, "FollowListPickerSheet.swift": 1, "FollowListsScreen.swift": 1, "FollowListScreen.swift": 1
    ]

    func testTextFieldsUseTheAppPlaceholderColour() throws {
        var counts: [String: Int] = [:]
        for file in try appSwiftFiles() where !file.path.contains("Watch") {
            let text = try collapsedText(file)
            let count = try matches(of: #"(?<![\w])(?:TextField|SecureField)\("#, in: text).count
            if count > 0 { counts[file.lastPathComponent] = count }
        }
        XCTAssertGreaterThan(counts["ExperienceDesignSystem.swift"] ?? 0, 0, "the scan must see the wrappers' own fields")
        var over: [String] = []
        for (file, count) in counts where count > (Self.plainFieldAllowed[file] ?? 0) {
            over.append("\(file): \(count) plain fields, \(Self.plainFieldAllowed[file] ?? 0) allowed")
        }
        XCTAssertEqual(over.sorted(), [], "use AppTextField or AppSecureField so the placeholder meets contrast")
    }

    // MARK: Colours drawn together (#3739, evidence d)

    /// A token foreground and an opaque token background on one modifier chain, in either order, as `(foreground,
    /// background)` token names: `.foregroundStyle(AppColors.secondaryText) ... .background(AppColors.panel)`. The chain
    /// is the modifiers between the two, up to 300 characters, with no brace, semicolon or other view in between, so two
    /// neighbouring views are never paired. A colour chosen by a ternary is seen too: `isActive ? AppColors.onEvergreen :
    /// AppColors.text` on `isActive ? AppColors.evergreen : AppColors.panel` is two pairs, the first arm on the first
    /// arm and the second on the second (a ternary on one side only is paired with each arm of the other). An arm that
    /// is not a bare token (`.clear`, `Color.white`, a tint with `.opacity(`) is not paired here: a tint has its own scan
    /// above, and a system colour has its own. A colour chosen by a variable or a function is not seen (#3739).
    static func tokenChains(in text: String) throws -> [(foreground: String, background: String)] {
        let background = #"(?:\.background|\.fill)\(\s*(?=[^(),]*AppColors\.)([^(),]*?)\s*[,)]"#
        let foreground = #"(?:foregroundStyle|foregroundColor)\(\s*(?=[^()]*AppColors\.)([^()]*?)\s*\)"#
        let between = #"([^{};]{0,300}?)"#
        let otherView = #"\b(?:Text|Image|Label|Button|HStack|VStack|ZStack|ForEach|Spacer|Section|Toggle|Picker|Link|NavigationLink)\("#
        var chains: [(foreground: String, background: String)] = []
        for (pattern, foregroundGroup, backgroundGroup) in [
            (foreground + between + background, 1, 3), (background + between + foreground, 3, 1)
        ] {
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                func group(_ index: Int) -> String { Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
                if group(2).range(of: otherView, options: .regularExpression) != nil { continue }
                chains += pairedArms(foreground: tokenArms(group(foregroundGroup)), background: tokenArms(group(backgroundGroup)))
            }
        }
        return chains
    }

    /// The arms of a colour argument, each a bare `AppColors` token name or nil: one arm for a plain colour, two for a
    /// ternary (`condition ? first : second`).
    private static func tokenArms(_ argument: String) -> [String?] {
        let arms: [String]
        // The ternary's own ` ? ` and ` : `, so an optional chain (`item?.state`) in the condition is not the question mark.
        if let question = argument.range(of: " ? "), let colon = argument.range(of: " : ", range: question.upperBound..<argument.endIndex) {
            arms = [String(argument[question.upperBound..<colon.lowerBound]), String(argument[colon.upperBound...])]
        } else {
            arms = [argument]
        }
        return arms.map { arm in
            let trimmed = arm.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("AppColors."), trimmed.dropFirst("AppColors.".count).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { return nil }
            return String(trimmed.dropFirst("AppColors.".count))
        }
    }

    private static func pairedArms(foreground: [String?], background: [String?]) -> [(foreground: String, background: String)] {
        let count = max(foreground.count, background.count)
        return (0..<count).compactMap { index in
            let fore = foreground.count == 1 ? foreground[0] : foreground[index]
            let back = background.count == 1 ? background[0] : background[index]
            guard let fore, let back else { return nil }
            return (fore, back)
        }
    }

    /// `AppColors` names that are another token under a second name (`Gate1RootView.swift`), so a chain that uses one is
    /// measured as the token it is.
    private static let tokenAliases = ["watchSecondary": "listeningSecondary", "interjectText": "captureText"]

    private static let tokensByName: [String: AppDynamicRGB] = {
        var tokens = Dictionary(uniqueKeysWithValues: AppSemanticColorRGB.all.map { ($0.name, $0.color) })
        for (alias, name) in tokenAliases { tokens[alias] = tokens[name] }
        return tokens
    }()

    /// Whether the audit has a pair for this foreground on this background, in the same colours in both appearances.
    private static func auditHasPair(
        foreground: String, background: String, in pairs: [AppColorContrastAudit.Pair] = AppColorContrastAudit.allPairs
    ) -> Bool {
        guard let foregroundColor = tokensByName[foreground], let backgroundColor = tokensByName[background] else { return false }
        return pairs.contains { $0.foreground == foregroundColor && $0.background == backgroundColor }
    }

    func testTokenChainScanSeesBothOrdersAndNeverPairsNeighbours() throws {
        let both = "Text(\"a\").foregroundStyle(AppColors.secondaryText).padding().background(AppColors.dangerBackground, in: Capsule())"
        let reversed = "Capsule().fill(AppColors.softGreen).frame(width: 4).foregroundStyle(AppColors.evergreen)"
        let neighbours = "Text(\"a\").foregroundStyle(AppColors.secondaryText) Text(\"b\").background(AppColors.panel)"
        let blocks = "Text(\"a\").foregroundStyle(AppColors.text) } VStack { Color.clear.background(AppColors.bone)"
        XCTAssertEqual(try Self.tokenChains(in: both).map { "\($0.foreground)/\($0.background)" }, ["secondaryText/dangerBackground"])
        XCTAssertEqual(try Self.tokenChains(in: reversed).map { "\($0.foreground)/\($0.background)" }, ["evergreen/softGreen"])
        XCTAssertEqual(try Self.tokenChains(in: neighbours).count, 0)
        XCTAssertEqual(try Self.tokenChains(in: blocks).count, 0)
    }

    /// A colour chosen by a ternary is two pairs, first arm on first arm, never a cross product, and an arm that is a
    /// tint or a system colour is left to the scans that own those (#3739).
    func testTokenChainScanPairsTernaryArmsOneForOne() throws {
        func chains(_ text: String) throws -> [String] { try Self.tokenChains(in: text).map { "\($0.foreground)/\($0.background)" } }
        let both = "Text(\"a\").foregroundStyle(isActive ? AppColors.onEvergreen : AppColors.text).background(isActive ? AppColors.evergreen : AppColors.panel, in: Capsule())"
        let reversed = "Capsule().fill(highlighted ? AppColors.evergreen : AppColors.softGreen).foregroundStyle(highlighted ? AppColors.onEvergreen : AppColors.evergreen)"
        let oneSide = "Text(\"a\").foregroundStyle(isOn ? AppColors.text : AppColors.secondaryText).background(AppColors.panel)"
        let arm = "Text(\"a\").foregroundStyle(isLit ? Color.white : AppColors.watchSecondary).background(isLit ? AppColors.softGreen : AppColors.panel)"
        let tint = "Text(\"a\").foregroundStyle(AppColors.text).background(isLit ? AppColors.softGreen.opacity(0.5) : AppColors.panel)"
        XCTAssertEqual(try chains(both), ["onEvergreen/evergreen", "text/panel"])
        XCTAssertEqual(try chains(reversed), ["onEvergreen/evergreen", "evergreen/softGreen"])
        XCTAssertEqual(try chains(oneSide), ["text/panel", "secondaryText/panel"])
        XCTAssertEqual(try chains(arm), ["watchSecondary/panel"])
        XCTAssertEqual(try chains(tint), [])
        // A system colour or a clear fill earlier in the chain must not swallow the token pair after it.
        let swallowed = "X.foregroundStyle(.secondary).foregroundStyle(AppColors.text).background(AppColors.panel)"
        let clear = "X.foregroundStyle(AppColors.text).background(Color.clear).background(AppColors.panel)"
        XCTAssertEqual(try chains(swallowed), ["text/panel"])
        XCTAssertEqual(try chains(clear), ["text/panel"])
        // An optional chain in the condition is not the ternary's question mark.
        let optional = "X.foregroundStyle(item?.state == nil ? AppColors.text : AppColors.secondaryText).background(AppColors.panel)"
        XCTAssertEqual(try chains(optional), ["text/panel", "secondaryText/panel"])
    }

    /// The case the audit found by hand: a pair nobody listed (`secondaryText` on `dangerBackground` is 4.27:1 in light
    /// mode) is invisible to the token list test, which proves only that each token is in some pair. Here a pair is taken
    /// out of the real list, so the lookup has to say it is missing, and the whole list has to have it.
    func testAPairNobodyListedIsSeen() {
        // Every pair that measures it, not one by name: the Timeline rows' generated pairs measure it too (#3734).
        let withoutIt = AppColorContrastAudit.allPairs.filter {
            !($0.foreground == AppSemanticColorRGB.secondaryText && $0.background == AppSemanticColorRGB.panel)
        }
        XCTAssertLessThan(withoutIt.count, AppColorContrastAudit.allPairs.count)
        XCTAssertFalse(Self.auditHasPair(foreground: "secondaryText", background: "panel", in: withoutIt))
        XCTAssertTrue(Self.auditHasPair(foreground: "secondaryText", background: "panel"))
        XCTAssertEqual(Self.tokensByName["watchSecondary"], Self.tokensByName["listeningSecondary"], "an alias is measured as its token")
    }

    /// Every colour the app really draws on an opaque token fill, in one modifier chain, is a pair the audit measures, so
    /// a new combination fails here until it has a pair (and a pair that fails is a known failure with an issue).
    func testEveryTokenChainTheAppDrawsIsAPairInTheAudit() throws {
        var found: Set<String> = []
        for file in try appSwiftFiles() {
            for chain in try Self.tokenChains(in: try collapsedText(file)) {
                found.insert("\(chain.foreground) on \(chain.background)")
                // Gate1RootView.swift defines `AppColors`; the scan sees no fill there, so an unknown name is a typo or a new token.
                XCTAssertNotNil(Self.tokensByName[chain.foreground], "\(file.lastPathComponent): \(chain.foreground) is not an AppColors token or alias")
                XCTAssertNotNil(Self.tokensByName[chain.background], "\(file.lastPathComponent): \(chain.background) is not an AppColors token or alias")
            }
        }
        XCTAssertGreaterThan(found.count, 5, "the scan must see the app's colour chains")
        let unlisted = found.filter { entry in
            let parts = entry.components(separatedBy: " on ")
            return !Self.auditHasPair(foreground: parts[0], background: parts[1])
        }
        XCTAssertEqual(
            unlisted.sorted(), [],
            "add a pair for it to AppColorContrastAudit.textBackgroundPairs (4.5:1 for text, 3:1 for an icon or shape) and let the audit measure it"
        )
    }
}
