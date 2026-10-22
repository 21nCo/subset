import Foundation

/// What the `point-in-time` command reads besides its arguments: the clock, the time zone, where the store is, the
/// app's settings, and whether the app is running. The executable fills it in; tests supply their own.
public struct StatusEnvironment {
    public var now: Date
    public var timeZone: TimeZone
    /// The store's folder; nil when Application Support cannot be found.
    public var storeDirectory: URL?
    public var settings: StoredSettings
    /// Whether pointInTime is running; nil when it could not be told.
    public var appRunning: Bool?
    /// The enclosing app's version, nil outside an app bundle.
    public var version: String?

    public init(now: Date, timeZone: TimeZone, storeDirectory: URL?, settings: StoredSettings, appRunning: Bool?, version: String?) {
        self.now = now
        self.timeZone = timeZone
        self.storeDirectory = storeDirectory
        self.settings = settings
        self.appRunning = appRunning
        self.version = version
    }
}

/// `point-in-time status [--date YYYY-MM-DD] [--json] [--include-titles]` and `point-in-time --version`. It only reads:
/// the store through a read-only connection (`StoreSnapshot`) and the app's settings, and it opens no network
/// connection. JSON output follows `schemas/status-v1.schema.json`.
public enum StatusCommand {
    public static let schemaVersion = 1
    /// Apps, sites, and titles listed in each top list.
    public static let topCount = 10

    /// Exit codes; the README documents them.
    public enum ExitCode: Int32, Sendable {
        case ok = 0
        case internalError = 1
        case usage = 2
        case storeMissing = 3
        case newerSchema = 4
        case storeLocked = 5
        case storeUnreadable = 6
    }

    public struct Output: Equatable, Sendable {
        public var standardOutput: String
        public var standardError: String
        public var exitCode: ExitCode
    }

    public static let usage = """
        Usage: point-in-time status [--date YYYY-MM-DD] [--json] [--include-titles]
               point-in-time --version

        Prints a day's focus summary from pointInTime's local activity store. Reads only; never starts the app, changes
        data, or uses the network.

          --date YYYY-MM-DD   The day to summarize, in this Mac's time zone. Default: today.
          --json              Print JSON (schemaVersion 1) instead of text.
          --include-titles    Also list window titles and page paths. Off by default.

        """

    struct Options: Equatable {
        var date: DateComponents?
        var json = false
        var includeTitles = false
    }

    public static func run(_ arguments: [String], environment: StatusEnvironment) -> Output {
        switch arguments.first {
        case "--version", "-V":
            guard arguments.count == 1 else { return usageError("--version takes no arguments.") }
            return Output(standardOutput: "point-in-time \(environment.version ?? "development build (not in pointInTime.app)")\n",
                          standardError: "", exitCode: .ok)
        case "--help", "-h", "help":
            return Output(standardOutput: usage, standardError: "", exitCode: .ok)
        case "status":
            switch parse(Array(arguments.dropFirst())) {
            case .success(let options): return status(options, environment: environment)
            case .failure(let error): return usageError(error.message)
            }
        case nil: return usageError("Missing command.")
        case let other?: return usageError("Unknown command \"\(other)\".")
        }
    }

    struct UsageError: Error { var message: String }

