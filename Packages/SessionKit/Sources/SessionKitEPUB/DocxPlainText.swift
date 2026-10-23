import Foundation
import ZIPFoundation

/// The paragraphs of a Word .docx as plain text, one per line (#2481): Teams and Google Meet transcripts come
/// as .docx, and `TranscriptImport` reads the text. Tabs stay tabs, so "Name<tab>0:03" keeps its separator.
/// Lives here because this module already links ZIPFoundation.
public enum DocxPlainText {
    public enum Failure: Error, Equatable, LocalizedError {
        case notADocx

        public var errorDescription: String? { "This file isn't a Word document Spoken Margins can read." }
    }

    /// Caps the document part at 32 MB so a hostile file can't exhaust memory.
    public static func text(from url: URL, maximumBytes: Int = 32 * 1_024 * 1_024) throws -> String {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) } catch { throw Failure.notADocx }
        guard let entry = archive["word/document.xml"], entry.uncompressedSize <= UInt64(maximumBytes) else { throw Failure.notADocx }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: false) { data.append($0) }
        return try text(fromDocumentXML: data)
    }

    public static func text(fromDocumentXML data: Data) throws -> String {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw Failure.notADocx }
        return delegate.paragraphs.joined(separator: "\n")
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        private var current = ""
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "w:p": current = ""
            case "w:t": inText = true
            case "w:tab": current += "\t"
            case "w:br", "w:cr": current += "\n"
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "w:p": paragraphs.append(current)
            case "w:t": inText = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }
    }
}
