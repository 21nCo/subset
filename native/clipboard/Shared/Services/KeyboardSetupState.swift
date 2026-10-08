#if canImport(Foundation)
import Foundation

enum KeyboardSetupState {
    static let hasSeenKeyboardKey = "dev.subset.clipboard.hasSeenKeyboardExtension"
    static let keyboardHasFullAccessKey = "dev.subset.clipboard.keyboardHasFullAccess"
    static let didDismissOnboardingKey = "dev.subset.clipboard.didDismissKeyboardOnboarding"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedContainer.appGroupIdentifier)
    }

    static var hasSeenKeyboardExtension: Bool {
        defaults?.bool(forKey: hasSeenKeyboardKey) ?? false
    }

    static var lastKnownKeyboardHasFullAccess: Bool {
        defaults?.bool(forKey: keyboardHasFullAccessKey) ?? false
    }

    static var didDismissOnboarding: Bool {
        get { defaults?.bool(forKey: didDismissOnboardingKey) ?? false }
        set { defaults?.set(newValue, forKey: didDismissOnboardingKey) }
    }

    static func noteKeyboardPresentation(fullAccess: Bool) {
        defaults?.set(true, forKey: hasSeenKeyboardKey)
        defaults?.set(fullAccess, forKey: keyboardHasFullAccessKey)
    }
}
#endif
