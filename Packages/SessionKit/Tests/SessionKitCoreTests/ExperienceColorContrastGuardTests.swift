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
    /// measured by `timelineRowPairs`; `noText` means no text sits on it (a hairline, a stripe, a pressed state, a
    /// plain shape); `unaudited` is a fill with text or an icon on it that no pair measures yet, left for #3739's next
    /// slices. A new tint is not in this list, so it fails until someone says which of the three it is. The key is the token and the
    /// alpha, not the call site: a new text fill that reuses an audited key is not seen, so give it a new alpha or a pair.
    private enum TintKind: Equatable { case audited, noText, unaudited }

    private static let tints: [String: TintKind] = [
        "evergreen@0.12": .audited, "evergreen@0.07": .audited, "coral@0.08": .audited, "ochre@0.08": .audited,
        "plum@0.07": .audited,
        // Card borders: `ExperienceSurface(tint:)` strokes with it, on a panel fill.
        "coral@0.34": .noText, "evergreen@0.18": .noText, "ochre@0.16": .noText, "ochre@0.65": .noText,
        "ochre@0.7": .noText, "ochre@0.5": .noText, "evergreen@0.5": .noText,
        "plum@0.4": .noText, "plum@0.08": .noText,
        // Strokes, stripes and dots.
        "evergreen@0.25": .noText, "bone@0.75": .noText, "border@0.75": .noText, "border@0.8": .noText,
        // Fills with text or an icon on them that no pair measures yet.
        "ochre@0.20": .unaudited, "plum@0.16": .unaudited, "ochre@0.12": .unaudited, "evergreen@0.16": .unaudited,
        "listeningAccent@0.18": .unaudited, "border@0.45": .unaudited, "softGreen@0.85": .unaudited,
        "softGreen@0.55": .unaudited,
        // The Watch's plates and the playback card's own controls; the pressed state is the alpha.
        "watchControl@0.8": .unaudited, "watchControl@0.72": .unaudited, "watchControl@0.35": .unaudited,
        // Their button labels are drawn on the dimmed fill.
        "panel@0.75": .unaudited, "listeningAccent@0.75": .unaudited, "captureBackground@0.78": .unaudited,
        "primaryAction@0.78": .unaudited, "softGreen@0.7": .unaudited
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
            let marker = "on \(parts[0]) at \(parts[1]) over"
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
