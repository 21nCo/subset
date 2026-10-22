import Foundation

/// The app's settings as kept in its defaults domain: the key names and how each stored value reads, including the value
/// a missing key stands for. The app reads and writes them through `UserDefaults`; the status command reads the same
/// domain without the app, so both decode a value the same way.
public struct StoredSettings {
    /// The app's bundle identifier, which names its defaults domain.
    public static let domain = "dev.subset.point-in-time"

    public enum Key {
        public static let onboardingCompleted = "onboardingCompleted"
        public static let trackingEnabled = "trackingEnabled"
        public static let pausedUntil = "pausedUntil"
        public static let excludedApps = "excludedApps"
        public static let exclusionMode = "exclusionMode"
        public static let classificationProvider = "classificationProvider"
        public static let sendWindowTitles = "sendWindowTitles"
        public static let openRouterModel = "openRouterModel"
        public static let driftCompanionEnabled = "driftCompanionEnabled"
        public static let driftThreshold = "driftThreshold"
        public static let quietHoursEnabled = "quietHoursEnabled"
        public static let quietHoursStart = "quietHoursStart"
        public static let quietHoursEnd = "quietHoursEnd"
        public static let driftNotificationFallback = "driftNotificationFallback"
        public static let driftPromptedEpisode = "driftPromptedEpisode"
        public static let focusWindowStart = "focusWindowStart"
        public static let focusWindowEnd = "focusWindowEnd"
        public static let driftBreakUntil = "driftBreakUntil"
    }

    private let value: (String) -> Any?

    /// `value` returns the stored object for a key, as `UserDefaults.object(forKey:)` does.
    public init(_ value: @escaping (String) -> Any?) {
        self.value = value
    }

    public init(_ values: [String: Any]) {
        self.init { values[$0] }
    }

    /// Reads like `UserDefaults.bool(forKey:)`: a number or a string such as "YES", false when missing.
    public func bool(_ key: String) -> Bool {
        let stored = value(key)
        return (stored as? NSNumber)?.boolValue ?? (stored as? NSString)?.boolValue ?? false
    }

    public func date(_ key: String) -> Date? { value(key) as? Date }

    public func int(_ key: String) -> Int? { (value(key) as? NSNumber)?.intValue }

    public func string(_ key: String) -> String? { value(key) as? String }

    public var onboardingCompleted: Bool { bool(Key.onboardingCompleted) }
    public var trackingEnabled: Bool { bool(Key.trackingEnabled) }
    /// `distantFuture` means paused until the user resumes.
    public var pausedUntil: Date? { date(Key.pausedUntil) }

    public var provider: ProviderChoice { ProviderChoice(stored: string(Key.classificationProvider)) }

    /// On until the user turns it off.
    public var driftCompanionEnabled: Bool { value(Key.driftCompanionEnabled) == nil ? true : bool(Key.driftCompanionEnabled) }
    public var driftThreshold: Int { DriftRule(threshold: int(Key.driftThreshold) ?? DriftRule.defaultThreshold).threshold }
    public var quietHoursEnabled: Bool { bool(Key.quietHoursEnabled) }
    /// Minutes after local midnight; 22:00 to 07:00 until changed.
    public var quietStartMinute: Int { int(Key.quietHoursStart) ?? 22 * 60 }
    public var quietEndMinute: Int { int(Key.quietHoursEnd) ?? 7 * 60 }

    public var driftRule: DriftRule {
        DriftRule(enabled: driftCompanionEnabled, threshold: driftThreshold,
                  quietHours: quietHoursEnabled ? QuietHours(startMinute: quietStartMinute, endMinute: quietEndMinute) : nil)
    }

    /// The companion's record of what it offered and the user's focus window and break.
    public var companionState: CompanionState {
        let start = date(Key.focusWindowStart), end = date(Key.focusWindowEnd)
        return CompanionState(promptedEpisode: date(Key.driftPromptedEpisode),
                              focusWindow: start.flatMap { start in end.map { DateInterval(start: start, end: max(start, $0)) } },
                              breakUntil: date(Key.driftBreakUntil))
    }
}
