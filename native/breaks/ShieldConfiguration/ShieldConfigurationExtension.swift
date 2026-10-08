import ManagedSettings
import ManagedSettingsUI
import UIKit

final class BreakShieldConfigurationDataSource: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        configuration(for: application.localizedDisplayName ?? "this app")
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        configuration(for: application.localizedDisplayName ?? category.localizedDisplayName ?? "this app")
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        configuration(for: webDomain.domain ?? "this website")
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        configuration(for: webDomain.domain ?? category.localizedDisplayName ?? "this website")
    }

    private func configuration(for itemName: String) -> ShieldConfiguration {
        let end = SharedStore.defaults.object(forKey: SharedStore.activeBreakEndKey) as? Date
        let remaining = max(0, end?.timeIntervalSinceNow ?? 0)
        let subtitle = remaining > 0
            ? "Let your eyes rest. \(remaining.compactDuration) remaining before \(itemName) is available."
            : "Your break is active. Take one slow breath before returning."

        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: UIColor(red: 0.08, green: 0.07, blue: 0.12, alpha: 0.82),
            icon: UIImage(systemName: "sparkles"),
            title: .init(text: "Stay with the break", color: .white),
            subtitle: .init(text: subtitle, color: UIColor.white.withAlphaComponent(0.74)),
            primaryButtonLabel: .init(text: "Keep resting", color: .white),
            primaryButtonBackgroundColor: UIColor(red: 0.78, green: 0.25, blue: 0.54, alpha: 1),
            secondaryButtonLabel: .init(text: "Close", color: UIColor.white.withAlphaComponent(0.72))
        )
    }
}
