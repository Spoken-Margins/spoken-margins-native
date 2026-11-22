import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #3733: the app had no accent colour, so every default-tinted link, bordered button and dialog button drew in system
/// blue, 3.6:1 on bone. The tint is `AppSemanticColorRGB.evergreen`, set as the asset catalog's global accent (alerts,
/// menus and sheets read it) and as the root `.tint` (toggles read that). These guards keep the asset equal to the token
/// and keep a filled button from drawing the system's white label on a light evergreen fill.
final class AccentColorGuardTests: XCTestCase {
    private struct Components {
        let red: Double, green: Double, blue: Double
    }

    private func appSources() throws -> URL { try TestInputs.directory(.appSources) }

    /// The accent's two appearances, read from the asset: the universal entry and the one marked dark.
    private func accentAppearances() throws -> (light: Components, dark: Components) {
        let url = try appSources().appendingPathComponent("Assets.xcassets/AccentColor.colorset/Contents.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors = try XCTUnwrap(root["colors"] as? [[String: Any]])
        var light: Components?
        var dark: Components?
        for entry in colors {
            let color = try XCTUnwrap(entry["color"] as? [String: Any])
            XCTAssertEqual(color["color-space"] as? String, "srgb")
            let values = try XCTUnwrap(color["components"] as? [String: String])
            func channel(_ name: String) throws -> Double { try XCTUnwrap(values[name].flatMap(Double.init)) }
            let components = Components(red: try channel("red"), green: try channel("green"), blue: try channel("blue"))
            let appearances = entry["appearances"] as? [[String: String]] ?? []
            if appearances.contains(where: { $0["appearance"] == "luminosity" && $0["value"] == "dark" }) {
                dark = components
            } else if appearances.isEmpty {
                light = components
            }
        }
        return (try XCTUnwrap(light, "the accent asset has no universal (light) colour"), try XCTUnwrap(dark, "the accent asset has no dark colour"))
    }

    func testTheAccentAssetIsTheEvergreenToken() throws {
        let accent = try accentAppearances()
        let token = AppSemanticColorRGB.evergreen
        // The asset stores three decimals, so it is checked to within a 255th, as a colour channel is.
        for (name, asset, expected) in [("light", accent.light, token.light), ("dark", accent.dark, token.dark)] {
            XCTAssertEqual(asset.red, expected.red, accuracy: 1.0 / 255, "\(name) red")
            XCTAssertEqual(asset.green, expected.green, accuracy: 1.0 / 255, "\(name) green")
            XCTAssertEqual(asset.blue, expected.blue, accuracy: 1.0 / 255, "\(name) blue")
        }
    }

    /// Every `.borderedProminent` fills with the tint and draws the system's white label unless the label is set. On the
    /// dark-mode evergreen that is about 1.8:1 (#537), so each one sets `.foregroundStyle(` within the next three lines
    /// (`filledActionButton()` does, and so do the buttons that set their own tint and label).
    func testEveryFilledButtonSetsItsOwnLabelColour() throws {
        let directory = try appSources()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var checked = 0
        var bare: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(".borderedProminent") {
                checked += 1
                let following = lines[(index + 1)..<min(index + 4, lines.count)]
                if !following.contains(where: { $0.contains(".foregroundStyle(") }) {
                    bare.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 3, "the scan must see the app's filled buttons")
        XCTAssertEqual(bare.sorted(), [], "use .filledActionButton(), or set .foregroundStyle on the button")
    }

    func testTheAccentPairsAreMeasuredAndPass() {
        let names = Set(AppColorContrastAudit.allPairs.map(\.name))
        for pair in AppColorContrastAudit.accentPairs { XCTAssertTrue(names.contains(pair.name), pair.name) }
        XCTAssertEqual(AppColorContrastAudit.failures(for: AppColorContrastAudit.accentPairs), [])
        XCTAssertFalse(AppColorContrastAudit.accentPairs.isEmpty)
    }
}
