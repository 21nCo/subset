import CryptoKit
import Foundation

#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#endif

enum ClipboardItemKind: String, Codable {
    case text
    case url
    case image
    case files

    var displayName: String {
        switch self {
        case .text:
            return "Text"
        case .url:
            return "Link"
        case .image:
            return "Image"
        case .files:
            return "Files"
        }
    }

    var symbolName: String {
        switch self {
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

    var accentColor: PlatformColor {
        switch self {
        case .text:
            return PlatformColor(red: 0.12, green: 0.53, blue: 0.96, alpha: 1)
        case .url:
            return PlatformColor(red: 0.19, green: 0.78, blue: 0.46, alpha: 1)
        case .image:
            return PlatformColor(red: 1.00, green: 0.30, blue: 0.38, alpha: 1)
        case .files:
            return PlatformColor(red: 0.56, green: 0.45, blue: 0.95, alpha: 1)
        }
    }
}

struct ClipboardItem: Codable, Identifiable {
    let id: UUID
    let kind: ClipboardItemKind
    let textContent: String?
    let imagePNGData: Data?
    let filePaths: [String]
    let capturedAt: Date
    let sourceAppName: String?
    let sourceBundleIdentifier: String?
    let signature: String

    var previewImage: PlatformImage? {
        guard let imagePNGData else { return nil }
        return PlatformImage(data: imagePNGData)
    }

    var sourceDisplayName: String? {
        if sourceBundleIdentifier == Bundle.main.bundleIdentifier {
            return "Clipboard"
        }

        #if canImport(UIKit)
        if sourceAppName == "System Clipboard" || sourceAppName == "Current Clipboard" {
            return nil
        }
        #endif

        #if canImport(AppKit)
        if let sourceBundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceBundleIdentifier),
           let bundle = Bundle(url: applicationURL) {
            let bundleName =
                (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: kCFBundleExecutableKey as String) as? String)

            if let friendlyBundleName = prettifiedAppName(bundleName) {
                return friendlyBundleName
            }
        }
        #endif

        return prettifiedAppName(sourceAppName)
    }

    var sourceDisplayLabel: String? {
        sourceDisplayName
    }

    #if canImport(AppKit)
    var sourceApplicationIcon: NSImage? {
        if let sourceBundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceBundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            icon.size = NSSize(width: 40, height: 40)
            return icon
        }

