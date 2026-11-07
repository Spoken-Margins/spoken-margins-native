import Foundation
import XCTest

/// Linux XCTest aborts the whole SessionKitCoreTests run, before one test has run, when a main-actor suite's tests are
/// all synchronous ("Could not cast value of type '(Suite) -> @MainActor () -> ()'"): SwiftPM's generated test table
/// is a typed array, and only a suite with an async test in it falls back to an untyped one. The hosted Linux run only
/// goes out on dispatch, so MarginCaptureRetryOrderTests (2026-11-06) sat on `main` unseen. Macs run it fine, so only
/// this check catches it early. A main-actor suite needs at least one `async` test.
final class MainActorTestsAreAsyncGuardTests: XCTestCase {
    private static let testFunction = try! NSRegularExpression(pattern: #"^\s*(@MainActor\s+)?func (test\w*)\(\)\s*(async\s*)?(throws\s*)?\{"#)

    func testNoMainActorSuiteInThisTargetHasOnlySynchronousTests() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var mainActorSuites = 0
        var offenders: [String] = []
        for file in files {
            var suite: String?
            var classIsMainActor = false
            var previousLine = ""
            var tests: [(isMainActor: Bool, isAsync: Bool)] = []
            func finishSuite() {
                guard let name = suite else { return }
                if tests.contains(where: { $0.isMainActor }) { mainActorSuites += 1 }
                if !tests.isEmpty, tests.allSatisfy({ $0.isMainActor && !$0.isAsync }) {
                    offenders.append("\(file.lastPathComponent) \(name)")
                }
                suite = nil
                tests = []
            }
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                defer { previousLine = line }
                // A suite starts at a class declaration in column 0; its attribute sits on that line or the one above.
                if !line.hasPrefix(" "), line.contains("class "), line.contains(": XCTestCase") {
                    finishSuite()
                    classIsMainActor = line.contains("@MainActor") || previousLine.trimmingCharacters(in: .whitespaces) == "@MainActor"
                    suite = line.components(separatedBy: "class ")[1].components(separatedBy: ":")[0]
                    continue
                }
                if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("}"), !line.hasPrefix("@"), !line.hasPrefix("//") {
                    finishSuite() // another top-level declaration ends the suite
                    continue
                }
                guard suite != nil, let match = Self.testFunction.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
                tests.append((isMainActor: classIsMainActor || match.range(at: 1).location != NSNotFound,
                              isAsync: match.range(at: 3).location != NSNotFound))
            }
            finishSuite()
        }
        XCTAssertGreaterThanOrEqual(mainActorSuites, 5, "the guard no longer finds main-actor suites; update it")
        XCTAssertEqual(offenders, [], "each of these main-actor suites needs an `async` test, or Linux XCTest aborts the run")
    }
}
