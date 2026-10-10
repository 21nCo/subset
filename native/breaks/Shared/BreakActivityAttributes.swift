import ActivityKit
import Foundation

struct BreakActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endsAt: Date
        var message: String
        var isLongBreak: Bool
    }

    var startedAt: Date
    var title: String
}
