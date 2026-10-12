import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Exercise the production modifier and banner tasks in a real SwiftUI host. This is not a
/// VoiceOver audio test or a full-root navigation journey.
@MainActor
final class UserFeedbackDeliveryViewTests: XCTestCase {
    func testTwoPresentationsDeliverOneAnnouncementAndOneDeadline() async throws {
        let model = try makeModel()
        let probe = DeliveryProbe()
        let first = expectation(description: "First feedback announcement")
        let extra = expectation(description: "A second presentation must stay passive")
        extra.isInverted = true
        probe.onAnnouncement = { count in
            if count == 1 { first.fulfill() } else { extra.fulfill() }
        }
        model.reportConfirmation("Saved.")
        let mounted = try mount(model, probe: probe, duplicate: true)
        defer { mounted.close(); probe.cancelAll() }

        await fulfillment(of: [first], timeout: 2)
        await fulfillment(of: [extra], timeout: 0.3)
        // A failing baseline must reach both real .tasks, including their sleep registrations.
        try await waitUntil { probe.requests.count == probe.announcements.count }
        print("feedback delivery observed: \(probe.announcements.count) announcements, \(probe.requests.count) deadlines")
        XCTAssertEqual(probe.announcements, ["Saved."])
        XCTAssertEqual(probe.requests.map(\.duration), [.seconds(3)])
    }

    func testSameTextWithANewEventIDCancelsAndReplacesDelivery() async throws {
        let model = try makeModel()
        let probe = DeliveryProbe()
        model.reportConfirmation("Saved.")
        let firstEvent = try XCTUnwrap(model.feedbackEvent)
        let mounted = try mount(model, probe: probe)
        defer { mounted.close(); probe.cancelAll() }
        try await waitUntil { probe.requests.count == 1 }
        let original = try XCTUnwrap(probe.requests.first)

        model.reportConfirmation("Saved.")
        let replacement = try XCTUnwrap(model.feedbackEvent)
        XCTAssertNotEqual(firstEvent.id, replacement.id)
        try await waitUntil { original.cancelled == true && probe.requests.count >= 2 }
        let next = try XCTUnwrap(probe.requests.last)
        XCTAssertFalse(original === next)
        XCTAssertEqual(probe.announcements, ["Saved.", "Saved."])
        XCTAssertEqual(probe.requests.count, 2)
        XCTAssertNil(next.cancelled)
        XCTAssertEqual(next.duration, .seconds(3))
        XCTAssertEqual(model.feedbackEvent?.id, replacement.id)

        next.finish(cancelled: false)
        try await waitUntil { model.feedbackEvent == nil }
    }

    func testContentReplacementAndTheSameEventKeepTheOriginalDeadline() async throws {
        let model = try makeModel()
        let probe = DeliveryProbe()
        let pane = TestPane()
        model.reportConfirmation("Saved.")
        let event = try XCTUnwrap(model.feedbackEvent)
        let mounted = try mountBranches(model, probe: probe, pane: pane)
        defer { mounted.close(); probe.cancelAll() }
        try await waitUntil { probe.requests.count == 1 }
        let original = try XCTUnwrap(probe.requests.first)
        let extra = expectation(description: "Content replacement must not announce again")
        extra.isInverted = true
        probe.onAnnouncement = { _ in extra.fulfill() }

        pane.alternate = true
        model.feedbackEvent = event
        try await waitUntil { pane.appeared }
        await fulfillment(of: [extra], timeout: 0.3)
        probe.onAnnouncement = nil
        XCTAssertEqual(model.feedbackEvent?.id, event.id)
        XCTAssertEqual(probe.announcements, ["Saved."])
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertNil(original.cancelled)
        XCTAssertEqual(original.duration, .seconds(3))

        original.finish(cancelled: false)
        try await waitUntil { model.feedbackEvent == nil }
    }

