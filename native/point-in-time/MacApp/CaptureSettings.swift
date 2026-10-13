import Foundation
import PointInTimeCore

/// The user's capture choices, persisted in the app's defaults. Tracking stays off until onboarding completes.
@MainActor
final class CaptureSettings {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboardingCompleted") }
        set { defaults.set(newValue, forKey: "onboardingCompleted"); onChange?() }
    }

    var trackingEnabled: Bool {
        get { defaults.bool(forKey: "trackingEnabled") }
        set { defaults.set(newValue, forKey: "trackingEnabled"); onChange?() }
    }

    /// `distantFuture` means paused until the user resumes.
    var pausedUntil: Date? {
        get { defaults.object(forKey: "pausedUntil") as? Date }
        set { defaults.set(newValue, forKey: "pausedUntil"); onChange?() }
    }

    /// Bundle ID to the display name shown in the menu.
    var excludedApps: [String: String] {
        get { defaults.dictionary(forKey: "excludedApps") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "excludedApps"); onChange?() }
    }

    var exclusionMode: ExclusionMode {
        get { defaults.string(forKey: "exclusionMode").flatMap(ExclusionMode.init) ?? .timeOnly }
        set { defaults.set(newValue.rawValue, forKey: "exclusionMode"); onChange?() }
    }

    var policy: CapturePolicy {
        CapturePolicy(excludedBundleIDs: Set(excludedApps.keys), exclusionMode: exclusionMode)
    }

    func isPaused(at date: Date = Date()) -> Bool {
        guard let until = pausedUntil else { return false }
        if until > date { return true }
        pausedUntil = nil
        return false
    }
}
