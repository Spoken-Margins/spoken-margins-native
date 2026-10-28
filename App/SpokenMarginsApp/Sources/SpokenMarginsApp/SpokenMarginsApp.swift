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
        DevicePowerSource.app.startMonitoring() // charging lengthens the render-ahead window (#2703)
        #if canImport(BackgroundTasks)
        AudioPreparationBackgroundController.shared.register()
        FollowedSourceBackgroundRefreshController.shared.register()
        ContinuedAudioPreparationController.shared.register()
        #endif
        WatchMarginReceiver.shared.activate() // Watch Margins (#2487), including a transfer that woke the app
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == BackgroundVoiceModelTransport.sessionIdentifier {
            BackgroundVoiceModelTransport.shared.handleBackgroundEvents(completion: completionHandler)
            return
        }
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
    @StateObject private var catalogDrawer: CatalogDrawerModel
    @StateObject private var playbackStartCue: PlaybackStartCue
    @StateObject private var bridge: BridgeService
    @Environment(\.scenePhase) private var scenePhase
    private let memoryFootprint: MemoryFootprintRecorder
    private let systemConditions: SystemConditionRecorder
    #if canImport(MetricKit)
    private let memoryExits: MemoryExitMetricsSubscriber
    private let previousRunExit: PreviousRunExitRecorder
    #endif

    init() {
        let model = Gate1AppModel.makeApplicationModel()
        // Memory use and memory kills, in Diagnostics (#122). Unit tests keep nothing on disk.
        let runningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let pinnedDiagnostics = PinnedDiagnostics(diagnostics: model.runtimeDiagnostics)
        let memoryFootprint = MemoryFootprintRecorder(diagnostics: pinnedDiagnostics,
                                                      fileURL: runningTests ? nil : MemoryFootprintRecorder.defaultFileURL)
        memoryFootprint.start(observing: model)
        self.memoryFootprint = memoryFootprint
        #if canImport(MetricKit)
        let memoryExits = MemoryExitMetricsSubscriber()
        memoryExits.start { line in pinnedDiagnostics.set(MemoryExitMetricsSubscriber.diagnosticsKey, line) }
        self.memoryExits = memoryExits
        #endif
        // Why iOS ended the last run, and the heat and memory warnings of this one, in Diagnostics (#1682).
        // Unit tests have no MetricKit history to read.
        let systemConditions = SystemConditionRecorder { [weak model] kind, fields in
            model?.recordDeveloperDiagnostic(kind, fields)
        }
        systemConditions.start()
        self.systemConditions = systemConditions
        #if canImport(MetricKit)
        let previousRunExit = PreviousRunExitRecorder()
        if !runningTests {
            previousRunExit.start { [weak model] kind, fields in
                model?.recordDeveloperDiagnostic(kind, fields)
            }
        }
        self.previousRunExit = previousRunExit
        #endif
        #if !SPOKEN_MARGINS_LEGACY
        ListeningEditionShortcutBridge.model = model
        #endif
        #if canImport(BackgroundTasks) && canImport(UIKit)
        // The same refresh as in the foreground, with the same six-hour staleness (#170).
        FollowedSourceBackgroundRefreshController.shared.install { [weak model] in await model?.performFollowedSourceRefresh(force: false) }
        #endif
        // A voice download iOS finished or woke the app for in the background carries on (#1819).
        BackgroundVoiceModelTransport.shared.onBackgroundEvents = { [weak model] in
            Task { @MainActor in await model?.requireVoiceDownloads().resumePending() }
        }
        _model = StateObject(wrappedValue: model)
        _playbackStartCue = StateObject(wrappedValue: PlaybackStartCue(model: model, pinned: pinnedDiagnostics))
        _bridge = StateObject(wrappedValue: BridgeService(store: BridgeService.makeStore()))
        _sharingCoordinator = StateObject(
            wrappedValue: Build23SharingCoordinator(model: model)
        )
        _catalogDrawer = StateObject(wrappedValue: CatalogDrawerModel(
            store: CatalogDrawerModel.makeStore(),
            subscriptions: { [weak model] in model?.feedSubscriptions ?? [] },
            follow: { [weak model] feedURL in
                guard let model else { throw CancellationError() }
                return try await model.followCatalogFeed(feedURL)
            },
            makeOPMLImport: { [weak model] in
                OPMLImportModel(
                    subscriptions: { model?.storedFeedSubscriptions() ?? [] },
                    follow: { feedURL in
                        guard let model else { throw CancellationError() }
                        _ = try await model.followCatalogFeed(feedURL, refreshAfter: false)
                    },
                    didFollow: { model?.refreshFollowedSources(force: false) }
                )
            },
            searcher: CatalogDrawerModel.makeSearcher()
        ))
    }

    var body: some Scene {
        WindowGroup {
            Gate1RootView()
                .environmentObject(model)
                .environmentObject(sharingCoordinator)
                .environmentObject(catalogDrawer)
                .environmentObject(bridge)
                .onReceive(NotificationCenter.default.publisher(for: ListeningReadyNotifications.opened)) { _ in model.openReadyListeningEdition() }
                .onOpenURL { url in
                    if LiveSessionLinkRouter.shared.handle(url) { return }
                    model.handleIncomingURL(url)
                }
                .onCompatibleChange(of: scenePhase) { phase in
                    if phase == .active {
                        model.handleAppBecameActive()
                    } else if phase == .inactive || phase == .background {
                        model.handleAppBecameInactiveOrBackground(entersBackground: phase == .background)
                        #if canImport(BackgroundTasks) && canImport(UIKit)
                        if phase == .background { FollowedSourceBackgroundRefreshController.shared.schedule(enabled: !model.storedFeedSubscriptions().isEmpty) }
                        #endif
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
