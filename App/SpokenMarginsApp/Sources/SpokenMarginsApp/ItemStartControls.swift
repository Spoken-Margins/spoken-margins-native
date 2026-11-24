import SessionKit
import SwiftUI

/// The item screen's start controls: the "preparing audio" line, the friend's-arrival line, the main listening button
/// and the second choice (#149, #3219, #3788, #4125). The screen draws them twice, once pinned at the bottom and once at
/// the top of its scrolling content, and `ItemStartControlsLayout` says which parts each place shows (#5110): every
/// part pinned at the default and large text sizes, only the main button pinned at the accessibility sizes.
///
/// It takes plain values and closures, not the model, so a layout test can draw it at any text size.
struct ItemStartControls: View {
    enum Placement { case pinned, inline }

    /// What the "preparing audio" line says, while the item's audio is made or fetched.
    struct Preparing: Equatable {
        let showsSpinner: Bool
        let description: String
    }

    /// The largest text size the pinned main button draws at the accessibility sizes. At it, "Hear Sam's Margins first ·
    /// 3 min" takes two lines on a phone; a long press shows the words full size in the Large Content Viewer.
    static let pinnedMainButtonTextCap = DynamicTypeSize.accessibility1

    let placement: Placement
    let layout: ItemStartControlsLayout
    let preparing: Preparing?
    let arrivalLine: String?
    let choices: ItemListeningChoices
    let onMainButton: () -> Void
    let onSecondChoice: () -> Void

    /// Whether this placement draws anything, so the screen leaves out an empty stack.
    var drawsAnything: Bool {
        ItemStartControlsLayout.Part.allCases.contains { shows($0) && isPresent($0) }
    }

    var body: some View {
        if shows(.preparingLine), let preparing {
            HStack(spacing: 10) {
                if preparing.showsSpinner {
                    ProgressView()
                        .tint(AppColors.evergreen)
                }
                Text(preparing.description)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(AppColors.secondaryText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(preparing.description)
            .accessibilityIdentifier("item.start.preparing")
        }
        if shows(.arrivalLine), let arrivalLine {
            Text(arrivalLine)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("item.arrival.waitingLine")
        }
        if shows(.mainButton) {
            mainButton
        }
        if shows(.secondChoice), let secondaryTitle = choices.secondaryTitle, let secondaryAction = choices.secondaryAction {
            Button(action: onSecondChoice) {
                // Words only, as on the screens the owner reviewed (#3247): the line already says whose Margins.
                Text(secondaryTitle)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .accessibilityLabel(choices.secondaryAccessibilityLabel ?? secondaryTitle)
            .accessibilityIdentifier(
                secondaryAction == .reviewNewMargins(thenContinue: false) ? "item.reviewNewMargins.button" : "item.listenWithout.button")
        }
    }

    @ViewBuilder
    private var mainButton: some View {
        let button = Button(action: onMainButton) {
            Label(choices.primaryTitle, systemImage: "play.fill")
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .filledActionButton()
        .accessibilityLabel(choices.primaryAccessibilityLabel ?? choices.primaryTitle)
        .accessibilityIdentifier("item.start.button")
        if placement == .pinned && layout.capsMainButtonText {
            button
                .dynamicTypeSize(...Self.pinnedMainButtonTextCap)
                .accessibilityShowsLargeContentViewer {
                    Label(choices.primaryTitle, systemImage: "play.fill")
                }
        } else {
            button
        }
    }

    private func shows(_ part: ItemStartControlsLayout.Part) -> Bool {
        switch placement {
        case .pinned: return layout.isPinned(part)
        case .inline: return layout.isInline(part)
        }
    }

    private func isPresent(_ part: ItemStartControlsLayout.Part) -> Bool {
        switch part {
        case .preparingLine: return preparing != nil
        case .arrivalLine: return arrivalLine != nil
        case .mainButton: return true
        case .secondChoice: return choices.secondaryTitle != nil && choices.secondaryAction != nil
        }
    }
}
