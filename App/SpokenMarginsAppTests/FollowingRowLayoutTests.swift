@testable import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #4723: a Following row's "N new" sits on the picture and "In Library" sits on a whole line, so neither adds a line
/// at default sizes, and at accessibility sizes the row stacks instead of breaking words. These tests lay out the
/// production rows. Widths are the row's width inside the List: screens of 320, 375, 402 and 440 pt minus 16 + 16.
@MainActor
final class FollowingRowLayoutTests: XCTestCase {
    private static let widths: [CGFloat] = [288, 343, 370, 408]

    private func show(newCount: Int = 2, inLibrary: Bool = false) -> FollowingShowRow {
        FollowingShowRow(
            id: "money", title: "Money & Macro Talks", newCount: newCount,
            newestEpisodeTitle: "Rates, tariffs and the long way round to a soft landing", newestEpisodeDate: nil,
            dateLabel: "Nov 19", playEntryID: "entry", playItemID: nil, newestEntryID: "entry",
            isNewestInLibrary: inLibrary, isQuiet: false, accessibilityLabel: "Money & Macro Talks.")
    }

    private func friend(newCount: Int) -> FollowingFriends.Friend {
        FollowingFriends.Friend(
            id: "cole", name: "Cole", marginCount: 3, newCount: newCount, newestAt: nil, items: [], summary: "3 Margins on 1 episode")
    }

    private func height<V: View>(of view: V, size: DynamicTypeSize, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: width, height: 4_000)).height
    }

    private func showHeight(
        _ row: FollowingShowRow, adding: Bool = false, starting: Bool = false, size: DynamicTypeSize = .large, width: CGFloat = 343
    ) -> CGFloat {
        height(
            of: FollowingShowRowView(
                row: row, artworkURL: nil, open: {}, play: {}, add: {}, isPlayStarting: starting, isAdding: adding),
            size: size, width: width)
    }

    func testInLibraryAddsNoHeight() {
        for width in [343, 370, 408] as [CGFloat] {
            let without = showHeight(show(inLibrary: false), width: width)
            let with = showHeight(show(inLibrary: true), width: width)
            XCTAssertEqual(with, without, accuracy: 0.5, "width \(width): In Library added \(with - without) pt")
        }
    }

    func testTheNewCountAddsNoHeight() {
        for inLibrary in [false, true] {
            let none = showHeight(show(newCount: 0, inLibrary: inLibrary))
            for count in [2, 150] {
                XCTAssertEqual(showHeight(show(newCount: count, inLibrary: inLibrary)), none, accuracy: 0.5,
                               "\(count) new, inLibrary \(inLibrary)")
            }
        }
        let noFriendCount = height(of: FollowingFriendRowView(friend: friend(newCount: 0), open: {}), size: .large, width: 343)
        let friendCount = height(of: FollowingFriendRowView(friend: friend(newCount: 3), open: {}), size: .large, width: 343)
        XCTAssertEqual(friendCount, noFriendCount, accuracy: 0.5)
    }

    func testStatusSlotStatesAddNoHeight() {
        let base = showHeight(show(inLibrary: false))
        XCTAssertEqual(showHeight(show(inLibrary: true)), base, accuracy: 0.5, "In Library")
        XCTAssertEqual(showHeight(show(inLibrary: false), adding: true), base, accuracy: 0.5, "Adding")
        XCTAssertEqual(showHeight(show(inLibrary: false), adding: true, starting: true), base, accuracy: 0.5, "Adding while starting")
    }

    func testNoSizeAddsMoreThanOneCaptionLineForInLibrary() {
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
        for size in sizes {
            let line = UIFont.preferredFont(
                forTextStyle: .caption1,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: Self.category(size))).lineHeight
            for width in Self.widths {
                let without = showHeight(show(inLibrary: false), size: size, width: width)
                let with = showHeight(show(inLibrary: true), size: size, width: width)
                XCTAssertLessThanOrEqual(with - without, line + 8 + 0.5, "\(size) at \(width): the row grew \(with - without) pt")
            }
        }
    }

    func testAccessibilitySizesReflowWithoutCuttingTheRow() {
        let large = showHeight(show(inLibrary: true), size: .large)
        let ax3 = showHeight(show(inLibrary: true), size: .accessibility3)
        XCTAssertGreaterThan(ax3, large)
        XCTAssertGreaterThan(ax3, 0)
        let friendAX = height(of: FollowingFriendRowView(friend: friend(newCount: 3), open: {}), size: .accessibility3, width: 343)
        XCTAssertGreaterThan(friendAX, 0)
    }

    private static func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        default: .extraExtraExtraLarge
        }
    }
}
