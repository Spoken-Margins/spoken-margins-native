import Foundation
import SessionKit

extension Gate1AppModel {
    /// The page reader for an article the listener asked for (a pasted or shared link, a read-later tap, a shared
    /// packet's article): a shortener's address, such as t.co from X, is followed to its article first, so the reader
    /// never stops on the shortener's own page (#4633). Feed refreshes keep the bare `readablePageExtractor`, so
    /// nothing in the background contacts a shortener. Tests replace `readablePageExtractor` and still get this wrapper.
    var listenerReadablePageExtractor: any ReadablePageExtracting {
        ShortLinkFollowingExtractor(wrapping: readablePageExtractor, resolver: ShortLinkResolver(fetch: ShortLinkTransport.hop))
    }
}
