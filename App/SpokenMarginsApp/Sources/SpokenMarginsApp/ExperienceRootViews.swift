import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

enum Build23ExperiencePolishLayout {
    enum LibraryComposition: Equatable {
        case horizontal
        case wrapped
    }

    static let addSourceBottomClearance: CGFloat = 32
    static let persistentMiniPlayerContentClearance: CGFloat = 8

    static func libraryComposition(
        isCompactWidth: Bool,
        isAccessibilitySize: Bool
    ) -> LibraryComposition {
        isCompactWidth || isAccessibilitySize ? .wrapped : .horizontal
    }

    static func rootContentBottomClearance(
        showsPersistentMiniPlayer: Bool
    ) -> CGFloat {
        showsPersistentMiniPlayer ? persistentMiniPlayerContentClearance : 0
    }
}

struct ExperienceRootTabs: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Binding var navigation: AppNavigationState

    private var rootSelection: Binding<AppRoot> {
        Binding(
            get: { navigation.selectedRoot },
            set: { navigation.select($0, recordingIsLocked: model.recordingNavigationIsLocked) }
        )
    }

    var body: some View {
        TabView(selection: rootSelection) {
            ExperienceLibraryScreen(addSourceRoute: addSourceRoute)
                .tabItem {
                    Label("Library", systemImage: AppRoot.library.systemImage)
                        .accessibilityIdentifier("navigation.tab.library")
                }
                .tag(AppRoot.library)

            ExperienceSourcesScreen()
                .tabItem {
                    Label("Sources", systemImage: AppRoot.sources.systemImage)
                        .accessibilityIdentifier("navigation.tab.sources")
                }
                .tag(AppRoot.sources)

            ExperienceMarginsScreen()
                .tabItem {
                    Label("Margins", systemImage: AppRoot.margins.systemImage)
                        .accessibilityIdentifier("navigation.tab.margins")
                }
                .tag(AppRoot.margins)
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(AppColors.evergreen)
        .safeAreaPadding(
            .bottom,
            Build23ExperiencePolishLayout.rootContentBottomClearance(
                showsPersistentMiniPlayer: model.shouldShowMiniPlayer
            )
        )
        .sheet(item: addSourceRoute) { route in
            ExperienceAddSourceFlow(initialRoute: route)
                .environmentObject(model)
        }
    }

    private var addSourceRoute: Binding<AddSourceRoute?> {
        Binding(
            get: { navigation.addSourceRoute },
            set: { navigation.addSourceRoute = $0 }
        )
    }
}
