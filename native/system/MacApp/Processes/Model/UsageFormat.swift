import Foundation
import SystemCore

/// Formats the window's figures in one locale, so tests can pin it. A missing value is "–", never zero.
public struct UsageFormat: Sendable {
    public let locale: Locale
    /// The user's home folder, shown as `~` in paths.
    public let home: String

    public init(locale: Locale = .current, home: String = NSHomeDirectory()) {
        self.locale = locale
        self.home = home
    }

    public func bytes(_ value: UInt64?) -> String {
        value.map { Int64(clamping: $0).formatted(.byteCount(style: .memory).locale(locale)) } ?? "–"
    }

    /// CPU percent, where 100 is one fully used logical core.
    public func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1)).locale(locale)) + "%" } ?? "–"
    }

    /// Nanojoules as joules.
    public func energy(_ nanojoules: UInt64?) -> String {
        nanojoules.map { (Double($0) / 1e9).formatted(.number.precision(.fractionLength(1)).locale(locale)) + " J" } ?? "–"
    }

    public func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(locale))
    }

    /// A path with the home folder shown as `~`.
    public func path(_ path: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A group figure: "≈" for an approximate sum, and how many members it leaves out.
    public func total<Value>(_ total: MetricTotal<Value>, _ format: (Value?) -> String) -> String {
        guard total.sum != nil else { return format(nil) }
        return (total.isApproximate ? "≈" : "") + format(total.sum)
    }

    /// Spoken form of a group figure, such as "about 2 GB, 3 of 10 processes not measured".
    public func spokenTotal<Value>(_ total: MetricTotal<Value>, _ format: (Value?) -> String) -> String {
        let value = total.sum == nil ? "not measured" : (total.isApproximate ? "about " : "") + format(total.sum)
        guard total.sum != nil, !total.isComplete else { return value }
        let count = total.measuredCount + total.unmeasuredCount
        return "\(value), \(total.unmeasuredCount) of \(count) processes not measured"
    }
}
