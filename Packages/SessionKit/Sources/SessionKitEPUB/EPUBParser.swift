import Foundation
import SessionKit
import ZIPFoundation

public struct EPUBParserLimits: Equatable, Sendable {
    public var maximumEntries: Int
    public var maximumEntryBytes: Int64
    public var maximumExpandedBytes: Int64
    public var maximumXMLDepth: Int

    public init(
        maximumEntries: Int = 4_096,
        maximumEntryBytes: Int64 = 8 * 1_024 * 1_024,
        maximumExpandedBytes: Int64 = 128 * 1_024 * 1_024,
        maximumXMLDepth: Int = 128
    ) {
        self.maximumEntries = maximumEntries
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumXMLDepth = maximumXMLDepth
    }
}

public enum EPUBImportError: Error, LocalizedError, Equatable {
    case malformedPackage(String)
    case protectedContent
    case unsafeArchivePath(String)
    case archiveLimitExceeded(String)
    case unsupportedEncryption
    case emptySpine

    public var errorDescription: String? {
        switch self {
        case .malformedPackage(let reason): return "The EPUB package is malformed: \(reason)."
        case .protectedContent: return "This EPUB is protected and cannot be imported."
        case .unsafeArchivePath(let path): return "The EPUB contains an unsafe path: \(path)."
        case .archiveLimitExceeded(let reason): return "The EPUB exceeds a safe import limit: \(reason)."
        case .unsupportedEncryption: return "This EPUB uses unsupported encryption."
        case .emptySpine: return "The EPUB has no readable spine content."
        }
    }
}

public struct EPUBImportResult: Equatable, Sendable {
    public var package: CanonicalSourcePackage
    public var text: String
}

public final class EPUBParser: @unchecked Sendable {
    private let limits: EPUBParserLimits

    public init(limits: EPUBParserLimits = EPUBParserLimits()) {
        self.limits = limits
    }

    public func parse(url: URL, itemId: String, sourceDocumentId: String) throws -> EPUBImportResult {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw EPUBImportError.malformedPackage("archive_open") }
        let entries = Array(archive)
        guard entries.count <= limits.maximumEntries else {
            throw EPUBImportError.archiveLimitExceeded("entry_count")
        }
        var expanded: Int64 = 0
        for entry in entries {
            try validate(path: entry.path)
            let size = Int64(entry.uncompressedSize)
            guard size <= limits.maximumEntryBytes else {
                throw EPUBImportError.archiveLimitExceeded("entry_size")
            }
            expanded += size
            guard expanded <= limits.maximumExpandedBytes else {
                throw EPUBImportError.archiveLimitExceeded("expanded_size")
            }
        }
        if let encryption = archive["META-INF/encryption.xml"] {
            let data = try read(encryption, from: archive)
            if String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("EncryptedData") {
                throw EPUBImportError.unsupportedEncryption
            }
        }
        guard let containerEntry = archive["META-INF/container.xml"] else {
            throw EPUBImportError.malformedPackage("missing_container")
        }
        let container = ContainerXMLDelegate(maximumDepth: limits.maximumXMLDepth)
        try parseXML(try read(containerEntry, from: archive), delegate: container)
        guard let opfPath = container.rootfilePath else {
            throw EPUBImportError.malformedPackage("missing_rootfile")
        }
        try validate(path: opfPath)
        guard let opfEntry = archive[opfPath] else {
            throw EPUBImportError.malformedPackage("missing_opf")
        }
        let opf = OPFXMLDelegate(maximumDepth: limits.maximumXMLDepth)
        try parseXML(try read(opfEntry, from: archive), delegate: opf)
        guard !opf.spine.isEmpty else { throw EPUBImportError.emptySpine }
        let base = (opfPath as NSString).deletingLastPathComponent

