/// The app's identity, shared by the menu-bar host and its tests. Matches the bundle settings in
/// ProjectGenerator.rb and MacApp/Info.plist.
public enum SystemIdentity {
    public static let appName = "Subset System"
    public static let bundleIdentifier = "dev.subset.system"
}

/// The commands the menu-bar status item offers, in menu order. The host maps each one to an action; later
/// issues add commands here rather than building menu items ad hoc.
public enum ShellCommand: CaseIterable, Sendable {
    case openSystem
    case settings
    case about
    case quit

    public var title: String {
        switch self {
        case .openSystem: "Open System"
        case .settings: "Settings…"
        case .about: "About \(SystemIdentity.appName)"
        case .quit: "Quit"
        }
    }

    /// The Command-key equivalent shown in the menu, or an empty string for none.
    public var keyEquivalent: String {
        switch self {
        case .openSystem: ""
        case .settings: ","
        case .about: ""
        case .quit: "q"
        }
    }

    /// Whether a separator precedes this command in the status menu.
    public var startsGroup: Bool {
        switch self {
        case .openSystem: false
        case .settings: false
        case .about: true
        case .quit: true
        }
    }
}
