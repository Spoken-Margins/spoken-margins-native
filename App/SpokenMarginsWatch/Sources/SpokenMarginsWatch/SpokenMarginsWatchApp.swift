import SwiftUI

@main
struct SpokenMarginsWatchApp: App {
    @StateObject private var library = WatchOfflineLibraryModel()
    @StateObject private var playback = WatchLocalPlaybackModel()
    @StateObject private var connectivity = WatchConnectivityInbox()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchUntetheredView()
            }
            .environmentObject(library)
            .environmentObject(playback)
            .environmentObject(connectivity)
            .task {
                connectivity.attach(library: library, playback: playback)
                library.refresh()
            }
        }
    }
}
