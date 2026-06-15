import SwiftUI

@main
struct SpokenMarginsWatchApp: App {
    @StateObject private var model = WatchTetheredModel()

    var body: some Scene {
        WindowGroup {
            WatchTetheredView()
                .environmentObject(model)
        }
    }
}
