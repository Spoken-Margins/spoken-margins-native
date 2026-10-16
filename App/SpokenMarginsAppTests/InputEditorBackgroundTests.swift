import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// The Timeline's "Reflect on this session" paste box drew as a solid black rectangle in dark mode (#1563): a
/// `TextEditor` paints its own opaque background over a plain `.background(...)`. This mounts the editor the way
/// the two paste boxes use it and checks the text view underneath no longer paints one.
@MainActor
final class InputEditorBackgroundTests: XCTestCase {
    func testTextEditorWithInputBackgroundLeavesItsOwnBackgroundClear() throws {
        for style in [UIUserInterfaceStyle.dark, .light] {
            let host = UIHostingController(rootView: TextEditor(text: .constant("A pasted response"))
                .frame(height: 180)
                .padding(8)
                .inputEditorBackground())
            host.overrideUserInterfaceStyle = style
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 300)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.view.layoutIfNeeded()

            guard let textView = Self.firstTextView(in: host.view) else {
                throw XCTSkip("TextEditor is not backed by a UITextView on this OS, so there is no view to inspect")
            }
            var alpha: CGFloat = 1
            (textView.backgroundColor ?? .clear).resolvedColor(with: host.traitCollection).getRed(nil, green: nil, blue: nil, alpha: &alpha)
            XCTAssertEqual(alpha, 0, accuracy: 0.01, "\(style == .dark ? "dark" : "light") mode: the editor paints its own background over the input colour")
        }
    }

    private static func firstTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for child in view.subviews {
            if let match = firstTextView(in: child) { return match }
        }
        return nil
    }
}
