import Foundation

/// The words and rules of a live-session photo Margin (#2708), with no UIKit so each is tested on the host. The screens
/// ask this type what to say and what a tap on Photo does, so a line and its button cannot disagree.
public enum LiveSessionPhotoMargin {
    /// Photo is offered on a paper book or something else, never in a meeting (a whiteboard has other people in the
    /// room) or an audiobook. Owner's "document session" (2026-10-25); Default taken 1 on #2708.
    public static func offers(_ kind: ElsewhereKind) -> Bool {
        switch kind {
        case .paper, .other: true
        case .meeting, .audiobook: false
        }
    }

    /// The line under the photo on the Margin screen. Nil where Photo isn't offered.
    public static func hint(for kind: ElsewhereKind) -> String? {
        switch kind {
        case .paper: "Say something that helps place this, like \u{201C}chapter 5\u{201D} or \u{201C}the paragraph about the budget\u{201D}."
        case .other: "Say what this is about."
        case .meeting, .audiobook: nil
        }
    }

    public static let buttonTitle = "Photo"
    public static let buttonAccessibilityLabel = "Add a Margin with a photo"
    public static let thumbnailAccessibilityLabel = "Photo you just took"
    /// The Margin is saved and the picture is not.
    public static let couldNotKeepLine = "The photo couldn't be kept. Your Margin is saved."
    public static let noCameraLine = "This device has no camera. Add a Margin by voice or in writing instead."
    public static let cameraOffLine = "The camera is off for Spoken Margins."
    public static let openSettingsTitle = "Open Settings"
    /// The picture could not be read, fitted or written, before any Margin was made: nothing was saved.
    public static let couldNotUseLine = "The photo couldn't be used. Try again, or add a Margin without a photo."
    public static let withoutPhotoTitle = "Add a Margin without a photo"
    /// True after a deletion, after a restore, and later when sessions sync to another device.
    public static let missingFileLine = "This photo isn't on this device."
    /// Said when the microphone can't be used after a photo was taken: the words go in writing and the photo stays.
    public static let writeInsteadLine = "The microphone isn't available, so write the Margin instead. Your photo is kept."

    /// Read after a list row's label when the Margin has a photo, as an accessibility value.
    public static let rowAccessibilityValue = "with a photo"

    /// What the system says about the camera, reduced to what the tap needs.
    public enum CameraAuthorization: Equatable, Sendable {
        case notDetermined, authorized, denied, restricted
    }

    /// What a tap on Photo does. Never a dead tap: with no camera or a camera that is off, the listener is told, and told
    /// what to do instead.
    public enum Tap: Equatable, Sendable {
        /// Open the system camera (the first use asks iOS's own permission question, with no screen of ours before it).
        case openCamera
        case noCamera
        /// Offer Open Settings and Add a Margin without a photo.
        case cameraOff
    }

    public static func tap(hasCamera: Bool, authorization: CameraAuthorization) -> Tap {
        guard hasCamera else { return .noCamera }
        switch authorization {
        case .notDetermined, .authorized: return .openCamera
        case .denied, .restricted: return .cameraOff
        }
    }

    /// Whether the dock's Photo control is live: a session that is running, nothing recording or being filed, and no
    /// photo already waiting for its words. A second tap during the camera or the permission question does nothing.
    public static func isEnabled(isRunning: Bool, isRecording: Bool, isCapturingPhoto: Bool, hasPhotoWaiting: Bool) -> Bool {
        isRunning && !isRecording && !isCapturingPhoto && !hasPhotoWaiting
    }
}
