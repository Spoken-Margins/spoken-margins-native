import Foundation
import XCTest
@testable import SessionKit

final class ExportSavedConfirmationTests: XCTestCase {
    private let files = ExportSavedConfirmation.saveToFilesActivity

    func testTable() {
        struct Row {
            let name: String
            let completed: Bool
            let type: String?
            let url: String?
            let failed: Bool
            let want: String?
        }
        let rows = [
            Row(name: "Save to Files, no URL", completed: true, type: files, url: nil, failed: false, want: "Saved to Files"),
            Row(name: "On My iPhone folder", completed: true, type: files, url: "file:///var/mobile/On%20My%20iPhone/Margin.md", failed: false, want: "Saved to On My iPhone"),
            Row(name: "iCloud Drive folder", completed: true, type: files, url: "file:///Users/x/Library/Mobile%20Documents/com~apple~CloudDocs/Notes/Margin.md", failed: false, want: "Saved to Notes"),
            Row(name: "nested folder", completed: true, type: files, url: "file:///a/b/c/Reading/2026/Margin.md", failed: false, want: "Saved to 2026"),
            Row(name: "URL with no useful parent", completed: true, type: files, url: "file:///Margin.md", failed: false, want: "Saved to Files"),
            Row(name: "Unicode and spaces", completed: true, type: files, url: "file:///x/Lectures%20%E2%80%94%20caf%C3%A9/Margin.md", failed: false, want: "Saved to Lectures \u{2014} caf\u{E9}"),
            Row(name: "cancel", completed: false, type: nil, url: nil, failed: false, want: nil),
            Row(name: "cancel with a type", completed: false, type: files, url: nil, failed: false, want: nil),
            Row(name: "failure", completed: true, type: files, url: nil, failed: true, want: nil),
            Row(name: "failure, not completed", completed: false, type: files, url: nil, failed: true, want: nil),
            Row(name: "AirDrop", completed: true, type: "com.apple.UIKit.activity.AirDrop", url: nil, failed: false, want: nil),
            Row(name: "no activity type", completed: true, type: nil, url: nil, failed: false, want: nil),
        ]
        for row in rows {
            let got = ExportSavedConfirmation.message(
                completed: row.completed, activityType: row.type, savedTo: row.url.flatMap(URL.init(string:)), failed: row.failed)
            XCTAssertEqual(got, row.want, row.name)
        }
    }
}
