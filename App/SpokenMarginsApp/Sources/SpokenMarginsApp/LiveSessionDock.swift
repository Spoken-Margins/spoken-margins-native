import SwiftUI

/// The two panes of the live session screen (#3491). Presentation only: choosing one never changes the session.
enum LiveSessionPane: String, CaseIterable, Hashable {
    case margins = "Margins"
    case session = "Session"

    var symbol: String {
        switch self {
        case .margins: "quote.bubble"
        case .session: "clock"
        }
    }

    var identifier: String {
        switch self {
        case .margins: "liveSession.margins.button"
        case .session: "liveSession.session.button"
        }
    }
}

/// What the dock's clock row says at one moment: the big clock, a small line beside it, and what VoiceOver reads.
struct LiveSessionDockClock: Equatable {
    let main: String
    let caption: String?
    let accessibility: String
}

/// The bottom of the live session screen, drawn like the playback screen's dock (#3491): the pane switch, then the
/// session clock with End at the right of the same row, then Add a Margin with the pencil beside it. Nothing in it
/// scrolls (except at accessibility text sizes, where it is capped like playback's). It holds values and closures
/// only; `LiveSessionView` owns the session.
struct LiveSessionDock: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var pane: LiveSessionPane
    let marginCount: Int
    let isRunning: Bool
    /// When Resume stops being offered for an ended session; nil when it isn't offered.
    let resumeUntil: Date?
    let clock: (Date) -> LiveSessionDockClock
    let end: () -> Void
    let resume: () -> Void
    let record: () -> Void
    let write: () -> Void
    /// A recording or a written Margin is already open elsewhere (the item's, from the mini player).
    var addIsDisabled = false

    var body: some View {
        VStack(spacing: PaneDockSpacing.row) {
            PaneSwitchControl(
                panes: LiveSessionPane.allCases,
                selection: $pane,
                symbol: { $0.symbol },
                title: { $0.rawValue },
                accessibilityTitle: { pane in
                    pane == .margins && marginCount > 0 ? "Margins, \(marginCount)" : pane.rawValue
                },
                identifier: { $0.identifier },
                badge: { pane in pane == .margins && marginCount > 0 ? "\(marginCount)" : nil },
                groupLabel: "Live session view",
                groupIdentifier: "liveSession.viewSwitch")
            clockRow
            MarginAddButtons(
                record: record, write: write,
                recordIdentifier: "liveSession.addMargin.button",
                writeIdentifier: "liveSession.write.button",
                isDisabled: !isRunning || addIsDisabled)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(AppColors.listeningBackground)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.18)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveSession.dock")
        .boundedScrollDock(dynamicTypeSize.isAccessibilitySize)
    }

    private var clockRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let line = clock(context.date)
                VStack(alignment: .leading, spacing: 0) {
                    Text(line.main)
                        .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let caption = line.caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(AppColors.watchSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.accessibility)
            }
            endOrResume
        }
        .frame(minHeight: 44)
    }

    /// Resume replaces End once the session has ended, for the 10 minutes after it (#2883), the same as the Watch's
    /// and the Lock Screen card's. It goes when the window closes, without the screen redrawing for another reason.
    @ViewBuilder
    private var endOrResume: some View {
        if isRunning {
            Button(action: end) {
                Label("End", systemImage: "stop.circle").frame(minHeight: 44).padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .accessibilityLabel("End session")
            .accessibilityIdentifier("liveSession.endSession")
        } else if let until = resumeUntil {
            TimelineView(.explicit([min(Date.now, until), until])) { context in
                if context.date < until {
                    Button(action: resume) {
                        Label("Resume", systemImage: "play.circle").frame(minHeight: 44).padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.evergreen)
                    .foregroundStyle(AppColors.onEvergreen)
                    .accessibilityLabel("Resume session")
                    .accessibilityIdentifier("liveSession.resume")
                }
            }
        }
    }
}

private enum PaneDockSpacing {
    /// Spacing only is tightened, as on the playback dock, so the dock stays a small part of a short phone.
    static let row: CGFloat = 4
}

/// The screen's running state: a pane that fills the room, an optional mini player pill, and the dock. The dock
/// sits in the bottom safe area, so End stays on screen however many Margins the pane holds (#3491).
struct LiveSessionStage<Pane: View, Pill: View, Dock: View>: View {
    let pane: Pane
    let pill: Pill
    let dock: Dock

    var body: some View {
        pane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    pill
                    dock
                }
            }
    }
}
