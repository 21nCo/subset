#if canImport(UIKit)
import SwiftUI
import UIKit

struct IOSClipboardHostView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var manager = MobileClipboardManager()
    @State private var hasSeenKeyboardExtension = KeyboardSetupState.hasSeenKeyboardExtension
    @State private var keyboardHasFullAccess = KeyboardSetupState.lastKnownKeyboardHasFullAccess
    @State private var showSetupGuide = !KeyboardSetupState.didDismissOnboarding

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard

                    if !keyboardHasFullAccess || !hasSeenKeyboardExtension {
                        setupStatusCard
                    }

                    if let preview = manager.pasteboardPreview {
                        currentClipboardCard(preview)
                    }

                    clipboardSection
                    imagePasteNote
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(uiColor: .systemGroupedBackground),
                        Color.white,
                        Color(red: 0.97, green: 0.98, blue: 1.00)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Clipboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Setup") {
                        showSetupGuide = true
                    }

                    Button("Refresh") {
                        manager.syncCurrentClipboardNow()
                        refreshSetupStatus()
                    }
                }
            }
            .onAppear {
                manager.refresh(forceSync: false)
                refreshSetupStatus()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                // Change-count gated: an unchanged clipboard is not re-read on every foreground.
                manager.refresh(forceSync: false)
                refreshSetupStatus()
            }
            // Swiping the guide away counts as seeing it, so it does not reappear every launch.
            .sheet(isPresented: $showSetupGuide, onDismiss: markSetupGuideSeen) {
                setupGuideSheet
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clipboard Keyboard")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.86))

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(manager.keyboardSubtitle)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(Color(uiColor: .systemBlue))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.88), in: Capsule())
            }

            Text(manager.statusMessage)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                )
        )
    }

    private var setupStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !hasSeenKeyboardExtension {
                Label("Clipboard Keyboard has not been opened yet.", systemImage: "keyboard.badge.ellipsis")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.82))

                Text("Open any text field, then long-press the globe or emoji key and switch to Clipboard Keyboard.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !keyboardHasFullAccess {
                Label("Clipboard Keyboard needs Full Access.", systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.orange)

                Text("Turn on Full Access so the keyboard can sync the current clipboard automatically.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Open Setup Guide") {
                    showSetupGuide = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(uiColor: .systemBlue), in: Capsule())

                Button("App Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.72))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.86), in: Capsule())
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.80))
        )
    }

    private func currentClipboardCard(_ preview: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current Clipboard")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.84))

            Button {
                manager.copyToClipboard(preview)
            } label: {
                HStack(spacing: 12) {
                    currentClipboardThumbnail(for: preview)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview.titleText)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.84))
                            .lineLimit(2)

                        Text(preview.bodyText)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.52))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(uiColor: .systemBlue))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.82))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var clipboardSection: some View {
        sectionCard(title: "Saved Clips") {
            MobileClipboardShelfView(
                items: manager.items,
                title: "Clipboard",
                subtitle: "\(manager.items.count) saved",
                emptyTitle: "Copy something first",
                emptyDescription: "Saved clips will appear here automatically."
            ) { item in
                manager.copyToClipboard(item)
            }
            .frame(height: 254)
        }
    }

    private var imagePasteNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Photo paste on iPhone")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.84))

            Text("Text and links paste directly. Photos are copied back to the clipboard first, so in many apps you still need to long-press the field and tap Paste.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.56))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.80))
        )
    }

    @ViewBuilder
    private func currentClipboardThumbnail(for item: ClipboardItem) -> some View {
        if item.kind == .image, let image = item.previewImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: item.kind.accentColor).opacity(0.14))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: item.kind.symbolName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color(uiColor: item.kind.accentColor))
                }
        }
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.86))

            content()
        }
    }

    private var setupGuideSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Set Up Clipboard Keyboard")
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    Text("iPhone and iPad do not let apps enable custom keyboards automatically, so this one setup still has to be done in Settings.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)

                    setupStep(number: 1, text: "Open Settings > General > Keyboard > Keyboards > Add New Keyboard...")
                    setupStep(number: 2, text: "Choose Clipboard Keyboard from the third-party keyboard list.")
                    setupStep(number: 3, text: "Tap Clipboard Keyboard again and turn on Allow Full Access.")
                    setupStep(number: 4, text: "Open any text field, long-press the globe or emoji key, and switch to Clipboard Keyboard.")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("After setup")
                            .font(.system(size: 16, weight: .bold, design: .rounded))

                        Text("Copy something, open the Clipboard Keyboard, and the current clipboard will appear there automatically.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.84))
                    )
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        markSetupGuideSeen()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("App Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    private func setupStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color(uiColor: .systemBlue), in: Circle())

            Text(text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.82))
        )
    }

    private func refreshSetupStatus() {
        hasSeenKeyboardExtension = KeyboardSetupState.hasSeenKeyboardExtension
        keyboardHasFullAccess = KeyboardSetupState.lastKnownKeyboardHasFullAccess
    }

    private func markSetupGuideSeen() {
        KeyboardSetupState.didDismissOnboarding = true
        showSetupGuide = false
        refreshSetupStatus()
    }
}
#endif
