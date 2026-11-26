import SwiftUI

extension Color {
    /// A plate colour from `WatchPlatePalette`, which has its own colour type because the Watch compiles it alone (#3731).
    init(_ color: WatchPlateColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}
