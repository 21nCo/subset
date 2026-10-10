import Foundation
import UIKit

@MainActor
final class ShortcutAutomationCoordinator {
    func run(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: trimmed)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }
}
