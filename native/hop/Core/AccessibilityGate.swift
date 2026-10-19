/// Tracks whether Hop holds the Accessibility permission and reports each change, so the host installs the event
/// tap exactly when trust is granted and removes it exactly when trust is revoked. The host samples trust at launch,
/// when the app becomes active, and every 2 seconds while the onboarding window is open; it never polls otherwise.
public struct AccessibilityGate: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        /// Trust is now held (or was held at the first sample): install the tap.
        case granted
        /// Trust is now missing (or was missing at the first sample): remove the tap and show the needs-permission
        /// state.
        case revoked
    }

    /// The last sampled trust, or nil before the first sample.
    public private(set) var isTrusted: Bool?

    public init() {}

    /// Records a sample and returns the change it represents, or nil when trust is as it was.
    public mutating func update(trusted: Bool) -> Change? {
        guard trusted != isTrusted else { return nil }
        isTrusted = trusted
        return trusted ? .granted : .revoked
    }

    /// Whether the onboarding window opens on its own at launch: only on the first launch, and only when trust is
    /// missing. Later it opens from the status menu.
    public static func showsOnboardingAtLaunch(trusted: Bool, onboardingShownBefore: Bool) -> Bool {
        !trusted && !onboardingShownBefore
    }
}
