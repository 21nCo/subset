import Foundation

/// The app's identity, read from the running bundle: the Debug and Release builds are separate apps to macOS
/// (ProjectGenerator.rb sets their bundle IDs and display names), so nothing names one of them in code. Everything
/// that depends on which app is running (the settings key, log subsystems, queue labels, the own-app window filter
/// and the names in menus and notices) goes through `current`.
public struct HopIdentity: Sendable, Equatable {
    public let bundleIdentifier: String
    public let appName: String

    /// The identity in a bundle's Info.plist values. A process without a bundle ID (the SwiftPM executable) is
    /// identified by its process name, the domain macOS gives its user defaults; without a display name or bundle name
    /// it is named by the process name too.
    public init(infoDictionary: [String: Any]?, processName: String) {
        func value(_ key: String) -> String? {
            (infoDictionary?[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        bundleIdentifier = value("CFBundleIdentifier") ?? processName
        appName = value("CFBundleDisplayName") ?? value("CFBundleName") ?? processName
    }

    public static let current = HopIdentity(
        infoDictionary: Bundle.main.infoDictionary,
        processName: ProcessInfo.processInfo.processName
    )

    public static var bundleIdentifier: String { current.bundleIdentifier }
    public static var appName: String { current.appName }
}

/// The commands the menu-bar status item offers, in menu order. The host maps each one to an action; later
/// issues add commands here rather than building menu items ad hoc.
public enum ShellCommand: CaseIterable, Sendable {
    /// Opens the onboarding window; offered only while Hop lacks the Accessibility permission.
    case grantAccessibility
    case settings
    case about
    case quit

    public var title: String {
        switch self {
        case .grantAccessibility: "Allow Accessibility Access…"
        case .settings: "Settings…"
        case .about: "About \(HopIdentity.appName)"
        case .quit: "Quit \(HopIdentity.appName)"
        }
    }

    /// The Command-key equivalent shown in the menu, or an empty string for none.
    public var keyEquivalent: String {
        switch self {
        case .grantAccessibility: ""
        case .settings: ","
        case .about: ""
        case .quit: "q"
        }
    }

    /// Whether a separator precedes this command in the status menu, unless it is the first item.
    public var startsGroup: Bool {
        switch self {
        case .grantAccessibility: false
        // Separated from the permission item when that precedes it; the host adds no separator before the first item.
        case .settings: true
        case .about: true
        case .quit: true
        }
    }

    /// The status menu while Hop does or does not hold the Accessibility permission.
    public static func statusMenu(trusted: Bool) -> [ShellCommand] {
        trusted ? [.settings, .about, .quit] : allCases
    }
}
