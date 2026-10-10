import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var startedAt: Date
        var samples: [Double]
        var title: String
        var elapsedText: String
    }

    var sessionID: String
}

extension RecordingActivityAttributes.ContentState {
    static let placeholder = RecordingActivityAttributes.ContentState(
        startedAt: .now,
        samples: [],
        title: "Recording in progress",
        elapsedText: "00:00"
    )
}
