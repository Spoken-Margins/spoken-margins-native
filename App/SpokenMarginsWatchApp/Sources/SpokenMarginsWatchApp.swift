import SwiftUI
import WatchKit

/// The Watch app (#2487 slice 1b): it always says which of three states it is in, records a spoken Margin with one
/// big Record button, starts and ends sessions, and says "Filed in…" only when the phone has filed it.
@main
struct SpokenMarginsWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchHomeView()
                    // The screens are named here, outside Home's once-a-second redraw, so a push is never rebuilt
                    // under the listener's finger (#2964).
                    .navigationDestination(for: WatchRoute.self) { route in
                        switch route {
                        case .waiting: WatchWaitingList()
                        case .end(let startedAt): WatchEndSessionView(startedAt: startedAt)
                        case .start: WatchStartSessionView()
                        case .microphoneTest: WatchMicrophoneTestView()
                        }
                    }
            }
            .environmentObject(WatchLink.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: WatchLink.shared.appBecameActive()
            case .background: WatchLink.shared.appWentToBackground()
            default: break
            }
        }
    }
}

/// Sets up the connection to the phone when the app launches, in the front or for a background wake, not when its
/// screen first appears (DESIGN section 9, changes point 10).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        MainActor.assumeIsolated { WatchLink.shared.activate() }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        MainActor.assumeIsolated {
            for task in backgroundTasks {
                if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask {
                    WatchLink.shared.keep(connectivity)
                } else {
                    task.setTaskCompletedWithSnapshot(false)
                }
            }
        }
    }
}

/// The screens Home opens.
enum WatchRoute: Hashable {
    case waiting
    case end(startedAt: Date)
    case start
    case microphoneTest
}

