import SessionKit
import SessionKitAudio
import SessionKitSharing
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
        // A live session photo no Margin names (a crash between its move and the Margin's save) is removed once per launch,
        // before any live-session screen opens (#2708). It runs on the file worker, so it is off the main thread and
        // serialized with every filing; a screen can't open in the milliseconds before it. Unit tests have no launch to clean up after.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task.detached(priority: .utility) { await LiveSessionFileWorker.shared.sweepPhotos() }
        }
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
        // How long each launch takes to reach a usable screen, kept across launches (#3752). First, so the
        // time before the model exists counts. Unit tests have no launch to time.
        let runningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !runningTests {
            LaunchRecorder.shared = LaunchRecorder()
        }
        let model = Gate1AppModel.makeApplicationModel()
        // Memory use and memory kills, in Diagnostics (#122). Unit tests keep nothing on disk.
        let pinnedDiagnostics = PinnedDiagnostics(diagnostics: model.runtimeDiagnostics)
        LaunchRecorder.shared?.attach { key, value in pinnedDiagnostics.set(key, value) }
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
                LaunchRecorder.shared?.noteExit(fields: fields) // the event log's 300 can push it out (#3752)
            }
        }
        self.previousRunExit = previousRunExit
        #endif
        #if !SPOKEN_MARGINS_LEGACY
        ListeningEditionShortcutBridge.model = model
        #endif
        #if SM_LOCKED_MARGIN_SPIKE
        model.installLockedMarginIntentBridge() // phone builds only (#3086)
        #endif
        #if canImport(BackgroundTasks) && canImport(UIKit)
        // The same refresh as in the foreground, with the same six-hour staleness (#170).
        FollowedSourceBackgroundRefreshController.shared.install { [weak model] in await model?.performFollowedSourceRefresh(force: false) }
        #endif
        // A voice download iOS finished or woke the app for in the background carries on (#1819).
        BackgroundVoiceModelTransport.shared.onBackgroundEvents = { [weak model] in
            Task { @MainActor in await model?.requireVoiceDownloads().resumePending() }
        }
        // Which notes this phone's voices can read, so the count of new Margins follows them (#3402).
        WrittenMarginVoiceCoverage.shared.install { [weak model] in
            Task { @MainActor in model?.hangTelemetry.labels.scoped("writtenMarginVoicesChanged") { model?.writtenMarginVoicesChanged() } }
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
                    subscriptions: { model?.feedSubscriptions ?? [] },
                    follow: { feedURL in
                        guard let model else { throw CancellationError() }
                        _ = try await model.followCatalogFeed(feedURL, refreshAfter: false)
                    },
                    didFollow: { model?.refreshFollowedSources(force: false) }
                )
            },
            searcher: CatalogDrawerModel.makeSearcher(),
            startFirstListen: { [weak model] sourceIds, allowsWelcome in
                await model?.startFirstListen(pickedSourceIds: sourceIds, allowsWelcomeSample: allowsWelcome)
            }
        ))
    }

    private func open(_ url: URL) {
        // First, before any router can swallow it: the export then tells a Live Activity tap that reached the app from
        // one that never did. Kind, host word and command only, never a path, query or key (#4031).
        model.recordDeveloperDiagnostic("url.received", IncomingURLDiagnostic.fields(
            for: url, appScheme: Gate2CompactCommandURL.scheme, compactHost: Gate2CompactCommandURL.host))
        let url = UITestingHooks.handedOffShareLink(url) ?? url
        if LiveSessionLinkRouter.shared.handle(url) { return }
        // A friend's file comes before the first-run drawer (#3291).
        if ShareLinkURL.isOnShareHost(url)
            || (url.isFileURL && url.pathExtension.lowercased() == SpokenMarginsPackageArchive.fileExtension) {
            catalogDrawer.friendFileArrived()
        }
        model.handleIncomingURL(url)
    }

    var body: some Scene {
        WindowGroup {
            Gate1RootView()
                .environmentObject(model)
                .environmentObject(sharingCoordinator)
                .environmentObject(catalogDrawer)
                .environmentObject(bridge)
                // Nil outside a UI test that names an appearance: the app follows the device (#4017).
                .preferredColorScheme(UITestingHooks.appearanceRequest.flatMap { $0 == "dark" ? ColorScheme.dark : ($0 == "light" ? .light : nil) })
                .onReceive(NotificationCenter.default.publisher(for: ListeningReadyNotifications.opened)) { _ in model.openReadyListeningEdition() }
                .onOpenURL(perform: open)
                .onCompatibleChange(of: scenePhase) { phase in
                    if phase == .active {
                        MainThreadOperationLabels.shared.scoped("scene.active") { model.handleAppBecameActive() }
                    } else if phase == .inactive || phase == .background {
                        MainThreadOperationLabels.shared.scoped("scene.inactiveOrBackground") { model.handleAppBecameInactiveOrBackground(entersBackground: phase == .background) }
                        #if canImport(BackgroundTasks) && canImport(UIKit)
                        if phase == .background {
                            // Read off main (#2508): the published list can predate the launch refresh.
                            Task { await model.publishFeedSubscriptionsAfterChange(); FollowedSourceBackgroundRefreshController.shared.schedule(enabled: !model.feedSubscriptions.isEmpty) }
                        }
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
                    MainThreadOperationLabels.shared.scoped("launch.sourceLinkHandoffs") { model.importPendingSourceLinkHandoffs() }
                    #if DEBUG
                    // The screen tour's packets (#3237) open the way a listener's tap does.
                    if let packet = UITestingHooks.packetToOpen() { open(packet) }
                    #endif
                }
                #if DEBUG
                .overlay {
                    // The screen tour's Live Activity card (#1940); only a UI-test launch names a text size.
                    if let name = UITestingHooks.liveActivityPreviewTextSize,
                       let preview = LiveActivityTourPreview(textSizeName: name) {
                        preview
                    }
                }
                #endif
        }
    }
}
