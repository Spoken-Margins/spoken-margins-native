import SessionKit
import SwiftUI

/// The one-time card that teaches the Apple Watch's own **Return to App** setting (#4563). Whether it is owed and when
/// it may open is `WatchReturnToAppTipPolicy`; this holds the sheet's state and the seen flag. Nothing here touches
/// the Watch.
///
/// A shared instance, like `LiveSessionLinkRouter.shared`, so the root view, Settings and the Library load can all
/// reach it without new `init` parameters (`Gate1RootView` is a hot file and Settings' equality stays as it is).
/// Tests build their own over a throwaway `UserDefaults` suite.
@MainActor
final class WatchReturnToAppTipNotice: ObservableObject {
    static let shared = WatchReturnToAppTipNotice()

    @Published var isPresented = false
    @Published private(set) var pairing: WatchPairingState = .none
    /// Whether the Library already held a Margin when this launch loaded it. Nil until it has loaded; set once.
    @Published private(set) var hadMarginAtLaunch: Bool?

    private let defaults: UserDefaults
    private let forcesNoWatch: Bool
    /// The card on screen was opened from Settings' row, which never touches the seen flag.
    private var openedFromSettings = false

    /// - Parameter forcesNoWatch: scripted UI runs never meet the card or the Settings row, even on a paired
    ///   simulator (the hosted simulators aren't paired today, and this keeps it that way if one ever is).
    init(defaults: UserDefaults = .standard, forcesNoWatch: Bool = UITestingHooks.isActive) {
        self.defaults = defaults
        self.forcesNoWatch = forcesNoWatch
    }

    private var hasSeen: Bool { defaults.bool(forKey: WatchReturnToAppTipPolicy.seenKey) }

    /// Called when the Library has loaded. Only the first call in a launch counts, so a Margin made later in the same
    /// launch never brings the card into the first run.
    func noteLibraryLoaded(hadMargin: Bool) {
        guard hadMarginAtLaunch == nil else { return }
        hadMarginAtLaunch = hadMargin
    }

    func updatePairing(_ state: WatchPairingState) {
        pairing = forcesNoWatch ? .none : state
    }

    /// The card is owed this launch. The root keeps re-checking for a quiet moment only while this is true.
    var isOwed: Bool {
        WatchReturnToAppTipPolicy.isOwed(pairing: pairing, hasSeen: hasSeen, hadMarginAtLaunch: hadMarginAtLaunch)
    }

    func presentIfNeeded(calm: Bool, supertonicDecided: Bool, supertonicShownThisLaunch: Bool) {
        guard !isPresented else { return }
        let decision = WatchReturnToAppTipPolicy.decide(
            pairing: pairing,
            hasSeen: hasSeen,
            hadMarginAtLaunch: hadMarginAtLaunch,
            calm: calm,
            supertonicDecided: supertonicDecided,
            noticeShownThisLaunch: supertonicShownThisLaunch
        )
        if decision == .show {
            openedFromSettings = false
            isPresented = true
        }
    }

    /// The card calls this when it appears. The flag is written here, not when the card was asked for, so a dropped
    /// presentation can't lose it and a kill with the card up doesn't bring it back.
    func cardAppeared() {
        guard !openedFromSettings else { return }
        defaults.set(true, forKey: WatchReturnToAppTipPolicy.seenKey)
    }

    /// Settings' row: open the card whatever the quiet check says. Settings is on the tabs.
    func openFromSettings() {
        openedFromSettings = true
        isPresented = true
    }

    func close() {
        isPresented = false
    }
}

/// The root's half of the card: offer it at the first quiet moment, and show it as a sheet.
struct WatchReturnToAppTipPresentation: ViewModifier {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var catalogDrawer: CatalogDrawerModel
    @ObservedObject private var notice = WatchReturnToAppTipNotice.shared
    @ObservedObject private var liveLinks = LiveSessionLinkRouter.shared
    @ObservedObject var supertonicNotice: SupertonicDownloadNotice
    let keyboardIsPresented: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// Bumped every 2 seconds while the card is owed. The loop can't read live values (a `.task` closure holds the
    /// modifier as it was when the task started), so it only bumps this, and the `onChange` below reads fresh ones.
    @State private var recheckTick = 0

    /// The tabs are on screen and the listener is doing nothing else. UIKit's own presentations are asked separately,
    /// only when the card is owed (`attemptToPresent`).
    private var calmInSwiftUI: Bool {
        scenePhase == .active && model.screen == .home && model.writtenMarginDraft == nil && !model.snapshot.isRecording
            && !model.isRequestingRecordingPermission && !keyboardIsPresented
    }

