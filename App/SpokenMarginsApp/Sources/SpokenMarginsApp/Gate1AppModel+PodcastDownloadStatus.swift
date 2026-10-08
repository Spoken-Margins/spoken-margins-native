import Foundation
import SessionKit

/// What the selected podcast's download is doing, in words, for the item and Playback screens (#936).
extension Gate1AppModel {
    private var selectedPodcastDownloadRecord: PodcastDownloadRecord? {
        podcastDownloadRecords[selectedItem.id]
    }

    /// "Downloading 42% of 107 MB" while it runs, "Downloaded, 107 MB" once it is saved, nil otherwise.
    var selectedPodcastDownloadStatusText: String? {
        guard let record = selectedPodcastDownloadRecord else { return nil }
        switch record.state {
        case .downloading: return PodcastDownloadStatusText.downloading(record)
        case .availableOffline: return PodcastDownloadStatusText.downloaded(record)
        case .waitingForWiFi, .streamingOnly, .failed, .evicted: return nil
        }
    }

    /// 0...1 while a download runs and its size is known; nil otherwise, which shows an indeterminate spinner.
    var selectedPodcastDownloadProgress: Double? {
        guard let record = selectedPodcastDownloadRecord, record.state == .downloading else { return nil }
        return record.progress
    }

    /// The Playback screen's download button: "Download Again" once saved, "Downloading 42%" while it runs.
    var selectedPodcastDownloadButtonTitle: String {
        guard let record = selectedPodcastDownloadRecord else { return "Download Audio" }
        switch record.state {
        case .availableOffline: return "Download Again"
        case .downloading: return PodcastDownloadStatusText.buttonTitle(record)
        case .waitingForWiFi, .streamingOnly, .failed, .evicted: return "Download Audio"
        }
    }
}
