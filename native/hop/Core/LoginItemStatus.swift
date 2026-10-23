/// Launch at login, as `SMAppService.mainApp.status` reports it. The host maps the status; what the Settings window
/// shows for each is decided here.
public enum LoginItemStatus: Sendable, Equatable {
    /// Not registered: Hop does not start at login.
    case notRegistered
    /// Registered and allowed: Hop starts at login.
    case enabled
    /// Registered, but the user has not allowed it in System Settings > General > Login Items (or turned it off
    /// there), so Hop does not start at login yet.
    case requiresApproval
    /// The system cannot find Hop's bundle to register, as for an unbundled build.
    case notFound

    /// Whether the Launch at login toggle shows on: Hop asked to start at login, whether or not it is approved yet.
    public var isOn: Bool {
        self == .enabled || self == .requiresApproval
    }

    /// Whether the Settings window offers Open Login Items.
    public var needsApproval: Bool {
        self == .requiresApproval
    }

    /// A line under the toggle, or nil when there is nothing to add.
    public var note: String? {
        switch self {
        case .notRegistered, .enabled: nil
        case .requiresApproval: "\(HopIdentity.appName) won't start at login until you allow it in System Settings > General > Login Items."
        case .notFound: "This copy of \(HopIdentity.appName) can't start at login. Move it to the Applications folder and open it from there."
        }
    }
}
