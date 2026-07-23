import SwiftUI
#if canImport(UIKit)
import UIKit

@MainActor
enum PodcastBackgroundSessionEvents {
    private static var completionHandler: (() -> Void)?

    static func store(_ completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
    }

    static func completeIfPending() {
        completionHandler?()
        completionHandler = nil
    }
}

final class SpokenMarginsAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == PodcastDownloadCoordinator.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        PodcastBackgroundSessionEvents.store(completionHandler)
    }
}
#endif

@main
struct SpokenMarginsApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(SpokenMarginsAppDelegate.self) private var appDelegate
    #endif
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
                        model.handleAppBecameActive()
                    } else if phase == .inactive || phase == .background {
                        model.syncPlaybackProgressForLifecycle()
                    }
                }
                #if canImport(UIKit)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    model.handleMemoryWarning()
                }
                #endif
                .task {
                    model.importPendingSourceLinkHandoffs()
                }
        }
    }
}