        var combined = ""
        var segments: [SpeakableSegment] = []
        for (spineIndex, idref) in opf.spine.enumerated() {
            guard let href = opf.manifest[idref]?.href else { continue }
            let path = resolve(path: href, relativeTo: base)
            try validate(path: path)
            guard let entry = archive[path] else { continue }
            let xhtml = XHTMLTextDelegate(maximumDepth: limits.maximumXMLDepth)
            try parseXML(try read(entry, from: archive), delegate: xhtml)
            for (blockIndex, block) in xhtml.blocks.enumerated() where !block.isEmpty {
                if !combined.isEmpty { combined.append("\n\n") }
                let utf8Start = combined.utf8.count
                combined.append(block)
                let segmentId = String(format: "spine-%04d-segment-%04d", spineIndex + 1, blockIndex + 1)
                let locator = SourceLocator(
                    documentId: sourceDocumentId,
                    spineItemId: idref,
                    segmentId: segmentId,
                    utf8Start: utf8Start,
                    utf8End: combined.utf8.count
                )
                segments.append(SpeakableSegment(id: segmentId, text: block, locator: locator))
            }
        }
        guard !segments.isEmpty else { throw EPUBImportError.emptySpine }

        let navigation = try navigationNodes(opf: opf, base: base, archive: archive, sourceDocumentId: sourceDocumentId, segments: segments)
        let package = CanonicalSourcePackage(
            id: "canonical-\(itemId)",
            itemId: itemId,
            sourceDocumentId: sourceDocumentId,
            format: .epub,
            title: opf.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? url.deletingPathExtension().lastPathComponent,
            author: opf.author?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            language: opf.language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            navigation: navigation,
            segments: segments
        )
        return EPUBImportResult(package: package, text: combined)
    }

    private func navigationNodes(
        opf: OPFXMLDelegate,
        base: String,
        archive: Archive,
        sourceDocumentId: String,
        segments: [SpeakableSegment]
    ) throws -> [CanonicalNavigationNode] {
        let navItem = opf.manifest.values.first { $0.properties.split(separator: " ").contains("nav") }
        let ncxItem = opf.spineTOC.flatMap { opf.manifest[$0] }
        guard let item = navItem ?? ncxItem else {
            return segments.enumerated().map { index, segment in
                CanonicalNavigationNode(id: "chapter-\(index + 1)", title: segment.text.split(separator: " ").prefix(8).joined(separator: " "), locator: segment.locator)
            }
        }
        let path = resolve(path: item.href, relativeTo: base)
        try validate(path: path)
        guard let entry = archive[path] else { return [] }
        let nav = NavigationXMLDelegate(maximumDepth: limits.maximumXMLDepth)
        try parseXML(try read(entry, from: archive), delegate: nav)
        let navigationBase = (path as NSString).deletingLastPathComponent
        func convert(_ node: RawNavigationNode, id: String) -> CanonicalNavigationNode {
            let referencedPath = resolve(path: node.href, relativeTo: navigationBase)
            let spineId = opf.manifest.first { _, item in
                resolve(path: item.href, relativeTo: base) == referencedPath
            }?.key
            let locator = spineId.flatMap { id in segments.first(where: { $0.locator.spineItemId == id })?.locator }
            return CanonicalNavigationNode(
                id: id,
                title: node.title,
                locator: locator,
                children: node.children.enumerated().map { convert($0.element, id: "\(id)-\($0.offset + 1)") }
            )
        }
        return nav.nodes.enumerated().map { convert($0.element, id: "nav-\($0.offset + 1)") }
    }

    private func read(_ entry: Entry, from archive: Archive) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= Int(limits.maximumEntryBytes) else {
                throw EPUBImportError.archiveLimitExceeded("streamed_entry_size")
            }
            data.append(chunk)
        }
        return data
    }

    private func parseXML(_ data: Data, delegate: XMLParserDelegate & DepthLimitedXMLDelegate) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), delegate.depthError == nil else {
            throw delegate.depthError ?? EPUBImportError.malformedPackage(parser.parserError?.localizedDescription ?? "xml")
        }
    }

    private func validate(path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.split(separator: "/").contains("..") else {
            throw EPUBImportError.unsafeArchivePath(path)
        }
    }

    private func resolve(path: String, relativeTo base: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        let withoutFragment = decoded.split(separator: "#", maxSplits: 1).first.map(String.init) ?? decoded
        return base.isEmpty ? withoutFragment : (base as NSString).appendingPathComponent(withoutFragment)
    }
}

private protocol DepthLimitedXMLDelegate: XMLParserDelegate {
    var depthError: EPUBImportError? { get }
}

