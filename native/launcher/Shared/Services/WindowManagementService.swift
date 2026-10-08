import AppKit
import ApplicationServices

@MainActor
final class WindowManagementService {
    private struct WindowTarget {
        let app: NSRunningApplication
        let windowTitle: String?
        let windowFrame: CGRect?
    }

    private var targetProcessIdentifier: pid_t?
    private var lastFailureDetail: String?

    func rememberTargetApplication(_ app: NSRunningApplication) {
        guard isEligibleTargetApplication(app) else {
            return
        }

        targetProcessIdentifier = app.processIdentifier
    }

    func rememberTargetApplication() {
        if let app = NSWorkspace.shared.frontmostApplication {
            rememberTargetApplication(app)
        }
    }

    func perform(_ command: WindowCommand) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            await self?.apply(command)
        }
    }

    private func apply(_ command: WindowCommand) async {
        lastFailureDetail = nil

        guard requestAccessibilityPermissionIfNeeded() else {
            showFailure("Accessibility permission is needed to move other app windows.")
            return
        }

        let targets = await targetWindowsAfterFocusSettles()
        guard !targets.isEmpty else {
            showFailure("No active app window was found. Click the app window once, then run the window command again.")
            return
        }

        var attemptedAppNames: [String] = []
        for target in targets {
            let app = target.app
            let appName = app.localizedName ?? "the selected app"
            attemptedAppNames.append(appName)

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 1.0)

            guard let window = targetWindow(
                from: appElement,
                matchingTitle: target.windowTitle,
                approximateFrame: target.windowFrame
            ) else {
                continue
            }

            let screenFrame = accessibilityScreenFrame(for: window)
            let targetFrame = frame(for: command, in: screenFrame)
            if set(frame: targetFrame, for: window, appName: appName) {
                return
            }
        }

        let detail = lastFailureDetail.map { "\n\nDetails: \($0)" } ?? ""
        showFailure("macOS did not allow moving \(attemptedAppNames.first ?? "the selected app"). Make sure Launcher has Accessibility permission and try again with a normal app window selected.\(detail)")
    }

    private func requestAccessibilityPermissionIfNeeded() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func targetWindowsAfterFocusSettles() async -> [WindowTarget] {
        for _ in 0..<8 {
            let targets = targetWindows()
            if !targets.isEmpty {
                return targets
            }

            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        return targetWindows()
    }

    private func targetWindows() -> [WindowTarget] {
        let visibleTargets = visibleWindowTargets()
        if !visibleTargets.isEmpty {
            return visibleTargets
        }

        return targetApplications().map {
            WindowTarget(app: $0, windowTitle: nil, windowFrame: nil)
        }
    }

    private func visibleWindowTargets() -> [WindowTarget] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownProcessIdentifier = NSRunningApplication.current.processIdentifier
        var seenProcessIdentifiers = Set<pid_t>()
        var targets: [WindowTarget] = []

        for info in windowInfo {
            guard let processIdentifierNumber = info[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }

            let processIdentifier = processIdentifierNumber.int32Value
            guard processIdentifier != ownProcessIdentifier,
                  !seenProcessIdentifiers.contains(processIdentifier),
                  let app = NSRunningApplication(processIdentifier: processIdentifier),
                  isEligibleTargetApplication(app),
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else {
                continue
            }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0 else {
                continue
            }

            var frame: CGRect?
            if let bounds = info[kCGWindowBounds as String] as? [String: Any] {
                frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            }

            guard let frame,
                  frame.width >= 120,
                  frame.height >= 120 else {
                continue
            }

            seenProcessIdentifiers.insert(processIdentifier)
            targets.append(
                WindowTarget(
                    app: app,
                    windowTitle: info[kCGWindowName as String] as? String,
                    windowFrame: frame
                )
            )
        }

        return targets
    }

    private func targetApplications() -> [NSRunningApplication] {
        var apps: [NSRunningApplication] = []

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           isEligibleTargetApplication(frontmost) {
            apps.append(frontmost)
        }

        if let targetProcessIdentifier {
            if let rememberedApp = NSRunningApplication(processIdentifier: targetProcessIdentifier),
               isEligibleTargetApplication(rememberedApp) {
                apps.append(rememberedApp)
            } else if NSRunningApplication(processIdentifier: targetProcessIdentifier) == nil {
                self.targetProcessIdentifier = nil
            }
        }

        var seenProcessIdentifiers = Set<pid_t>()
        return apps.filter { app in
            guard !seenProcessIdentifiers.contains(app.processIdentifier) else {
                return false
            }

            seenProcessIdentifiers.insert(app.processIdentifier)
            return true
        }
    }

    private func isEligibleTargetApplication(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular,
              !app.isTerminated else {
            return false
        }

        return true
    }

    private func targetWindow(
        from appElement: AXUIElement,
        matchingTitle title: String?,
        approximateFrame: CGRect?
    ) -> AXUIElement? {
        var candidates: [AXUIElement] = []

        if let focused = attribute(kAXFocusedWindowAttribute, from: appElement) {
            candidates.append(focused)
        }

        if let mainWindow = attribute(kAXMainWindowAttribute, from: appElement) {
            candidates.append(mainWindow)
        }

        candidates.append(contentsOf: windows(from: appElement))

        let movableCandidates = candidates.deduplicatedAXElements().filter { isMovableWindow($0) }

        if let title,
           !title.isEmpty,
           let titleMatch = movableCandidates.first(where: { stringAttribute(kAXTitleAttribute, from: $0) == title }) {
            return titleMatch
        }

        if let approximateFrame,
           let frameMatch = movableCandidates.first(where: { frameDistance(currentFrame(for: $0), approximateFrame) < 80 }) {
            return frameMatch
        }

        return movableCandidates.first
    }

    private func isMovableWindow(_ window: AXUIElement) -> Bool {
        guard currentFrame(for: window) != nil else {
            return false
        }

        var isPositionSettable = DarwinBoolean(false)
        var isSizeSettable = DarwinBoolean(false)
        let positionError = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &isPositionSettable)
        let sizeError = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &isSizeSettable)

        return positionError == .success
            && sizeError == .success
            && isPositionSettable.boolValue
            && isSizeSettable.boolValue
    }

    private func attribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { return nil }
        return value as! AXUIElement?
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func frameDistance(_ lhs: CGRect?, _ rhs: CGRect) -> CGFloat {
        guard let lhs else {
            return .greatestFiniteMagnitude
        }

        return abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private func windows(from appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }

        return windows
    }

    private func accessibilityScreenFrame(for window: AXUIElement) -> CGRect {
        guard let windowFrame = currentFrame(for: window) else {
            return accessibilityVisibleFrame(for: NSScreen.main) ?? .zero
        }

        return NSScreen.screens
            .compactMap { accessibilityVisibleFrame(for: $0) }
            .first { $0.intersects(windowFrame) }
            ?? accessibilityVisibleFrame(for: NSScreen.main)
            ?? .zero
    }

    private func accessibilityVisibleFrame(for screen: NSScreen?) -> CGRect? {
        guard let screen else { return nil }

        let screenUnion = NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }

        guard !screenUnion.isNull else {
            return nil
        }

        let visibleFrame = screen.visibleFrame
        return CGRect(
            x: visibleFrame.minX,
            y: screenUnion.maxY - visibleFrame.maxY,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    private func currentFrame(for window: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: window),
              let size = sizeAttribute(kAXSizeAttribute, from: window) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func frame(for command: WindowCommand, in screenFrame: CGRect) -> CGRect {
        let halfWidth = screenFrame.width / 2
        let halfHeight = screenFrame.height / 2
        let centeredSize = CGSize(width: min(1100, screenFrame.width * 0.72), height: min(760, screenFrame.height * 0.78))

        switch command {
        case .maximize:
            return screenFrame
        case .center:
            return CGRect(
                x: screenFrame.midX - centeredSize.width / 2,
                y: screenFrame.midY - centeredSize.height / 2,
                width: centeredSize.width,
                height: centeredSize.height
            )
        case .leftHalf:
            return CGRect(x: screenFrame.minX, y: screenFrame.minY, width: halfWidth, height: screenFrame.height)
        case .rightHalf:
            return CGRect(x: screenFrame.midX, y: screenFrame.minY, width: halfWidth, height: screenFrame.height)
        case .topHalf:
            return CGRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: halfHeight)
        case .bottomHalf:
            return CGRect(x: screenFrame.minX, y: screenFrame.midY, width: screenFrame.width, height: halfHeight)
        case .topLeft:
            return CGRect(x: screenFrame.minX, y: screenFrame.minY, width: halfWidth, height: halfHeight)
        case .topRight:
            return CGRect(x: screenFrame.midX, y: screenFrame.minY, width: halfWidth, height: halfHeight)
        case .bottomLeft:
            return CGRect(x: screenFrame.minX, y: screenFrame.midY, width: halfWidth, height: halfHeight)
        case .bottomRight:
            return CGRect(x: screenFrame.midX, y: screenFrame.midY, width: halfWidth, height: halfHeight)
        }
    }

    private func set(frame: CGRect, for window: AXUIElement, appName: String) -> Bool {
        AXUIElementSetMessagingTimeout(window, 1.0)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)

        var origin = frame.origin
        var size = frame.size

        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            showFailure("Could not build the target window frame.")
            return false
        }

        let firstPositionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let firstSizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        if firstPositionError == .success,
           firstSizeError == .success {
            return true
        }

        let secondSizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let secondPositionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)

        if secondPositionError == .success,
           secondSizeError == .success {
            return true
        }

        if runSystemEventsFallback(frame: frame, appName: appName),
           didApply(frame: frame, to: window) {
            return true
        }

        lastFailureDetail = failureDetail(
            appName: appName,
            frame: frame,
            window: window,
            firstPositionError: firstPositionError,
            firstSizeError: firstSizeError,
            secondPositionError: secondPositionError,
            secondSizeError: secondSizeError
        )
        return false
    }

    private func failureDetail(
        appName: String,
        frame: CGRect,
        window: AXUIElement,
        firstPositionError: AXError,
        firstSizeError: AXError,
        secondPositionError: AXError,
        secondSizeError: AXError
    ) -> String {
        let currentFrame = currentFrame(for: window)
        return "\(appName), position \(firstPositionError.rawValue)/\(secondPositionError.rawValue), size \(firstSizeError.rawValue)/\(secondSizeError.rawValue), target \(format(frame)), current \(currentFrame.map(format) ?? "unknown")"
    }

    private func format(_ frame: CGRect) -> String {
        "x:\(Int(frame.minX)) y:\(Int(frame.minY)) w:\(Int(frame.width)) h:\(Int(frame.height))"
    }

    private func didApply(frame targetFrame: CGRect, to window: AXUIElement) -> Bool {
        guard let currentFrame = currentFrame(for: window) else {
            return false
        }

        let positionTolerance: CGFloat = 12
        let sizeTolerance: CGFloat = 24

        return abs(currentFrame.minX - targetFrame.minX) <= positionTolerance
            && abs(currentFrame.minY - targetFrame.minY) <= positionTolerance
            && abs(currentFrame.width - targetFrame.width) <= sizeTolerance
            && abs(currentFrame.height - targetFrame.height) <= sizeTolerance
    }

    private func runSystemEventsFallback(frame: CGRect, appName: String) -> Bool {
        let escapedAppName = appName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let x = Int(frame.minX.rounded())
        let y = Int(frame.minY.rounded())
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())
        let script = """
        tell application "System Events"
            tell process "\(escapedAppName)"
                set frontmost to true
                if exists window 1 then
                    set position of window 1 to {\(x), \(y)}
                    set size of window 1 to {\(width), \(height)}
                end if
            end tell
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }

    private func pointAttribute(_ name: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        AXValueGetValue((axValue as! AXValue), .cgPoint, &point)
        return point
    }

    private func sizeAttribute(_ name: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        AXValueGetValue((axValue as! AXValue), .cgSize, &size)
        return size
    }

    private func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Window command failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private extension Array where Element == AXUIElement {
    func deduplicatedAXElements() -> [AXUIElement] {
        var seen = Set<CFHashCode>()
        return filter { element in
            let hash = CFHash(element)
            guard !seen.contains(hash) else {
                return false
            }

            seen.insert(hash)
            return true
        }
    }
}
