import SwiftUI

@main
struct SpokenMarginsApp: App {
    @StateObject private var model = Gate1AppModel()

    var body: some Scene {
        WindowGroup {
            Gate1RootView()
                .environmentObject(model)
        }
    }
}