    func testRecordingCancelsDeliveryAndUnlockingRestartsTheSameEvent() async throws {
        let model = try makeModel()
        let probe = DeliveryProbe()
        model.reportConfirmation("Saved.")
        let event = try XCTUnwrap(model.feedbackEvent)
        let mounted = try mount(model, probe: probe)
        defer { mounted.close(); probe.cancelAll() }
        try await waitUntil { probe.requests.count == 1 }
        let original = try XCTUnwrap(probe.requests.first)
        let whileLocked = expectation(description: "Recording suppresses delivery")
        whileLocked.isInverted = true
        probe.onAnnouncement = { _ in whileLocked.fulfill() }

        model.snapshot.isRecording = true
        XCTAssertTrue(model.recordingNavigationIsLocked)
        XCTAssertEqual(model.feedbackEvent?.id, event.id, "The non-polling recording fixture must preserve feedback")
        try await waitUntil { original.cancelled == true }
        await fulfillment(of: [whileLocked], timeout: 0.3)
        probe.onAnnouncement = nil
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(model.feedbackEvent?.id, event.id)

        model.snapshot.isRecording = false
        try await waitUntil { probe.requests.count >= 2 }
        let restarted = try XCTUnwrap(probe.requests.last)
        XCTAssertFalse(original === restarted)
        XCTAssertEqual(probe.announcements, ["Saved.", "Saved."])
        XCTAssertEqual(probe.requests.count, 2)
        XCTAssertEqual(restarted.duration, .seconds(3))
        XCTAssertNil(restarted.cancelled)
        XCTAssertEqual(model.feedbackEvent?.id, event.id)

        restarted.finish(cancelled: false)
        try await waitUntil { model.feedbackEvent == nil }
    }

    func testWarningActionAndErrorKeepTheirDeliveryPolicyWithoutInvokingActions() async throws {
        var actions = 0
        var retries = 0
        let cases: [(UserFeedbackEvent, Duration?, String)] = [
            (.init(kind: .warning, message: "Check connection."), .seconds(6), "Check connection."),
            (.init(kind: .success, message: "Saved.", action: .init(
                title: "Play now", accessibilityLabel: "Play now, Article", identifier: "feedback.test.play",
                perform: { actions += 1 }
            )), .seconds(8), "Saved. Play now is available."),
            (.init(kind: .error, message: "Could not save.", retry: .init(
                key: "feedback-test", action: { retries += 1 }
            )), nil, "Could not save.")
        ]
        for (event, duration, announcement) in cases {
            let model = try makeModel()
            let probe = DeliveryProbe()
            model.presentFeedback(event)
            let unexpectedDeadline = duration == nil
                ? expectation(description: "A persistent error has no deadline") : nil
            if let unexpectedDeadline {
                unexpectedDeadline.isInverted = true
                probe.onRequest = { unexpectedDeadline.fulfill() }
            }
            let mounted = try mount(model, probe: probe)
            defer { mounted.close(); probe.cancelAll() }
            try await waitUntil { !probe.announcements.isEmpty }
            XCTAssertEqual(probe.announcements, [announcement])
            if let duration {
                try await waitUntil { probe.requests.count == 1 }
                let request = try XCTUnwrap(probe.requests.first)
                XCTAssertEqual(request.duration, duration)
                request.finish(cancelled: false)
                try await waitUntil { model.feedbackEvent == nil }
            } else {
                let unexpected = try XCTUnwrap(unexpectedDeadline)
                await fulfillment(of: [unexpected], timeout: 0.3)
                XCTAssertTrue(probe.requests.isEmpty)
                XCTAssertEqual(model.feedbackEvent?.id, event.id)
            }
            XCTAssertEqual(actions, 0)
            XCTAssertEqual(retries, 0)
        }
    }

    func testUnmountCancelsTheActualDeadlineWithoutDismissingTheEvent() async throws {
        let model = try makeModel()
        let probe = DeliveryProbe()
        model.reportConfirmation("Saved.")
        let event = try XCTUnwrap(model.feedbackEvent)
        let mounted = try mount(model, probe: probe)
        defer { mounted.close(); probe.cancelAll() }
        try await waitUntil { probe.requests.count == 1 }
        let request = try XCTUnwrap(probe.requests.first)

        mounted.close()
        // Observe lifecycle cancellation before fallback cleanup can cause it.
        try await waitUntil { request.cancelled == true }
        XCTAssertEqual(model.feedbackEvent?.id, event.id)
        XCTAssertEqual(probe.announcements, ["Saved."])
    }

    private func makeModel() throws -> Gate1AppModel {
        let preferences = VoicePreferencesSnapshot.capture()
        addTeardownBlock { @MainActor in preferences.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-view-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: directory.appendingPathComponent("library.sqlite")
        )
        model.captureWatcher = MarginCaptureWatcher(autoPoll: false, nowMs: { 0 })
        return model
    }

