import SwiftUI

/// A paragraph mark for paragraph skips; a text glyph for other configured text units.
struct PlaybackTextSkipIcon: View {
    enum Direction { case backward, forward }
    let direction: Direction
    let unit: String

    var body: some View {
        HStack(spacing: 3) {
            if direction == .backward { Image(systemName: "chevron.left").font(.caption.bold()) }
            if unit == "paragraph" {
                Text("¶")
            } else {
                Image(systemName: "text.alignleft")
            }
            if direction == .forward { Image(systemName: "chevron.right").font(.caption.bold()) }
        }
        .accessibilityHidden(true) // The transport button retains its unit-specific spoken label.
    }
}

#Preview("Text skip units") {
    HStack {
        PlaybackTextSkipIcon(direction: .backward, unit: "paragraph")
        PlaybackTextSkipIcon(direction: .forward, unit: "paragraph")
        PlaybackTextSkipIcon(direction: .forward, unit: "sentence")
    }
    .font(.title2)
    .padding()
}
