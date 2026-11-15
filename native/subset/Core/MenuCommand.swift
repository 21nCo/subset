/// The commands in the menu bar item's menu, in order. The app builds its menu from this list, so the menu and its
/// tests share one definition.
public enum MenuCommand: CaseIterable, Sendable {
    case openSubset
    case about
    case quit

    public var title: String {
        switch self {
        case .openSubset: "Open \(SubsetIdentity.appName)"
        case .about: "About \(SubsetIdentity.appName)"
        case .quit: "Quit \(SubsetIdentity.appName)"
        }
    }

    /// The Command-key equivalent shown in the menu, or nil for none.
    public var keyEquivalent: Character? {
        switch self {
        case .openSubset: "o"
        case .about: nil
        case .quit: "q"
        }
    }

    /// Whether a separator precedes this command in the menu.
    public var startsGroup: Bool {
        switch self {
        case .openSubset: false
        case .about: true
        case .quit: false
        }
    }
}
