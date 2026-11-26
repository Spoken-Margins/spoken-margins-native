import Foundation
import XCTest
@testable import SessionKit

/// #4340: a Margin's Paper note role rides the opt-in iCloud sync as an edited register, like the sharing star.
final class PaperNoteRoleSyncTests: XCTestCase {
    private let t0: Int64 = 1_700_000_000_000

    func testTheRoleRoundTripsThroughASyncRecord() throws {
        for role in PaperNoteRole.allCases {
            var clock = SyncClock(device: "A")
            var margin = SyncFixtures.margin(id: "m1")
            margin.paperRole = role
            let record = try MarginSync.record(for: margin, itemKey: "paper-1", clock: &clock, wallMillis: t0)
            XCTAssertEqual(record["paperRole"]?.stringValue, role.rawValue)
            XCTAssertEqual(MarginSync.apply(record, to: SyncFixtures.margin(id: "m1")).paperRole, role)
        }
    }

    func testAMarginWithNoRoleWritesNoRoleField() throws {
        var clock = SyncClock(device: "A")
        let record = try MarginSync.record(for: SyncFixtures.margin(id: "m1"), itemKey: "paper-1", clock: &clock, wallMillis: t0)
        XCTAssertNil(record["paperRole"])
        var onOtherPhone = SyncFixtures.margin(id: "m1")
        onOtherPhone.paperRole = .purpose
        XCTAssertEqual(MarginSync.apply(record, to: onOtherPhone).paperRole, .purpose, "a record that says nothing leaves the role alone")
    }

    func testChangingAndTakingOffTheRoleAreWrittenAndNothingElseIs() throws {
        var clock = SyncClock(device: "A")
        var base = SyncFixtures.margin(id: "m1")
        base.paperRole = .evidence
        var record = try MarginSync.record(for: base, itemKey: "paper-1", clock: &clock, wallMillis: t0)

        var changed = base
        changed.paperRole = .purpose
        MarginSync.write(changed, changedFrom: base, into: &record, clock: &clock, wallMillis: t0 + 1000)
        XCTAssertEqual(record["paperRole"]?.stringValue, "purpose")
        XCTAssertEqual(MarginSync.apply(record, to: base).paperRole, .purpose)

        var cleared = changed
        cleared.paperRole = nil
        MarginSync.write(cleared, changedFrom: changed, into: &record, clock: &clock, wallMillis: t0 + 2000)
        XCTAssertEqual(MarginSync.apply(record, to: changed).paperRole, nil, "taking the role off reaches the other phone")

        // An edit that leaves the role alone does not touch its register.
        let before = record["paperRole"]
        var edited = cleared
        edited.privateSharingNote = "for Sam"
        MarginSync.write(edited, changedFrom: cleared, into: &record, clock: &clock, wallMillis: t0 + 3000)
        XCTAssertEqual(record["paperRole"], before)
    }

    func testARoleThisBuildDoesNotKnowIsLeftAsTheDeviceHasIt() throws {
        var clock = SyncClock(device: "A")
        var record = try MarginSync.record(for: SyncFixtures.margin(id: "m1"), itemKey: "paper-1", clock: &clock, wallMillis: t0)
        record.set("paperRole", .string("methodology"), clock: &clock, wallMillis: t0 + 1)
        var local = SyncFixtures.margin(id: "m1")
        local.paperRole = .keyFinding
        XCTAssertEqual(MarginSync.apply(record, to: local).paperRole, .keyFinding)
    }

    func testTheRoleIsEncryptedLikeEveryThingTheListenerWrote() {
        XCTAssertTrue(SyncFieldSchema.isEncrypted(field: "paperRole"))
    }
}