private class DepthDelegate: NSObject, DepthLimitedXMLDelegate {
    let maximumDepth: Int
    var depth = 0
    var depthError: EPUBImportError?
    init(maximumDepth: Int) { self.maximumDepth = maximumDepth }
    func enter(_ parser: XMLParser) {
        depth += 1
        if depth > maximumDepth { depthError = .archiveLimitExceeded("xml_depth"); parser.abortParsing() }
    }
    func leave() { depth = max(0, depth - 1) }
}

private final class ContainerXMLDelegate: DepthDelegate {
    var rootfilePath: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        enter(parser)
        if elementName.lowercased().hasSuffix("rootfile") { rootfilePath = attributeDict["full-path"] }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { leave() }
}

private struct OPFManifestItem { var href: String; var mediaType: String; var properties: String }

private final class OPFXMLDelegate: DepthDelegate {
    var manifest: [String: OPFManifestItem] = [:]
    var spine: [String] = []
    var spineTOC: String?
    var title: String?
    var author: String?
    var language: String?
    private var capture: String?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        enter(parser)
        let name = elementName.lowercased().split(separator: ":").last.map(String.init) ?? elementName.lowercased()
        if name == "item", let id = attributeDict["id"], let href = attributeDict["href"] {
            manifest[id] = OPFManifestItem(href: href, mediaType: attributeDict["media-type"] ?? "", properties: attributeDict["properties"] ?? "")
        } else if name == "itemref", let idref = attributeDict["idref"] { spine.append(idref) }
        else if name == "spine" { spineTOC = attributeDict["toc"] }
        else if name == "title" || name == "creator" || name == "language" { capture = name; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased().split(separator: ":").last.map(String.init) ?? elementName.lowercased()
        if name == capture { if name == "title" { title = text }; if name == "creator" { author = text }; if name == "language" { language = text }; capture = nil }
        leave()
    }
}

private final class XHTMLTextDelegate: DepthDelegate {
    var blocks: [String] = []
    private var current = ""
    private let blockElements: Set<String> = ["p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote"]
    private var ignoredDepth = 0
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        enter(parser)
        let name = elementName.lowercased().split(separator: ":").last.map(String.init) ?? elementName.lowercased()
        if ignoredDepth > 0 || ["script", "style", "svg", "math", "iframe"].contains(name) { ignoredDepth += 1; return }
        if blockElements.contains(name), !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flush() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if ignoredDepth == 0 { current += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased().split(separator: ":").last.map(String.init) ?? elementName.lowercased()
        if ignoredDepth > 0 { ignoredDepth -= 1 } else if blockElements.contains(name) { flush() }
        leave()
    }
    func parserDidEndDocument(_ parser: XMLParser) { flush() }
    private func flush() {
        let clean = current.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { blocks.append(clean) }
        current = ""
    }
}

private struct RawNavigationNode { var title: String; var href: String; var children: [RawNavigationNode] = [] }

private final class RawNavigationBuilder {
    var title = ""
    var href = ""
    var children: [RawNavigationNode] = []
    func build() -> RawNavigationNode? {
        let clean = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !href.isEmpty else { return nil }
        return RawNavigationNode(title: clean, href: href, children: children)
    }
}

private final class NavigationXMLDelegate: DepthDelegate {
    var nodes: [RawNavigationNode] = []
    private var stack: [RawNavigationBuilder] = []
    private var capturesTitle = false
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        enter(parser)
        let name = elementName.lowercased().split(separator: ":").last.map(String.init) ?? elementName.lowercased()
        if name == "li" || name == "navpoint" { stack.append(RawNavigationBuilder()) }
        if name == "a" || name == "content" {
            if let href = attributeDict["href"] ?? attributeDict["src"] { stack.last?.href = href }
            capturesTitle = name == "a"
            if capturesTitle { text = "" }
        }
        if name == "text" { capturesTitle = true; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capturesTitle { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased().split(separator: ":").last.map(String.init) ?? elementName.lowercased()
        if name == "a" || name == "text" {
            if stack.last?.title.isEmpty == true { stack.last?.title = text }
            capturesTitle = false
            text = ""
        }
        if name == "li" || name == "navpoint", let builder = stack.popLast(), let node = builder.build() {
            if let parent = stack.last { parent.children.append(node) } else { nodes.append(node) }
        }
        leave()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