    /// The root has to give its screen to something else, so an open card closes (it still counts as seen).
    private var rootNeedsScreen: Bool {
        model.snapshot.isRecording || model.isRequestingRecordingPermission || model.writtenMarginDraft != nil
            || model.spokenMarginsPackageImportReview != nil || model.isTermsOfUsePresented
            || liveLinks.cover != nil
            || catalogDrawer.isPresented || model.isHelpPresented || model.isSharingInterjectionsPresented
    }

    /// While the card is owed and the tabs are up, ask again every 2 seconds: a tab's own sheet closing isn't
    /// reported to the root, and SwiftUI doesn't observe UIKit's presentations.
    private var keepsChecking: Bool {
        notice.isOwed && !notice.isPresented && !supertonicNotice.shownThisLaunch && model.screen == .home
    }

    private func attemptToPresent() {
        guard notice.isOwed, !notice.isPresented else { return }
        notice.presentIfNeeded(
            calm: calmInSwiftUI && !ShareFilePresenter.rootHasPresentation(),
            supertonicDecided: supertonicNotice.decidedThisLaunch,
            supertonicShownThisLaunch: supertonicNotice.shownThisLaunch
        )
    }

    func body(content: Content) -> some View {
        content
            .task {
                WatchMarginReceiver.shared.onPairingChange = { WatchReturnToAppTipNotice.shared.updatePairing($0) }
                notice.updatePairing(WatchMarginReceiver.shared.currentPairingState())
                attemptToPresent()
            }
            .task(id: keepsChecking) {
                guard keepsChecking else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    recheckTick += 1
                }
            }
            .onChange(of: recheckTick) { attemptToPresent() }
            .onChange(of: calmInSwiftUI) { attemptToPresent() }
            .onChange(of: notice.pairing) { attemptToPresent() }
            .onChange(of: notice.hadMarginAtLaunch) { attemptToPresent() }
            .onChange(of: supertonicNotice.decidedThisLaunch) { attemptToPresent() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                notice.updatePairing(WatchMarginReceiver.shared.currentPairingState())
                attemptToPresent()
            }
            .onChange(of: rootNeedsScreen) { _, needs in
                if needs, notice.isPresented { notice.close() }
            }
            .trackedSheet(isPresented: $notice.isPresented) {
                WatchReturnToAppTipCard(appeared: { notice.cardAppeared() }, gotIt: { notice.close() })
            }
    }
}

/// The card. Static words, so it has one state: no loading, empty, error or offline.
struct WatchReturnToAppTipCard: View {
    let appeared: () -> Void
    let gotIt: () -> Void

    static let header = "Keep Spoken Margins on your Watch"
    static let introduction = "Turn on Return to App, and Spoken Margins stays on your wrist while you listen, ready for a Margin."
    static let subheading = "On your Apple Watch:"
    static let timingFootnote = "Return to Clock also sets how long your Watch waits before it goes back to the clock face."
    static let whereToFindFootnote = "These steps stay in Settings, under How Spoken Margins Works."

    /// The words and the button together whenever they fit the sheet. At accessibility text sizes the words scroll and
    /// Got It stays in a bottom inset, the way `SupertonicDownloadNoticeCard` does (#3724).
    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 16) {
                words
                button
            }
            .padding(24)
            ScrollView {
                words
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                button
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .background(.regularMaterial)
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: appeared)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchTip.card")
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(Self.header)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColors.text)
            } icon: {
                Image(systemName: "applewatch")
                    .foregroundStyle(AppColors.evergreen)
            }
            .accessibilityAddTraits(.isHeader)
            Text(Self.introduction)
                .foregroundStyle(AppColors.text)
            Text(Self.subheading)
                .font(.headline)
                .foregroundStyle(AppColors.text)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(WatchReturnToAppSteps.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(AppColors.secondaryText)
                        Text(step)
                            .foregroundStyle(AppColors.text)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("watchTip.step.\(index + 1)")
                }
            }
            Text(Self.timingFootnote)
                .font(.callout)
                .foregroundStyle(AppColors.secondaryText)
            Text(Self.whereToFindFootnote)
                .font(.callout)
                .foregroundStyle(AppColors.secondaryText)
        }
    }

    private var button: some View {
        Button(action: gotIt) {
            Text("Got It").frame(maxWidth: .infinity)
        }
        .filledActionButton()
        .controlSize(.large)
        .accessibilityIdentifier("watchTip.gotIt")
    }
}
