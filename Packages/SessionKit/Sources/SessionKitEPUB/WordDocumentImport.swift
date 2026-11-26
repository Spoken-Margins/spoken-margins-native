import Foundation
import SessionKit

/// A Word document picked in + › Files, read into what `SourceFileItemBuilder` makes a Library item of (#4594).
///
/// The text is the document's body as Word shows it with tracked changes accepted (`DocxPlainText.paragraphs`); its
/// Title and Heading paragraphs are the chapters. Comments, footnotes, headers and footers are not read: they stay in
/// the original file, which the import keeps beside the item. The title is the document's own (File › Properties) unless
/// it's one an authoring tool left ("Microsoft Word - x.docx"), else the file name.
///
/// A file that can't be read is refused with a sentence that says why, and nothing is added.
public enum WordDocumentImport {
    public enum Failure: Error, Equatable, LocalizedError {
        /// An old binary Word file (`.doc`).
        case oldWordFormat
        /// A `.docx` saved with a password: Word encrypts the whole file.
        case passwordProtected
        /// Not a Word document at all (a renamed file, a damaged one).
        case notAWordDocument
        /// A Word document with no text in its body.
        case empty
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .oldWordFormat:
                "This is an older Word document (.doc). Open it in Word or Pages, save it as .docx, and add it again."
            case .passwordProtected:
                "This Word document has a password. Remove the password in Word, save it, and add it again."
            case .notAWordDocument:
                "This file isn't a Word document Spoken Margins can read. Save it again as .docx and try again."
            case .empty:
                "This Word document has no text to read aloud."
            case .tooLarge:
                "This Word document is too large to add. Try splitting it into smaller documents."
            }
        }
    }

    /// The extensions this import takes. A `.doc` is taken only to be refused with its own sentence.
    public static let fileExtensions: Set<String> = ["docx", "doc"]

    /// The most of a picked file that is read: the whole file is in memory while its text is read.
    public static let maximumFileBytes = 100 * 1_024 * 1_024

    public static func handles(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Reads a picked Word file from disk: its text, and its bytes. The size is checked before the file is read. The
    /// caller holds the file's security-scoped access.
    public static func read(url: URL) throws -> (imported: ImportedSourceText, original: Data) {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maximumFileBytes {
            throw Failure.tooLarge
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.notAWordDocument }
        return (try read(data: data, fileName: url.lastPathComponent), data)
    }

    /// Reads a picked Word file. `data` is the whole file, the bytes the import keeps as the original.
    public static func read(
        data: Data, fileName: String, maximumDocumentBytes: Int = DocxPlainText.defaultMaximumBytes
    ) throws -> ImportedSourceText {
        guard data.count <= maximumFileBytes else { throw Failure.tooLarge }
        // Word's old format and an encrypted `.docx` are both compound files, not zips; tell them apart before unzipping.
        if isCompoundFile(data) {
            throw containsEncryptedPackage(data) ? Failure.passwordProtected : Failure.oldWordFormat
        }
        if (fileName as NSString).pathExtension.lowercased() == "doc" { throw Failure.oldWordFormat }
        let read: (paragraphs: [DocumentParagraph], title: String?)
        do {
            read = try DocxPlainText.paragraphs(from: data, maximumBytes: maximumDocumentBytes)
        } catch DocxPlainText.Failure.tooLarge {
            throw Failure.tooLarge
        } catch {
            throw Failure.notAWordDocument
        }
        guard read.paragraphs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw Failure.empty
        }
        let title = read.title.flatMap { PDFItemTitle.isPlaceholder($0) ? nil : $0 }
        return ImportedSourceText(
            text: read.paragraphs.map(\.text).joined(separator: "\n"),
            documentStructure: nil,
            title: title,
            paragraphs: read.paragraphs
        )
    }

    /// The OLE compound file signature that `.doc`, `.xls` and an encrypted Office file start with.
    private static let compoundFileSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    static func isCompoundFile(_ data: Data) -> Bool {
        data.count >= compoundFileSignature.count && Array(data.prefix(compoundFileSignature.count)) == compoundFileSignature
    }

    /// An encrypted Office file is a compound file holding a stream named "EncryptedPackage"; its directory stores
    /// names in UTF-16LE.
    static func containsEncryptedPackage(_ data: Data) -> Bool {
        guard let name = "EncryptedPackage".data(using: .utf16LittleEndian) else { return false }
        return data.range(of: name) != nil
    }
}
