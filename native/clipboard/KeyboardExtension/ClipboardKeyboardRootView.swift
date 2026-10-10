#if canImport(UIKit)
import SwiftUI

struct ClipboardKeyboardRootView: View {
    @ObservedObject var controller: KeyboardClipboardController

    let needsInputModeSwitchKey: Bool
    let onAdvanceToNextInputMode: () -> Void
    let onBackspace: () -> Void
    let onReload: () -> Void
    let onOpenKeyboardSettings: () -> Void
    let onSelect: (ClipboardItem) -> Void

    var body: some View {
        VStack(spacing: 8) {
            topBar

            if !controller.hasFullAccess {
                fullAccessBanner
            }

            statusBanner

            MobileClipboardShelfView(
                items: controller.items,
                title: "Clipboard",
                subtitle: controller.subtitle,
                emptyTitle: "Copy something first",
                emptyDescription: "Copy text, a link, or a photo, then open this keyboard again.",
                showsSearch: false
            ) { item in
                onSelect(item)
            }

            footerBar
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(
                colors: [
                    Color(uiColor: .systemGray6),
                    Color.white,
                    Color(red: 0.96, green: 0.98, blue: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if needsInputModeSwitchKey {
                Button(action: onAdvanceToNextInputMode) {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.76))
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.92), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next keyboard")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Clipboard")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.86))

                Text(controller.subtitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.48))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onReload) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.92), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reload clipboard history")
        }
    }

    private var fullAccessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(Color.orange)

            Text("Allow Full Access to sync clipboard history automatically.")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Settings") {
                onOpenKeyboardSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange, in: Capsule())
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
                )
        )
    }

    private var statusBanner: some View {
        Text(controller.statusMessage)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.58))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.82))
            )
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Text("Text pastes directly. Photos copy to the clipboard first.")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.46))
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(action: onBackspace) {
                Image(systemName: "delete.left.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 38)
                    .background(Color(uiColor: .systemBlue), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
        }
    }
}
#endif