/// Home: the state line and one big Record button. Below, reached with the crown: what's waiting, Start session or
/// End, Resume, and the microphone test.
///
/// While the phone has an item loaded (#3494) the first screen is "On this episode" (big, blue), "On the session"
/// (smaller, orange, only while a session runs) and a back, play or pause, forward row. With nothing loaded it is the
/// single Record it always was. While recording, the screen names the target in large words and offers Stop and Discard.
struct WatchHomeView: View {
    @EnvironmentObject private var link: WatchLink
    @StateObject private var recorder = WatchMarginRecorder()
    @State private var asksToDiscard = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let home = link.home(now: now)
            let playing = recorder.isRecording ? nil : link.nowPlaying(now: now)
            // The screen the owner chose must fit a 41 mm Watch with no scrolling, so its lines stay short (#3494).
            let compact = playing != nil || (recorder.isRecording && recorder.choiceWasShown)
            ScrollView {
                VStack(spacing: compact ? 4 : 8) {
                    stateLine(home, now: now, lines: compact ? 1 : 2)
                    if recorder.isRecording {
                        recordingScreen(home, now: now)
                        statusLine(home, now: now)
                    } else if let playing {
                        episodeHeader(playing, now: now)
                        episodeButtons(home)
                        transportRow(playing)
                        // "Filed in…" stays within reach of the crown once it has left the top.
                        if case .idle = recorder.state, !lastMarginIsNews(now: now) { statusLine(home, now: now) }
                    } else {
                        recordButton(.session)
                            .frame(height: 120)
                        statusLine(home, now: now)
                    }
                    below(home, now: now)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func stateLine(_ home: WatchSessionModel.Home, now: Date, lines: Int) -> some View {
        Label(home.line(now: now), systemImage: home.symbol)
            .font(.footnote)
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(home.line(now: now))
    }

    /// Blue for the episode, orange for the session, always with the words and a different symbol (the owner is
    /// red-green colour-blind).
    private func tint(_ target: WatchRecordingTarget) -> Color {
        target == .episode ? .blue : .orange
    }

    private func symbol(_ target: WatchRecordingTarget) -> String {
        target == .episode ? "headphones" : "list.bullet.rectangle"
    }

    /// The single Record, with nothing loaded: it records for the session, as it always did.
    private func recordButton(_ target: WatchRecordingTarget) -> some View {
        Button {
            recorder.toggle(target: target)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 40, weight: .semibold))
                Text("Record")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(.blue)
        .accessibilityLabel("Record a spoken Margin")
    }

    private func lastMarginIsNews(now: Date) -> Bool {
        guard let id = link.lastMarginId else { return false }
        return link.ledger.isNews(id, now: now)
    }

    /// The line above the buttons: why the recording failed, else where the last Margin went while that is news, else the
    /// item's title. "Filed in…" is how the listener knows the target was right, so it never waits below the fold (#3494).
    @ViewBuilder
    private func episodeHeader(_ playing: WatchNowPlaying, now: Date) -> some View {
        if case .failed(let message) = recorder.state {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if lastMarginIsNews(now: now), let id = link.lastMarginId, let display = link.ledger.display(id, now: now) {
            Label(display.words, systemImage: display.symbol)
                .font(.footnote)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(playing.title)
                .font(.footnote)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "On this episode" is the big one; "On the session" is smaller and only there while a session runs.
    @ViewBuilder
    private func episodeButtons(_ home: WatchSessionModel.Home) -> some View {
        targetButton(.episode, size: home.session == nil ? 90 : 60)
        if home.session != nil {
            targetButton(.session, size: 38)
        }
    }

    private func targetButton(_ target: WatchRecordingTarget, size: CGFloat) -> some View {
        Button {
            recorder.toggle(target: target)
        } label: {
            Label(target.words, systemImage: "mic.fill")
                .font(size >= 60 ? .headline : .footnote.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: size)
        .tint(tint(target))
        .accessibilityLabel("Record a spoken Margin \(target.words.lowercased())")
    }

    private func transportRow(_ playing: WatchNowPlaying) -> some View {
        HStack(spacing: 6) {
            transportButton(.skipBack, symbol: "gobackward", label: "Back")
            transportButton(
                playing.isPlaying ? .pause : .play, symbol: playing.isPlaying ? "pause.fill" : "play.fill",
                label: playing.isPlaying ? "Pause" : "Play"
            )
            transportButton(.skipForward, symbol: "goforward", label: "Forward")
        }
        .frame(height: 38)
        .disabled(!link.isReachable)
        .opacity(link.isReachable ? 1 : 0.4)
    }

    private func transportButton(_ transport: WatchTransport, symbol: String, label: String) -> some View {
        Button {
            link.sendTransport(transport)
        } label: {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(label)
    }

    /// While recording: the target in large words, how long, and Stop beside Discard (#3494).
    @ViewBuilder
    private func recordingScreen(_ home: WatchSessionModel.Home, now: Date) -> some View {
        let target = recorder.plan?.target ?? .session
        // Named whenever the listener had a choice to make when it began, so "which one did I click" is always answered.
        let withTarget = recorder.choiceWasShown
        if withTarget {
            Label(target.words, systemImage: symbol(target))
                .font(.title3.weight(.bold))
                .foregroundStyle(tint(target))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Recording \(target.words.lowercased())")
        }
        // Stop and Discard side by side: Stop is the wide one, Discard one tap away from it (#3494).
        HStack(spacing: 6) {
            Button {
                recorder.toggle(target: target)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Stop")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .tint(withTarget ? tint(target) : .orange)
            .accessibilityLabel("Stop recording the spoken Margin")
            Button(role: .destructive) {
                discardTapped(now: now)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Discard")
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityLabel("Discard this recording")
        }
        .frame(height: withTarget ? 84 : 100)
        .confirmationDialog("Discard this Margin?", isPresented: $asksToDiscard) {
            Button("Discard", role: .destructive) { recorder.discardRecording() }
            Button("Keep recording", role: .cancel) {}
        }
    }

    /// A short clip is thrown away at once; a longer one asks first (#3494).
    private func discardTapped(now: Date) {
        guard case .recording(let since) = recorder.state else { return }
        let plan = recorder.plan ?? WatchRecordingPlan(target: .session)
        if plan.discardAsks(afterRecording: now.timeIntervalSince(since)) {
            asksToDiscard = true
        } else {
            recorder.discardRecording()
        }
    }

    @ViewBuilder
    private func statusLine(_ home: WatchSessionModel.Home, now: Date) -> some View {
        switch recorder.state {
        case .recording(let since):
            let elapsed = WatchContract.milliseconds(seconds: now.timeIntervalSince(since)) / 1_000
            VStack(spacing: 2) {
                Label(String(format: "Recording %d:%02d", elapsed / 60, elapsed % 60), systemImage: "mic")
                    .font(.footnote.monospacedDigit())
                if recorder.plan?.target != .episode {
                    Text((home.session?.kind ?? .other).hint)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
        case .idle:
            if let id = link.lastMarginId, let display = link.ledger.display(id, now: now) {
                Label(display.words, systemImage: display.symbol)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func below(_ home: WatchSessionModel.Home, now: Date) -> some View {
        if link.ledger.waitingCount > 0 {
            NavigationLink(value: WatchRoute.waiting) {
                Label("\(link.ledger.waitingCount) waiting", systemImage: "hourglass")
            }
        }
        if let session = home.session {
            // A meeting ends in one tap; the kinds that ask where you stopped also ask when (#2709).
            if session.kind == .meeting {
                Button {
                    link.endSession()
                } label: {
                    Label("End", systemImage: "stop.circle")
                }
            } else {
                NavigationLink(value: WatchRoute.end(startedAt: session.startedAt)) {
                    Label("End", systemImage: "stop.circle")
                }
            }
        } else {
            if let note = home.endNote {
                Text(note).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let resumable = home.resumable, let ended = resumable.endedAt {
                Button {
                    link.resumeSession()
                } label: {
                    Label("Ended \(WatchContractFormat.timeOfDay(resumable.shownEnd ?? ended)) · Resume", systemImage: "arrow.uturn.backward.circle")
                }
            }
            NavigationLink(value: WatchRoute.start) {
                Label("Start session", systemImage: "play.circle")
            }
        }
        NavigationLink(value: WatchRoute.microphoneTest) {
            Label("Microphone test", systemImage: "waveform")
        }
    }
}

/// End session: when did it stop? Now, 5, 15 or 30 minutes or an hour ago; only the choices that fall inside the session
/// are offered (#2709). Tapping one ends the session at that time.
struct WatchEndSessionView: View {
    @EnvironmentObject private var link: WatchLink
    @Environment(\.dismiss) private var dismiss
    let startedAt: Date
    /// Fixed when the screen opens, so the choices don't shift under the crown.
    @State private var openedAt = Date()

    var body: some View {
        List(Array(WatchEndChoice.choices(startedAt: startedAt, tappedAt: openedAt).enumerated()), id: \.offset) { _, choice in
            Button(choice.label) {
                link.endSession(stoppedAt: choice.date(tappedAt: Date()))
                dismiss()
            }
        }
        .navigationTitle("When did it end?")
    }
}

/// Start session: four kinds, one tap starts it (WATCH.md 2.2 point 3).
struct WatchStartSessionView: View {
    @EnvironmentObject private var link: WatchLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(WatchSessionKind.allCases, id: \.self) { kind in
            Button(kind.label) {
                link.startSession(kind: kind)
                dismiss()
            }
        }
        .navigationTitle("Start session")
    }
}

/// The Margins the Watch still holds, each with its state, Retry and Delete (DESIGN section 3). Only each row's words
/// tick; the list itself is not redrawn every second, and the buttons are borderless so a tap on a row presses one
/// button, not both Retry and Delete (#2964).
struct WatchWaitingList: View {
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        List {
            if link.ledger.held.isEmpty {
                Text("Nothing waiting")
                    .font(.footnote)
            }
            ForEach(link.ledger.held) { item in
                WatchWaitingRow(item: item)
            }
        }
        .navigationTitle("Waiting")
    }
}

struct WatchWaitingRow: View {
    @EnvironmentObject private var link: WatchLink
    let item: WatchMarginLedger.Held

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WatchContractFormat.timeOfDay(item.transfer.wallStart))
                .font(.headline.monospacedDigit())
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let display = link.ledger.display(item.id, now: context.date) {
                    Label(display.words, systemImage: display.symbol).font(.footnote)
                }
            }
            HStack {
                Button("Retry") { link.retry(item.id) }
                Button("Delete", role: .destructive) { link.delete(item.id) }
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
    }
}
