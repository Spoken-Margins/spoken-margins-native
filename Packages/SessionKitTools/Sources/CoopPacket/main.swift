import Foundation

/// `coop-packet`: makes and checks co-op test packets on the Mac (#856).
///
/// Synthetic listeners answer real packets, or start threads for a person to answer, so the
/// whole co-op loop can be pressure-tested without recruiting people. Packets are written with
/// the same SessionKit code the app uses, and every packet is read back by the current reader and
/// the Build 29 reader before it leaves the Mac.
///
///     swift run --package-path Packages/SessionKitTools coop-packet inspect <packet>...
///     swift run --package-path Packages/SessionKitTools coop-packet build <plan.json> [--out <dir>]
///     swift run --package-path Packages/SessionKitTools coop-packet check <packet>...
///     swift run --package-path Packages/SessionKitTools coop-packet map <edition.json> [--type text|pdf|epub] [--url <link>|--no-url]
///
/// The plan format is in `Packages/SessionKitTools/Sources/CoopPacket/README.md`.

let usage = """
usage:
  coop-packet inspect <packet>...            print each packet as JSON (item, sender, Margins, reply links)
  coop-packet build <plan.json> [--out dir]  write a packet from a plan, then check it
  coop-packet check <packet>...              read every packet in both readers, then merge them in every order
  coop-packet map <edition.json> [--type text|pdf|epub] [--url link | --no-url] [--sender label] [--name file] [--out dir]
                                             write a map-only packet (a Listening Map, no Margins) from a Listening Edition
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("coop-packet: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }
let rest = Array(arguments.dropFirst())
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL }

do {
    switch command {
    case "inspect":
        guard !rest.isEmpty else { fail(usage) }
        let reports = try rest.map { try PacketInspector.inspect(fileURL($0)) }
        print(try PacketInspector.json(reports.count == 1 ? AnyEncodable(reports[0]) : AnyEncodable(reports)))
    case "build":
        guard let planPath = rest.first else { fail(usage) }
        var outDirectory: URL?
        if let flag = rest.firstIndex(of: "--out") {
            guard rest.indices.contains(flag + 1) else { fail("--out needs a folder") }
            outDirectory = fileURL(rest[flag + 1])
        }
        let built = try await PacketBuilder.build(planURL: fileURL(planPath), outDirectory: outDirectory)
        print("wrote \(built.url.path)")
        print("  digest \(built.digest)")
        print("  \(built.marginCount) Margins, \(built.replyCount) replies, \(built.byteCount / 1024) KB")
        let report = try CoopCheck.run([built.url])
        print(report.text)
        if !report.passed { exit(2) }
    case "map":
        guard let editionPath = rest.first, !editionPath.hasPrefix("--") else { fail(usage) }
        func value(of flag: String) -> String? {
            guard let index = rest.firstIndex(of: flag) else { return nil }
            guard rest.indices.contains(index + 1) else { fail("\(flag) needs a value") }
            return rest[index + 1]
        }
        let built = try MapPacketBuilder.build(
            editionURL: fileURL(editionPath),
            itemType: value(of: "--type") ?? "text",
            canonicalURL: rest.contains("--no-url") ? "" : value(of: "--url"),
            sender: value(of: "--sender") ?? "A friend (synthetic)",
            fileName: value(of: "--name"),
            outDirectory: value(of: "--out").map(fileURL)
        )
        print("wrote \(built.url.path)")
        print("  digest \(built.digest)")
        print("  \(built.sceneCount) chapters, \(built.byteCount / 1024) KB")
        let report = try CoopCheck.run([built.url])
        print(report.text)
        if !report.passed { exit(2) }
    case "check":
        guard !rest.isEmpty else { fail(usage) }
        let report = try CoopCheck.run(rest.map(fileURL))
        print(report.text)
        if !report.passed { exit(2) }
    default:
        fail(usage)
    }
} catch {
    fail("\(error)")
}
