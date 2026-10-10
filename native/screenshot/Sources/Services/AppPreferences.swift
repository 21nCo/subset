import AppKit
import Foundation
import Security

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case wallpaper
    case shortcuts
    case quickAccess
    case recording
    case screenshots
    case annotate
    case cloud
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .wallpaper: "Wallpaper"
        case .shortcuts: "Shortcuts"
        case .quickAccess: "Quick Access"
        case .recording: "Recording"
        case .screenshots: "Screenshots"
        case .annotate: "Annotate"
        case .cloud: "Cloud"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .wallpaper: "photo.on.rectangle"
        case .shortcuts: "command"
        case .quickAccess: "bolt"
        case .recording: "record.circle"
        case .screenshots: "camera.viewfinder"
        case .annotate: "pencil.and.outline"
        case .cloud: "cloud"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private enum Key {
        static let afterCaptureActions = "afterCaptureActions"
        static let exportDirectory = "exportDirectory"
        static let fileNamePattern = "fileNamePattern"
        static let imageFormat = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let includeCursor = "includeCursor"
        static let captureWindowShadow = "captureWindowShadow"
        static let hideDesktopIcons = "hideDesktopIcons"
        static let quickAccessSize = "quickAccessSize"
        static let quickAccessAutoCloseSeconds = "quickAccessAutoCloseSeconds"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let historyDays = "historyDays"
        static let showRecordingControls = "showRecordingControls"
        static let showRecordingTime = "showRecordingTime"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let showCamera = "showCamera"
        static let showKeystrokes = "showKeystrokes"
        static let highlightClicks = "highlightClicks"
        static let openVideoEditor = "openVideoEditor"
        static let cloudBaseURL = "cloudBaseURL"
        static let uploadToken = "uploadToken"
        static let selectedSettingsTab = "selectedSettingsTab"
    }

    @Published var afterCaptureActions: Set<AfterCaptureAction> { didSet { persistActions() } }
    @Published var exportDirectory: URL { didSet { defaults.set(exportDirectory.path, forKey: Key.exportDirectory) } }
    @Published var fileNamePattern: String { didSet { defaults.set(fileNamePattern, forKey: Key.fileNamePattern) } }
    @Published var imageFormat: String { didSet { defaults.set(imageFormat, forKey: Key.imageFormat) } }
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) } }
    @Published var includeCursor: Bool { didSet { defaults.set(includeCursor, forKey: Key.includeCursor) } }
    @Published var captureWindowShadow: Bool { didSet { defaults.set(captureWindowShadow, forKey: Key.captureWindowShadow) } }
    @Published var hideDesktopIcons: Bool { didSet { defaults.set(hideDesktopIcons, forKey: Key.hideDesktopIcons) } }
    @Published var quickAccessSize: Double { didSet { defaults.set(quickAccessSize, forKey: Key.quickAccessSize) } }
    /// Seconds before the Quick Access overlay closes on its own; 0 keeps it open until dismissed.
    @Published var quickAccessAutoCloseSeconds: Int { didSet { defaults.set(quickAccessAutoCloseSeconds, forKey: Key.quickAccessAutoCloseSeconds) } }
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }
    @Published var historyDays: Int { didSet { defaults.set(historyDays, forKey: Key.historyDays) } }
    @Published var showRecordingControls: Bool { didSet { defaults.set(showRecordingControls, forKey: Key.showRecordingControls) } }
    @Published var showRecordingTime: Bool { didSet { defaults.set(showRecordingTime, forKey: Key.showRecordingTime) } }
    @Published var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: Key.recordSystemAudio) } }
    @Published var recordMicrophone: Bool { didSet { defaults.set(recordMicrophone, forKey: Key.recordMicrophone) } }
    @Published var showCamera: Bool { didSet { defaults.set(showCamera, forKey: Key.showCamera) } }
    @Published var showKeystrokes: Bool { didSet { defaults.set(showKeystrokes, forKey: Key.showKeystrokes) } }
    @Published var highlightClicks: Bool { didSet { defaults.set(highlightClicks, forKey: Key.highlightClicks) } }
    @Published var openVideoEditor: Bool { didSet { defaults.set(openVideoEditor, forKey: Key.openVideoEditor) } }
    @Published var cloudBaseURL: String { didSet { defaults.set(cloudBaseURL, forKey: Key.cloudBaseURL) } }
    @Published var uploadToken: String {
        didSet {
            if Self.storeUploadToken(uploadToken) { defaults.removeObject(forKey: Key.uploadToken) }
        }
    }
    @Published var selectedSettingsTab: SettingsTab { didSet { defaults.set(selectedSettingsTab.rawValue, forKey: Key.selectedSettingsTab) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        exportDirectory = URL(fileURLWithPath: defaults.string(forKey: Key.exportDirectory) ?? desktop.path)
        fileNamePattern = defaults.string(forKey: Key.fileNamePattern) ?? "Screenshot {date} at {time}"
        imageFormat = defaults.string(forKey: Key.imageFormat) ?? "png"
        jpegQuality = defaults.object(forKey: Key.jpegQuality) as? Double ?? 0.92
        includeCursor = defaults.object(forKey: Key.includeCursor) as? Bool ?? false
        captureWindowShadow = defaults.object(forKey: Key.captureWindowShadow) as? Bool ?? true
        hideDesktopIcons = defaults.object(forKey: Key.hideDesktopIcons) as? Bool ?? true
        quickAccessSize = defaults.object(forKey: Key.quickAccessSize) as? Double ?? 2
        quickAccessAutoCloseSeconds = defaults.object(forKey: Key.quickAccessAutoCloseSeconds) as? Int ?? 0
        hasCompletedOnboarding = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
        historyDays = defaults.object(forKey: Key.historyDays) as? Int ?? 30
        showRecordingControls = defaults.object(forKey: Key.showRecordingControls) as? Bool ?? true
        showRecordingTime = defaults.object(forKey: Key.showRecordingTime) as? Bool ?? true
        recordSystemAudio = defaults.object(forKey: Key.recordSystemAudio) as? Bool ?? true
        recordMicrophone = defaults.object(forKey: Key.recordMicrophone) as? Bool ?? false
        showCamera = defaults.object(forKey: Key.showCamera) as? Bool ?? false
        showKeystrokes = defaults.object(forKey: Key.showKeystrokes) as? Bool ?? false
        highlightClicks = defaults.object(forKey: Key.highlightClicks) as? Bool ?? true
        openVideoEditor = defaults.object(forKey: Key.openVideoEditor) as? Bool ?? true
        cloudBaseURL = defaults.string(forKey: Key.cloudBaseURL) ?? ""
        let migratedToken = defaults.string(forKey: Key.uploadToken)
        uploadToken = Self.storedUploadToken() ?? migratedToken ?? ""
        // Keep the legacy defaults copy until the Keychain write succeeds.
        if let migratedToken, !migratedToken.isEmpty, Self.storeUploadToken(migratedToken) {
            defaults.removeObject(forKey: Key.uploadToken)
        }
        selectedSettingsTab = SettingsTab(rawValue: defaults.string(forKey: Key.selectedSettingsTab) ?? "general") ?? .general

        if let raw = defaults.array(forKey: Key.afterCaptureActions) as? [String] {
            afterCaptureActions = Set(raw.compactMap(AfterCaptureAction.init(rawValue:)))
        } else {
            afterCaptureActions = [.quickAccess, .copy, .save]
        }
    }

    /// Hosted sharing is opt-in: it needs a valid Worker URL and an upload token entered by the user.
    var isCloudConfigured: Bool {
        CloudShareService.validatedBaseURL(cloudBaseURL) != nil && !uploadToken.isEmpty
    }

    func formattedFileName(at date: Date = Date(), suffix: String? = nil) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HH.mm.ss"
        var name = fileNamePattern
            .replacingOccurrences(of: "{date}", with: day.string(from: date))
            .replacingOccurrences(of: "{time}", with: time.string(from: date))
        if let suffix, !suffix.isEmpty { name += " \(suffix)" }
        return name.replacingOccurrences(of: "/", with: "-")
    }

    private func persistActions() {
        defaults.set(afterCaptureActions.map(\.rawValue).sorted(), forKey: Key.afterCaptureActions)
    }

    private static let tokenService = "dev.subset.screenshot.cloud"
    private static let tokenAccount = "upload-token"

    private static func storedUploadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func storeUploadToken(_ token: String) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
        ]
        if token.isEmpty {
            let status = SecItemDelete(identity as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        if status != errSecSuccess { NSLog("Screenshot: storing the upload token in the Keychain failed (%d)", status) }
        return status == errSecSuccess
    }
}
