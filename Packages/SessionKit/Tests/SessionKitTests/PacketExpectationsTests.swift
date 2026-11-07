import Foundation
@testable import SessionKit
import SessionKitSharing
import ShippedPacketReader
import SessionKitTestInputs
import XCTest

/// `Contracts/examples/packets/expectations.json` records what `coop-packet check` said about every public example
/// packet: what this build's reader does, and what Build 29's frozen reader does (#1386). Until this test only the
/// Python reference reader was compared to it, so a change to either Swift reader went unnoticed until someone re-ran
/// the tool (#1850). Here both readers run over every packet on every SessionKit run.
///
/// An expectation's `swift` text is one of
/// - `imports`: both readers accept the packet;
/// - `<refusal>`: both readers refuse it, this build's with that text (Build 29's wording may differ, so only
///   "refuses" is compared for it);
/// - `imports; Build 29: <refusal>`: this build accepts it and Build 29 refuses it with that text;
/// - `<refusal>; Build 29: <refusal>`: both refuse it, each with its own text.
final class PacketExpectationsTests: XCTestCase {
    /// What `expectations.json` says Build 29's reader does, beyond what it says about this build's.
    enum ShippedExpectation: Equatable {
        /// No separate Build 29 text: it accepts what this build accepts, and refuses what this build refuses.
        case followsCurrent
        case imports
        case refuses(String)
    }

    struct Expected: Equatable {
        /// `nil` means this build's reader accepts the packet; otherwise the refusal text.
        var current: String?
        var shipped: ShippedExpectation
    }

    /// The marker the recorder writes between the two readers' answers.
    static let shippedMarker = "; Build 29: "

    /// What `expectations.json` records for one packet, as data.
    static func parse(_ swift: String) -> Expected {
        let parts = swift.components(separatedBy: shippedMarker)
        let current: String? = parts[0] == "imports" ? nil : parts[0]
        guard parts.count == 2 else { return Expected(current: current, shipped: .followsCurrent) }
        return Expected(current: current, shipped: parts[1] == "imports" ? .imports : .refuses(parts[1]))
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PacketExpectationsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func expectationsAndPackets() throws -> (recorded: [String: String], onDisk: Set<String>, folder: URL) {
        // Read each input into a `let` before asserting, so a skip is a skip, never a failure (TestInputs).
        let folder = try TestInputs.url(.contracts, "examples/packets")
        let data = try Data(contentsOf: folder.appending(path: "expectations.json"))
        let file = try JSONDecoder().decode(ExpectationsFile.self, from: data)
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".spokenmargins") }
        return (file.packets.mapValues(\.swift), Set(onDisk), folder)
    }

    private struct ExpectationsFile: Decodable {
        struct Entry: Decodable { let swift: String }
        let packets: [String: Entry]
    }

    /// What this build's reader does with a packet: `nil` accepts, otherwise the refusal text.
    private func currentVerdict(_ url: URL) -> String? {
        do {
            _ = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets-\(UUID().uuidString)"))
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// What Build 29's frozen reader does: `nil` imports, otherwise the refusal text with its prefix stripped.
    private func shippedVerdict(_ url: URL) -> String? {
        do {
            try ShippedPacketReader.importPacket(at: url)
            return nil
        } catch {
            let text = String(describing: error)
            let prefix = "\(ShippedPacketReader.build) could not import \(url.lastPathComponent): "
            return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
        }
    }

    func testEveryExamplePacketHasAnEntryAndEveryEntryHasAPacket() throws {
        let (recorded, onDisk, _) = try expectationsAndPackets()
        XCTAssertEqual(onDisk.subtracting(recorded.keys).sorted(), [],
                       "a packet in Contracts/examples/packets with no entry in expectations.json: run coop-packet check on it and record the answer")
        XCTAssertEqual(Set(recorded.keys).subtracting(onDisk).sorted(), [],
                       "an entry in expectations.json with no packet in Contracts/examples/packets")
    }

    func testBothReadersGiveTheRecordedVerdictOnEveryExamplePacket() throws {
        let (recorded, onDisk, folder) = try expectationsAndPackets()
        XCTAssertFalse(onDisk.isEmpty)
        for name in recorded.keys.sorted() where onDisk.contains(name) {
            try verify(name: name, swift: recorded[name]!, packet: folder.appending(path: name))
        }
    }

    private func verify(name: String, swift: String, packet: URL) throws {
        let expected = Self.parse(swift)
        let current = currentVerdict(packet)
        let shipped = shippedVerdict(packet)

        XCTAssertEqual(current, expected.current, "\(name): this build's reader changed its verdict (recorded: \(swift))")
        switch expected.shipped {
        case .imports:
            XCTAssertNil(shipped, "\(name): Build 29's reader changed its verdict (recorded: \(swift))")
        case .refuses(let text):
            XCTAssertEqual(shipped, text, "\(name): Build 29's reader changed its verdict (recorded: \(swift))")
        case .followsCurrent:
            XCTAssertEqual(shipped == nil, current == nil,
                           "\(name): Build 29 and this build now disagree about whether the packet is refused (recorded: \(swift))")
        }
    }

    // MARK: The parser itself

    func testTheRecordedTextsParse() {
        XCTAssertEqual(Self.parse("imports"), Expected(current: nil, shipped: .followsCurrent))
        XCTAssertEqual(Self.parse("invalidDigest"), Expected(current: "invalidDigest", shipped: .followsCurrent))
        XCTAssertEqual(Self.parse("imports; Build 29: invalidManifest(\"x\")"),
                       Expected(current: nil, shipped: .refuses("invalidManifest(\"x\")")))
        XCTAssertEqual(Self.parse("invalidManifest(\"a\"); Build 29: invalidManifest(\"b\")"),
                       Expected(current: "invalidManifest(\"a\")", shipped: .refuses("invalidManifest(\"b\")")))
    }
}
