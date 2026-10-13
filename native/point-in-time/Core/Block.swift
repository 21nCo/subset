import Foundation

/// Seconds spent in one app within a block.
public struct AppTime: Equatable, Sendable, Codable {
    public var bundleID: String
    public var appName: String
    public var seconds: Double

    public init(bundleID: String, appName: String, seconds: Double) {
        self.bundleID = bundleID
        self.appName = appName
        self.seconds = seconds
    }
}

/// A fixed three-minute bucket of wall-clock time. Every UTC offset in use is a multiple of 15 minutes, so buckets
/// aligned to the Unix epoch also start on local three-minute boundaries, including local midnight.
public struct Block: Equatable, Sendable {
    public static let length: TimeInterval = 180

    public var start: Date
    /// Recorded, non-excluded seconds in the bucket.
    public var activeSeconds: Double
    /// Seconds of excluded apps recorded as anonymous time.
    public var excludedSeconds: Double
    /// Per-app seconds, longest first.
    public var apps: [AppTime]
    /// The app with the most time, and the title and URL of its longest segment in this bucket.
    public var dominantBundleID: String?
    public var dominantAppName: String?
    public var dominantTitle: String?
    public var dominantURL: RedactedURL?

    public var end: Date { start.addingTimeInterval(Block.length) }

    public static func bucketStart(containing date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / length).rounded(.down) * length)
    }

    /// Bucket starts touched by any part of the given span; none for an empty or reversed span.
    public static func bucketStarts(from start: Date, to end: Date) -> [Date] {
        guard end > start else { return [] }
        var result: [Date] = []
        var bucket = bucketStart(containing: start)
        while bucket < end {
            result.append(bucket)
            bucket = bucket.addingTimeInterval(length)
        }
        return result
    }

    /// Rolls the overlapping parts of `segments` into the bucket starting at `start`. Returns nil when nothing was
    /// recorded in it. Ties between apps resolve by bundle ID so the result is deterministic.
    public static func rollUp(start: Date, segments: [Segment]) -> Block? {
        let end = start.addingTimeInterval(length)
        var excluded = 0.0
        var perApp: [String: AppTime] = [:]
        var longest: [String: (seconds: Double, segment: Segment)] = [:]
        for segment in segments {
            let overlap = min(segment.end, end).timeIntervalSince(max(segment.start, start))
            guard overlap > 0 else { continue }
            if segment.excluded {
                excluded += overlap
                continue
            }
            guard let bundleID = segment.bundleID else { continue }
            perApp[bundleID, default: AppTime(bundleID: bundleID, appName: segment.appName ?? bundleID, seconds: 0)].seconds += overlap
            if overlap > (longest[bundleID]?.seconds ?? 0) { longest[bundleID] = (overlap, segment) }
        }
        let apps = perApp.values.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.bundleID < $1.bundleID }
        let active = apps.reduce(0) { $0 + $1.seconds }
        guard active > 0 || excluded > 0 else { return nil }
        let dominant = apps.first.flatMap { longest[$0.bundleID]?.segment }
        return Block(start: start, activeSeconds: active, excludedSeconds: excluded, apps: apps,
                     dominantBundleID: dominant?.bundleID, dominantAppName: dominant?.appName,
                     dominantTitle: dominant?.windowTitle, dominantURL: dominant?.url)
    }
}
