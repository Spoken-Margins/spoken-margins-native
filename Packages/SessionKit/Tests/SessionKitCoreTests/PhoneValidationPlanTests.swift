import XCTest
@testable import SessionKit

final class PhoneValidationPlanTests: XCTestCase {
    private func request() throws -> PhoneValidationPlan.Request {
        let json = #"""
        {"build":"abc1234","required":[101,102],"previousStillOpen":[101],
         "controls":["Play","Pause"],"proposal":{"blocked":[],"checks":[
           {"issues":[101],"source":"The same article","setup":"Open the linked article.",
            "controls":["Play"],"action":"Tap **Play**.","expected":"Hear the article once.","minutes":1},
           {"issues":[102],"source":"The same article","setup":"Open the linked article.",
            "controls":["Pause"],"action":"Tap **Pause**.","expected":"Audio stops.","minutes":1}]}}
        """#
        return try JSONDecoder().decode(PhoneValidationPlan.Request.self, from: Data(json.utf8))
    }

    func testGroupsTwoFixesIntoOneSourceStep() throws {
        let input = try request()
        let plan = try PhoneValidationPlan.audit(input)
        let markdown = plan.markdown(build: input.build, planID: "daily-1")
        XCTAssertEqual(markdown.components(separatedBy: "**The same article**").count - 1, 1)
        XCTAssertTrue(markdown.contains("Audio stops. (#102)"))
        XCTAssertTrue(markdown.contains("Hear the article once. (#101)"))
        XCTAssertEqual(plan.minutes, 4)
    }

    func testRejectsDroppingStillOpenIssueFromPreviousPlan() throws {
        var input = try request()
        input.proposal.checks.removeFirst()
        XCTAssertThrowsError(try PhoneValidationPlan.audit(input))
        input.required = [102] // The collector cannot hide the omission either.
        XCTAssertThrowsError(try PhoneValidationPlan.audit(input))
    }

    func testRejectsInventedControlAndCheckWithoutExpectedResult() throws {
        var input = try request()
        input.proposal.checks[0].controls = ["Magic play"]
        XCTAssertThrowsError(try PhoneValidationPlan.audit(input))
        input = try request()
        input.proposal.checks[0].expected = ""
        XCTAssertThrowsError(try PhoneValidationPlan.audit(input))
    }

    func testControlNameMustBeNamedExactlyRatherThanAsALookalike() throws {
        for action in ["Tap Playroom.", "Tap **Playroom**.", "Tap **play**.", "Tap ** Play **.", ""] {
            var input = try request()
            input.proposal.checks[0].action = action
            XCTAssertThrowsError(try PhoneValidationPlan.audit(input), action)
        }
    }

    func testBlockedIssueRemainsVisibleAndCannotBePassed() throws {
        var input = try request()
        input.proposal.checks.removeFirst()
        input.proposal.blocked = [.init(issue: 101, reason: "Missing PDF link")]
        let markdown = try PhoneValidationPlan.audit(input).markdown(build: input.build, planID: "daily-1")
        XCTAssertTrue(markdown.contains("#101: Missing PDF link"))
        XCTAssertFalse(markdown.contains("#101: TODO"))
        input.proposal.checks.append(try request().proposal.checks[0])
        XCTAssertThrowsError(try PhoneValidationPlan.audit(input))
    }
}
