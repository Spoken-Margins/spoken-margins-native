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

    /// #3734: the audit's hand-computed numbers for the Timeline rows in light mode.
    func testTheTimelineRowFindingsAreMeasured() throws {
        XCTAssertEqual(try ratio("row detail on evergreen at 0.12 over bone", "light"), 3.97, accuracy: 0.01)
        XCTAssertEqual(try ratio("row detail on evergreen at 0.07 over bone", "light"), 4.32, accuracy: 0.01)
        XCTAssertEqual(try ratio("row detail on coral at 0.08 over bone", "light"), 4.34, accuracy: 0.01)
        XCTAssertEqual(try ratio("row detail on plum at 0.07 over bone", "light"), 4.35, accuracy: 0.01)
        XCTAssertEqual(try ratio("my Margin row label on coral at 0.08 over bone", "light"), 4.44, accuracy: 0.01)
    }

    /// #3731: white on the system orange and blue, from Apple's published values.
    func testTheWatchPlateFindingsAreMeasured() throws {
        XCTAssertEqual(try ratio("watch session plate label", "dark"), 2.06, accuracy: 0.01)
        XCTAssertEqual(try ratio("watch episode and Record plate label", "dark"), 3.65, accuracy: 0.01)
    }

    /// Each finding is a known failure until its own issue fixes it, so a fix that works has to delete the entry.
    func testEveryNewFindingIsListedAsKnownUntilItsIssueFixesIt() {
        let listed = Set(AppColorContrastAudit.knownFailures.map { "\($0.pair) [\($0.appearance)]" })
        let measured = AppColorContrastAudit.measurements(for: AppColorContrastAudit.timelineRowPairs + AppColorContrastAudit.watchPlatePairs)
        let failing = measured.filter(\.fails).map { "\($0.pair) [\($0.appearance)]" }
        XCTAssertFalse(failing.isEmpty, "the audit must see the findings")
        XCTAssertEqual(Set(failing).subtracting(listed), [], "an unlisted failure is a new bug: fix it or list it with its issue")
        XCTAssertEqual(AppColorContrastAudit.staleKnownFailures(), [])
    }
}

final class AppLiveActivityPairsTests: XCTestCase {
    /// The same pairs on a white surface: every pair with a light mark on it has to fail, or the audit measures nothing.
    private func onWhite(_ pairs: [AppColorContrastAudit.Pair]) -> [AppColorContrastAudit.Pair] {
        pairs.map { .init(name: $0.name, foreground: $0.foreground, background: AppSemanticColorRGB.white, minimumRatio: $0.minimumRatio) }
    }

    func testTheLiveActivityPairsPassTodayExceptTheListedBlue() {
        XCTAssertFalse(AppColorContrastAudit.liveActivityPairs.isEmpty)
        let failing = AppColorContrastAudit.failures(for: AppColorContrastAudit.liveActivityPairs)
        XCTAssertEqual(failing.count, 1, "\(failing)")
        XCTAssertTrue(failing[0].hasPrefix("live activity button label tint (blue) [light]"), "\(failing)")
        XCTAssertTrue(AppColorContrastAudit.knownFailures.contains { $0.pair == "live activity button label tint (blue)" && $0.appearance == "light" })
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
        for alpha in ["0.74", "0.78", "0.8", "0.84", "0.86"] {
            XCTAssertTrue(text.contains(".white.opacity(\(alpha))"), "white at \(alpha) is no longer drawn: drop its pair")
        }
        for alpha in ["0.16", "0.12", "0.14"] {
            XCTAssertTrue(text.contains("Color.white.opacity(\(alpha))"), "the white chip at \(alpha) is no longer drawn: drop its pair")
        }
        XCTAssertTrue(text.contains("Color.green.opacity(0.28)"), "the system green chip")
        XCTAssertTrue(text.contains("? .red : .orange"), "the recording tint")
        XCTAssertTrue(text.contains(".tint(.blue)"), "the blue button tint")
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
        "evergreen@0.12": .audited, "evergreen@0.07": .audited, "coral@0.08": .audited, "ochre@0.08": .audited,
        "plum@0.07": .audited,
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
        "border@0.45": .noText,
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
    private static let systemColorBaseline: [String: Int] = [
        "AppTopBanners.swift": 1, "EdgeSwipeBackTransition.swift": 1, "ExperienceRecordingScreen.swift": 1,
        "FirstMarginPromptCard.swift": 2, "Gate1RootView.swift": 1, "Gate2LiveActivityWidget.swift": 13,
        "LiveActivityTourPreview.swift": 1, "LiveSessionActivityWidget.swift": 8, "MiniPlayer.swift": 1,
        "PinnedMarginCardView.swift": 4, "PlaybackFeedbackTagView.swift": 3, "PlaybackLivePassageView.swift": 1,
        "PlaybackMarginRowView.swift": 1, "PlaybackMarginTranscriptionStatusView.swift": 1, "PlaybackMarginsFilterView.swift": 2,
        "PlaybackNativeTextPeekView.swift": 1, "PlaybackPaneSwitchView.swift": 2, "PlaybackPositionSlider.swift": 1,
        "PlaybackScreen.swift": 6, "SpokenMarginsWatchApp.swift": 5, "VoicesSettingsScreen.swift": 2,
        "WatchUntetheredView.swift": 28
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
    /// `AppSecureField` draw it in `secondaryText`. Only the three system alerts keep a plain field: the system draws those.
    private static let plainFieldAllowed: [String: Int] = [
        "ExperienceDesignSystem.swift": 3, "ExperienceItemDetailScreen.swift": 1, "ItemCollectionSheet.swift": 1,
        "SpokenNoteRenameAlert.swift": 1
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
}
