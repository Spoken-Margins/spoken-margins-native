import SwiftUI

@main
struct SpokenMarginsApp: App {
    @StateObject private var model = Gate1AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Gate1RootView()
                .environmentObject(model)
                .onOpenURL { url in
                    model.handleIncomingURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.importPendingSourceLinkHandoffs()
                    }
                }
                .task {
                    model.importPendingSourceLinkHandoffs()
                }
        }
    }
}
