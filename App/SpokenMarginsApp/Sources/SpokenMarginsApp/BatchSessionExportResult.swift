import Foundation

struct BatchSessionExportResult: Equatable {
    let exportedFileNames: [String]
    let failures: [String]
    let destinationName: String
}
