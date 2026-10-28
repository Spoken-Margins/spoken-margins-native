import SessionKit
import SwiftUI

struct ExperienceEditorialHeader: View {
    let eyebrow: String
    let title: String
    let detail: String?

    init(eyebrow: String, title: String, detail: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.15)
                .foregroundStyle(AppColors.evergreen)
            Text(title)
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .foregroundStyle(AppColors.text)
            if let detail {
                Text(detail)
                    .font(.body)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ExperienceSurface<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let tint: Color?
    let padding: CGFloat
    let content: Content

    init(tint: Color? = nil, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(AppColors.text)
            .background(AppColors.panel)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(tint ?? AppColors.border, lineWidth: contrast == .increased ? 2 : 0.75)
            }
    }
}

/// Apple's minimum hit area for a control. A control drawn smaller keeps its look and gets this much room to tap (#151).
enum TapTarget {
    static let minimum: CGFloat = 44
}

extension View {
    /// Gives a small control at least 44 × 44 pt to tap. Apply it after the visible background or clip, so the
    /// drawn shape stays the same size and only the hit area grows.
    func minimumTapTarget() -> some View {
        frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Grows the hit area by this much on each side without moving anything: the layout keeps its size, and
    /// the control still looks the same. For controls in rows too tight to take a 44 pt frame (#1929).
    func expandedHitArea(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
    }
}

/// A bare icon button label (dismiss ✕, clear search) with a 44 pt hit area around the unchanged glyph (#151).
struct TapTargetIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .minimumTapTarget()
    }
}

/// A row with a time or percent gutter on the left. The gutter's width scales with the text size so
/// "1:02:03" or "100%" fits; at accessibility sizes it would eat half the row, so the time sits above the
/// content instead (#1938).
struct GutterRow<Gutter: View, Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric private var gutterWidth: CGFloat
    private let alignment: VerticalAlignment
    private let spacing: CGFloat?
    private let gutter: Gutter
    private let content: Content

    init(
        gutterWidth: CGFloat,
        alignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder gutter: () -> Gutter,
        @ViewBuilder content: () -> Content
    ) {
        _gutterWidth = ScaledMetric(wrappedValue: gutterWidth, relativeTo: .caption)
        self.alignment = alignment
        self.spacing = spacing
        self.gutter = gutter()
        self.content = content()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                gutter
                content
            }
        } else {
            HStack(alignment: alignment, spacing: spacing) {
                gutter.frame(width: gutterWidth, alignment: .leading)
                content
            }
        }
    }
}

struct ExperienceFilterChip<Content: View>: View {
    private let preferences = AppAccessibilityPreferences()
    let isActive: Bool
    let content: Content

    init(isActive: Bool, @ViewBuilder content: () -> Content) {
        self.isActive = isActive
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 5) {
            // Under Differentiate Without Color the active chip says so with a glyph as well as its fill (#1922).
            if isActive && preferences.differentiatesWithoutColor {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).accessibilityHidden(true)
            }
            content
        }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isActive ? AppColors.onEvergreen : AppColors.text)
            .padding(.horizontal, 13)
            .frame(minHeight: 38)
            .background(isActive ? AppColors.evergreen : AppColors.panel)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(isActive ? AppColors.evergreen : AppColors.border)
            }
            .minimumTapTarget()
            .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Marks a shared Margin the listener hasn't heard yet (#469). The word carries the meaning, not the color.
struct NewMarginBadge: View {
    var body: some View {
        Text("New")
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppColors.onEvergreen)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(AppColors.evergreen, in: Capsule())
            .accessibilityLabel("New to you")
    }
}

extension View {
    func experienceListBlock(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalPadding: CGFloat = 11
    ) -> some View {
        frame(maxWidth: horizontalSizeClass == .regular ? 960 : .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(
                top: verticalPadding,
                leading: horizontalSizeClass == .regular ? 28 : 16,
                bottom: verticalPadding,
                trailing: horizontalSizeClass == .regular ? 28 : 16
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(AppColors.bone)
    }
}

struct SMExperienceTypeCover: View {
    let id: String
    let mediaType: String
    let sourceReferenceType: String?
    let size: CGFloat

    init(row: LibraryItemRow, size: CGFloat) {
        id = row.id
        mediaType = row.mediaType
        sourceReferenceType = row.sourceReferenceType
        self.size = size
    }

    init(id: String, mediaType: String, sourceReferenceType: String? = nil, size: CGFloat) {
        self.id = id
        self.mediaType = mediaType
        self.sourceReferenceType = sourceReferenceType
        self.size = size
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(background)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Circle()
                .fill(foreground.opacity(0.13))
                .frame(width: size * 0.52, height: size * 0.52)
                .offset(x: size * 0.16, y: size * 0.18)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .accessibilityHidden(true)
    }

    private var systemImage: String {
        let normalized = mediaType.lowercased()
        if normalized.contains("podcast") || normalized.contains("audio") { return "waveform" }
        if normalized.contains("epub") || normalized.contains("book") { return "book.closed.fill" }
        if normalized.contains("pdf") { return "doc.richtext.fill" }
        if sourceReferenceType == "url" { return "safari.fill" }
        return "doc.text.fill"
    }

    private var background: Color {
        switch stableSeed {
        case 0: AppColors.softGreen
        case 1: AppColors.ochre.opacity(0.20)
        default: AppColors.plum.opacity(0.16)
        }
    }

    private var foreground: Color {
        switch stableSeed {
        case 0: AppColors.evergreen
        case 1: AppColors.ochre
        default: AppColors.plum
        }
    }

    private var stableSeed: Int {
        id.utf8.reduce(0) { partial, byte in (partial &* 31 &+ Int(byte)) % 3 }
    }
}

struct SMExperienceEmptyState: View {
    let systemImage: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            Button(actionTitle, action: action)
                .filledActionButton()
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

extension View {
    /// The filled action button. It sets the label to `onEvergreen`: the system's white label on
    /// dark-mode evergreen is about 1.8:1, which the owner couldn't read on Add to Library (#537).
    /// The contrast audit checks `onEvergreen` against evergreen and plum, so tint with one of those.
    func filledActionButton(tint: Color = AppColors.evergreen) -> some View {
        buttonStyle(.borderedProminent)
            .tint(tint)
            .foregroundStyle(AppColors.onEvergreen)
    }
}

/// A listener-facing failure: an icon as well as a colour, because colour alone
/// cannot tell failure from status for a red-green colour-blind listener (#308).
struct FailureMessageLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .foregroundStyle(AppColors.dangerText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Puts the app's input colour behind a `TextEditor`. A `TextEditor` paints its own opaque scroll background,
    /// black in the dark scheme, which covered a plain `.background(AppColors.inputBackground)` (#1563).
    func inputEditorBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(AppColors.inputBackground)
            .increasedContrastEdge(cornerRadius: 8)
    }
}
