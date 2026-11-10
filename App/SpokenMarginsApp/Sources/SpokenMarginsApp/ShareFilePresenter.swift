#if canImport(UIKit)
import UIKit

/// Hands a file (the listening-signals log, #483, or the diagnostics export, #903) to the iOS share sheet.
/// Nothing is uploaded by the app.
///
/// The sheet is presented straight from UIKit, not as a SwiftUI `.sheet` inside the Settings form. Settings reads the
/// whole `Gate1AppModel`, which publishes many times a second while audio renders, and with the sheet hosted there the
/// share sheet kept reloading: its preview flipped between a thumbnail and the plain file icon and the People row
/// blanked and refilled (#4026). A sheet UIKit presents is outside every SwiftUI redraw.
@MainActor
enum ShareFilePresenter {
    /// Presents the share sheet for `fileURL` over whatever is on top. Does nothing without a foreground window.
    static func present(fileURL: URL) {
        guard let top = topViewController() else { return }
        top.present(makeController(fileURL: fileURL, anchoredIn: top.view), animated: true)
    }

    /// The sheet itself, apart from presenting it, so a test can check what it carries and how it is anchored.
    static func makeController(fileURL: URL, anchoredIn view: UIView) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        // On iPad the sheet is a popover and needs an anchor; a centred one with no arrow reads like the phone's sheet.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    /// The view controller a new sheet should go over: the front-most one, following presented sheets.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return topViewController(from: window?.rootViewController)
    }

    static func topViewController(from root: UIViewController?) -> UIViewController? {
        var top = root
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
#endif
