import SwiftUI
import UserNotifications
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
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = ListeningReadyNotifications.shared
        #if canImport(BackgroundTasks)
        AudioPreparationBackgroundController.shared.register()
        #endif
        return true
    }

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
@MainActor
struct SpokenMarginsApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(SpokenMarginsAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var model: Gate1AppModel
    @StateObject private var sharingCoordinator: Build23SharingCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = Gate1AppModel.makeApplicationModel()
        #if !SPOKEN_MARGINS_LEGACY
        ListeningEditionShortcutBridge.model = model
        #endif
        _model = StateObject(wrappedValue: model)
        _sharingCoordinator = StateObject(
            wrappedValue: Build23SharingCoordinator(model: model)
        )
    }

    var body: some Scene {
        WindowGroup {
            Gate1RootView()
                .environmentObject(model)
                .environmentObject(sharingCoordinator)
                .onReceive(NotificationCenter.default.publisher(for: ListeningReadyNotifications.opened)) { _ in model.openReadyListeningEdition() }
                .onOpenURL { url in
                    model.handleIncomingURL(url)
                }
                .onCompatibleChange(of: scenePhase) { phase in
                    if phase == .active {
                        model.handleAppBecameActive()
                    } else if phase == .inactive || phase == .background {
                        model.handleAppBecameInactiveOrBackground()
                    }
                }
                #if canImport(UIKit)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    model.handleMemoryWarning()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    model.handleApplicationWillTerminate()
                }
                #endif
                .task {
                    model.importPendingSourceLinkHandoffs()
                }
        }
    }
}
