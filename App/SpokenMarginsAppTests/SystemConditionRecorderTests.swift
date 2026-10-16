import XCTest
@testable import SpokenMarginsApp

/// #1682: heat and memory warnings left no event of their own in Diagnostics.
@MainActor
final class SystemConditionRecorderTests: XCTestCase {
    private var events: [(kind: String, fields: [String: String])] = []
    private var thermal: ProcessInfo.ThermalState = .nominal
    private var background = false

    private func makeRecorder() -> SystemConditionRecorder {
        SystemConditionRecorder(
            record: { [unowned self] kind, fields in self.events.append((kind, fields)) },
            isInBackground: { [unowned self] in self.background },
            thermalState: { [unowned self] in self.thermal }
        )
    }

    func testThermalChangesAreRecordedWithTheStateBeforeAndWhetherTheAppWasInTheBackground() {
        let recorder = makeRecorder()
        recorder.recordThermalChange()
        XCTAssertTrue(events.isEmpty, "no change since launch")

        thermal = .serious
        background = true
        recorder.recordThermalChange()
        recorder.recordThermalChange()
        thermal = .nominal
        background = false
        recorder.recordThermalChange()

        XCTAssertEqual(events.map(\.kind), ["app.thermal_state", "app.thermal_state"], "the repeat is not recorded")
        XCTAssertEqual(events[0].fields, ["state": "serious", "previous": "nominal", "background": "true"])
        XCTAssertEqual(events[1].fields, ["state": "nominal", "previous": "serious", "background": "false"])
    }

    func testMemoryWarningsAreRecordedWithWhetherTheAppWasInTheBackground() {
        let recorder = makeRecorder()
        recorder.recordMemoryWarning()
        background = true
        recorder.recordMemoryWarning()

        XCTAssertEqual(events.map(\.kind), ["app.memory_warning", "app.memory_warning"])
        XCTAssertEqual(events[0].fields, ["background": "false"])
        XCTAssertEqual(events[1].fields, ["background": "true"])
    }

    func testTheSystemThermalNotificationReachesTheRecorder() async {
        let heated = expectation(description: "thermal change recorded")
        let recorder = SystemConditionRecorder(
            record: { [unowned self] kind, fields in
                self.events.append((kind, fields))
                heated.fulfill()
            },
            isInBackground: { false },
            thermalState: { [unowned self] in self.thermal }
        )
        recorder.start()

        thermal = .fair
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await fulfillment(of: [heated], timeout: 5)
        XCTAssertEqual(events.map(\.kind), ["app.thermal_state"])
        XCTAssertEqual(events.first?.fields["state"], "fair")
        withExtendedLifetime(recorder) {}
    }
}
