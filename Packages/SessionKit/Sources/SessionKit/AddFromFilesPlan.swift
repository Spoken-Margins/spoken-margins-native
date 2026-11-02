import Foundation

/// Sorts what a listener picked in the Add sheet's single "Import from Files" tile into the import each file takes
/// (#3217). Before, "Document or Book" and "Audiobook" were two tiles that both opened the Files picker and differed
/// only in the types they allowed; now one picker allows them all and the file's own type picks the route.
///
/// The rule goes by the file name's extension, case-blind, and the order inside each group is the order picked.
/// Anything that is not a packet, an audio file, a collection (`.json`) or a folder is a document, which is what
/// the old document route did with every file that was not one of those, so an odd extension still reaches the same
/// importer and its own error message as before.
public struct AddFromFilesPlan: Equatable, Sendable {
    /// A `.spokenmargins` packet: staged for review, like one opened from Messages or Mail.
    public var packets: [URL] = []
    /// An audio file the listener owns: MP3, M4A, M4B or audio MP4. Each becomes its own audiobook item.
    public var audio: [URL] = []
    /// A Listening Edition collection file (`.json`).
    public var collections: [URL] = []
    /// A picked folder, which the edition import walks for collection files (#2672).
    public var folders: [URL] = []
    /// Text, Markdown, PDF, EPUB, and anything else the document route took.
    public var documents: [URL] = []

    public static let packetExtension = "spokenmargins"
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "mp4"]
    public static let collectionExtension = "json"

    public init(picking urls: [URL], isFolder: (URL) -> Bool) {
        for url in urls {
            if isFolder(url) { folders.append(url); continue }
            switch url.pathExtension.lowercased() {
            case Self.packetExtension: packets.append(url)
            case let ext where Self.audioExtensions.contains(ext): audio.append(url)
            case Self.collectionExtension: collections.append(url)
            default: documents.append(url)
            }
        }
    }

    /// Nothing was picked.
    public var isEmpty: Bool {
        packets.isEmpty && audio.isEmpty && collections.isEmpty && folders.isEmpty && documents.isEmpty
    }

    /// The part that goes through the document and collection import together, which already splits them.
    public var documentsAndCollections: [URL] { documents + collections + folders }
}
