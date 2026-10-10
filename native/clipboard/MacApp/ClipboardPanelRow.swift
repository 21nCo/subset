import AppKit
import SwiftUI

struct ClipboardPanelRow: View {
    let item: ClipboardItem
    let cardSize: CGSize
    let isSelected: Bool
    let action: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var isCompactCard: Bool {
        cardSize.height < 190
    }

    private var headerHeight: CGFloat {
        isCompactCard ? 42 : 54
    }

    private var previewHeight: CGFloat {
        let reservedDetailHeight = isCompactCard ? 60.0 : 88.0
        let availablePreviewHeight = cardSize.height - headerHeight - reservedDetailHeight
        let proposedHeight = isCompactCard ? cardSize.height * 0.31 : cardSize.height * 0.40
        // Never exceed the space the header and details leave, or the card's content clips.
        return max(0, min(max(isCompactCard ? 44 : 60, proposedHeight), availablePreviewHeight))
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private var detailHeight: CGFloat {
        max(cardSize.height - headerHeight - previewHeight, isCompactCard ? 60 : 88)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                cardHeader
                previewArea
                detailSection
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .background(
                cardShape
                    .fill(Color.white.opacity(0.95))
            )
            .clipShape(cardShape)
            .overlay(
                cardShape
                    .strokeBorder(borderColor, lineWidth: isSelected ? 2.5 : 1)
            )
            .overlay(alignment: .topLeading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(headerColor.opacity(0.14))
                        .frame(width: 44, height: 5)
                        .padding(.top, 8)
                        .padding(.leading, 14)
                }
            }
            .shadow(color: shadowColor, radius: isSelected ? 22 : 16, y: isSelected ? 12 : 8)
            .scaleEffect(isSelected ? 1.01 : 1)
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
    }

    private var cardHeader: some View {
        ZStack(alignment: .topTrailing) {
            headerColor

            VStack(alignment: .leading, spacing: 3) {
                Text(item.kind.displayName)
                    .font(.system(size: isCompactCard ? 12.5 : 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(Self.relativeFormatter.localizedString(for: item.capturedAt, relativeTo: Date()))
                    .font(.system(size: isCompactCard ? 9.5 : 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.leading, 13)
            .padding(.trailing, 58)
            .padding(.top, isCompactCard ? 9 : 11)

            headerAccessory
                .padding(.top, isCompactCard ? 4 : 5)
                .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: headerHeight, alignment: .topLeading)
    }

    private var headerAccessory: some View {
        ZStack {
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 16, bottomLeading: 16, bottomTrailing: 0, topTrailing: 16),
                style: .continuous
            )
            .fill(Color.white.opacity(0.92))

            if let sourceApplicationIcon = item.sourceApplicationIcon {
                Image(nsImage: sourceApplicationIcon)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .shadow(color: Color.black.opacity(0.08), radius: 4, y: 1)
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(headerColor)
            }
        }
        .frame(width: 44, height: 30)
    }

    private var previewArea: some View {
        ZStack {
            if let image = item.previewImage {
                Color.black.opacity(0.05)

                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(6)
            } else {
                previewFallback
            }
        }
        .frame(height: previewHeight)
        .clipped()
    }

    @ViewBuilder
    private var previewFallback: some View {
        switch item.kind {
        case .text:
            LinearGradient(
                colors: [Color.white, Color(red: 0.95, green: 0.97, blue: 1.00)],
                startPoint: .top,
                endPoint: .bottom
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 7) {
                    Rectangle()
                        .fill(Color(nsColor: ClipboardItemKind.text.accentColor).opacity(0.32))
                        .frame(width: 72, height: 8)
                        .clipShape(Capsule())

                    Rectangle()
                        .fill(Color.black.opacity(0.10))
                        .frame(width: 116, height: 6)
                        .clipShape(Capsule())

                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                        .frame(width: 98, height: 6)
                        .clipShape(Capsule())

                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                        .frame(width: 86, height: 6)
                        .clipShape(Capsule())
                }
                .padding(12)
            }
        case .url:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.38, green: 0.88, blue: 0.63),
                        Color(red: 0.20, green: 0.74, blue: 0.48)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                mapPattern

                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 0)

                    Text(item.titleText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(item.bodyText)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        case .image:
            Color(red: 0.98, green: 0.90, blue: 0.92)
        case .files:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.77, green: 0.71, blue: 1.00),
                        Color(red: 0.58, green: 0.47, blue: 0.95)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(item.filePaths.count == 1 ? "1 file" : "\(item.filePaths.count) files")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sourceDisplayLabel = item.sourceDisplayLabel {
                HStack(spacing: 6) {
                    if let sourceApplicationIcon = item.sourceApplicationIcon {
                        Image(nsImage: sourceApplicationIcon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 13, height: 13)
                    }

                    Text(sourceDisplayLabel)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                }
            }

            Text(item.titleText)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.8))
                .lineLimit(1)

            Text(item.bodyText)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.58))
                .lineLimit(isCompactCard ? 1 : 2)

            Spacer(minLength: 0)

            HStack {
                Text(metadataText)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.38))

                Spacer()

                Text("Paste")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(headerColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCompactCard ? 9 : 10)
        .frame(maxWidth: .infinity, minHeight: detailHeight, maxHeight: detailHeight, alignment: .topLeading)
        .background(Color.white.opacity(0.98))
    }

    private var mapPattern: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<5, id: \.self) { index in
                    Path { path in
                        let y = CGFloat(index) * 28 + 10
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                    .stroke(Color.white.opacity(0.22), lineWidth: 2)
                }

                ForEach(0..<6, id: \.self) { index in
                    Path { path in
                        let x = CGFloat(index) * 44 + 8
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    }
                    .stroke(Color.white.opacity(0.16), lineWidth: 2)
                }

                Circle()
                    .fill(Color.orange)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: 22, y: -6)
            }
        }
    }

    private var metadataText: String {
        switch item.kind {
        case .text, .url:
            return "\(item.textContent?.count ?? 0) characters"
        case .image:
            if let image = item.previewImage {
                return "\(Int(image.size.width)) x \(Int(image.size.height))"
            }
            return "Image"
        case .files:
            return item.filePaths.count == 1 ? "1 file" : "\(item.filePaths.count) files"
        }
    }

    private var headerColor: Color {
        Color(nsColor: item.kind.accentColor)
    }

    private var borderColor: Color {
        isSelected ? headerColor.opacity(0.80) : Color.white.opacity(0.88)
    }

    private var shadowColor: Color {
        isSelected ? headerColor.opacity(0.22) : Color.black.opacity(0.10)
    }
}
