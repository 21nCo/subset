import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ClipboardHistoryPanel: View {
    private struct PanelMetrics {
        let searchWidth: CGFloat
        let contentSpacing: CGFloat
        let horizontalPadding: CGFloat
        let contentTopPadding: CGFloat
        let contentBottomPadding: CGFloat
        let shelfFrameHeight: CGFloat?
        let shelfVerticalPadding: CGFloat
        let cardSpacing: CGFloat
        let cardSize: CGSize
        let showsShelfHint: Bool
        let usesVerticalShelf: Bool
    }

    private enum ShelfFilter: String, CaseIterable, Identifiable {
        case all
        case text
        case url
        case image
        case files

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:
                return "All"
            case .text:
                return "Text"
            case .url:
                return "Links"
            case .image:
                return "Images"
            case .files:
                return "Files"
            }
        }

        var heading: String {
            switch self {
            case .all:
                return "Clipboard"
            case .text:
                return "Text"
            case .url:
                return "Links"
            case .image:
                return "Images"
            case .files:
                return "Files"
            }
        }

        var symbolName: String {
            switch self {
            case .all:
                return "clock.arrow.circlepath"
            case .text:
                return "text.alignleft"
            case .url:
                return "link"
            case .image:
                return "photo"
            case .files:
                return "folder"
            }
        }

        func matches(_ item: ClipboardItem) -> Bool {
            switch self {
            case .all:
                return true
            case .text:
                return item.kind == .text
            case .url:
                return item.kind == .url
            case .image:
                return item.kind == .image
            case .files:
                return item.kind == .files
            }
        }
    }

    @ObservedObject var manager: ClipboardManager

    let placement: ClipboardShelfPlacement
    let presentationToken: UUID
    let onSelect: (ClipboardItem) -> Void
    let onClose: () -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var selectedFilter: ShelfFilter = .all
    @State private var selectedItemID: ClipboardItem.ID?
    @State private var keyMonitor: Any?

    private var searchScopedItems: [ClipboardItem] {
        manager.filteredItems
    }

    private var displayedItems: [ClipboardItem] {
        searchScopedItems.filter { selectedFilter.matches($0) }
    }

    private var displayedItemIDs: [ClipboardItem.ID] {
        displayedItems.map(\.id)
    }

    private var panelShape: UnevenRoundedRectangle {
        switch placement {
        case .bottom:
            return UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 28, bottomLeading: 0, bottomTrailing: 0, topTrailing: 28),
                style: .continuous
            )
        case .right:
            return UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 28, bottomLeading: 28, bottomTrailing: 0, topTrailing: 0),
                style: .continuous
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = metrics(for: geometry.size)

            VStack(spacing: 0) {
                toolbar(metrics: metrics)

                VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                    shelfHeader(metrics: metrics)
                    shelfContent(metrics: metrics)
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.top, metrics.contentTopPadding)
                .padding(.bottom, metrics.contentBottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(panelBackground)
            .overlay(
                panelShape
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            )
            .overlay(alignment: placement == .bottom ? .top : .leading) {
                glowEdge
            }
            .clipShape(panelShape)
        }
        .task(id: presentationToken) {
            try? await Task.sleep(for: .milliseconds(120))
            isSearchFocused = false
            synchronizeSelection(resetToFirst: true)
        }
        .onAppear {
            installKeyMonitor()
            synchronizeSelection(resetToFirst: true)
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: displayedItemIDs) {
            synchronizeSelection()
        }
    }

    @ViewBuilder
    private func toolbar(metrics: PanelMetrics) -> some View {
        if metrics.usesVerticalShelf {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    searchField(width: nil)
                    closeButton
                }

                filterScroller

                if !manager.hasAccessibilityPermission {
                    permissionButton
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .background(toolbarBackground)
        } else {
            HStack(spacing: 12) {
                searchField(width: metrics.searchWidth)
                filterScroller
                Spacer(minLength: 10)

                if !manager.hasAccessibilityPermission {
                    permissionButton
                }

                closeButton
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(toolbarBackground)
        }
    }

    private func searchField(width: CGFloat?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.48))

            TextField("Search copied items", text: $manager.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.76))
                .focused($isSearchFocused)
                .onSubmit {
                    activateSelectedItem()
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .frame(maxWidth: width ?? .infinity)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
        )
    }

    private var filterScroller: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(ShelfFilter.allCases) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.56))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
        .accessibilityLabel("Close shelf")
    }

    private var permissionButton: some View {
        Button("Enable Paste") {
            manager.openAccessibilitySettings()
        }
        .help("Grant Accessibility so Clipboard can paste into the previous app. Until then, choosing an item copies it for a manual ⌘V.")
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .foregroundStyle(Color.black.opacity(0.74))
    }

    private func filterChip(_ filter: ShelfFilter) -> some View {
        let isSelected = selectedFilter == filter
        let tint = chipColor(for: filter)
        let count = itemCount(for: filter)

        return Button {
            selectedFilter = filter
        } label: {
            HStack(spacing: 8) {
                Image(systemName: filter.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)

                Text(filter.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(tint.opacity(isSelected ? 1 : 0.82))
            }
            .foregroundStyle(Color.black.opacity(isSelected ? 0.86 : 0.66))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? tint.opacity(0.30) : Color.white.opacity(0.14),
                        lineWidth: 1
                    )
            )
            .overlay(
                Capsule()
                    .fill(isSelected ? tint.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title), \(count) items")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func shelfHeader(metrics: PanelMetrics) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(selectedFilter.heading)
                .font(.system(size: metrics.usesVerticalShelf ? 22 : 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.82))

            Text(headerSubtitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.42))

            Spacer(minLength: 12)

            if metrics.showsShelfHint {
                Text(shortcutHint)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.40))
                    .lineLimit(1)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func shelfContent(metrics: PanelMetrics) -> some View {
        if displayedItems.isEmpty {
            emptyState
        } else if metrics.usesVerticalShelf {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: metrics.cardSpacing) {
                        ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                            card(for: item, index: index, size: metrics.cardSize)
                        }
                    }
                    .padding(.vertical, metrics.shelfVerticalPadding)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    scrollSelection(using: proxy, for: metrics)
                }
                .onChange(of: selectedItemID) {
                    scrollSelection(using: proxy, for: metrics)
                }
            }
        } else {
            GeometryReader { shelfGeometry in
                let verticalPadding = bottomShelfVerticalPadding(for: shelfGeometry.size, metrics: metrics)
                let cardSize = bottomShelfCardSize(for: shelfGeometry.size, verticalPadding: verticalPadding)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: metrics.cardSpacing) {
                            ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                                card(for: item, index: index, size: cardSize)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, verticalPadding)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onAppear {
                        scrollSelection(using: proxy, for: metrics)
                    }
                    .onChange(of: selectedItemID) {
                        scrollSelection(using: proxy, for: metrics)
                    }
                }
            }
        }
    }

    /// One shelf card with its ⌘1–⌘9 quick-paste badge, context menu, and VoiceOver description.
    private func card(for item: ClipboardItem, index: Int, size: CGSize) -> some View {
        ClipboardPanelRow(
            item: item,
            cardSize: size,
            isSelected: item.id == selectedItemID
        ) {
            selectedItemID = item.id
            onSelect(item)
        }
        .overlay(alignment: .bottomTrailing) {
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .contextMenu {
            Button(manager.hasAccessibilityPermission ? "Paste" : "Copy to Clipboard") {
                selectedItemID = item.id
                onSelect(item)
            }
            Divider()
            Button("Delete from History", role: .destructive) {
                manager.delete(item)
            }
        }
        .accessibilityLabel("\(item.kind.displayName): \(item.titleText)")
        .accessibilityValue(item.sourceAppName.map { "From \($0)" } ?? "")
        .accessibilityHint(index < 9 ? "Press Return or Command \(index + 1) to paste" : "Press Return to paste")
        .id(item.id)
    }

    private var emptyState: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.55, blue: 0.97),
                            Color(red: 0.23, green: 0.76, blue: 0.44)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: selectedFilter == .image ? "photo.on.rectangle.angled" : "doc.on.clipboard")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                )
                .frame(width: 96, height: 96)
                .shadow(color: Color.black.opacity(0.10), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 10) {
                Text(emptyTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.80))

                Text(emptyDescription)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.56))
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
    }

    private var toolbarBackground: some View {
        Rectangle()
            .fill(Color.white.opacity(0.02))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
            }
    }

    private var panelBackground: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.18),
                    Color.white.opacity(0.04),
                    Color.white.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    Color(red: 1.00, green: 0.83, blue: 0.54).opacity(0.10),
                    .clear,
                    Color(red: 1.00, green: 0.66, blue: 0.78).opacity(0.10)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            RadialGradient(
                colors: [Color.white.opacity(0.26), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 420
            )
            .offset(x: 90, y: -30)
        }
    }

    @ViewBuilder
    private var glowEdge: some View {
        if placement == .bottom {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), Color.white.opacity(0.08), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 26)
        } else {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.36), Color.white.opacity(0.08), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 24)
        }
    }

    private var shortcutHint: String {
        let verb = manager.hasAccessibilityPermission ? "paste" : "copy"
        return "Return or ⌘1–9 to \(verb) · ⌘⌫ delete · ⌘F search · Esc close"
    }

    private var headerSubtitle: String {
        let verb = manager.hasAccessibilityPermission ? "paste" : "copy"
        return displayedItems.isEmpty ? "Nothing ready yet" : "\(displayedItems.count) ready to \(verb)"
    }

    private var emptyTitle: String {
        switch selectedFilter {
        case .all:
            return "Copy something and it will appear here."
        case .text:
            return "Plain text clips show up here."
        case .url:
            return "Copied links show up here."
        case .image:
            return "Copied images show up here."
        case .files:
            return "Copied files show up here."
        }
    }

    private var emptyDescription: String {
        switch selectedFilter {
        case .all:
            return manager.searchQuery.isEmpty
                ? "Clipboard keeps text, links, images, and files you copy. Press ⇧⌘V for the bottom shelf or ⌥⇧⌘V for the right shelf. Items marked concealed by password managers are never saved."
                : "Nothing matches \u{201C}\(manager.searchQuery)\u{201D}. Press Esc to leave search, then ⌘F to search again."
        case .text:
            return "Anything copied as plain text is grouped here, including notes, snippets, and messages."
        case .url:
            return "Only real clipboard URLs appear here. A page title or regular text stays in Text."
        case .image:
            return "Only images copied to the clipboard appear here. A screenshot saved straight to disk will not show up unless it was copied."
        case .files:
            return "Files or folders copied from Finder appear here so you can paste them back into another app."
        }
    }

    private func itemCount(for filter: ShelfFilter) -> Int {
        searchScopedItems.filter { filter.matches($0) }.count
    }

    private func metrics(for size: CGSize) -> PanelMetrics {
        let usesVerticalShelf = placement == .right
        let horizontalPadding: CGFloat = usesVerticalShelf ? 18 : 24
        let contentSpacing: CGFloat = usesVerticalShelf ? 12 : 10
        let contentTopPadding: CGFloat = usesVerticalShelf ? 14 : 12
        let contentBottomPadding: CGFloat = usesVerticalShelf ? 18 : 12
        let shelfVerticalPadding: CGFloat = usesVerticalShelf ? 4 : 8
        let cardSpacing: CGFloat = usesVerticalShelf ? 14 : 18

        if usesVerticalShelf {
            let cardWidth = max(248, size.width - (horizontalPadding * 2) - 4)
            let cardHeight = min(max(188, size.height * 0.18), 216)

            return PanelMetrics(
                searchWidth: size.width - 92,
                contentSpacing: contentSpacing,
                horizontalPadding: horizontalPadding,
                contentTopPadding: contentTopPadding,
                contentBottomPadding: contentBottomPadding,
                shelfFrameHeight: nil,
                shelfVerticalPadding: shelfVerticalPadding,
                cardSpacing: cardSpacing,
                cardSize: CGSize(width: cardWidth, height: cardHeight),
                showsShelfHint: false,
                usesVerticalShelf: true
            )
        } else {
            let searchWidth = min(max(236, size.width * 0.18), 290)
            let chromeHeight: CGFloat = 110
            let shelfHeight = max(156, min(216, size.height - chromeHeight))
            let cardHeight = shelfHeight - (shelfVerticalPadding * 2)
            let cardWidth = min(max(cardHeight * 0.94, 148), 182)

            return PanelMetrics(
                searchWidth: searchWidth,
                contentSpacing: contentSpacing,
                horizontalPadding: horizontalPadding,
                contentTopPadding: contentTopPadding,
                contentBottomPadding: contentBottomPadding,
                shelfFrameHeight: shelfHeight,
                shelfVerticalPadding: shelfVerticalPadding,
                cardSpacing: cardSpacing,
                cardSize: CGSize(width: cardWidth, height: cardHeight),
                showsShelfHint: size.width > 900,
                usesVerticalShelf: false
            )
        }
    }

    private func chipColor(for filter: ShelfFilter) -> Color {
        switch filter {
        case .all:
            return Color(red: 0.35, green: 0.55, blue: 0.95)
        case .text:
            return Color(nsColor: ClipboardItemKind.text.accentColor)
        case .url:
            return Color(nsColor: ClipboardItemKind.url.accentColor)
        case .image:
            return Color(nsColor: ClipboardItemKind.image.accentColor)
        case .files:
            return Color(nsColor: ClipboardItemKind.files.accentColor)
        }
    }

    private func bottomShelfVerticalPadding(for size: CGSize, metrics: PanelMetrics) -> CGFloat {
        max(metrics.shelfVerticalPadding, min(14, size.height * 0.08))
    }

    private func bottomShelfCardSize(for size: CGSize, verticalPadding: CGFloat) -> CGSize {
        let availableHeight = max(136, size.height - (verticalPadding * 2) - 2)
        let cardWidth = min(max(availableHeight * 0.94, 148), 182)
        return CGSize(width: cardWidth, height: availableHeight)
    }

    private func synchronizeSelection(resetToFirst: Bool = false) {
        guard !displayedItems.isEmpty else {
            selectedItemID = nil
            return
        }

        if resetToFirst || selectedItemID == nil || !displayedItems.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = displayedItems.first?.id
        }
    }

    private func moveSelection(offset: Int) {
        guard !displayedItems.isEmpty, offset != 0 else { return }

        let currentIndex = displayedItems.firstIndex(where: { $0.id == selectedItemID }) ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), displayedItems.count - 1)
        selectedItemID = displayedItems[nextIndex].id
    }

    private func activateSelectedItem() {
        guard let selectedItem = displayedItems.first(where: { $0.id == selectedItemID }) ?? displayedItems.first else {
            return
        }

        selectedItemID = selectedItem.id
        onSelect(selectedItem)
    }

    private func scrollSelection(using proxy: ScrollViewProxy, for metrics: PanelMetrics) {
        guard let selectedItemID else { return }

        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(selectedItemID, anchor: metrics.usesVerticalShelf ? .top : .center)
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Only keys aimed at the visible shelf: the monitor outlives orderOut, and other windows
        // (such as the clear-history alert) must keep their own Return and Esc.
        guard let window = event.window as? ClipboardPanel, window.isVisible else { return false }

        // Caps Lock is part of deviceIndependentFlagsMask; ignore it so ⌘ shortcuts still match.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)

        if modifiers == [.command],
           event.keyCode == UInt16(kVK_ANSI_F) {
            isSearchFocused = true
            return true
        }

        // ⌘1–⌘9 paste the matching visible card, like Paste's quick paste.
        if modifiers == [.command],
           let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           (1...9).contains(digit) {
            guard digit <= displayedItems.count else { return true }
            let item = displayedItems[digit - 1]
            selectedItemID = item.id
            onSelect(item)
            return true
        }

        // ⌘⌫ removes the selected card from history (not while editing the search text).
        if modifiers == [.command],
           event.keyCode == UInt16(kVK_Delete),
           !isSearchFocused,
           let selected = displayedItems.first(where: { $0.id == selectedItemID }) {
            manager.delete(selected)
            return true
        }

        if isSearchFocused {
            if event.keyCode == UInt16(kVK_Escape) {
                isSearchFocused = false
                return true
            }

            return false
        }

        switch event.keyCode {
        case UInt16(kVK_LeftArrow):
            moveSelection(offset: placement == .bottom ? -1 : 0)
            return placement == .bottom
        case UInt16(kVK_RightArrow):
            moveSelection(offset: placement == .bottom ? 1 : 0)
            return placement == .bottom
        case UInt16(kVK_UpArrow):
            moveSelection(offset: placement == .right ? -1 : 0)
            return placement == .right
        case UInt16(kVK_DownArrow):
            moveSelection(offset: placement == .right ? 1 : 0)
            return placement == .right
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            activateSelectedItem()
            return true
        case UInt16(kVK_Escape):
            onClose()
            return true
        default:
            return false
        }
    }
}
