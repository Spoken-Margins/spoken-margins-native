import Foundation

/// The colours of the two segmented controls on the playback plate: the pane switch (Now, Timeline, Margins) and the
/// Margins filter (All, Mine, Shared) (#3735). Both sit in a tray drawn on the always-dark listening plate, and the
/// selected option is a pill drawn on that tray. Foundation only, so the views and the contrast audit in
/// `ExperienceColorContrast.swift` read the same numbers.
///
/// The values here are what the views drew before the audit could see them. A later change moves them, and the
/// audit's pairs and its known failures move with them.
public enum PlaybackSegmentPalette {
    /// The colour the tray and the pills are drawn in, each at its own alpha over what is under it.
    public static let fill = AppSemanticColorRGB.white
    /// The tray behind the options, over the listening plate.
    public static let trayAlpha = 0.06
    /// The selected pane's pill, over the tray.
    public static let paneSelectedFillAlpha = 0.18
    /// The selected filter's pill, over the tray.
    public static let filterSelectedFillAlpha = 0.40
    /// The words of the selected option.
    public static let selectedLabel = AppSemanticColorRGB.white
    /// The words of an option that is not selected, on the tray.
    public static let unselectedLabel = AppSemanticColorRGB.white

    /// The plate the controls sit on: the playback dock and the live session dock both draw it.
    public static let plate = AppSemanticColorRGB.listeningBackground

    /// The tray over the plate, as it is seen.
    public static var tray: AppDynamicRGB { fill.composited(over: plate, alpha: trayAlpha) }
    /// The selected pane's pill over the tray over the plate.
    public static var paneSelectedPill: AppDynamicRGB { fill.composited(over: tray, alpha: paneSelectedFillAlpha) }
    /// The selected filter's pill over the tray over the plate.
    public static var filterSelectedPill: AppDynamicRGB { fill.composited(over: tray, alpha: filterSelectedFillAlpha) }
}