    private func mount(_ model: Gate1AppModel, probe: DeliveryProbe, duplicate: Bool = false,
                       pane: TestPane? = nil) throws -> MountedFeedback {
        let root = FeedbackTestContent(pane: pane ?? TestPane(), duplicate: duplicate)
            .modifier(AppFeedbackPresentation())
            .environmentObject(model)
            .environment(\.feedbackDeliveryEffects, probe.effects)
        return try mountRoot(AnyView(root))
    }

    private func mountBranches(_ model: Gate1AppModel, probe: DeliveryProbe,
                               pane: TestPane) throws -> MountedFeedback {
        let root = RootBranchingFeedbackTestContent(pane: pane)
            .environmentObject(model)
            .environment(\.feedbackDeliveryEffects, probe.effects)
        return try mountRoot(AnyView(root))
    }

    private func mountRoot(_ root: AnyView) throws -> MountedFeedback {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return MountedFeedback(host: host, window: window, previousKeyWindow: previousKeyWindow)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The mounted feedback did not reach the requested lifecycle state", file: file, line: line)
    }
}

@MainActor
private final class TestPane: ObservableObject {
    @Published var alternate = false
    var appeared = false
}

@MainActor
private struct FeedbackTestContent: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject var pane: TestPane
    let duplicate: Bool

    var body: some View {
        VStack {
            if pane.alternate {
                Text("Second pane").onAppear { pane.appeared = true }
            } else {
                Text("First pane")
            }
            if duplicate, let feedback = model.feedbackEvent {
                UserFeedbackBanner(feedback: feedback)
            }
        }
    }
}

/// Match Gate1RootView's topology: apply the production modifier directly to a conditional Group,
/// rather than to a custom view or a retained stack that could provide a different identity boundary.
@MainActor
private struct RootBranchingFeedbackTestContent: View {
    @ObservedObject var pane: TestPane

    var body: some View {
        Group {
            if pane.alternate {
                Text("Second screen").onAppear { pane.appeared = true }
            } else {
                VStack { Text("First screen") }
            }
        }
        .background(AppColors.background.ignoresSafeArea())
        .modifier(AppFeedbackPresentation())
    }
}

@MainActor
private struct MountedFeedback {
    let host: UIHostingController<AnyView>
    let window: UIWindow
    let previousKeyWindow: UIWindow?

    func close() {
        // Removing the SwiftUI tree triggers its own task cancellation even while the test retains host.
        host.rootView = AnyView(EmptyView())
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
    }
}

@MainActor
private final class DeliveryProbe {
    var announcements: [String] = []
    var requests: [PendingFeedbackSleep] = []
    var onAnnouncement: ((Int) -> Void)?
    var onRequest: (() -> Void)?

    var effects: UserFeedbackDeliveryEffects {
        UserFeedbackDeliveryEffects(
            announce: { [weak self] message in
                guard let self else { return }
                announcements.append(message)
                onAnnouncement?(announcements.count)
            },
            sleep: { [weak self] duration in
                guard let self else { throw CancellationError() }
                try await self.pause(for: duration)
            }
        )
    }

    private func pause(for duration: Duration) async throws {
        let request = PendingFeedbackSleep(duration: duration)
        requests.append(request)
        onRequest?()
        try await request.wait()
    }

    func cancelAll() {
        for request in requests { request.finish(cancelled: true) }
    }
}

/// Exactly one terminal transition, even if task cancellation arrives before continuation install.
/// The lock protects every mutable field; continuations are always resumed outside the lock.
private final class PendingFeedbackSleep: @unchecked Sendable {
    let duration: Duration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var terminalCancellation: Bool?

    init(duration: Duration) { self.duration = duration }

    var cancelled: Bool? { lock.withLock { terminalCancellation } }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { install($0) }
        } onCancel: {
            self.finish(cancelled: true)
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let terminal = lock.withLock { () -> Bool? in
            if let terminalCancellation { return terminalCancellation }
            self.continuation = continuation
            return nil as Bool?
        }
        if let terminal { resume(continuation, cancelled: terminal) }
    }

    func finish(cancelled: Bool) {
        let pending = lock.withLock {
            guard terminalCancellation == nil else { return nil as CheckedContinuation<Void, any Error>? }
            terminalCancellation = cancelled
            let pending = continuation
            continuation = nil
            return pending
        }
        if let pending { resume(pending, cancelled: cancelled) }
    }

    private func resume(_ continuation: CheckedContinuation<Void, any Error>, cancelled: Bool) {
        if cancelled { continuation.resume(throwing: CancellationError()) }
        else { continuation.resume() }
    }
}
