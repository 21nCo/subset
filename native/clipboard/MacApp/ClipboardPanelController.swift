import AppKit
import CoreGraphics
import SwiftUI

enum ClipboardShelfPlacement {
    case bottom
    case right
}

@MainActor
final class ClipboardPanelController {
    private let manager: ClipboardManager
    private var panel: ClipboardPanel?
    private var presentationTarget: ActiveAppTarget?
    private var presentationToken = UUID()

    private(set) var isPresented = false
    private(set) var currentPlacement: ClipboardShelfPlacement = .bottom

    init(manager: ClipboardManager) {
        self.manager = manager
    }

    func show(placement: ClipboardShelfPlacement = .bottom) {
        currentPlacement = placement
        presentationTarget = manager.currentPasteTarget()
        presentationToken = UUID()
        manager.resetSearch()
        manager.refreshPermissionState()

        let panel = panelInstance()
        updateContent(of: panel)
        applyLayout(to: panel)

        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        isPresented = true
    }

    func hide() {
        panel?.orderOut(nil)
        isPresented = false
    }

    private func panelInstance() -> ClipboardPanel {
        if let panel {
            return panel
        }

        let panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 280),
            view: makePanelView()
        )

        self.panel = panel
        return panel
    }

    private func updateContent(of panel: ClipboardPanel) {
        panel.contentView = NSHostingView(rootView: makePanelView())
    }

    private func makePanelView() -> some View {
        ClipboardHistoryPanel(
            manager: manager,
            placement: currentPlacement,
            presentationToken: presentationToken,
            onSelect: { [weak self] item in
                self?.paste(item)
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )
    }

    private func paste(_ item: ClipboardItem) {
        let target = presentationTarget ?? manager.currentPasteTarget()
        hide()

        Task { @MainActor [weak self] in
            await self?.manager.paste(item, to: target)
            self?.presentationTarget = nil
        }
    }

    private func applyLayout(to panel: NSPanel) {
        guard let screen = targetScreen() else { return }
        panel.setFrame(panelFrame(for: screen), display: true)
    }

    private func targetScreen() -> NSScreen? {
        screenForTarget(presentationTarget ?? manager.currentPasteTarget())
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        switch currentPlacement {
        case .bottom:
            let height = min(max(340, screenFrame.height * 0.34), 392)
            return NSRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: screenFrame.width,
                height: height
            )
        case .right:
            let visibleFrame = screen.visibleFrame
            let width = min(max(360, visibleFrame.width * 0.28), 430)
            return NSRect(
                x: visibleFrame.maxX - width,
                y: visibleFrame.minY,
                width: width,
                height: visibleFrame.height
            )
        }
    }

    private func screenForTarget(_ target: ActiveAppTarget?) -> NSScreen? {
        guard
            let target,
            let windowFrame = frontmostWindowFrame(for: target.processIdentifier)
        else {
            return nil
        }

        return NSScreen.screens.max(by: { overlapArea(between: $0.frame, and: windowFrame) < overlapArea(between: $1.frame, and: windowFrame) })
    }

    private func frontmostWindowFrame(for processIdentifier: pid_t) -> CGRect? {
        guard
            let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }

        let boundsKey = kCGWindowBounds as String
        let ownerPIDKey = kCGWindowOwnerPID as String
        let layerKey = kCGWindowLayer as String

        let candidateWindows = infoList.compactMap { info -> CGRect? in
            guard
                let ownerPIDValue = info[ownerPIDKey] as? NSNumber,
                ownerPIDValue.int32Value == processIdentifier,
                let layerValue = info[layerKey] as? NSNumber,
                layerValue.intValue == 0,
                let boundsValue = info[boundsKey],
                CFGetTypeID(boundsValue as CFTypeRef) == CFDictionaryGetTypeID(),
                let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
                bounds.width > 0,
                bounds.height > 0
            else {
                return nil
            }

            return bounds
        }

        return candidateWindows.max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
    }

    private func overlapArea(between lhs: CGRect, and rhs: CGRect) -> CGFloat {
        lhs.intersection(rhs).width * lhs.intersection(rhs).height
    }
}
