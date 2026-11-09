import XCTest
@testable import SessionKit

/// #318 (from #1819, #2858): the background voice download's one piece that needs URLSession. Mac only: Linux has no
/// background URLSession, so SessionKit builds without BackgroundVoiceModelTransport there.
final class BackgroundVoiceModelTransportTests: XCTestCase {
    /// #2858 audit: a Wi-Fi-only task is told apart from one the listener started by its own request, which is what
    /// keeps its resume data (it carries the request) and its running task out of a mobile-data download.
    func testAWiFiOnlyTaskIsToldApartFromOneTheListenerStarted() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://fixture.invalid/model.bin")!
        var wifiOnly = URLRequest(url: url)
        wifiOnly.allowsCellularAccess = false
        wifiOnly.allowsExpensiveNetworkAccess = false
        wifiOnly.allowsConstrainedNetworkAccess = false

        XCTAssertTrue(BackgroundVoiceModelTransport.isWiFiOnly(session.downloadTask(with: wifiOnly)))
        XCTAssertFalse(BackgroundVoiceModelTransport.isWiFiOnly(session.downloadTask(with: URLRequest(url: url))))
    }
}
