import Foundation

/// The phone's voices changed what can be read (#3402): a note no voice could read is new again, or the other way round.
/// `showsAsNew` and the offer ask live, so the screens only need to draw again, and the Library's count to be read again.
extension Gate1AppModel {
    func writtenMarginVoicesChanged() {
        objectWillChange.send()
        refreshLibraryRowsInBackground(mustPublish: true)
        refreshMarginRowsInBackground()
    }
}
