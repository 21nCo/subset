import Combine
import Foundation

/// The Command Line section's view of the `subset` command: checked when the window opens and on **Check Again**.
@MainActor
public final class CommandLineModel: ObservableObject {
    @Published public private(set) var status: SubsetCommandStatus = .checking
    @Published public private(set) var isChecking = false

    private let detector: SubsetCommandDetector

    public init(detector: SubsetCommandDetector) {
        self.detector = detector
    }

    /// Looks for `subset` again. A check while another runs does nothing.
    public func check() async {
        guard !isChecking else { return }
        isChecking = true
        status = .checking
        status = await detector.detect()
        isChecking = false
    }
}
