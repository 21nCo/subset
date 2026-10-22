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

    private var stored: StoredSettings { StoredSettings { [defaults] in defaults.object(forKey: $0) } }

    var onboardingCompleted: Bool {
        get { stored.onboardingCompleted }
        set { defaults.set(newValue, forKey: StoredSettings.Key.onboardingCompleted); onChange?() }
    }

    var trackingEnabled: Bool {
        get { stored.trackingEnabled }
        set { defaults.set(newValue, forKey: StoredSettings.Key.trackingEnabled); onChange?() }
    }

    /// `distantFuture` means paused until the user resumes.
    var pausedUntil: Date? {
        get { stored.pausedUntil }
        set { defaults.set(newValue, forKey: StoredSettings.Key.pausedUntil); onChange?() }
    }

    /// Bundle ID to the display name shown in the menu.
    var excludedApps: [String: String] {
        get { defaults.dictionary(forKey: StoredSettings.Key.excludedApps) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: StoredSettings.Key.excludedApps); onChange?() }
    }

    var exclusionMode: ExclusionMode {
        get { defaults.string(forKey: StoredSettings.Key.exclusionMode).flatMap(ExclusionMode.init) ?? .timeOnly }
        set { defaults.set(newValue.rawValue, forKey: StoredSettings.Key.exclusionMode); onChange?() }
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
