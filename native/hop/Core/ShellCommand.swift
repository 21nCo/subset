/// The app's identity, shared by the menu-bar host and its tests. Matches the bundle settings in
/// ProjectGenerator.rb and MacApp/Info.plist.
public enum HopIdentity {
    public static let appName = "Hop"
    public static let bundleIdentifier = "dev.subset.hop"
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