        guard
            let sourceDisplayName,
            let runningApplication = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == sourceDisplayName }),
            let bundleURL = runningApplication.bundleURL
        else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 40, height: 40)
        return icon
    }
    #endif

    var titleText: String {
        switch kind {
        case .text:
            return sanitized(textContent) ?? "Text clip"
        case .url:
            return sanitized(textContent) ?? "Link clip"
        case .image:
            return "Copied image"
        case .files:
            if filePaths.count == 1 {
                return URL(fileURLWithPath: filePaths[0]).lastPathComponent
            }
            return "\(filePaths.count) files"
        }
    }

    var bodyText: String {
        switch kind {
        case .text:
            return bodyPreview(for: textContent, fallback: "Plain text clipboard item.")
        case .url:
            return bodyPreview(for: textContent, fallback: "URL clipboard item.")
        case .image:
            guard let previewImage else {
                return "Image clipboard item."
            }
            #if canImport(AppKit)
            let size = previewImage.size
            #elseif canImport(UIKit)
            let size = previewImage.size
            #endif
            return "Image preview • \(Int(size.width)) x \(Int(size.height))"
        case .files:
            return filePaths
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: "  •  ")
        }
    }

    var searchableText: String {
        [
            titleText,
            bodyText,
            sourceAppName ?? "",
            sourceBundleIdentifier ?? "",
            filePaths.joined(separator: " ")
        ]
        .joined(separator: "\n")
    }

    static func fromString(
        _ rawString: String,
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil
    ) -> ClipboardItem? {
        let trimmedString = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedString.isEmpty else { return nil }

        let kind: ClipboardItemKind = looksLikeURL(trimmedString) ? .url : .text
        return ClipboardItem(
            id: UUID(),
            kind: kind,
            textContent: trimmedString,
            imagePNGData: nil,
            filePaths: [],
            capturedAt: Date(),
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            signature: signature(for: trimmedString)
        )
    }

    static func imageItem(
        pngData: Data,
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil
    ) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            kind: .image,
            textContent: nil,
            imagePNGData: pngData,
            filePaths: [],
            capturedAt: Date(),
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            signature: signature(for: pngData)
        )
    }

    static func fileItem(
        filePaths: [String],
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil
    ) -> ClipboardItem? {
        let normalizedPaths = filePaths.filter { !$0.isEmpty }
        guard !normalizedPaths.isEmpty else { return nil }

        return ClipboardItem(
            id: UUID(),
            kind: .files,
            textContent: nil,
            imagePNGData: nil,
            filePaths: normalizedPaths,
            capturedAt: Date(),
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            signature: signature(for: normalizedPaths.joined(separator: "\n"))
        )
    }

    #if canImport(AppKit)
    static func fromPasteboard(
        _ pasteboard: NSPasteboard,
        sourceApp: NSRunningApplication?
    ) -> ClipboardItem? {
        let sourceAppName = sourceApp?.localizedName
        let sourceBundleIdentifier = sourceApp?.bundleIdentifier

        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL],
           !fileURLs.isEmpty {
            return fileItem(
                filePaths: fileURLs.map(\.path),
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier
            )
        }

        if let image = NSImage(pasteboard: pasteboard),
           let imagePNGData = image.pngDataRepresentation() {
            return imageItem(
                pngData: imagePNGData,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier
            )
        }

        if let rawString = pasteboard.string(forType: .string) {
            return fromString(
                rawString,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier
            )
        }

        return nil
    }

    func write(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()

        switch kind {
        case .text, .url:
            guard let textContent else { return false }
            return pasteboard.setString(textContent, forType: .string)
        case .image:
            guard let previewImage else { return false }
            return pasteboard.writeObjects([previewImage])
        case .files:
            let urls = filePaths.map(URL.init(fileURLWithPath:))
            return pasteboard.writeObjects(urls as [NSURL])
        }
    }
    #endif

    #if canImport(UIKit)
    static func fromPasteboard(
        _ pasteboard: UIPasteboard,
        sourceAppName: String? = "System Clipboard",
        sourceBundleIdentifier: String? = nil
    ) -> ClipboardItem? {
        if let url = pasteboard.url {
            if url.isFileURL {
                return fileItem(
                    filePaths: [url.path],
                    sourceAppName: sourceAppName,
                    sourceBundleIdentifier: sourceBundleIdentifier
                )
            }

            return fromString(
                url.absoluteString,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier
            )
        }

        if let image = pasteboard.image,
           let imagePNGData = image.optimizedClipboardImageData() {
            return imageItem(
                pngData: imagePNGData,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier
            )
        }

        if let rawString = pasteboard.string {
            return fromString(
                rawString,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier
            )
        }

        return nil
    }

    @discardableResult
    func write(to pasteboard: UIPasteboard) -> Bool {
        switch kind {
        case .text:
            guard let textContent else { return false }
            pasteboard.string = textContent
            return true
        case .url:
            guard let textContent else { return false }
            pasteboard.url = URL(string: textContent)
            pasteboard.string = textContent
            return true
        case .image:
            guard let previewImage else { return false }
            pasteboard.image = previewImage
            return true
        case .files:
            guard let firstPath = filePaths.first else { return false }
            pasteboard.url = URL(fileURLWithPath: firstPath)
            return true
        }
    }
    #endif

    private static func looksLikeURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), let scheme = components.scheme else {
            return false
        }

        return ["http", "https", "mailto", "file"].contains(scheme.lowercased())
    }

    private static func signature(for string: String) -> String {
        signature(for: Data(string.utf8))
    }

    private static func signature(for data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func sanitized(_ string: String?) -> String? {
        guard let string else { return nil }
        let collapsedWhitespace = string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsedWhitespace.isEmpty ? nil : collapsedWhitespace
    }

    private func bodyPreview(for string: String?, fallback: String) -> String {
        guard let sanitizedText = sanitized(string) else { return fallback }
        if sanitizedText == titleText {
            return fallback
        }
        return sanitizedText
    }

    private func prettifiedAppName(_ rawName: String?) -> String? {
        guard let sanitizedName = sanitized(rawName) else { return nil }

        let withoutAppSuffix = sanitizedName.replacingOccurrences(of: ".app", with: "")
        let splitCamelCase = withoutAppSuffix
            .replacingOccurrences(
                of: #"(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let collapsedWhitespace = splitCamelCase
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return collapsedWhitespace.isEmpty ? nil : collapsedWhitespace
    }
}

#if canImport(AppKit)
private extension NSImage {
    func pngDataRepresentation() -> Data? {
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
#elseif canImport(UIKit)
private extension UIImage {
    func pngDataRepresentation() -> Data? {
        pngData()
    }

    func optimizedClipboardImageData(maxDimension: CGFloat = 1400) -> Data? {
        let sourceSize = size
        let largestDimension = max(sourceSize.width, sourceSize.height)

        let renderImage: UIImage
        if largestDimension > maxDimension, largestDimension > 0 {
            let scaleRatio = maxDimension / largestDimension
            let targetSize = CGSize(
                width: max(1, sourceSize.width * scaleRatio),
                height: max(1, sourceSize.height * scaleRatio)
            )

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            renderImage = renderer.image { _ in
                draw(in: CGRect(origin: .zero, size: targetSize))
            }
        } else {
            renderImage = self
        }

        return renderImage.jpegData(compressionQuality: 0.82) ?? renderImage.pngData()
    }
}
#endif