    static func parse(_ arguments: [String]) -> Result<Options, UsageError> {
        var options = Options()
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--json": options.json = true
            case "--include-titles": options.includeTitles = true
            case "--date":
                guard let value = remaining.popFirst() else { return .failure(UsageError(message: "--date needs a value: YYYY-MM-DD.")) }
                guard let date = day(value) else { return .failure(UsageError(message: "--date must be a calendar date as YYYY-MM-DD.")) }
                options.date = date
            default:
                if argument.hasPrefix("--date="), let date = day(String(argument.dropFirst("--date=".count))) {
                    options.date = date
                } else {
                    return .failure(UsageError(message: argument.hasPrefix("--date=") ? "--date must be a calendar date as YYYY-MM-DD." : "Unknown option \"\(argument)\"."))
                }
            }
        }
        return .success(options)
    }

    /// `YYYY-MM-DD` as year, month, and day, only when that day exists in the Gregorian calendar.
    static func day(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), year >= 1 else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard components.isValidDate(in: calendar) else { return nil }
        return components
    }

    private static func usageError(_ message: String) -> Output {
        Output(standardOutput: "", standardError: "point-in-time: \(message)\n\n" + usage, exitCode: .usage)
    }

    static func status(_ options: Options, environment: StatusEnvironment) -> Output {
        let report = StatusReport.build(options: options, environment: environment)
        guard options.json else {
            return Output(standardOutput: report.text(), standardError: report.errors.map { "point-in-time: \($0.message)\n" }.joined(),
                          exitCode: report.exitCode)
        }
        return json(report.jsonObject(), exitCode: report.exitCode)
    }

    /// `object` as JSON with `exitCode`, or nothing on standard output and exit code 1 when it cannot be encoded.
    static func json(_ object: [String: Any], exitCode: ExitCode) -> Output {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return Output(standardOutput: "", standardError: "point-in-time: The status could not be encoded as JSON.\n", exitCode: .internalError)
        }
        return Output(standardOutput: String(decoding: data, as: UTF8.self) + "\n", standardError: "", exitCode: exitCode)
    }
}

/// One status answer: everything both outputs show.
struct StatusReport {
    struct Failure {
        var code: String
        var message: String
    }

    struct Drift {
        var episode: DriftEpisode
        var threshold: Int
        var state: String
    }

    var observedAt: Date
    var calendar: Calendar
    var day: DateInterval
    var isToday: Bool
    var version: String?
    var storeState: String
    var schemaVersion: Int?
    var snapshot: StoreSnapshot?
    var report: DayReport?
    var tracking: String
    var pausedUntil: Date?
    var appRunning: Bool?
    var provider: ProviderChoice
    var drift: Drift?
    var includeTitles: Bool
    var errors: [Failure]
    var exitCode: StatusCommand.ExitCode

    static func build(options: StatusCommand.Options, environment: StatusEnvironment) -> StatusReport {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = environment.timeZone
        let now = environment.now
        let anchor = options.date.flatMap { components -> Date? in
            var local = components
            local.hour = 12
            return calendar.date(from: local)
        } ?? now
        let day = ReportPeriod.day(containing: anchor, calendar: calendar)
        let isToday = day.contains(now) && now < day.end
        let settings = environment.settings
        let pausedUntil = settings.pausedUntil.flatMap { $0 > now ? $0 : nil }
        let tracking = !settings.onboardingCompleted ? "notSetUp" : !settings.trackingEnabled ? "off" : pausedUntil != nil ? "paused" : "on"
        var result = StatusReport(observedAt: now, calendar: calendar, day: day, isToday: isToday, version: environment.version,
                                  storeState: "ok", schemaVersion: nil, snapshot: nil, report: nil, tracking: tracking,
                                  pausedUntil: pausedUntil, appRunning: environment.appRunning, provider: settings.provider, drift: nil,
                                  includeTitles: options.includeTitles, errors: [], exitCode: .ok)
        guard let directory = environment.storeDirectory else {
            result.fail(.unreadable("Application Support could not be found."))
            return result
        }
        // Today also reads what the drift companion reads, back to the day before, so a session begun last evening is whole.
        let driftRange = DriftDetector.readRange(now: now, calendar: calendar)
        let from = isToday ? min(day.start, driftRange.lowerBound) : day.start
        let to = isToday ? max(day.end, driftRange.upperBound) : day.end
        let snapshot: StoreSnapshot
        do {
            snapshot = try StoreSnapshot.read(directory: directory, blocksFrom: from, to: to)
        } catch {
            result.fail(error)
            return result
        }
        result.snapshot = snapshot
        result.schemaVersion = snapshot.schemaVersion
        result.report = DayReport(day: day.start, blocks: snapshot.blocks, calendar: calendar)
        // The current drift is the companion's decision, from the blocks it reads: the day's totals may include blocks
        // starting after now (recorded before the clock was set back), which are not part of the current session. The
        // state it would keep (a stale offer forgotten) is used here and never saved.
        let driftBlocks = DriftDetector.blocksInReadRange(snapshot.blocks, now: now, calendar: calendar)
        let rule = settings.driftRule
        let (decision, companionState) = DriftDetector.decide(driftBlocks, readFrom: driftRange.lowerBound, now: now, rule: rule,
                                                              state: settings.companionState, calendar: calendar)
        if isToday, let episode = DriftDetector.episode(in: driftBlocks, now: now, rule: rule, state: companionState, calendar: calendar) {
            let state = switch decision {
            case .prompt: "notYetOffered"
            case .alreadyPrompted: "offered"
            case .suppressed: "suppressed"
            case .none: rule.enabled ? "belowThreshold" : "companionOff"
            }
            result.drift = Drift(episode: episode, threshold: rule.threshold, state: state)
        }
        return result
    }

