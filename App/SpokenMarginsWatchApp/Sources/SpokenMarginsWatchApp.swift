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
struct WatchHomeView: View {
    @EnvironmentObject private var link: WatchLink
    @StateObject private var recorder = WatchMarginRecorder()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let home = link.home(now: now)
            ScrollView {
                VStack(spacing: 8) {
                    stateLine(home, now: now)
                    recordButton(home)
                        .frame(height: 120)
                    statusLine(home, now: now)
                    below(home, now: now)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func stateLine(_ home: WatchSessionModel.Home, now: Date) -> some View {
        Label(home.line(now: now), systemImage: home.symbol)
            .font(.footnote)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(home.line(now: now))
    }

    private func recordButton(_ home: WatchSessionModel.Home) -> some View {
        Button {
            recorder.toggle()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 40, weight: .semibold))
                Text(recorder.isRecording ? "Stop" : "Record")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Blue and orange, with the icon and word carrying the meaning too (the owner is red-green colour-blind).
        .tint(recorder.isRecording ? .orange : .blue)
        .accessibilityLabel(recorder.isRecording ? "Stop recording the spoken Margin" : "Record a spoken Margin")
    }

    @ViewBuilder
    private func statusLine(_ home: WatchSessionModel.Home, now: Date) -> some View {
        switch recorder.state {
        case .recording(let since):
            let elapsed = WatchContract.milliseconds(seconds: now.timeIntervalSince(since)) / 1_000
            VStack(spacing: 2) {
                Label(String(format: "Recording %d:%02d", elapsed / 60, elapsed % 60), systemImage: "mic")
                    .font(.footnote.monospacedDigit())
                Text((home.session?.kind ?? .other).hint)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
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
