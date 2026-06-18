import SwiftUI

@main
struct SpokenMarginsWatchApp: App {
    @StateObject private var model = WatchTetheredModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                WatchUntetheredView()
                WatchTetheredView()
            }
            .tabViewStyle(.verticalPage)
            .environmentObject(model)
        }
    }
}
