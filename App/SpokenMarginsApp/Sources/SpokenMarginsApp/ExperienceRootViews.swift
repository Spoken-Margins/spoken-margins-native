import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

enum Build23ExperiencePolishLayout {
    static let addSourceBottomClearance: CGFloat = 32
}

struct ExperienceRootTabs: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Binding var navigation: AppNavigationState
    var showsMiniPlayer = false

    private var rootSelection: Binding<AppRoot> {
        Binding(
            get: { navigation.selectedRoot },
            set: { navigation.select($0, recordingIsLocked: model.recordingNavigationIsLocked) }
        )
    }

    var body: some View {
        TabView(selection: rootSelection) {
            ExperienceLibraryScreen(addSourceRoute: addSourceRoute)
                .safeAreaInset(edge: .bottom, spacing: 8) { miniPlayer }
                .tabItem {
                    Label("Library", systemImage: AppRoot.library.systemImage)
                        .accessibilityIdentifier("navigation.tab.library")
                }
                .tag(AppRoot.library)

            ExperienceSourcesScreen(scrollMemory: $navigation.followingScroll)
                .safeAreaInset(edge: .bottom, spacing: 8) { miniPlayer }
                .tabItem {
                    Label("Following", systemImage: AppRoot.sources.systemImage)
                        .accessibilityIdentifier("navigation.tab.sources")
                }
                .tag(AppRoot.sources)

            ExperienceMarginsScreen()
                .safeAreaInset(edge: .bottom, spacing: 8) { miniPlayer }
                .tabItem {
                    Label("Margins", systemImage: AppRoot.margins.systemImage)
                        .accessibilityIdentifier("navigation.tab.margins")
                }
                .tag(AppRoot.margins)
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(AppColors.evergreen)
        .sheet(item: addSourceRoute) { route in
            ExperienceAddSourceFlow(initialRoute: route)
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if showsMiniPlayer {
            MiniPlayerBar()
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
    }

    private var addSourceRoute: Binding<AddSourceRoute?> {
        Binding(
            get: { navigation.addSourceRoute },
            set: { navigation.addSourceRoute = $0 }
        )
    }
}
