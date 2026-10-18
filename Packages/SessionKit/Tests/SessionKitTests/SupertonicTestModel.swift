import Foundation
import SessionKitSupertonic
import SessionKitTestInputs
import XCTest

/// Supertonic's real model for the tests that render with it. It is a download, in neither the repository nor
/// the app (#1820), so these tests read the `supertonicModel` input and skip, naming it and how to fetch it,
/// when it isn't there.
enum SupertonicTestModel {
    static func assets() throws -> SupertonicAssetLocation {
        let assets = SupertonicAssetLocation(rootURL: try TestInputs.supertonicModel())
        do {
            try assets.validate()
        } catch {
            throw XCTSkip("needs supertonicModel: the fetched folder is incomplete (\(error.localizedDescription)); run `scripts/voice-catalog fetch supertonic-3-int8`")
        }
        return assets
    }
}
