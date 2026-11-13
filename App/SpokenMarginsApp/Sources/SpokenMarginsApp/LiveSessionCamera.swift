import AVFoundation
import SessionKit
import SwiftUI
import UIKit

/// What the live session needs to know about the camera (#2708): whether this device has one and whether Spoken
/// Margins may use it, reduced to what `LiveSessionPhotoMargin.tap` decides on. The first use goes straight to the
/// system camera, which asks iOS's own question with `NSCameraUsageDescription`; no screen of ours comes before it.
@MainActor
enum LiveSessionCamera {
    static var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    static var authorization: LiveSessionPhotoMargin.CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    static var tap: LiveSessionPhotoMargin.Tap {
        LiveSessionPhotoMargin.tap(hasCamera: hasCamera, authorization: authorization)
    }

    /// Opens Spoken Margins' page in Settings, for a camera that is off.
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    #if DEBUG
    /// A simulator has no camera, so a test supplies the picture where the camera would return one: launch with
    /// `-LiveSessionFixturePhoto` and Photo takes this fixture, a generated page-sized image, instead of opening the
    /// camera. Never compiled into a release build. The real camera is part of the owner's phone check.
    static var fixturePhoto: Data? {
        guard ProcessInfo.processInfo.arguments.contains("-LiveSessionFixturePhoto") else { return nil }
        let size = CGSize(width: 3_000, height: 4_000)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.96, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.darkGray.setFill()
            for line in 0..<24 {
                context.fill(CGRect(x: 300, y: 400 + CGFloat(line) * 130, width: 2_400, height: 36))
            }
        }
        return image.jpegData(compressionQuality: 0.9)
    }
    #endif
}

/// The system camera, full screen, for one picture (#2708). The system's own Retake and Use Photo are the confirmation, so
/// a picture reaches `onPicture` only when the listener chose it, and Cancel returns with nothing taken. The document
/// scanner is not used: its auto-capture and several pages are slow for one quick picture of a page or a board.
struct LiveSessionCameraPicker: UIViewControllerRepresentable {
    /// The picture as JPEG data, as the camera made it.
    let onPicture: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicture: onPicture, onCancel: onCancel) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onPicture: (Data) -> Void
        private let onCancel: () -> Void

        init(onPicture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onPicture = onPicture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) else {
                onCancel()
                return
            }
            onPicture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

/// Fits a picture to what a Margin may keep and waits for its words, off the main actor (#2708). The encoder scales to
/// 2,048 px, writes a JPEG within 1.5 MB with no metadata (no location, no camera details), and the store keeps it in
/// the temporary folder until the Margin is saved or cancelled.
enum LiveSessionPhotoIntake {
    /// Nil when the picture can't be read or fitted, or the file can't be written; the caller says the Margin can still
    /// be added without a photo.
    static func stage(_ pictureData: Data, in store: LiveSessionPhotoStore) async -> LiveSessionPhotoStore.Staged? {
        await Task.detached(priority: .userInitiated) { () -> LiveSessionPhotoStore.Staged? in
            guard let encoded = try? LiveSessionPhotoEncoder.encode(pictureData) else { return nil }
            return try? store.stage(data: encoded.data, widthPx: encoded.widthPx, heightPx: encoded.heightPx)
        }.value
    }

    /// The store the app's photos live in: Application Support, with staged files in the temporary folder.
    static var store: LiveSessionPhotoStore? {
        LiveSessionFileWorker.shared.root.map { LiveSessionPhotoStore(root: $0) }
    }
}
