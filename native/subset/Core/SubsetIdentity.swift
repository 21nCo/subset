/// Who the app is to macOS and to the rest of Subset. `bundleID` is what `macos-release.json`, the catalog feed and
/// `subset` know the app by, so the Xcode project, `MacApp/Info.plist` and the release config must agree with it
/// (`SubsetIdentityTests` checks they do).
public enum SubsetIdentity {
    /// The name in the menu bar, the window title, the About panel, and `/Applications/Subset.app`.
    public static let appName = "Subset"
    public static let bundleID = "dev.subset.manager"
    /// The SwiftUI scene ID of the main window, which the menu opens.
    public static let mainWindowID = "main"
    /// The SF Symbol of the menu bar item.
    public static let menuBarSymbol = "square.grid.2x2"
}
