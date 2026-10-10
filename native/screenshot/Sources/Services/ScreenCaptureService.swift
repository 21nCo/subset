import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenCaptureService {
    private(set) var previousArea: CGRect?

    var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenCaptureAccess() -> Bool {
        hasScreenCaptureAccess || CGRequestScreenCaptureAccess()
    }

    func captureFullscreen(displayID: CGDirectDisplayID? = nil) async -> NSImage? {
        guard requestScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let resolved = displayID ?? displayUnderPointer() ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == resolved }) ?? content.displays.first else { return nil }
            // SCDisplay reports points; capture at the display's backing scale.
            let scale = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            })?.backingScaleFactor ?? 1
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = AppPreferences.shared.includeCursor
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: image, size: .zero)
        } catch {
            return nil
        }
    }

    func capture(area cocoaRect: CGRect, remember: Bool = true) async -> NSImage? {
        guard requestScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let center = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
                  let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == CGDirectDisplayID(screenNumber.uint32Value) }) else { return nil }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(
                x: cocoaRect.minX - display.frame.minX,
                y: Self.primaryDisplayHeight - cocoaRect.maxY - display.frame.minY,
                width: cocoaRect.width,
                height: cocoaRect.height
            )
            configuration.width = max(2, Int(cocoaRect.width * screen.backingScaleFactor))
            configuration.height = max(2, Int(cocoaRect.height * screen.backingScaleFactor))
            configuration.showsCursor = AppPreferences.shared.includeCursor
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            if remember { previousArea = cocoaRect }
            return NSImage(cgImage: image, size: .zero)
        } catch {
            return nil
        }
    }

    func capturePreviousArea() async -> NSImage? {
        guard let previousArea else { return nil }
        return await capture(area: previousArea, remember: false)
    }

    func windowRect(at cocoaPoint: CGPoint) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let quartzPoint = CGPoint(x: cocoaPoint.x, y: Self.primaryDisplayHeight - cocoaPoint.y)
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.contains(quartzPoint),
                  let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID != ProcessInfo.processInfo.processIdentifier else { continue }
            return cocoaGlobalRect(from: bounds)
        }
        return nil
    }

    func activeApplicationMetadata() -> (application: String?, window: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, nil)
    }

    private func displayUnderPointer() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
            .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Quartz (CoreGraphics/ScreenCaptureKit) global coordinates have their origin at the
    /// top-left of the primary display, so flipping Cocoa Y uses that display's height, not
    /// the height of the whole desktop.
    static var primaryDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.height ?? 0
    }

    private func cocoaGlobalRect(from quartzRect: CGRect) -> CGRect {
        CGRect(x: quartzRect.minX, y: Self.primaryDisplayHeight - quartzRect.maxY, width: quartzRect.width, height: quartzRect.height)
    }
}
