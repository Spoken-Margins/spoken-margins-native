import Foundation

/// The colours of the two segmented controls on the playback plate: the pane switch (Now, Timeline, Margins) and the
/// Margins filter (All, Mine, Shared) (#3735). Both sit in a tray drawn on the always-dark listening plate, and the
/// selected option is a pill drawn on that tray. Foundation only, so the views and the contrast audit in
/// `ExperienceColorContrast.swift` read the same numbers.
///
/// The selected option is an opaque white pill with plate-green words, and the selected pane has a short bar under its
/// words as a second cue (#3735). The pairs in `ExperienceColorContrast.swift` measure these numbers.
public enum PlaybackSegmentPalette {
    /// The colour the tray and the pills are drawn in, each at its own alpha over what is under it.
    public static let fill = AppSemanticColorRGB.white
    /// The tray behind the options, over the listening plate.
    public static let trayAlpha = 0.06
    /// The selected pane's pill, over the tray: opaque, a luminance step that reads without hue.
    public static let paneSelectedFillAlpha = 1.0
    /// The selected filter's pill, over the tray: the same pill as the pane switch, so the two controls look alike.
    public static let filterSelectedFillAlpha = 1.0
    /// The words of the selected option, its symbol and the bar under it: the plate's own dark green, on the pill.
    public static let selectedLabel = AppSemanticColorRGB.listeningBackground
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
