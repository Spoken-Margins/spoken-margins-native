import SessionKit
import SwiftUI

/// The one-time card that tells a listener whose voice is James or Lily that Supertonic is now a free download
/// (#1820), with a button to Settings › Voices. Whether it shows is `SupertonicDownloadNoticePolicy`; this holds the
/// sheet's state and the request that Settings opens Voices. Nothing downloads from here.
@MainActor
final class SupertonicDownloadNotice: ObservableObject {
    @Published var isPresented = false
    /// Set by the card's button. Settings opens Voices when it appears and clears it.
    @Published var opensVoices = false

    private let defaults: UserDefaults
    private let modelInstalled: () -> Bool

    init(defaults: UserDefaults = .standard, modelInstalled: @escaping () -> Bool = { SupertonicAssetResolver.isAvailable }) {
        self.defaults = defaults
        self.modelInstalled = modelInstalled
    }

    /// Called when the app's root appears. Showing the card records it as seen, so it never comes back.
    func presentIfNeeded(savedVoiceIsSupertonic: Bool, anotherSheetShowing: Bool) {
        switch SupertonicDownloadNoticePolicy.decide(
            savedVoiceIsSupertonic: savedVoiceIsSupertonic,
            modelInstalled: modelInstalled(),
            hasSeen: defaults.bool(forKey: SupertonicDownloadNoticePolicy.seenKey),
            anotherSheetShowing: anotherSheetShowing
        ) {
        case .show:
            defaults.set(true, forKey: SupertonicDownloadNoticePolicy.seenKey)
            isPresented = true
        case .settle:
            defaults.set(true, forKey: SupertonicDownloadNoticePolicy.seenKey)
        case .wait, .done:
            break
        }
    }

    /// The card's button: close it and ask Settings to open Voices. The caller opens Settings.
    func openVoices() {
        isPresented = false
        opensVoices = true
    }

    /// Settings asks whether it should open Voices now; true once per request.
    func takeVoicesRequest() -> Bool {
        guard opensVoices else { return false }
        opensVoices = false
        return true
    }
}

/// The root's half of the card (#1820): offer it once the root has appeared, and show it as a sheet. `.task` runs
/// after the root's own `onAppear`, so the welcome drawer has already decided whether it is showing.
struct SupertonicDownloadNoticePresentation: ViewModifier {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var catalogDrawer: CatalogDrawerModel
    @ObservedObject var notice: SupertonicDownloadNotice

    func body(content: Content) -> some View {
        content
            .task {
                // Scripted UI routes drive their own screens; the card would sit over them.
                guard !UITestingHooks.suppressesFirstRun else { return }
                notice.presentIfNeeded(
                    savedVoiceIsSupertonic: model.ttsVoiceSelection.supertonicVoice != nil,
                    anotherSheetShowing: catalogDrawer.isPresented || model.isTermsOfUsePresented
                        || model.isAIDataSharingConsentPresented || model.spokenMarginsPackageImportReview != nil
                )
            }
            .sheet(isPresented: $notice.isPresented) {
                SupertonicDownloadNoticeCard(
                    openVoices: {
                        notice.openVoices()
                        model.openSettings()
                    },
                    notNow: { notice.isPresented = false }
                )
            }
    }
}

struct SupertonicDownloadNoticeCard: View {
    let openVoices: () -> Void
    let notNow: () -> Void

    /// "141 MB", from the catalog snapshot the app ships, so a listener on cellular data knows before they tap.
    static let downloadSize: String? = Bundle.main
        .url(forResource: "catalog-snapshot", withExtension: "json", subdirectory: "VoiceCatalog")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { SupertonicDownloadNoticePolicy.downloadByteCount(catalogSnapshot: $0, voiceId: SupertonicAssetResolver.catalogVoiceId) }
        .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .decimal) }

    static var downloadSentence: String {
        let size = downloadSize.map { " (\($0))" } ?? ""
        return "James and Lily use the Supertonic voice, which no longer comes inside the app. Download it once\(size) in Settings › Voices, ideally on Wi‑Fi."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Supertonic is now a free download")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColors.text)
            } icon: {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(AppColors.accent)
            }
            .accessibilityAddTraits(.isHeader)
            Text(Self.downloadSentence)
                .foregroundStyle(AppColors.text)
            Text("Until then, the app’s backup voice reads your articles. Your choice of voice stays, and audio already made with Supertonic is kept.")
                .font(.callout)
                .foregroundStyle(AppColors.secondaryText)
            Button(action: openVoices) {
                Text("Open Voices").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("supertonicNotice.openVoices")
            Button("Not Now", action: notNow)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("supertonicNotice.notNow")
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("supertonicNotice.card")
    }
}
