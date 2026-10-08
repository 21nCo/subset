#if canImport(UIKit)
import SwiftUI
import UIKit

struct MobileClipboardShelfView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case text
        case links
        case images
        case files

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .text: return "Text"
            case .links: return "Links"
            case .images: return "Images"
            case .files: return "Files"
            }
        }

        var symbolName: String {
            switch self {
            case .all: return "clock.arrow.circlepath"
            case .text: return "text.alignleft"
            case .links: return "link"
            case .images: return "photo"
            case .files: return "folder"
            }
        }

        func matches(_ item: ClipboardItem) -> Bool {
            switch self {
            case .all: return true
            case .text: return item.kind == .text
            case .links: return item.kind == .url
            case .images: return item.kind == .image
            case .files: return item.kind == .files
            }
        }
    }

    let items: [ClipboardItem]
    let title: String
    let subtitle: String
    let emptyTitle: String
    let emptyDescription: String
    let onSelect: (ClipboardItem) -> Void

    @State private var searchQuery = ""
    @State private var selectedFilter: Filter = .all

    private var filteredItems: [ClipboardItem] {
        let scopedItems = items.filter { selectedFilter.matches($0) }
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else { return scopedItems }

        return scopedItems.filter { item in
            item.searchableText.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let isPad = geometry.size.width >= 700
            let isWide = geometry.size.width >= 420
            let topBarHeight: CGFloat = isWide ? 48 : 94
            let filterHeight: CGFloat = 38
            let chromeHeight = topBarHeight + filterHeight + 46
            let cardWidth = min(max(geometry.size.width * (isPad ? 0.26 : 0.46), 150), isPad ? 246 : 186)
            let cardHeight = min(max(geometry.size.height - chromeHeight, isPad ? 132 : 142), isPad ? 212 : 192)

            VStack(alignment: .leading, spacing: 12) {
                topBar(isWide: isWide)
                filterBar

                if filteredItems.isEmpty {
                    emptyState
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: isPad ? 16 : 12) {
                            ForEach(filteredItems) { item in
                                MobileClipboardCard(
                                    item: item,
                                    size: CGSize(width: cardWidth, height: cardHeight),
                                    action: { onSelect(item) }
                                )
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 184, idealHeight: 230, maxHeight: 280)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func topBar(isWide: Bool) -> some View {
        if isWide {
            HStack(spacing: 10) {
                searchField
                titleBadge
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                searchField
                titleBadge
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.42))

            TextField("Search", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.82), in: Capsule())
    }

    private var titleBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(uiColor: .systemBlue))

            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.80))

            Text(subtitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.46))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.82), in: Capsule())
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: filter.symbolName)
                                .font(.system(size: 11, weight: .bold))

                            Text(filter.title)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(chipColor(for: filter))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(selectedFilter == filter ? chipColor(for: filter).opacity(0.14) : Color.white.opacity(0.72))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptyTitle)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.82))

            Text(emptyDescription)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
    }

    private func chipColor(for filter: Filter) -> Color {
        switch filter {
        case .all: return Color(uiColor: .systemBlue)
        case .text: return Color(uiColor: ClipboardItemKind.text.accentColor)
        case .links: return Color(uiColor: ClipboardItemKind.url.accentColor)
        case .images: return Color(uiColor: ClipboardItemKind.image.accentColor)
        case .files: return Color(uiColor: ClipboardItemKind.files.accentColor)
        }
    }
}

private struct MobileClipboardCard: View {
    let item: ClipboardItem
    let size: CGSize
    let action: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var headerColor: Color {
        Color(uiColor: item.kind.accentColor)
    }

    private var headerHeight: CGFloat { 48 }

    private var detailHeight: CGFloat {
        max(56, min(size.height * 0.34, 84))
    }

    private var previewHeight: CGFloat {
        max(54, size.height - headerHeight - detailHeight)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                header
                preview
                details
            }
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.84), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.kind.displayName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(Self.relativeFormatter.localizedString(for: item.capturedAt, relativeTo: Date()))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.90))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Image(systemName: item.kind.symbolName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(headerColor)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .background(headerColor)
        .frame(height: headerHeight, alignment: .top)
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            switch item.kind {
            case .image:
                if let image = item.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    placeholderPreview
                }

            case .url:
                LinearGradient(
                    colors: [Color(red: 0.56, green: 0.88, blue: 0.95), Color(red: 0.44, green: 0.78, blue: 0.96)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(alignment: .bottomLeading) {
                    Text(item.titleText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(10)
                }

            default:
                placeholderPreview
            }
        }
        .frame(height: previewHeight)
        .background(Color(uiColor: .systemGray6))
    }

    private var placeholderPreview: some View {
        LinearGradient(
            colors: [Color.white, Color(uiColor: .secondarySystemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                Capsule()
                    .fill(Color(uiColor: item.kind.accentColor).opacity(0.24))
                    .frame(width: 72, height: 9)

                Capsule()
                    .fill(Color.black.opacity(0.10))
                    .frame(width: 110, height: 6)

                Capsule()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 90, height: 6)

                Capsule()
                    .fill(Color.black.opacity(0.07))
                    .frame(width: 72, height: 6)
            }
            .padding(12)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sourceDisplayLabel = item.sourceDisplayLabel {
                Text(sourceDisplayLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.42))
                    .lineLimit(1)
            }

            Text(item.titleText)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.86))
                .lineLimit(2)

            Text(item.bodyText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.54))
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: detailHeight, maxHeight: detailHeight, alignment: .topLeading)
    }
}
#endif