    private mutating func fail(_ failure: StoreReadFailure) {
        let (state, code, exit): (String, String, StatusCommand.ExitCode) = switch failure {
        case .missing: ("missing", "store_missing", .storeMissing)
        case .newerSchema: ("newerSchema", "store_newer_schema", .newerSchema)
        case .olderSchema: ("olderSchema", "store_older_schema", .storeUnreadable)
        case .locked: ("locked", "store_locked", .storeLocked)
        case .unreadable: ("unreadable", "store_unreadable", .storeUnreadable)
        }
        if case .newerSchema(let found, _) = failure { schemaVersion = found }
        if case .olderSchema(let found, _) = failure { schemaVersion = found }
        storeState = state
        errors.append(Failure(code: code, message: failure.message))
        exitCode = exit
    }

    // MARK: JSON

    func jsonObject() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.timeZone = calendar.timeZone
        iso.formatOptions = [.withInternetDateTime]
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        func time(_ date: Date?) -> Any { orNull(date.map { iso.string(from: $0) }) }
        func seconds(_ value: Double) -> Int { Int(value.rounded()) }
        let parts = calendar.dateComponents([.year, .month, .day], from: day.start)
        let totals = report?.totals
        var object: [String: Any] = [
            "schemaVersion": StatusCommand.schemaVersion,
            "command": "status",
            "version": orNull(version),
            "observedAt": time(observedAt),
            "date": String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
            "timeZone": calendar.timeZone.identifier,
            "day": ["start": time(day.start), "end": time(day.end), "isToday": isToday],
            "store": ["state": storeState, "schemaVersion": orNull(schemaVersion)],
            "freshness": ["lastSegmentEnd": time(snapshot?.latestSegmentEnd), "lastClassifiedAt": time(snapshot?.lastClassified)],
            // Paused until the user resumes has no end.
            "tracking": ["state": tracking, "pausedUntil": time(pausedUntil == .distantFuture ? nil : pausedUntil), "appRunning": orNull(appRunning)],
            "classification": ["provider": provider.statusName, "pending": orNull(report?.pendingCount),
                               "failed": orNull(report?.failedCount)],
            "totals": orNull(totals.map { totals -> Any in
                ["focus": seconds(totals.focus), "neutral": seconds(totals.neutral), "drift": seconds(totals.drift),
                 "unclassified": seconds(totals.unclassified), "excluded": seconds(totals.excluded),
                 "classified": seconds(totals.classified), "recorded": seconds(totals.recorded)]
            }),
            "focusPercent": orNull(totals?.focusShare.map { Int(($0 * 100).rounded()) }),
            "topApps": (report?.apps ?? []).prefix(StatusCommand.topCount).map {
                ["bundleID": $0.id, "name": $0.name, "seconds": seconds($0.seconds)] as [String: Any]
            },
            "topHosts": (report?.hosts ?? []).prefix(StatusCommand.topCount).map { ["host": $0.id, "seconds": seconds($0.seconds)] as [String: Any] },
            "currentDrift": orNull(drift.map { drift -> Any in
                ["start": time(drift.episode.start), "end": time(drift.episode.end), "driftBlocks": drift.episode.blockStarts.count,
                 "threshold": drift.threshold, "state": drift.state]
            }),
            "titles": NSNull(),
            "errors": errors.map { ["code": $0.code, "message": $0.message] }
        ]
        if includeTitles {
            object["titles"] = titles().map {
                ["bundleID": $0.bundleID, "app": $0.app, "title": orNull($0.title), "url": orNull($0.url), "seconds": seconds($0.seconds)] as [String: Any]
            }
        }
        return object
    }

    struct TitleTotal {
        var bundleID: String
        var app: String
        var title: String?
        var url: String?
        var seconds: Double
    }

    /// Per window title and page: the time of each block's main app in that block, for the title and page of its longest
    /// segment, longest first. Only with `--include-titles`.
    func titles() -> [TitleTotal] {
        var totals: [String: TitleTotal] = [:]
        for block in report?.blocks ?? [] {
            guard let bundleID = block.dominantBundleID, block.dominantTitle != nil || block.dominantURL != nil,
                  let main = block.apps.first(where: { $0.bundleID == bundleID }) else { continue }
            let url = block.dominantURL?.string
            let key = [bundleID, block.dominantTitle ?? "", url ?? ""].joined(separator: "\u{0}")
            totals[key, default: TitleTotal(bundleID: bundleID, app: main.appName, title: block.dominantTitle, url: url, seconds: 0)].seconds += main.seconds
        }
        return Array(totals.values.sorted {
            $0.seconds != $1.seconds ? $0.seconds > $1.seconds : ($0.bundleID, $0.title ?? "", $0.url ?? "") < ($1.bundleID, $1.title ?? "", $1.url ?? "")
        }.prefix(StatusCommand.topCount))
    }

    // MARK: Text

    func text() -> String {
        let locale = Locale.autoupdatingCurrent
        func time(_ date: Date) -> String {
            calendar.isDate(date, inSameDayAs: observedAt) ? ReportText.time(date, calendar: calendar, locale: locale)
                : date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        }
        let dayName = day.start.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        var lines = ["pointInTime, \(dayName)\(isToday ? " (today)" : "") in \(calendar.timeZone.identifier)"]
        let trackingText = switch tracking {
        case "notSetUp": "not set up"
        case "paused": pausedUntil == .distantFuture ? "paused until resumed" : "paused until \(pausedUntil.map(time) ?? "")"
        default: tracking
        }
        let running = appRunning.map { $0 ? ", app running" : ", app not running" } ?? ""
        lines.append("Tracking: \(trackingText)\(running). Classification: \(provider == .off ? "off" : provider.statusName)"
                     + (report.map { ", \($0.pendingCount) pending, \($0.failedCount) failed" } ?? "") + ".")
        if let report {
            lines.append(ReportText.totals(report.totals))
            func list(_ totals: [UsageTotal]) -> String {
                totals.prefix(5).map { "\($0.name) \(ReportText.duration($0.seconds))" }.joined(separator: ", ")
            }
            if !report.apps.isEmpty { lines.append("Top apps: " + list(report.apps) + ".") }
            if !report.hosts.isEmpty { lines.append("Top sites: " + list(report.hosts) + ".") }
            if includeTitles {
                for title in titles().prefix(5) {
                    lines.append("  \(title.app): \([title.title, title.url].compactMap { $0 }.joined(separator: " — ")) (\(ReportText.duration(title.seconds)))")
                }
            }
        }
        if let drift {
            let count = drift.episode.blockStarts.count
            lines.append("Drift: \(count) drift block\(count == 1 ? "" : "s") since \(time(drift.episode.start)) (\(drift.state)).")
        }
        if let snapshot {
            lines.append("Last activity: \(snapshot.latestSegmentEnd.map(time) ?? "none"). Last classified: \(snapshot.lastClassified.map(time) ?? "never").")
        }
        // Errors go to standard error.
        return lines.joined(separator: "\n") + "\n"
    }
}

extension ProviderChoice {
    /// The provider's name in status output; never a credential.
    var statusName: String {
        switch self {
        case .off: "off"
        case .openRouter: "openrouter"
        }
    }
}
