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
    let content: Content

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
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

struct ExperienceFilterChip<Content: View>: View {
    let isActive: Bool
    let content: Content

    init(isActive: Bool, @ViewBuilder content: () -> Content) {
        self.isActive = isActive
        self.content = content()
    }

    var body: some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isActive ? Color.white : AppColors.text)
            .padding(.horizontal, 13)
            .frame(minHeight: 38)
            .background(isActive ? AppColors.evergreen : AppColors.panel)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(isActive ? AppColors.evergreen : AppColors.border)
            }
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
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}
