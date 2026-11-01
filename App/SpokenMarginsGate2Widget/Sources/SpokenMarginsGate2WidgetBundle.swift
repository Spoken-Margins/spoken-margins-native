import SwiftUI
import WidgetKit

/// The extension's entry point, in its own file so the app can compile Gate2LiveActivityWidget.swift for its layout
/// tests without a second `@main` (#1940).
@main
struct SpokenMarginsGate2WidgetBundle: WidgetBundle {
    var body: some Widget {
        Gate2LiveActivityWidget()
        LiveSessionActivityWidget()
    }
}
