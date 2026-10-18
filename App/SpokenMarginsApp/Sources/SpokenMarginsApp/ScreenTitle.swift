import SwiftUI

extension View {
    /// Marks a hand-built screen or section title as a heading, so the VoiceOver Headings rotor can jump
    /// between titles (#1916). Use it on the title's `Text`; it changes nothing visually.
    func screenTitle() -> some View {
        accessibilityAddTraits(.isHeader)
    }
}
